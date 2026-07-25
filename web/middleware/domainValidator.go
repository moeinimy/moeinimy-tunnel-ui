// Package middleware provides HTTP middleware functions for the vpn-ui web panel,
// including domain validation and URL redirection utilities.
package middleware

import (
	"net"
	"net/http"
	"strings"
	"sync/atomic"

	"github.com/gin-gonic/gin"
)

// allowedDomain is the host the panel answers on, or "" for no restriction.
//
// It is a live value rather than a closure argument because the middleware chain
// is built once, at panel startup: with the domain baked in, saving the setting
// changed the database but not the running engine, so the lock silently did
// nothing until someone restarted the service — and nothing in the UI said so.
var allowedDomain atomic.Value // string

func init() { allowedDomain.Store("") }

// SetAllowedDomain updates the host the panel accepts. Empty disables the check.
// Called at startup and again whenever the webDomain setting is saved, so the
// change takes effect on the very next request.
func SetAllowedDomain(domain string) {
	allowedDomain.Store(strings.TrimSpace(domain))
}

// AllowedDomain reports the currently enforced host ("" when unrestricted).
func AllowedDomain() string {
	d, _ := allowedDomain.Load().(string)
	return d
}

// DomainValidatorMiddleware validates the request host against a FIXED domain.
// Used by the subscription server, which has its own domain setting and is
// rebuilt when that changes.
func DomainValidatorMiddleware(domain string) gin.HandlerFunc {
	return domainValidator(func() string { return domain })
}

// LiveDomainValidatorMiddleware validates against the domain most recently given
// to SetAllowedDomain, so the panel picks up a change without a restart.
func LiveDomainValidatorMiddleware() gin.HandlerFunc {
	return domainValidator(AllowedDomain)
}

// domainValidator rejects any host other than the resolved domain with 403.
// While the resolver returns "" every request passes, so it is safe to install
// unconditionally.
func domainValidator(resolve func() string) gin.HandlerFunc {
	return func(c *gin.Context) {
		domain := strings.TrimSpace(resolve())
		if domain == "" {
			c.Next()
			return
		}

		host := c.Request.Host
		if colonIndex := strings.LastIndex(host, ":"); colonIndex != -1 {
			host, _, _ = net.SplitHostPort(c.Request.Host)
		}

		// Hostnames are case-insensitive, so a browser sending "Panel.Example.com"
		// for a setting saved as "panel.example.com" must not be locked out.
		if !strings.EqualFold(host, domain) {
			c.AbortWithStatus(http.StatusForbidden)
			return
		}

		c.Next()
	}
}
