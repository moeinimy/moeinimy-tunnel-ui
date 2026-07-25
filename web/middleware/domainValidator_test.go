package middleware

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
)

// serve runs one request through the live validator and reports the status.
func serve(t *testing.T, host string) int {
	t.Helper()
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.Use(LiveDomainValidatorMiddleware())
	r.GET("/", func(c *gin.Context) { c.Status(http.StatusOK) })

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Host = host
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	return w.Code
}

// The panel used to bake the domain into the middleware at startup, so saving the
// setting did nothing until a restart. The value is now read per request.
func TestLiveDomainTakesEffectWithoutRebuild(t *testing.T) {
	t.Cleanup(func() { SetAllowedDomain("") })

	SetAllowedDomain("")
	if got := serve(t, "203.0.113.9:2083"); got != http.StatusOK {
		t.Fatalf("unset: got %d, want 200 (no restriction configured)", got)
	}

	// Same middleware instance, domain set afterwards — this is the bug being
	// guarded: it must now bite immediately.
	SetAllowedDomain("panel.example.com")
	if got := serve(t, "203.0.113.9:2083"); got != http.StatusForbidden {
		t.Errorf("IP after set: got %d, want 403", got)
	}
	if got := serve(t, "panel.example.com:2083"); got != http.StatusOK {
		t.Errorf("configured domain: got %d, want 200", got)
	}

	// And clearing it must reopen access, again with no restart.
	SetAllowedDomain("")
	if got := serve(t, "203.0.113.9:2083"); got != http.StatusOK {
		t.Errorf("after clearing: got %d, want 200", got)
	}
}

func TestDomainMatchIsCaseInsensitiveAndPortAgnostic(t *testing.T) {
	t.Cleanup(func() { SetAllowedDomain("") })
	SetAllowedDomain("panel.example.com")

	for _, host := range []string{
		"panel.example.com",      // no port
		"panel.example.com:2083", // with port
		"Panel.Example.COM:2083", // hostnames are case-insensitive
	} {
		if got := serve(t, host); got != http.StatusOK {
			t.Errorf("host %q: got %d, want 200", host, got)
		}
	}

	// A subdomain is a different host and stays blocked: the setting is a lock,
	// not a suffix match.
	for _, host := range []string{"www.panel.example.com:2083", "evil.com:2083"} {
		if got := serve(t, host); got != http.StatusForbidden {
			t.Errorf("host %q: got %d, want 403", host, got)
		}
	}
}

// The subscription server keeps its own fixed domain, independent of the panel's.
func TestStaticValidatorIsIndependentOfTheLiveOne(t *testing.T) {
	t.Cleanup(func() { SetAllowedDomain("") })
	SetAllowedDomain("panel.example.com")

	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.Use(DomainValidatorMiddleware("sub.example.com"))
	r.GET("/", func(c *gin.Context) { c.Status(http.StatusOK) })

	call := func(host string) int {
		req := httptest.NewRequest(http.MethodGet, "/", nil)
		req.Host = host
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		return w.Code
	}

	if got := call("sub.example.com:2096"); got != http.StatusOK {
		t.Errorf("sub domain: got %d, want 200", got)
	}
	if got := call("panel.example.com:2096"); got != http.StatusForbidden {
		t.Errorf("panel domain must not open the sub server: got %d, want 403", got)
	}
}
