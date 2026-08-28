package service

import (
	"encoding/json"
	"path/filepath"
	"sync"
	"testing"

	"github.com/mhsanaei/3x-ui/v2/database"
	"github.com/mhsanaei/3x-ui/v2/database/model"
	"github.com/mhsanaei/3x-ui/v2/logger"
	"github.com/mhsanaei/3x-ui/v2/xray"
	"github.com/op/go-logging"
)

var renewTestLoggerOnce sync.Once

// TestRenewMembersWritesSettingsJSON pins the fault behind "I pressed renew and
// neither config was renewed — not the date, not the quota".
//
// The traffic rows are derived from each inbound's settings JSON, so writing only the
// rows left the panel rendering the expired date it reads from the JSON, and left the
// generated config carrying it too. The renewal was real in one table and invisible
// everywhere the customer or the operator could see.
func TestRenewMembersWritesSettingsJSON(t *testing.T) {
	renewTestLoggerOnce.Do(func() { logger.InitLogger(logging.ERROR) })
	if err := database.InitDB(filepath.Join(t.TempDir(), "test.db")); err != nil {
		t.Fatalf("InitDB: %v", err)
	}
	db := database.GetDB()

	const (
		oldExpiry = int64(1000)
		oldTotal  = int64(500)
		newExpiry = int64(9_000_000)
		newTotal  = int64(42_000)
	)

	// Two inbounds, because the customer's complaint was about a combined account:
	// one member each, and BOTH have to come back renewed.
	for _, seed := range []struct {
		id    int
		email string
	}{{1, "cust@a"}, {2, "cust@b"}} {
		settings, _ := json.Marshal(map[string]any{"clients": []any{map[string]any{
			"email": seed.email, "id": "keep-me", "flow": "xtls-rprx-vision",
			"totalGB": oldTotal, "expiryTime": oldExpiry, "enable": true,
		}}})
		if err := db.Create(&model.Inbound{
			Id: seed.id, UserId: 1, Enable: true, Tag: "in", Protocol: "vless",
			Port: 1000 + seed.id, Settings: string(settings),
		}).Error; err != nil {
			t.Fatalf("seed inbound: %v", err)
		}
		if err := db.Create(&xray.ClientTraffic{
			InboundId: seed.id, Email: seed.email, Enable: true, GroupId: 7,
			Up: 999, Down: 999, Total: oldTotal, ExpiryTime: oldExpiry,
		}).Error; err != nil {
			t.Fatalf("seed traffic: %v", err)
		}
	}

	if err := db.Create(&model.ClientGroup{
		Id: 7, Name: "cust", Enable: true, Total: newTotal, ExpiryTime: newExpiry,
	}).Error; err != nil {
		t.Fatalf("seed group: %v", err)
	}

	var svc ClientGroupService
	if err := svc.RenewMembers(7); err != nil {
		t.Fatalf("RenewMembers: %v", err)
	}

	for _, seed := range []struct {
		id    int
		email string
	}{{1, "cust@a"}, {2, "cust@b"}} {
		var in model.Inbound
		if err := db.First(&in, seed.id).Error; err != nil {
			t.Fatalf("reload inbound %d: %v", seed.id, err)
		}
		var parsed struct {
			Clients []map[string]any `json:"clients"`
		}
		if err := json.Unmarshal([]byte(in.Settings), &parsed); err != nil {
			t.Fatalf("inbound %d settings did not survive the rewrite: %v", seed.id, err)
		}
		if len(parsed.Clients) != 1 {
			t.Fatalf("inbound %d: want 1 client, got %d", seed.id, len(parsed.Clients))
		}
		c := parsed.Clients[0]
		if got := int64(c["expiryTime"].(float64)); got != newExpiry {
			t.Errorf("inbound %d %s: expiryTime = %d, want %d (the date the customer paid for)",
				seed.id, seed.email, got, newExpiry)
		}
		if got := int64(c["totalGB"].(float64)); got != newTotal {
			t.Errorf("inbound %d %s: totalGB = %d, want %d (the quota they paid for)",
				seed.id, seed.email, got, newTotal)
		}
		// Everything else about the account has to survive the round trip: a narrow
		// struct here would silently drop the credential and the flow.
		if c["id"] != "keep-me" || c["flow"] != "xtls-rprx-vision" {
			t.Errorf("inbound %d %s: renewal lost unrelated client fields: %#v", seed.id, seed.email, c)
		}

		var ct xray.ClientTraffic
		if err := db.Where("email = ?", seed.email).First(&ct).Error; err != nil {
			t.Fatalf("reload traffic %s: %v", seed.email, err)
		}
		if ct.Up != 0 || ct.Down != 0 {
			t.Errorf("%s: usage not cleared: up=%d down=%d", seed.email, ct.Up, ct.Down)
		}
		if ct.ExpiryTime != newExpiry || ct.Total != newTotal {
			t.Errorf("%s: traffic row not renewed: expiry=%d total=%d", seed.email, ct.ExpiryTime, ct.Total)
		}
	}
}
