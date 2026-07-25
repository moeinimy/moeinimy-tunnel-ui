package service

import (
	"bufio"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/mhsanaei/3x-ui/v2/logger"

	"github.com/goccy/go-json"
	"golang.org/x/crypto/ssh"
)

// SshOutboundService manages operator-configured SSH egress tunnels. Each tunnel is an
// in-process ssh.Client plus a local SOCKS5 server on 127.0.0.1:SocksPort ("ssh -D"
// in-process); a synthesized native `socks` outbound (tag == cfg.Tag) in the Xray
// template routes egress into it. Reverse and routing target it purely by that tag, so
// no special-casing is needed - it is just a tagged socks outbound (the shipped WARP
// pattern). Config lives in the `sshOutbounds` setting; live state is the package-level
// sshOutMgr singleton (the boot path drives a zero-value service copy).
type SshOutboundService struct{}

// SshOutboundConfig is one tunnel. Secrets (Password/PrivateKey/Passphrase) are stored
// in the `sshOutbounds` setting (PermXraySettings-gated) and never echoed back by List.
type SshOutboundConfig struct {
	Tag        string `json:"tag" form:"tag"`
	Remark     string `json:"remark" form:"remark"`
	Address    string `json:"address" form:"address"`
	Port       int    `json:"port" form:"port"`
	Username   string `json:"username" form:"username"`
	AuthType   string `json:"authType" form:"authType"` // "password" | "privateKey"
	Password   string `json:"password" form:"password"`
	PrivateKey string `json:"privateKey" form:"privateKey"`
	Passphrase string `json:"passphrase" form:"passphrase"`
	KnownHost  string `json:"knownHost" form:"knownHost"` // SHA256/MD5 fingerprint pin; "" = TOFU
	SocksPort  int    `json:"socksPort" form:"socksPort"`
}

const sshOutboundsSettingKey = "sshOutbounds"

// --- Service API (thin; live state lives in sshOutMgr) ---

// InitSshOutbound raises every configured tunnel at panel boot.
func (s *SshOutboundService) InitSshOutbound() {
	for _, cfg := range s.load() {
		if err := sshOutMgr.start(cfg); err != nil {
			logger.Warning("ssh outbound: start failed for", cfg.Tag, ":", err)
		}
	}
}

// List returns the configured tunnels with secrets stripped (never leak the PEM/password).
func (s *SshOutboundService) List() []SshOutboundConfig {
	list := s.load()
	out := make([]SshOutboundConfig, len(list))
	for i, c := range list {
		c.Password = ""
		c.PrivateKey = ""
		c.Passphrase = ""
		out[i] = c
	}
	return out
}

// Save upserts a tunnel by tag and (re)starts it. A blank secret on edit keeps the
// stored one, so the UI can show an empty field without wiping the key.
func (s *SshOutboundService) Save(cfg SshOutboundConfig) error {
	cfg.Tag = strings.TrimSpace(cfg.Tag)
	cfg.Address = strings.TrimSpace(cfg.Address)
	if cfg.Tag == "" {
		return errors.New("tag is required")
	}
	if cfg.Address == "" {
		return errors.New("address is required")
	}
	if cfg.Port <= 0 {
		cfg.Port = 22
	}
	if cfg.SocksPort <= 0 || cfg.SocksPort > 65535 {
		return errors.New("local socks port must be between 1 and 65535")
	}

	all := s.load()
	prev, hadPrev := findTunnel(all, cfg.Tag)
	if hadPrev {
		if cfg.Password == "" {
			cfg.Password = prev.Password
		}
		if cfg.PrivateKey == "" {
			cfg.PrivateKey = prev.PrivateKey
		}
		if cfg.Passphrase == "" {
			cfg.Passphrase = prev.Passphrase
		}
	}

	out := make([]SshOutboundConfig, 0, len(all)+1)
	for _, c := range all {
		if c.Tag == cfg.Tag {
			continue // replaced below
		}
		if c.SocksPort == cfg.SocksPort {
			return fmt.Errorf("local socks port %d is already used by outbound %q", cfg.SocksPort, c.Tag)
		}
		out = append(out, c)
	}
	out = append(out, cfg)

	if err := s.persist(out); err != nil {
		return err
	}
	return sshOutMgr.start(cfg)
}

// Delete removes a tunnel by tag and stops it.
func (s *SshOutboundService) Delete(tag string) error {
	all := s.load()
	out := make([]SshOutboundConfig, 0, len(all))
	for _, c := range all {
		if c.Tag != tag {
			out = append(out, c)
		}
	}
	if err := s.persist(out); err != nil {
		return err
	}
	sshOutMgr.stop(tag)
	return nil
}

// Status reports whether a tunnel's SSH client is currently connected, plus its log.
func (s *SshOutboundService) Status(tag string) (bool, string) { return sshOutMgr.status(tag) }

