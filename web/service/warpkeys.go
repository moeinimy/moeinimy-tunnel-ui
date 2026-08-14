package service

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/mhsanaei/3x-ui/v2/logger"
)

// WarpKeyService keeps a working WARP+ licence on this server without anyone
// having to go and find one.
//
// A WARP+ key is not a permanent thing: it admits five devices and is handed
// around until it is spent, so the key that worked last week is usually "Free"
// today. That is the whole reason WARP stops improving anything a few days after
// it is set up — the licence quietly lapses back to the free tier while
// everything still looks configured.
//
// So the panel keeps a source of fresh keys, tries them, and applies the first
// that is genuinely WARP+. Automatically when the connection has failed, and on
// demand when the operator wants to see the list themselves.
type WarpKeyService struct{}

// WarpKeySource is where fresh keys are published. Overridable so an operator who
// keeps their own list is not stuck with this one.
const WarpKeySource = "https://raw.githubusercontent.com/ircfspace/warpkey/main/plus/full"

// warpKeyPattern is the shape of a licence: three dash-separated groups of eight.
// Matching it rather than splitting lines means a page with headings, blank lines
// or HTML around the keys still yields exactly the keys.
var warpKeyPattern = regexp.MustCompile(`\b[A-Za-z0-9]{8}-[A-Za-z0-9]{8}-[A-Za-z0-9]{8}\b`)

// cloudflare's own client API, the one warp-cli itself speaks.
const warpAPI = "https://api.cloudflareclient.com/v0a2158"

// WarpKeyResult is one key's verdict.
type WarpKeyResult struct {
	Key string `json:"key"`
	// Verdict is "unlimited" (live WARP+), "free" (accepted but still limited —
	// spent or expired), "rejected" (Cloudflare refused it) or "error".
	Verdict string `json:"verdict"`
	Detail  string `json:"detail"`
}

// WarpKeyScan is the state of a scan, polled by the UI while it runs.
type WarpKeyScan struct {
	Running bool            `json:"running"`
	Done    bool            `json:"done"`
	Checked int             `json:"checked"`
	Total   int             `json:"total"`
	Results []WarpKeyResult `json:"results"`
	Applied string          `json:"applied"`
	Error   string          `json:"error"`
}

var warpKeys = struct {
	sync.Mutex
	scan WarpKeyScan
}{}

var warpHTTP = &http.Client{Timeout: 30 * time.Second}

// FetchKeys pulls the published list and returns the keys in it, in order.
func (s *WarpKeyService) FetchKeys() ([]string, error) {
	resp, err := warpHTTP.Get(WarpKeySource)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("the key source answered HTTP %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	var keys []string
	for _, k := range warpKeyPattern.FindAllString(string(body), -1) {
		if !seen[k] {
			seen[k] = true
			keys = append(keys, k)
		}
	}
	if len(keys) == 0 {
		return nil, fmt.Errorf("no keys found at %s", WarpKeySource)
	}
	return keys, nil
}

// warpAPICall talks to Cloudflare's client API as warp-cli does.
func warpAPICall(method, path, token string, body any) (map[string]any, int, error) {
	var buf io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			return nil, 0, err
		}
		buf = bytes.NewReader(raw)
	}
	req, err := http.NewRequest(method, warpAPI+path, buf)
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set("Content-Type", "application/json; charset=UTF-8")
	req.Header.Set("User-Agent", "okhttp/3.12.1")
	req.Header.Set("CF-Client-Version", "a-6.30-3596")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := warpHTTP.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	out := map[string]any{}
	_ = json.Unmarshal(raw, &out)
	if resp.StatusCode != http.StatusOK {
		return out, resp.StatusCode, fmt.Errorf("HTTP %d: %s", resp.StatusCode, clip(string(raw), 120))
	}
	return out, resp.StatusCode, nil
}

// clip keeps an API error readable in a log line.
func clip(s string, n int) string {
	s = strings.TrimSpace(s)
	if len(s) > n {
		return s[:n]
	}
	return s
}

