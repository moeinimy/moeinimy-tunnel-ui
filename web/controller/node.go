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
	nodeService   service.NodeService
	tunnelService service.TunnelService
}

// NewNodeController registers the node channel endpoints under the base path.
func NewNodeController(g *gin.RouterGroup) *NodeController {
	a := &NodeController{}
	node := g.Group("/node")
	node.POST("/poll", a.poll)
	node.POST("/result", a.result)
	return a
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