// StopAll tears every tunnel down (panel shutdown).
func (s *SshOutboundService) StopAll() { sshOutMgr.stopAll() }

func (s *SshOutboundService) load() []SshOutboundConfig {
	var settingService SettingService
	raw, err := settingService.getString(sshOutboundsSettingKey)
	if err != nil || strings.TrimSpace(raw) == "" {
		return nil
	}
	var out []SshOutboundConfig
	if err := json.Unmarshal([]byte(raw), &out); err != nil {
		logger.Warning("ssh outbound: bad sshOutbounds setting:", err)
		return nil
	}
	return out
}

func (s *SshOutboundService) persist(list []SshOutboundConfig) error {
	var settingService SettingService
	b, err := json.Marshal(list)
	if err != nil {
		return err
	}
	return settingService.setString(sshOutboundsSettingKey, string(b))
}

func findTunnel(list []SshOutboundConfig, tag string) (SshOutboundConfig, bool) {
	for _, c := range list {
		if c.Tag == tag {
			return c, true
		}
	}
	return SshOutboundConfig{}, false
}

// --- Live state: the tunnel manager ---

var sshOutMgr = newSshOutManager()

func newSshOutManager() *sshOutManager {
	return &sshOutManager{tunnels: map[string]*sshTunnel{}}
}

type sshOutManager struct {
	mu      sync.Mutex
	tunnels map[string]*sshTunnel // keyed by cfg.Tag
}

type sshTunnel struct {
	cfg     SshOutboundConfig
	ln      net.Listener // local SOCKS5 listener; stays bound across reconnects
	log     *procLog     // procmgr.go ring buffer, reused for the Logs viewer
	gen     atomic.Int64 // bumped on stop/restart; loops compare to exit cleanly
	client  atomic.Pointer[ssh.Client]
	closing atomic.Bool
}

// start binds the local SOCKS5 listener once, then runs a supervisor that keeps an
// ssh.Client dialed with capped backoff. The listener persists across reconnects so the
// Xray socks outbound never sees the port vanish (CONNECTs fail transiently while
// reconnecting rather than the outbound looking misconfigured). Replaces any existing
// tunnel for the same tag.
func (m *sshOutManager) start(cfg SshOutboundConfig) error {
	m.stop(cfg.Tag)
	ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", cfg.SocksPort))
	if err != nil {
		return err
	}
	t := &sshTunnel{cfg: cfg, ln: ln, log: &procLog{}}
	m.mu.Lock()
	m.tunnels[cfg.Tag] = t
	m.mu.Unlock()
	go t.serveSocks()
	go t.supervise()
	return nil
}

func (m *sshOutManager) stop(tag string) {
	m.mu.Lock()
	t := m.tunnels[tag]
	delete(m.tunnels, tag)
	m.mu.Unlock()
	if t == nil {
		return
	}
	t.closing.Store(true)
	t.gen.Add(1)
	if t.ln != nil {
		_ = t.ln.Close() // unblocks the accept loop
	}
	if cl := t.client.Load(); cl != nil {
		_ = cl.Close() // unblocks supervise()'s cl.Wait()
	}
}

func (m *sshOutManager) stopAll() {
	m.mu.Lock()
	tags := make([]string, 0, len(m.tunnels))
	for tag := range m.tunnels {
		tags = append(tags, tag)
	}
	m.mu.Unlock()
	for _, tag := range tags {
		m.stop(tag)
	}
}

func (m *sshOutManager) status(tag string) (bool, string) {
	m.mu.Lock()
	t := m.tunnels[tag]
	m.mu.Unlock()
	if t == nil {
		return false, ""
	}
	return t.client.Load() != nil, t.log.String()
}

// supervise dials (and redials) the SSH server, keeping t.client populated while up.
func (t *sshTunnel) supervise() {
	gen := t.gen.Load()
	backoff := time.Second
	for !t.closing.Load() && t.gen.Load() == gen {
		cl, err := ssh.Dial("tcp", net.JoinHostPort(t.cfg.Address, strconv.Itoa(t.cfg.Port)), t.clientConfig())
		if err != nil {
			t.log.add("dial: " + err.Error())
			if !t.sleep(backoff, gen) {
				return
			}
			if backoff *= 2; backoff > 30*time.Second {
				backoff = 30 * time.Second
			}
			continue
		}
		backoff = time.Second
		t.client.Store(cl)
		t.log.add("connected to " + t.cfg.Address)
		cl.Wait() // blocks until the SSH connection drops
		t.client.Store(nil)
		if !t.closing.Load() && t.gen.Load() == gen {
			t.log.add("disconnected, reconnecting")
		}
	}
}

// sleep waits d, but wakes early (returning false) if the tunnel is stopped/restarted.
func (t *sshTunnel) sleep(d time.Duration, gen int64) bool {
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if t.closing.Load() || t.gen.Load() != gen {
			return false
		}
		time.Sleep(100 * time.Millisecond)
	}
	return !t.closing.Load() && t.gen.Load() == gen
}

