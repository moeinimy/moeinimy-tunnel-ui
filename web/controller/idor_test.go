package controller

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strings"
	"testing"

	"github.com/mhsanaei/3x-ui/v2/database"
	"github.com/mhsanaei/3x-ui/v2/database/model"
	"github.com/mhsanaei/3x-ui/v2/logger"
	"github.com/mhsanaei/3x-ui/v2/util/crypto"
	"github.com/mhsanaei/3x-ui/v2/web/locale"
	"github.com/mhsanaei/3x-ui/v2/xray"

	"github.com/gin-contrib/sessions"
	"github.com/gin-contrib/sessions/cookie"
	"github.com/gin-gonic/gin"
	"github.com/op/go-logging"
	"github.com/xlzd/gotp"
)

// Cross-admin isolation, driven end to end.
//
// This exists because the unit tests could not have caught the bugs it pins. They
// exercise the middleware in isolation (a seeded context, no DB) and the services
// in isolation (no routes), and every real IDOR lived in the seam between the two:
// a route whose actual target is resolved somewhere the route table cannot see,
// either a body field or a service that re-resolves by email and ignores the path
// id. `owns` on a path :id proves nothing until you read the service it fronts.
//
// It also runs as a NON-super admin on purpose. Super admins bypass every ownership
// check, so the same suite run as a super admin passes while every hole is open.
//
// Each case is a real HTTP request through a real router against a real SQLite,
// asking: can Reza touch Ali's inbound?

type idorFixture struct {
	router *gin.Engine
	ali    *model.User
	reza   *model.User
	// Ali's, the victim's.
	aliInbound  *model.Inbound
	aliEmail    string
	rezaInbound *model.Inbound
}

// as builds a request authenticated as the given admin, bypassing the cookie by
// seeding the same per-request cache session.GetLoginUser reads.
func (f *idorFixture) as(t *testing.T, user *model.User, method, path, body string) *httptest.ResponseRecorder {
	t.Helper()
	r := gin.New()
	r.Use(func(c *gin.Context) {
		c.Set("LOGIN_USER_ROW", user)
		c.Set("base_path", "/")
		c.Set("I18n", func(i18nType locale.I18nType, key string, keyParams ...string) string { return key })
		c.Next()
	})
	NewInboundController(r.Group("/panel/api/inbounds"))

	req := httptest.NewRequest(method, path, strings.NewReader(body))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("X-Requested-With", "XMLHttpRequest")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	return w
}

func newIdorFixture(t *testing.T) *idorFixture {
	t.Helper()
	// The controllers log; without this the package-level logger is nil and any
	// warning panics rather than reporting the finding under test.
	logger.InitLogger(logging.CRITICAL)
	if err := database.InitDB(filepath.Join(t.TempDir(), "idor.db")); err != nil {
		t.Fatalf("InitDB: %v", err)
	}
	db := database.GetDB()

	// Two ordinary admins. Reza deliberately holds EVERY capability bit: this suite
	// is about ownership, not permissions, so Reza must fail purely because the
	// objects are not his.
	all := model.Permission(0)
	for _, d := range model.AllPermissions {
		all |= d.Bit
	}
	ali := &model.User{Username: "ali", Password: "x", Enable: true, Permissions: all}
	reza := &model.User{Username: "reza", Password: "x", Enable: true, Permissions: all}
	for _, u := range []*model.User{ali, reza} {
		if err := db.Create(u).Error; err != nil {
			t.Fatalf("create admin: %v", err)
		}
	}

	aliInbound := &model.Inbound{
		UserId: ali.Id, Tag: "inbound-41001", Port: 41001, Protocol: model.VMESS, Enable: true,
		Settings: `{"clients":[{"id":"ali-uuid","email":"ali-client","enable":true}]}`,
	}
	rezaInbound := &model.Inbound{
		UserId: reza.Id, Tag: "inbound-41002", Port: 41002, Protocol: model.VMESS, Enable: true,
		Settings: `{"clients":[{"id":"reza-uuid","email":"reza-client","enable":true}]}`,
	}
	for _, ib := range []*model.Inbound{aliInbound, rezaInbound} {
		if err := db.Create(ib).Error; err != nil {
			t.Fatalf("create inbound: %v", err)
		}
	}
	// Access is ASSIGNED, so creating a row grants nothing. Give each admin exactly
	// their own, which is what a super admin ticking the checklist does.
	for _, g := range []*model.InboundAccess{
		{UserId: ali.Id, InboundId: aliInbound.Id},
		{UserId: reza.Id, InboundId: rezaInbound.Id},
	} {
		if err := db.Create(g).Error; err != nil {
			t.Fatalf("grant access: %v", err)
		}
	}

	// Ali's client is DISABLED and has usage, so a cross-admin reset is observable:
	// it would both zero the counter and force-enable it.
	if err := db.Create(&xray.ClientTraffic{
		InboundId: aliInbound.Id, Email: "ali-client", Enable: false, Up: 5000, Down: 5000,
	}).Error; err != nil {
		t.Fatalf("create client traffic: %v", err)
	}

	return &idorFixture{ali: ali, reza: reza, aliInbound: aliInbound, aliEmail: "ali-client", rezaInbound: rezaInbound}
}