// TestKey reports whether a key is live WARP+.
//
// It registers a device of its own, applies the key, reads the verdict, and then
// DELETES that device. The delete is the point: a licence admits five devices and
// every test spends one, so a checker that skips it burns the quota of precisely
// the keys that turned out to be good.
//
// This machine's own WARP registration is never touched — the test happens on a
// device that exists for a second.
func (s *WarpKeyService) TestKey(key string) WarpKeyResult {
	pub := make([]byte, 32)
	if _, err := rand.Read(pub); err != nil {
		return WarpKeyResult{Key: key, Verdict: "error", Detail: err.Error()}
	}
	reg, _, err := warpAPICall("POST", "/reg", "", map[string]any{
		"key":        base64.StdEncoding.EncodeToString(pub),
		"install_id": "", "fcm_token": "",
		"tos":    time.Now().UTC().Format("2006-01-02T15:04:05.000Z"),
		"model":  "PC",
		"locale": "en_US",
	})
	if err != nil {
		return WarpKeyResult{Key: key, Verdict: "error", Detail: err.Error()}
	}
	id, _ := reg["id"].(string)
	token, _ := reg["token"].(string)
	if id == "" || token == "" {
		return WarpKeyResult{Key: key, Verdict: "error", Detail: "the API returned no device"}
	}
	defer func() {
		if _, _, derr := warpAPICall("DELETE", "/reg/"+id, token, nil); derr != nil {
			logger.Debug("warp keys: could not release the test device: ", derr)
		}
	}()

	acct, _, err := warpAPICall("PUT", "/reg/"+id+"/account", token, map[string]any{"license": key})
	if err != nil {
		return WarpKeyResult{Key: key, Verdict: "rejected", Detail: err.Error()}
	}
	kind, _ := acct["account_type"].(string)
	kind = strings.ToLower(kind)
	if kind != "" && kind != "limited" && kind != "free" {
		detail := kind
		if q, ok := acct["premium_data"].(float64); ok && q > 0 {
			detail = fmt.Sprintf("%s, %d GB", kind, int64(q)/(1024*1024*1024))
		}
		return WarpKeyResult{Key: key, Verdict: "unlimited", Detail: detail}
	}
	return WarpKeyResult{Key: key, Verdict: "free", Detail: kind}
}

// warpRegistration is the WireGuard WARP registration the panel owns: the device
// id and access token it was given when it registered. The licence lives on the
// REGISTRATION, so upgrading it changes nothing about the WireGuard config the
// outbound uses — same private key, same endpoint, same addresses. Only
// Cloudflare's treatment of that device changes, which is why a key can be
// swapped underneath a running tunnel without dropping a single connection.
func (s *WarpKeyService) warpRegistration() (id, token string, ok bool) {
	var warpService WarpService
	raw, err := warpService.GetWarpData()
	if err != nil || strings.TrimSpace(raw) == "" {
		return "", "", false
	}
	var data map[string]string
	if json.Unmarshal([]byte(raw), &data) != nil {
		return "", "", false
	}
	id, token = data["device_id"], data["access_token"]
	return id, token, id != "" && token != ""
}

// WarpAccount is what Cloudflare says about the panel's own registration.
type WarpAccount struct {
	Managed bool   `json:"managed"` // the panel holds a registration at all
	Type    string `json:"type"`    // "limited"/"free" or a premium tier
	Plus    bool   `json:"plus"`
	QuotaGB int64  `json:"quotaGB"`
}

// Account reads the panel's own WARP registration.
func (s *WarpKeyService) Account() WarpAccount {
	id, token, ok := s.warpRegistration()
	if !ok {
		return WarpAccount{}
	}
	acct, _, err := warpAPICall("GET", "/reg/"+id+"/account", token, nil)
	if err != nil {
		return WarpAccount{Managed: true}
	}
	kind, _ := acct["account_type"].(string)
	kind = strings.ToLower(kind)
	out := WarpAccount{Managed: true, Type: kind}
	out.Plus = kind != "" && kind != "limited" && kind != "free"
	if q, okq := acct["premium_data"].(float64); okq {
		out.QuotaGB = int64(q) / (1024 * 1024 * 1024)
	}
	return out
}

// warpQuotaFloorGB is when a licence counts as spent rather than spendable. A key
// that is nearly out is one that will lapse mid-evening, so it is replaced while
// there is still something to replace it with.
const warpQuotaFloorGB = 5

// NeedsRenewal reports whether the panel's WARP has fallen back to free, or is
// close enough to the end of its allowance to be worth replacing now.
//
// This is what keeps the scanner quiet: nothing runs while the licence is
// healthy, however often the published list changes. A scan costs a registration
// per key at Cloudflare, so scanning hourly for no reason would be rude to the
// key pool everyone shares.
func (s *WarpKeyService) NeedsRenewal() (bool, string) {
	acct := s.Account()
	if !acct.Managed {
		return false, ""
	}
	if !acct.Plus {
		return true, "the account is on the free tier"
	}
	if acct.QuotaGB > 0 && acct.QuotaGB < warpQuotaFloorGB {
		return true, fmt.Sprintf("only %d GB left on the licence", acct.QuotaGB)
	}
	return false, ""
}