// clientConfig builds the ssh.ClientConfig from the tunnel's auth settings. The host key
// is pinned to cfg.KnownHost when set (SHA256 or legacy MD5 fingerprint), else TOFU-logged
// - never InsecureIgnoreHostKey silently.
func (t *sshTunnel) clientConfig() *ssh.ClientConfig {
	cfg := &ssh.ClientConfig{
		User:    t.cfg.Username,
		Timeout: 15 * time.Second,
	}
	switch t.cfg.AuthType {
	case "privateKey":
		var signer ssh.Signer
		var err error
		if strings.TrimSpace(t.cfg.Passphrase) != "" {
			signer, err = ssh.ParsePrivateKeyWithPassphrase([]byte(t.cfg.PrivateKey), []byte(t.cfg.Passphrase))
		} else {
			signer, err = ssh.ParsePrivateKey([]byte(t.cfg.PrivateKey))
		}
		if err != nil {
			t.log.add("private key error: " + err.Error())
		} else {
			cfg.Auth = []ssh.AuthMethod{ssh.PublicKeys(signer)}
		}
	default:
		cfg.Auth = []ssh.AuthMethod{ssh.Password(t.cfg.Password)}
	}
	if pin := strings.TrimSpace(t.cfg.KnownHost); pin != "" {
		cfg.HostKeyCallback = func(hostname string, remote net.Addr, key ssh.PublicKey) error {
			if ssh.FingerprintSHA256(key) == pin || ssh.FingerprintLegacyMD5(key) == pin {
				return nil
			}
			return fmt.Errorf("host key mismatch (got %s)", ssh.FingerprintSHA256(key))
		}
	} else {
		cfg.HostKeyCallback = func(hostname string, remote net.Addr, key ssh.PublicKey) error {
			t.log.add("host key (TOFU) " + ssh.FingerprintSHA256(key) + " - paste it as the pin to enforce")
			return nil
		}
	}
	return cfg
}

func (t *sshTunnel) serveSocks() {
	for {
		conn, err := t.ln.Accept()
		if err != nil {
			return // listener closed on stop
		}
		go t.handleSocks(conn)
	}
}

// handleSocks negotiates a minimal SOCKS5 CONNECT (no auth; loopback only) and relays it
// over a direct-tcpip channel on the SSH client - the inverse of the inbound's
// handleDirectTCPIP. UDP ASSOCIATE is rejected (TCP-only for now).
func (t *sshTunnel) handleSocks(conn net.Conn) {
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(30 * time.Second)) // handshake window
	br := bufio.NewReader(conn)

	// Greeting: VER, NMETHODS, METHODS...
	head := make([]byte, 2)
	if _, err := io.ReadFull(br, head); err != nil || head[0] != 0x05 {
		return
	}
	methods := make([]byte, int(head[1]))
	if _, err := io.ReadFull(br, methods); err != nil {
		return
	}
	if _, err := conn.Write([]byte{0x05, 0x00}); err != nil { // no auth
		return
	}

	// Request: VER, CMD, RSV, ATYP, DST.ADDR, DST.PORT
	reqHead := make([]byte, 4)
	if _, err := io.ReadFull(br, reqHead); err != nil || reqHead[0] != 0x05 {
		return
	}
	host, err := socksReadAddr(br, reqHead[3])
	if err != nil {
		t.socksReply(conn, 0x08) // address type not supported
		return
	}
	portBuf := make([]byte, 2)
	if _, err := io.ReadFull(br, portBuf); err != nil {
		return
	}
	port := int(binary.BigEndian.Uint16(portBuf))

	if reqHead[1] != 0x01 { // CONNECT only
		t.socksReply(conn, 0x07) // command not supported
		return
	}

	client := t.client.Load()
	if client == nil {
		t.socksReply(conn, 0x04) // host unreachable (tunnel down / reconnecting)
		return
	}
	upstream, err := client.Dial("tcp", net.JoinHostPort(host, strconv.Itoa(port)))
	if err != nil {
		t.log.add("channel to " + host + ": " + err.Error())
		t.socksReply(conn, 0x05) // connection refused
		return
	}
	if err := t.socksReply(conn, 0x00); err != nil {
		upstream.Close()
		return
	}
	_ = conn.SetDeadline(time.Time{}) // clear handshake deadline for the relay

	done := make(chan struct{}, 2)
	go func() { _, _ = io.Copy(upstream, br); done <- struct{}{} }()
	go func() { _, _ = io.Copy(conn, upstream); done <- struct{}{} }()
	<-done
	conn.Close()
	upstream.Close()
	<-done
}

// socksReply writes a SOCKS5 reply with the given REP code and a 0.0.0.0:0 bound address.
func (t *sshTunnel) socksReply(conn net.Conn, rep byte) error {
	_, err := conn.Write([]byte{0x05, rep, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
	return err
}