func (f *idorFixture) aliSettings(t *testing.T) string {
	t.Helper()
	ib := &model.Inbound{}
	if err := database.GetDB().Where("id = ?", f.aliInbound.Id).First(ib).Error; err != nil {
		t.Fatalf("reload Ali's inbound: %v", err)
	}
	return ib.Settings
}

// TestCrossAdminIsolation is the regression suite for every cross-admin hole.
// Each subtest is a concrete exploit: Reza, fully permissioned but not the owner,
// reaching for Ali's data.
func TestCrossAdminIsolation(t *testing.T) {
	gin.SetMode(gin.TestMode)

	t.Run("addClient onto another admin's inbound", func(t *testing.T) {
		f := newIdorFixture(t)
		// The target inbound is a BODY field, invisible to the route table.
		body := url.Values{
			"id":       {fmt.Sprint(f.aliInbound.Id)},
			"settings": {`{"clients":[{"id":"reza-backdoor","email":"reza-backdoor","enable":true}]}`},
		}.Encode()
		f.as(t, f.reza, http.MethodPost, "/panel/api/inbounds/addClient", body)

		if strings.Contains(f.aliSettings(t), "reza-backdoor") {
			t.Error("Reza provisioned a live account on Ali's inbound: it eats Ali's IP pool " +
				"and quota and never shows in Reza's own list")
		}
	})

	t.Run("copyClients from another admin's inbound", func(t *testing.T) {
		f := newIdorFixture(t)
		// Destination is Reza's own (so `owns` on :id passes); the SOURCE is Ali's and
		// arrives in the body. An empty clientEmails copies everything.
		body := url.Values{"sourceInboundId": {fmt.Sprint(f.aliInbound.Id)}}.Encode()
		w := f.as(t, f.reza, http.MethodPost,
			fmt.Sprintf("/panel/api/inbounds/%d/copyClients", f.rezaInbound.Id), body)

		ib := &model.Inbound{}
		database.GetDB().Where("id = ?", f.rezaInbound.Id).First(ib)
		if strings.Contains(ib.Settings, "ali-client") || strings.Contains(w.Body.String(), "ali-client") {
			t.Error("Reza copied Ali's client credentials (uuid/password/email) into his own " +
				"inbound and can read them straight back out")
		}
	})

	t.Run("resetClientTraffic on another admin's client", func(t *testing.T) {
		f := newIdorFixture(t)
		// Reza's OWN inbound id (so `owns` passes) plus Ali's client email. The service
		// resolves by email and ignores the id.
		f.as(t, f.reza, http.MethodPost,
			fmt.Sprintf("/panel/api/inbounds/%d/resetClientTraffic/%s", f.rezaInbound.Id, f.aliEmail), "")

		ct := &xray.ClientTraffic{}
		database.GetDB().Where("email = ?", f.aliEmail).First(ct)
		if ct.Up == 0 && ct.Down == 0 {
			t.Error("Reza zeroed Ali's client usage")
		}
		if ct.Enable {
			t.Error("Reza force-enabled a client Ali had disabled, defeating quota enforcement")
		}
	})

	t.Run("read another admin's inbound", func(t *testing.T) {
		f := newIdorFixture(t)
		w := f.as(t, f.reza, http.MethodGet,
			fmt.Sprintf("/panel/api/inbounds/get/%d", f.aliInbound.Id), "")
		if strings.Contains(w.Body.String(), "ali-uuid") {
			t.Errorf("Reza read Ali's inbound config: %s", w.Body.String())
		}
	})

	t.Run("delete another admin's inbound", func(t *testing.T) {
		f := newIdorFixture(t)
		f.as(t, f.reza, http.MethodPost,
			fmt.Sprintf("/panel/api/inbounds/del/%d", f.aliInbound.Id), "")
		var n int64
		database.GetDB().Model(model.Inbound{}).Where("id = ?", f.aliInbound.Id).Count(&n)
		if n == 0 {
			t.Error("Reza deleted Ali's inbound")
		}
	})

	t.Run("list is scoped to the caller", func(t *testing.T) {
		f := newIdorFixture(t)
		w := f.as(t, f.reza, http.MethodGet, "/panel/api/inbounds/list", "")
		if strings.Contains(w.Body.String(), "41001") {
			t.Error("Ali's inbound appears in Reza's list")
		}
		if !strings.Contains(w.Body.String(), "41002") {
			t.Error("Reza's OWN inbound is missing from his list; scoping is too aggressive")
		}
	})

	t.Run("onlines and lastOnline do not leak other admins' clients", func(t *testing.T) {
		f := newIdorFixture(t)
		for _, path := range []string{"/panel/api/inbounds/onlines", "/panel/api/inbounds/lastOnline"} {
			w := f.as(t, f.reza, http.MethodPost, path, "")
			if strings.Contains(w.Body.String(), f.aliEmail) {
				t.Errorf("%s leaked Ali's client roster to Reza: %s", path, w.Body.String())
			}
		}
	})

	t.Run("bulk ops cannot target another admin's inbound", func(t *testing.T) {
		f := newIdorFixture(t)
		payload, _ := json.Marshal(map[string]any{
			"op": "resetTraffic",
			"targets": []map[string]any{
				{"inboundId": f.rezaInbound.Id, "email": "reza-client"},
				{"inboundId": f.aliInbound.Id, "email": f.aliEmail}, // the poisoned one
			},
		})
		f.as(t, f.reza, http.MethodPost, "/panel/api/inbounds/bulkUpdateClients",
			url.Values{"data": {string(payload)}}.Encode())

		ct := &xray.ClientTraffic{}
		database.GetDB().Where("email = ?", f.aliEmail).First(ct)
		if ct.Up == 0 && ct.Down == 0 {
			t.Error("a bulk batch containing one foreign inbound reached Ali's client; " +
				"the batch must be refused whole, not applied partially")
		}
	})

	// The property that distinguishes ASSIGNED access from created-by ownership: a
	// grant can be given and taken away for an inbound the admin never created.
	t.Run("a granted inbound becomes visible, a revoked one disappears", func(t *testing.T) {
		f := newIdorFixture(t)
		db := database.GetDB()

		// Reza did not create Ali's inbound and cannot see it.
		w := f.as(t, f.reza, http.MethodGet, "/panel/api/inbounds/list", "")
		if strings.Contains(w.Body.String(), "41001") {
			t.Fatal("Ali's inbound is visible to Reza before any grant")
		}

		// The super admin ticks it for Reza.
		if err := db.Create(&model.InboundAccess{UserId: f.reza.Id, InboundId: f.aliInbound.Id}).Error; err != nil {
			t.Fatalf("grant: %v", err)
		}
		w = f.as(t, f.reza, http.MethodGet, "/panel/api/inbounds/list", "")
		if !strings.Contains(w.Body.String(), "41001") {
			t.Error("a granted inbound must appear in the admin's list")
		}
		w = f.as(t, f.reza, http.MethodGet, fmt.Sprintf("/panel/api/inbounds/get/%d", f.aliInbound.Id), "")
		if !strings.Contains(w.Body.String(), "ali-uuid") {
			t.Error("a granted inbound must be reachable, not just listed")
		}

		// And untick it.
		if err := db.Where("user_id = ? AND inbound_id = ?", f.reza.Id, f.aliInbound.Id).
			Delete(&model.InboundAccess{}).Error; err != nil {
			t.Fatalf("revoke: %v", err)
		}
		w = f.as(t, f.reza, http.MethodGet, fmt.Sprintf("/panel/api/inbounds/get/%d", f.aliInbound.Id), "")
		if strings.Contains(w.Body.String(), "ali-uuid") {
			t.Error("a revoked inbound must stop being reachable immediately")
		}
	})

	// The counterpart: a super admin SHOULD reach everything. Without this the suite
	// would pass just as well if ownership refused everyone.
	t.Run("super admin bypasses ownership", func(t *testing.T) {
		f := newIdorFixture(t)
		// A real super admin, holding NO grants: they must reach everything by role.
		super := &model.User{}
		if err := database.GetDB().Model(model.User{}).Where("is_super_admin = ?", true).
			First(super).Error; err != nil {
			t.Fatalf("no seeded super admin: %v", err)
		}
		w := f.as(t, super, http.MethodGet,
			fmt.Sprintf("/panel/api/inbounds/get/%d", f.aliInbound.Id), "")
		if !strings.Contains(w.Body.String(), "ali-uuid") {
			t.Errorf("a super admin must be able to read any inbound; got %s", w.Body.String())
		}
	})
}