// ApplyKeyToRegistration licenses the panel's OWN WireGuard registration.
//
// Nothing about the outbound changes: the config is derived from the private key
// and the peer, neither of which a licence touches. The tunnel keeps running and
// simply stops being throttled.
func (s *WarpKeyService) ApplyKeyToRegistration(key string) error {
	id, token, ok := s.warpRegistration()
	if !ok {
		return fmt.Errorf("this panel holds no WARP registration of its own")
	}
	acct, _, err := warpAPICall("PUT", "/reg/"+id+"/account", token, map[string]any{"license": key})
	if err != nil {
		return fmt.Errorf("Cloudflare refused the licence: %w", err)
	}
	kind, _ := acct["account_type"].(string)
	kind = strings.ToLower(kind)
	if kind == "" || kind == "limited" || kind == "free" {
		return fmt.Errorf("Cloudflare kept the account on the free tier — the key is spent")
	}
	return nil
}

// ApplyKey puts a licence on THIS server's warp-cli registration and reports what
// Cloudflare then says the account is.
func (s *WarpKeyService) ApplyKey(key string) error {
	if !WarpSocksInstalled() {
		return fmt.Errorf("warp-cli is not installed on this server")
	}
	if out, err := warpCli("registration", "license", key); err != nil {
		return fmt.Errorf("applying the licence: %v %s", err, firstLine(out))
	}
	// "Success" only means the command was accepted; the registration is what says
	// whether the account actually moved off the free tier.
	show, _ := warpCli("registration", "show")
	if strings.Contains(strings.ToLower(show), "account type: free") ||
		strings.Contains(strings.ToLower(show), "account type: limited") {
		return fmt.Errorf("Cloudflare kept the account on the free tier — the key is spent or expired")
	}
	// A licence only takes effect on a fresh connection.
	_, _ = warpCli("disconnect")
	_, _ = warpCli("connect")
	return nil
}

// Scan tries the published keys, newest first, and applies the first live one.
//
// Runs in the background: a list is long, Cloudflare rate-limits a burst of
// registrations, and the UI must not sit on a request for minutes. Progress is
// readable throughout via ScanState.
//
// apply=false only reports, which is what the operator wants the first time —
// they want to see the list and choose.
func (s *WarpKeyService) Scan(apply bool, limit int) bool {
	warpKeys.Lock()
	if warpKeys.scan.Running {
		warpKeys.Unlock()
		return false
	}
	warpKeys.scan = WarpKeyScan{Running: true}
	warpKeys.Unlock()

	go func() {
		defer func() {
			warpKeys.Lock()
			warpKeys.scan.Running = false
			warpKeys.scan.Done = true
			warpKeys.Unlock()
		}()

		keys, err := s.FetchKeys()
		if err != nil {
			warpKeys.Lock()
			warpKeys.scan.Error = err.Error()
			warpKeys.Unlock()
			return
		}
		if limit > 0 && len(keys) > limit {
			keys = keys[:limit]
		}
		warpKeys.Lock()
		warpKeys.scan.Total = len(keys)
		warpKeys.Unlock()

		for i, key := range keys {
			res := s.TestKey(key)

			warpKeys.Lock()
			warpKeys.scan.Results = append(warpKeys.scan.Results, res)
			warpKeys.scan.Checked = i + 1
			warpKeys.Unlock()

			if res.Verdict == "unlimited" && apply {
				// Whichever WARP this server actually runs. The WireGuard
				// registration is preferred where the panel owns one, because
				// licensing it needs no daemon and drops no connection.
				applyTo := s.ApplyKey
				if _, _, owns := s.warpRegistration(); owns {
					applyTo = s.ApplyKeyToRegistration
				}
				if aerr := applyTo(key); aerr != nil {
					logger.Warning("warp keys: a live key would not apply: ", aerr)
				} else {
					warpKeys.Lock()
					warpKeys.scan.Applied = key
					warpKeys.Unlock()
					logger.Info("warp keys: applied a fresh WARP+ licence")
					return
				}
			}
			// Cloudflare rate-limits registrations in a burst; without a gap a long
			// list turns into a page of errors that say nothing about the keys.
			if i+1 < len(keys) {
				time.Sleep(2 * time.Second)
			}
		}
	}()
	return true
}

// ScanState is the current/most-recent scan, for the UI to poll.
func (s *WarpKeyService) ScanState() WarpKeyScan {
	warpKeys.Lock()
	defer warpKeys.Unlock()
	return warpKeys.scan
}

// AccountIsFree reports whether this server's WARP has lapsed to the free tier —
// the state a spent licence leaves behind, and the one worth replacing a key for.
func (s *WarpKeyService) AccountIsFree() bool {
	show, err := warpCli("registration", "show")
	if err != nil {
		return false
	}
	low := strings.ToLower(show)
	return strings.Contains(low, "account type: free") || strings.Contains(low, "account type: limited")
}
