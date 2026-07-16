package controller

import (
	"github.com/mhsanaei/3x-ui/v2/web/service"

	"github.com/gin-gonic/gin"
)

// TunnelController exposes tunnel management (the vendored tunnel-manager) to
// the panel UI under /panel/tunnel. It only forwards to TunnelService, which
// shells out to `tunnelctl`; no tunnel state lives in the x-ui database.
type TunnelController struct {
	tunnelService service.TunnelService
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
	if err := c.ShouldBindJSON(&req); err != nil {
		jsonMsg(c, I18nWeb(c, "pages.tunnel.toasts.createFailed"), err)
		return
	}
	err := a.tunnelService.Create(req.Fields)
	jsonMsg(c, I18nWeb(c, "pages.tunnel.toasts.created"), err)
}

func (a *TunnelController) remove(c *gin.Context) {
	err := a.tunnelService.Remove(c.Param("name"))
	jsonMsg(c, I18nWeb(c, "pages.tunnel.toasts.removed"), err)
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
