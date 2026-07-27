package service

import (
	"github.com/mhsanaei/3x-ui/v2/database"
	"github.com/mhsanaei/3x-ui/v2/util/common"
	"github.com/mhsanaei/3x-ui/v2/database/model"
	"github.com/mhsanaei/3x-ui/v2/xray"

	"gorm.io/gorm"
)

// ClientGroupService manages shared allowances spanning several accounts.
//
// A customer is one person however they connect: an OpenVPN account on the phone, a
// VLESS account on the laptop, an L2TP account for the network that blocks the rest.
// The protocols cannot share an ACCOUNT — VLESS authenticates by UUID, OpenVPN and
// L2TP by username and password — so what a group shares instead is the entitlement:
// separate credentials, one quota, one expiry, one switch.
type ClientGroupService struct{}

// GroupUsage is a group plus the figures that are computed rather than stored.
type GroupUsage struct {
	model.ClientGroup
	// Up, Down and Members are summed over the group's accounts on demand. They are
	// never written back to the member rows: each row keeps accumulating only its own
	// bytes, and storing the group's figure there would double-count, because the next
	// collection adds each member's delta to a row that already holds everyone's.
	Up      int64 `json:"up"`
	Down    int64 `json:"down"`
	Members int   `json:"members"`
}

func (s *ClientGroupService) GetGroups() ([]*GroupUsage, error) {
	db := database.GetDB()
	var groups []*model.ClientGroup
	if err := db.Model(model.ClientGroup{}).Find(&groups).Error; err != nil {
		return nil, err
	}
	out := make([]*GroupUsage, 0, len(groups))
	for _, g := range groups {
		u := &GroupUsage{ClientGroup: *g}
		var agg struct {
			Up, Down int64
			Members  int
		}
		db.Model(xray.ClientTraffic{}).
			Select("COALESCE(SUM(up),0) as up, COALESCE(SUM(down),0) as down, COUNT(*) as members").
			Where("group_id = ?", g.Id).Scan(&agg)
		u.Up, u.Down, u.Members = agg.Up, agg.Down, agg.Members
		out = append(out, u)
	}
	return out, nil
}

func (s *ClientGroupService) AddGroup(g *model.ClientGroup) error {
	return database.GetDB().Save(g).Error
}

func (s *ClientGroupService) UpdateGroup(g *model.ClientGroup) error {
	if g.Id == 0 {
		return common.NewError("group id is required")
	}
	return database.GetDB().Model(model.ClientGroup{}).Where("id = ?", g.Id).
		Updates(map[string]any{
			"name":        g.Name,
			"total":       g.Total,
			"expiry_time": g.ExpiryTime,
			"reset":       g.Reset,
			"enable":      g.Enable,
			"comment":     g.Comment,
		}).Error
}

// DelGroup removes a group and releases its members, who go back to being billed on
// their own totals. Membership is cleared explicitly rather than left to a foreign
// key: a stale group_id would leave those accounts pointing at nothing, and the
// enforcement below would stop mirroring an entitlement onto them while their own
// expiry still read whatever the group last wrote.
func (s *ClientGroupService) DelGroup(id int) error {
	db := database.GetDB()
	return db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Model(xray.ClientTraffic{}).Where("group_id = ?", id).
			Update("group_id", 0).Error; err != nil {
			return err
		}
		return tx.Delete(model.ClientGroup{}, id).Error
	})
}

// SetMembership puts the named accounts in a group (id 0 removes them from any).
func (s *ClientGroupService) SetMembership(groupId int, emails []string) error {
	if len(emails) == 0 {
		return nil
	}
	return database.GetDB().Model(xray.ClientTraffic{}).
		Where("email IN (?)", emails).Update("group_id", groupId).Error
}

// enforceGroups mirrors each group's entitlement onto its members and expires them
// together when the group's SHARED usage runs out.
//
// It deliberately does not disable anyone itself. Everything downstream of an account
// running out — removing it from Xray, telling the VPN backends to drop its live
// sessions, flipping enable — already happens in disableInvalidClients, driven by the
// member's own row. So a group that is spent writes a past expiry onto its members and
// lets that existing machinery do exactly what it does for an ordinary account. There
// is one disabling path, not two that have to agree.
//
// Writing a past expiry is safe to do repeatedly and safe to undo: expiry is the
// GROUP's to set while an account belongs to one, and every tick rewrites it from the
// group. Raise the group's quota and the next tick restores the real date; the account
// comes back without anyone editing it.
func (s *ClientGroupService) enforceGroups(tx *gorm.DB) error {
	var groups []*model.ClientGroup
	if err := tx.Model(model.ClientGroup{}).Find(&groups).Error; err != nil {
		return err
	}
	for _, g := range groups {
		var agg struct{ Used int64 }
		if err := tx.Model(xray.ClientTraffic{}).
			Select("COALESCE(SUM(up),0) + COALESCE(SUM(down),0) as used").
			Where("group_id = ?", g.Id).Scan(&agg).Error; err != nil {
			return err
		}

		spent := g.Total > 0 && agg.Used >= g.Total
		expiry := g.ExpiryTime
		if spent || !g.Enable {
			// 1ms after the epoch: unambiguously past, and distinct from 0, which
			// disableInvalidClients reads as "never expires".
			expiry = 1
		}

		if err := tx.Model(xray.ClientTraffic{}).Where("group_id = ?", g.Id).
			Updates(map[string]any{
				"total":       g.Total,
				"expiry_time": expiry,
				"reset":       g.Reset,
			}).Error; err != nil {
			return err
		}
	}
	return nil
}
