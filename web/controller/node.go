package controller

import (
	"crypto/sha256"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"github.com/mhsanaei/3x-ui/v2/config"
	"github.com/mhsanaei/3x-ui/v2/logger"
	"github.com/mhsanaei/3x-ui/v2/web/service"
	"github.com/mhsanaei/3x-ui/v2/xray"

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
	node.GET("/asset/:name", a.asset)
	return a
}

// nodeAssets are the files a node may download, mapped to where this panel keeps
// its own copy. Strictly a fixed set: the name comes off the wire, and anything
// that let it choose a path would serve this server's filesystem to whoever holds
// a node token.
func nodeAssetPath(name string) string {
	switch name {
	case "xray":
		return xray.GetBinaryPath()
	case "geoip.dat", "geosite.dat",
		"geoip_IR.dat", "geosite_IR.dat",
		"geoip_RU.dat", "geosite_RU.dat":
		return filepath.Join(config.GetBinFolderPath(), name)
	}
	return ""
}

// asset serves the panel's own core and geo files to a node.
//
// This is what keeps the promise that a foreign server needs one command and
// nothing else: the node never fetches a core from the internet, never picks a
// version, and cannot end up on a build this panel did not test. It gets exactly
// what this panel runs — including the fork's patches — over the same channel the
// agent already uses.
//
// The node offers the hash it already has, so a node that is current pays for one
// 304 rather than another download of a ~40 MB binary.
func (a *NodeController) asset(c *gin.Context) {
	token := c.GetHeader("X-Node-Token")
	if token == "" {
		token = c.Query("token")
	}
	if a.nodeService.ValidToken(token) == "" {
		c.AbortWithStatus(http.StatusNotFound)
		return
	}
	path := nodeAssetPath(c.Param("name"))
	if path == "" {
		c.AbortWithStatus(http.StatusNotFound)
		return
	}
	data, err := os.ReadFile(path)
	if err != nil {
		// The geo files are optional on this server too; say "not here" rather than
		// "server error", because the agent treats them as best effort.
		c.AbortWithStatus(http.StatusNotFound)
		return
	}
	sum := fmt.Sprintf("%x", sha256.Sum256(data))
	if strings.EqualFold(c.GetHeader("X-Have-Sha256"), sum) {
		c.Status(http.StatusNotModified)
		return
	}
	c.Header("X-Asset-Sha256", sum)
	c.Data(http.StatusOK, "application/octet-stream", data)
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
