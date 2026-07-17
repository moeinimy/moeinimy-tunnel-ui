package controller

import (
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"regexp"
	"strings"

	"github.com/mhsanaei/3x-ui/v2/logger"
	"github.com/mhsanaei/3x-ui/v2/web/service"

	"github.com/gin-gonic/gin"
)

// validTunnelName mirrors the charset tunnelctl itself accepts.
var tunnelNamePattern = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$`)

func validTunnelName(s string) bool { return tunnelNamePattern.MatchString(s) }

// bindData decodes a structured payload from the panel UI.
//
// The panel's axios is globally configured to form-urlencode EVERY request body
// (web/assets/js/axios-init.js sets x-www-form-urlencoded and Qs.stringify's the
// data), so a JSON body never arrives as JSON from the browser — binding JSON
// directly fails with "invalid character 'i' in literal false". The panel's own
// convention (see inbound.go) is to send complex payloads as a JSON string in a
// single "data" form field, which is what we read here. Raw JSON is still
// accepted so API/curl clients keep working.
func bindData(c *gin.Context, out any) error {
	if strings.HasPrefix(c.ContentType(), "application/json") {
		return c.ShouldBindJSON(out)
	}
	raw := c.PostForm("data")
	if raw == "" {
		return errors.New("missing 'data' payload")
	}
	return json.Unmarshal([]byte(raw), out)
}

// nodeRepo is the GitHub repo the Iran-node one-liner is fetched from.
const nodeRepo = "moeinimy/moeinimy-tunnel-ui"

// nodeExecAllowlist is the set of tunnelctl subcommands the panel may run on a
// remote node. Mirrors the node agent's own allowlist — read + safe control
// only; nothing that could be abused for arbitrary execution.
var nodeExecAllowlist = map[string]bool{
	"json": true, "list": true, "names": true, "fields": true,
	"start": true, "stop": true, "restart": true, "enable": true,
	"disable": true, "status": true, "logs": true, "create": true,
	"set": true, "remove": true, "optimize": true,
}

// TunnelController exposes tunnel management (the vendored tunnel-manager) to
// the panel UI under /panel/tunnel. It only forwards to TunnelService, which
// shells out to `tunnelctl`; no tunnel state lives in the x-ui database.
type TunnelController struct {
	tunnelService service.TunnelService
	nodeService   service.NodeService
}

// NewTunnelController creates a new TunnelController and initializes its routes.
func NewTunnelController(g *gin.RouterGroup) *TunnelController {
	a := &TunnelController{}
	a.initRouter(g)
	return a
}

func (a *TunnelController) initRouter(g *gin.RouterGroup) {
	g = g.Group("/tunnel")

	// Reads
	g.GET("/meta", a.meta)
	g.GET("/list", a.list)
	g.GET("/protocols", a.protocols)
	g.GET("/schema", a.schema)
	g.GET("/tunnel/:name", a.tunnel)
	g.GET("/fields/:name", a.fields)
	g.GET("/logs/:name", a.logs)

	// Lifecycle / control
	g.POST("/create", a.create)
	g.POST("/remove/:name", a.remove)
	g.POST("/start/:name", a.start)
	g.POST("/stop/:name", a.stop)
	g.POST("/restart/:name", a.restart)
	g.POST("/enable/:name", a.enable)
	g.POST("/disable/:name", a.disable)
	g.POST("/set/:name", a.set)
	g.POST("/optimize/:action", a.optimize)
	g.POST("/update", a.update)

	// One form -> both sides of a tunnel (foreign here + Iran on the node).
	g.POST("/pair", a.createPair)

	// Iran-node management (login-protected). The node's own poll/result
	// endpoints are token-authed and registered separately in web.go.
	g.GET("/nodes", a.nodesList)
	g.POST("/nodes", a.nodeCreate)
	g.POST("/nodes/:id/remove", a.nodeRemove)
	g.POST("/nodes/:id/exec", a.nodeExec)
}

// meta returns backend availability plus panel-level metadata (version, role,
// counts, protocols, optimize state). When the backend is not installed the
// UI shows a setup card instead of erroring.
func (a *TunnelController) meta(c *gin.Context) {
	if !a.tunnelService.Installed() {
		jsonObj(c, gin.H{"installed": false}, nil)
		return
	}
	raw, err := a.tunnelService.Meta()
	if err != nil {
		jsonMsg(c, I18nWeb(c, "pages.tunnel.toasts.loadFailed"), err)
		return
	}
	jsonObj(c, gin.H{"installed": true, "meta": raw}, nil)
}

func (a *TunnelController) list(c *gin.Context) {
	raw, err := a.tunnelService.List()
	if err != nil {
		jsonMsg(c, I18nWeb(c, "pages.tunnel.toasts.loadFailed"), err)
		return
	}
	jsonObj(c, raw, nil)
}

func (a *TunnelController) protocols(c *gin.Context) {
	raw, err := a.tunnelService.Protocols()
	if err != nil {
		jsonMsg(c, I18nWeb(c, "pages.tunnel.toasts.loadFailed"), err)
		return
	}
	jsonObj(c, raw, nil)
}

// schema returns the per-protocol form definition the UI renders its create form
// from, so the panel asks exactly what the CLI wizard asks.
func (a *TunnelController) schema(c *gin.Context) {
	raw, err := a.tunnelService.Schema()
	if err != nil {
		jsonMsg(c, I18nWeb(c, "pages.tunnel.toasts.loadFailed"), err)
		return
	}
	jsonObj(c, raw, nil)
}

func (a *TunnelController) tunnel(c *gin.Context) {
	raw, err := a.tunnelService.Tunnel(c.Param("name"))
	if err != nil {
		jsonMsg(c, I18nWeb(c, "pages.tunnel.toasts.loadFailed"), err)
		return
	}
	jsonObj(c, raw, nil)
}

func (a *TunnelController) fields(c *gin.Context) {
	raw, err := a.tunnelService.Fields(c.Param("name"))
	if err != nil {
		jsonMsg(c, I18nWeb(c, "pages.tunnel.toasts.loadFailed"), err)
		return
	}
	jsonObj(c, raw, nil)
}

func (a *TunnelController) logs(c *gin.Context) {
	out, err := a.tunnelService.Logs(c.Param("name"))
	if err != nil {
		jsonMsg(c, I18nWeb(c, "pages.tunnel.toasts.loadFailed"), err)
		return
	}
	jsonObj(c, out, nil)
}

// createRequest is the JSON body for POST /create: an explicit field map the
// UI form builds (NAME, PROTOCOL, ROLE, REMOTE_IP, and protocol-specific keys).
type createRequest struct {
	Fields map[string]string `json:"fields"`
}

func (a *TunnelController) create(c *gin.Context) {
	var req createRequest
	if err := bindData(c, &req); err != nil {
		jsonMsg(c, I18nWeb(c, "pages.tunnel.toasts.createFailed"), err)
		return
	}
	err := a.tunnelService.Create(req.Fields)
	jsonMsg(c, I18nWeb(c, "pages.tunnel.toasts.created"), err)
}

// remove deletes the tunnel here AND on every online node carrying one by the
// same name. A tunnel is a pair created under one name, so removing only the
// local half leaves the node's half running, holding its port and crash-looping
// against an endpoint that no longer exists — which is how a node ends up full
// of dead tunnels blocking the ports of every new one.
func (a *TunnelController) remove(c *gin.Context) {
	name := c.Param("name")
	err := a.tunnelService.Remove(name)
	msg := I18nWeb(c, "pages.tunnel.toasts.removed")
	// Mirror to the nodes even if the local half was already gone, so a
	// half-removed pair can still be cleaned up from the panel.
	nodes := a.nodeService.RemoveTunnelEverywhere(name)
	if len(nodes) > 0 {
		msg += " — " + I18nWeb(c, "pages.tunnel.toasts.removedOnNodes") + ": " + strings.Join(nodes, ", ")
		// The local half being absent is not a failure when a node still had one
		// and we cleaned it: reporting the local "No such tunnel" as an error made
		// the panel show red for a removal that had actually worked, so the tunnel
		// looked undeletable while it was already gone.
		err = nil
	}
	jsonMsg(c, msg, err)
}

func (a *TunnelController) start(c *gin.Context) {
	err := a.tunnelService.Start(c.Param("name"))
	jsonMsg(c, I18nWeb(c, "pages.tunnel.toasts.started"), err)
}

func (a *TunnelController) stop(c *gin.Context) {
	err := a.tunnelService.Stop(c.Param("name"))
	jsonMsg(c, I18nWeb(c, "pages.tunnel.toasts.stopped"), err)
}

func (a *TunnelController) restart(c *gin.Context) {
	err := a.tunnelService.Restart(c.Param("name"))
	jsonMsg(c, I18nWeb(c, "pages.tunnel.toasts.restarted"), err)
}

func (a *TunnelController) enable(c *gin.Context) {
	err := a.tunnelService.Enable(c.Param("name"))
	jsonMsg(c, I18nWeb(c, "pages.tunnel.toasts.enabled"), err)
}

func (a *TunnelController) disable(c *gin.Context) {
	err := a.tunnelService.Disable(c.Param("name"))
	jsonMsg(c, I18nWeb(c, "pages.tunnel.toasts.disabled"), err)
}

// setFieldReq is the body for POST /set/:name. Tagged for both JSON and form
// binding so the UI can send either.
type setFieldReq struct {
	Key   string `json:"key" form:"key"`
	Value string `json:"value" form:"value"`
}

func (a *TunnelController) set(c *gin.Context) {
	var req setFieldReq
	if err := c.ShouldBind(&req); err != nil {
		jsonMsg(c, I18nWeb(c, "pages.tunnel.toasts.saveFailed"), err)
		return
	}
	err := a.tunnelService.SetField(c.Param("name"), req.Key, req.Value)
	jsonMsg(c, I18nWeb(c, "pages.tunnel.toasts.saved"), err)
}

func (a *TunnelController) optimize(c *gin.Context) {
	err := a.tunnelService.Optimize(c.Param("action"))
	jsonMsg(c, I18nWeb(c, "pages.tunnel.toasts.saved"), err)
}

// update pulls the latest tunnel backend from GitHub and reinstalls it, so the
// operator never needs SSH for a backend upgrade. Returns the version before and
// after plus the log, which the UI shows.
func (a *TunnelController) update(c *gin.Context) {
	before, _ := a.tunnelService.Version()
	log, err := a.tunnelService.Update()
	if err != nil {
		jsonMsg(c, I18nWeb(c, "pages.tunnel.toasts.updateFailed")+": "+log, err)
		return
	}
	after, _ := a.tunnelService.Version()
	jsonObj(c, gin.H{"before": before, "after": after, "log": log,
		"changed": before != after}, nil)
}

// panelHost returns the address the caller reached this panel on (no port) —
// what the Iran side must dial back to.
func panelHost(c *gin.Context) string {
	h := c.Request.Host
	if host, _, err := net.SplitHostPort(h); err == nil {
		h = host
	}
	return h
}

type pairReq struct {
	NodeID   string            `json:"nodeId"`
	Name     string            `json:"name"`
	Protocol string            `json:"protocol"`
	Fields   map[string]string `json:"fields"`
}

// createPair builds a complete tunnel across both servers from one form: it
// pushes the Iran side to the node and creates the foreign side here, sharing a
// secret and pointing each end at the other. If either half fails the other is
// rolled back, so the panel never leaves a tunnel with a missing end.
func (a *TunnelController) createPair(c *gin.Context) {
	var req pairReq
	if err := bindData(c, &req); err != nil {
		jsonMsg(c, I18nWeb(c, "pages.tunnel.toasts.createFailed"), err)
		return
	}
	if !validTunnelName(req.Name) {
		jsonMsg(c, I18nWeb(c, "pages.tunnel.toasts.createFailed"), errors.New("invalid tunnel name"))
		return
	}

	// The schema declares which side each field belongs on; without it a
	// side-specific option would be applied to both hosts.
	schemaRaw, schemaErr := a.tunnelService.Schema()
	if schemaErr != nil {
		jsonMsg(c, I18nWeb(c, "pages.tunnel.toasts.createFailed"), schemaErr)
		return
	}
	ff, inf, online, err := a.nodeService.BuildPair(req.NodeID, req.Name, req.Protocol, req.Fields, panelHost(c), schemaRaw)
	if err != nil {
		jsonMsg(c, I18nWeb(c, "pages.tunnel.toasts.createFailed"), err)
		return
	}
	if !online {
		jsonMsg(c, I18nWeb(c, "pages.tunnel.toasts.createFailed"),
			errors.New(I18nWeb(c, "pages.tunnel.node.execFailed")))
		return
	}

	// Iran side first: if the far end can't be built there's nothing to clean up
	// here yet.
	args := []string{"create"}
	for k, v := range inf {
		args = append(args, k+"="+v)
	}
	if out, err := a.nodeService.Exec(req.NodeID, args); err != nil {
		jsonMsg(c, strings.TrimSpace(out), err)
		return
	}

	// Foreign side. On failure, remove the Iran half we just made.
	if err := a.tunnelService.Create(ff); err != nil {
		if _, rbErr := a.nodeService.Exec(req.NodeID, []string{"remove", req.Name}); rbErr != nil {
			logger.Warning("pair rollback: could not remove Iran side of ", req.Name, ": ", rbErr)
		}
		jsonMsg(c, I18nWeb(c, "pages.tunnel.toasts.createFailed"), err)
		return
	}
	jsonMsg(c, I18nWeb(c, "pages.tunnel.toasts.pairCreated"), nil)
}

// ---- Iran-node management --------------------------------------------------

func (a *TunnelController) nodesList(c *gin.Context) {
	jsonObj(c, a.nodeService.List(), nil)
}

type nodeCreateReq struct {
	Name string `json:"name" form:"name"`
	// Optional tunnel to auto-provision on first connect.
	Protocol string            `json:"protocol"`
	Fields   map[string]string `json:"fields"`
}

// nodeCreate registers a node and returns the ready-to-run one-liner for the
// Iran server, with the panel URL + one-time token baked in. If a protocol is
// supplied, the tunnel is configured now and brought up automatically when the
// node connects (foreign side here, Iran side pushed to the node).
func (a *TunnelController) nodeCreate(c *gin.Context) {
	var req nodeCreateReq
	_ = bindData(c, &req)
	name := strings.TrimSpace(req.Name)
	if name == "" {
		name = "iran-node"
	}
	var setup *service.NodeSetup
	if strings.TrimSpace(req.Protocol) != "" {
		fields := req.Fields
		if fields == nil {
			fields = map[string]string{}
		}
		setup = &service.NodeSetup{Name: name, Protocol: req.Protocol, Fields: fields}
	}
	id, token := a.nodeService.Create(name, setup)

	scheme := "http"
	if c.Request.TLS != nil || strings.EqualFold(c.GetHeader("X-Forwarded-Proto"), "https") {
		scheme = "https"
	}
	panelURL := scheme + "://" + c.Request.Host + c.GetString("base_path")
	oneliner := "bash <(curl -fsSL https://raw.githubusercontent.com/" + nodeRepo +
		"/main/scripts/install.sh) --iran --panel " + panelURL + " --token " + token

	jsonObj(c, gin.H{"id": id, "name": name, "token": token, "oneliner": oneliner}, nil)
}

func (a *TunnelController) nodeRemove(c *gin.Context) {
	err := a.nodeService.Remove(c.Param("id"))
	jsonMsg(c, I18nWeb(c, "pages.tunnel.toasts.removed"), err)
}

type nodeExecReq struct {
	Args []string `json:"args"`
}

// nodeExec runs an allowlisted tunnelctl command on a node and returns its output.
func (a *TunnelController) nodeExec(c *gin.Context) {
	var req nodeExecReq
	if err := bindData(c, &req); err != nil || len(req.Args) == 0 {
		pureJsonMsg(c, http.StatusOK, false, I18nWeb(c, "pages.tunnel.toasts.loadFailed"))
		return
	}
	if !nodeExecAllowlist[req.Args[0]] {
		pureJsonMsg(c, http.StatusOK, false, "command not allowed")
		return
	}
	out, err := a.nodeService.Exec(c.Param("id"), req.Args)
	if err != nil {
		jsonMsg(c, out, err)
		return
	}
	jsonObj(c, out, nil)
}