// The login flow must never ask an admin for a code they do not have.
//
// This regressed once already: with 2FA per-admin, the pre-auth "does this account
// have 2FA?" endpoint becomes a username oracle, and the first fix for that was to
// always claim yes, which showed a Code box to every admin who had never enabled it.
// The real answer is two-step, and these are the two properties that matter.
func TestLoginTwoFactorPrompt(t *testing.T) {
	gin.SetMode(gin.TestMode)

	post := func(t *testing.T, form string) *httptest.ResponseRecorder {
		t.Helper()
		r := gin.New()
		// login writes a session, so the store has to be there or it panics.
		r.Use(sessions.Sessions("vpn-ui", cookie.NewStore([]byte("test-secret"))))
		r.Use(func(c *gin.Context) {
			c.Set("base_path", "/")
			c.Set("I18n", func(i18nType locale.I18nType, key string, keyParams ...string) string { return key })
			c.Next()
		})
		NewIndexController(r.Group("/"))
		req := httptest.NewRequest(http.MethodPost, "/login", strings.NewReader(form))
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		return w
	}

	t.Run("the preflight never claims an account has 2FA", func(t *testing.T) {
		newIdorFixture(t)
		r := gin.New()
		r.Use(sessions.Sessions("vpn-ui", cookie.NewStore([]byte("test-secret"))))
		r.Use(func(c *gin.Context) {
			c.Set("base_path", "/")
			c.Set("I18n", func(i18nType locale.I18nType, key string, keyParams ...string) string { return key })
			c.Next()
		})
		NewIndexController(r.Group("/"))
		req := httptest.NewRequest(http.MethodPost, "/getTwoFactorEnable", nil)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		// It must not report true: pre-auth it cannot know WHICH account is logging
		// in, and answering per-username would leak which usernames exist.
		if strings.Contains(w.Body.String(), `"obj":true`) {
			t.Errorf("the login page would show a Code field to every admin: %s", w.Body.String())
		}
	})

	t.Run("an admin without 2FA is never asked for a code", func(t *testing.T) {
		f := newIdorFixture(t)
		hash, _ := crypto.HashPasswordAsBcrypt("pw")
		database.GetDB().Model(model.User{}).Where("id = ?", f.reza.Id).
			Updates(map[string]any{"password": hash, "two_factor_enable": false})

		w := post(t, url.Values{"username": {"reza"}, "password": {"pw"}}.Encode())
		if strings.Contains(w.Body.String(), "twoFactorRequired") {
			t.Errorf("an admin who never enabled 2FA was asked for a code: %s", w.Body.String())
		}
		if !strings.Contains(w.Body.String(), `"success":true`) {
			t.Errorf("a correct password without 2FA should just log in: %s", w.Body.String())
		}
	})

	t.Run("an admin WITH 2FA is asked, only after the password checks out", func(t *testing.T) {
		f := newIdorFixture(t)
		hash, _ := crypto.HashPasswordAsBcrypt("pw")
		database.GetDB().Model(model.User{}).Where("id = ?", f.reza.Id).
			Updates(map[string]any{
				"password": hash, "two_factor_enable": true, "two_factor_token": "JBSWY3DPEHPK3PXP",
			})

		// Right password, no code: asked for the code.
		w := post(t, url.Values{"username": {"reza"}, "password": {"pw"}}.Encode())
		if !strings.Contains(w.Body.String(), "twoFactorRequired") {
			t.Errorf("an admin with 2FA was not asked for a code: %s", w.Body.String())
		}

		// WRONG password: must NOT reveal that the account has 2FA, or the login form
		// becomes the very oracle the pre-auth endpoint was closed to prevent.
		w = post(t, url.Values{"username": {"reza"}, "password": {"wrong"}}.Encode())
		if strings.Contains(w.Body.String(), "twoFactorRequired") {
			t.Errorf("a WRONG password revealed that the account has 2FA: %s", w.Body.String())
		}

		// A correct code completes the login.
		w = post(t, url.Values{
			"username": {"reza"}, "password": {"pw"},
			"twoFactorCode": {gotp.NewDefaultTOTP("JBSWY3DPEHPK3PXP").Now()},
		}.Encode())
		if !strings.Contains(w.Body.String(), `"success":true`) {
			t.Errorf("a correct code should complete the login: %s", w.Body.String())
		}
	})
}

