package controller

import (
	"net"
	"net/http"

	"github.com/mhsanaei/3x-ui/v2/logger"
	"github.com/mhsanaei/3x-ui/v2/web/service"

	"github.com/gin-gonic/gin"
)

// NodeController serves the token-authed endpoints the Iran-node agent talks to.
// These are deliberately NOT under /panel (no session): the node authenticates
// with its own token. A bad token gets a 404 so the endpoints stay invisible to
// unauthenticated scanners.
type NodeController struct {
	nodeService      service.NodeService
	tunnelService    service.TunnelService
	nodePanelService service.NodePanelService
}

// NewNodeController registers the node channel endpoints under the base path.
func NewNodeController(g *gin.RouterGroup) *NodeController {
	a := &NodeController{}
	node := g.Group("/node")
	node.POST("/poll", a.poll)
	node.POST("/result", a.result)
	// Panel-to-panel sync: a foreign node runs this same panel and asks for the
	// inbounds it is to serve, then reports what they carried.
	node.POST("/panel/pull", a.panelPull)
	node.POST("/panel/usage", a.panelUsage)
	return a
}

type nodePanelPullBody struct {
	Token string `json:"token" form:"token"`
}

// panelPull hands a node the inbound set assigned to it.
//
// Token-authed and outside the login group, like the agent's own endpoints: the
// node holds a token, not a session. A bad token gets a 404 so these stay
// invisible to anything scanning.
func (a *NodeController) panelPull(c *gin.Context) {
	var b nodePanelPullBody
	_ = c.ShouldBind(&b)
	id := a.nodeService.ValidToken(b.Token)
	if id == "" {
		c.AbortWithStatus(http.StatusNotFound)
		return
	}
	set, err := a.nodePanelService.InboundsFor(id)
	if err != nil {
		logger.Warning("node sync: could not read the inbounds for node ", id, ": ", err)
		c.AbortWithStatus(http.StatusInternalServerError)
		return
	}
	c.JSON(http.StatusOK, set)
}

type nodePanelUsageBody struct {
	Token string             `json:"token"`
	Usage *service.NodeUsage `json:"usage"`
}

// panelUsage records what a node's inbounds have carried, so the master shows the
// real figures. Enforcement is the node's own — it sees all of that traffic — so
// this is bookkeeping, not a second place where quota is decided.
func (a *NodeController) panelUsage(c *gin.Context) {
	var b nodePanelUsageBody
	if err := c.ShouldBindJSON(&b); err != nil {
		c.AbortWithStatus(http.StatusBadRequest)
		return
	}
	id := a.nodeService.ValidToken(b.Token)
	if id == "" {
		c.AbortWithStatus(http.StatusNotFound)
		return
	}
	if err := a.nodePanelService.ApplyUsage(id, b.Usage); err != nil {
		logger.Warning("node sync: could not record usage from node ", id, ": ", err)
	}
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

type nodePollBody struct {
	Token string `json:"token" form:"token"`
}

// poll is long-polled by the node agent; returns any queued commands. On a
// node's first connect it also runs the auto-provision step: create the
// foreign-side tunnel here (now that the node's public IP is known) and queue
// the matching Iran-side tunnel for the node.
func (a *NodeController) poll(c *gin.Context) {
	var b nodePollBody
	_ = c.ShouldBind(&b)
	ip := getRemoteIp(c)

	foreignHost := c.Request.Host
	if h, _, err := net.SplitHostPort(foreignHost); err == nil {
		foreignHost = h
	}
	if ff, ok := a.nodeService.Provision(b.Token, ip, foreignHost); ok {
		if err := a.tunnelService.Create(ff); err != nil {
			logger.Warning("node auto-provision: foreign-side create failed: ", err)
		}
	}

	cmds, ok := a.nodeService.Poll(b.Token, ip)
	if !ok {
		c.AbortWithStatus(http.StatusNotFound)
		return
	}
	c.JSON(http.StatusOK, gin.H{"commands": cmds})
}

type nodeResultBody struct {
	Token   string `json:"token" form:"token"`
	ID      string `json:"id" form:"id"`
	Output  string `json:"output" form:"output"`
	Success bool   `json:"success" form:"success"`
}

// result records a command's output posted back by the node agent.
func (a *NodeController) result(c *gin.Context) {
	var b nodeResultBody
	if err := c.ShouldBind(&b); err != nil {
		c.AbortWithStatus(http.StatusBadRequest)
		return
	}
	if !a.nodeService.Result(b.Token, b.ID, b.Output, b.Success) {
		c.AbortWithStatus(http.StatusNotFound)
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true})
}
