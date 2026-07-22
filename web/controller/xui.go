package controller

import (
	"github.com/mhsanaei/3x-ui/v2/database/model"

	"github.com/gin-gonic/gin"
)

// XUIController is the main controller for the vpn-ui panel, managing sub-controllers.
type XUIController struct {
	BaseController

	settingController     *SettingController
	xraySettingController *XraySettingController
	coreController        *CoreController
	adminController       *AdminController
	tunnelController      *TunnelController
}

// NewXUIController creates a new XUIController and initializes its routes.
func NewXUIController(g *gin.RouterGroup) *XUIController {
	a := &XUIController{}
	a.initRouter(g)
	return a
}

// initRouter sets up the main panel routes and initializes sub-controllers.
func (a *XUIController) initRouter(g *gin.RouterGroup) {
	g = g.Group("/panel")
	g.Use(a.checkLogin)

	// The overview is the one page every admin may see; it is where a permission
	// denial redirects to, so gating it would loop.
	g.GET("/", a.index)
	g.GET("/inbounds", requirePerm(model.PermAccessInbounds), a.inbounds)
	g.GET("/settings", requirePerm(model.PermPanelSettings), a.settings)
	g.GET("/xray", requirePerm(model.PermXraySettings), a.xraySettings)
	g.GET("/core", requirePerm(model.PermCoreSettings), a.coreSettings)
	g.GET("/admins", requireSuperAdmin(), a.admins)
	// Tunnels reconfigure the host's networking and can execute commands on a
	// remote node, so they stay super-admin only rather than riding on one of the
	// per-inbound permissions.
	g.GET("/tunnel", requireSuperAdmin(), a.tunnel)

	a.settingController = NewSettingController(g)
	a.xraySettingController = NewXraySettingController(g)
	a.coreController = NewCoreController(g)
	a.adminController = NewAdminController(g)
	a.tunnelController = NewTunnelController(g)
}

// index renders the main panel index page.
func (a *XUIController) index(c *gin.Context) {
	html(c, "index.html", "pages.index.title", nil)
}

// inbounds renders the inbounds management page.
func (a *XUIController) inbounds(c *gin.Context) {
	html(c, "inbounds.html", "pages.inbounds.title", nil)
}

// settings renders the settings management page.
func (a *XUIController) settings(c *gin.Context) {
	html(c, "settings.html", "pages.settings.title", nil)
}

// xraySettings renders the Xray settings page.
func (a *XUIController) xraySettings(c *gin.Context) {
	html(c, "xray.html", "pages.xray.title", nil)
}

// coreSettings renders the Core Settings page (per-core status + provisioning).
func (a *XUIController) coreSettings(c *gin.Context) {
	html(c, "core.html", "pages.core.title", nil)
}

// admins renders the Admins management page (super admin only).
func (a *XUIController) admins(c *gin.Context) {
	html(c, "admins.html", "pages.admins.title", nil)
}

// tunnel renders the Tunnel management page (server-to-server tunnels + nodes).
func (a *XUIController) tunnel(c *gin.Context) {
	html(c, "tunnel.html", "pages.tunnel.title", nil)
}