// The Admins form must actually carry every field to the service.
//
// This exists because a real bug slipped through: spec() silently omitted
// InboundIds, so the form parsed the ticked inbounds and threw them away. Creating
// an admin reported success and granted nothing. No unit test caught it: the
// service tests call AddAdmin directly with a hand-built spec, and the middleware
// tests never reach a handler. The gap was the form-to-spec mapping itself.
func TestAdminFormCarriesEveryField(t *testing.T) {
	gin.SetMode(gin.TestMode)
	f := newIdorFixture(t)

	super := &model.User{}
	if err := database.GetDB().Model(model.User{}).Where("is_super_admin = ?", true).
		First(super).Error; err != nil {
		t.Fatalf("no super admin: %v", err)
	}

	r := gin.New()
	r.Use(func(c *gin.Context) {
		c.Set("LOGIN_USER_ROW", super)
		c.Set("base_path", "/")
		c.Set("I18n", func(i18nType locale.I18nType, key string, keyParams ...string) string { return key })
		c.Next()
	})
	NewAdminController(r.Group("/panel"))

	form := url.Values{
		"username":     {"formtest"},
		"password":     {"pw"},
		"nickname":     {"Form Test"},
		"enable":       {"true"},
		"isSuperAdmin": {"false"},
		"permissions":  {"accessInbounds", "createClient"},
		// Exactly how the modal sends a multi-select: repeated keys.
		"inboundIds": {fmt.Sprint(f.aliInbound.Id), fmt.Sprint(f.rezaInbound.Id)},
	}.Encode()
	req := httptest.NewRequest(http.MethodPost, "/panel/admins/add", strings.NewReader(form))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("X-Requested-With", "XMLHttpRequest")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if !strings.Contains(w.Body.String(), `"success":true`) {
		t.Fatalf("add admin: %s", w.Body.String())
	}

	created := &model.User{}
	if err := database.GetDB().Model(model.User{}).Where("username = ?", "formtest").
		First(created).Error; err != nil {
		t.Fatalf("created admin missing: %v", err)
	}
	if created.Nickname != "Form Test" {
		t.Errorf("nickname = %q; want %q", created.Nickname, "Form Test")
	}
	if !created.Permissions.Has(model.PermAccessInbounds) || !created.Permissions.Has(model.PermCreateClient) {
		t.Errorf("permissions = %v; want accessInbounds + createClient", created.Permissions.Slugs())
	}

	// The bit that was silently dropped.
	var granted []int
	if err := database.GetDB().Model(&model.InboundAccess{}).
		Where("user_id = ?", created.Id).Pluck("inbound_id", &granted).Error; err != nil {
		t.Fatalf("read grants: %v", err)
	}
	if len(granted) != 2 {
		t.Errorf("ticked 2 inbounds, %d were granted (%v): the form's inbound "+
			"selection never reached the database", len(granted), granted)
	}

	// And an edit must REPLACE the set, not merge into it: unticking has to revoke.
	edit := url.Values{
		"username": {"formtest"}, "nickname": {"Form Test"}, "enable": {"true"},
		"isSuperAdmin": {"false"}, "permissions": {"accessInbounds"},
		"inboundIds": {fmt.Sprint(f.aliInbound.Id)},
	}.Encode()
	req = httptest.NewRequest(http.MethodPost, fmt.Sprintf("/panel/admins/update/%d", created.Id),
		strings.NewReader(edit))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("X-Requested-With", "XMLHttpRequest")
	w = httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if !strings.Contains(w.Body.String(), `"success":true`) {
		t.Fatalf("update admin: %s", w.Body.String())
	}
	granted = nil
	database.GetDB().Model(&model.InboundAccess{}).Where("user_id = ?", created.Id).Pluck("inbound_id", &granted)
	if len(granted) != 1 || granted[0] != f.aliInbound.Id {
		t.Errorf("after unticking one, grants = %v; want exactly [%d]", granted, f.aliInbound.Id)
	}
}
