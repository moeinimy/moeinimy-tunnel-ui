package service

import (
	"strings"

	"github.com/mhsanaei/3x-ui/v2/database"
	"github.com/mhsanaei/3x-ui/v2/database/model"
	"github.com/mhsanaei/3x-ui/v2/logger"
	"github.com/mhsanaei/3x-ui/v2/util/common"
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

// --- Combined accounts -------------------------------------------------------------

// CombinedMember is one protocol's half of a combined account: the inbound the account
// lands on, and the account itself in exactly the shape /addClient already takes.
//
// The client arrives ALREADY BUILT rather than being assembled here out of a flat
// form. Each protocol's client is a different shape — VLESS carries a uuid and a flow,
// OpenVPN and L2TP a username, a password and a per-account User Limit — and the
// browser has one constructor per protocol for exactly that. Rebuilding those shapes in
// Go would be a second definition of every one of them, free to drift from the first;
// this way the combined form and the ordinary Add Client form post the same JSON, and
// the whole of AddInboundClient's validation applies to both without being repeated.
type CombinedMember struct {
	InboundId int    `json:"inboundId"`
	Settings  string `json:"settings"`
}

// CombinedCreated is one account a combined create produced.
type CombinedCreated struct {
	InboundId int            `json:"inboundId"`
	Protocol  model.Protocol `json:"protocol"`
	Email     string         `json:"email"`

	// NeedRestart is AddInboundClient's own answer FOR THIS ACCOUNT, kept per member
	// rather than OR'd into one flag for the batch. Adding an account to Xray's API is
	// attempted for every protocol including the ones Xray does not serve, so an
	// OpenVPN or L2TP member always comes back needing a restart; folded together with
	// a VLESS member's, that would bounce the core after every combined account. The
	// caller, which knows which protocols are Xray's, reads them apart.
	NeedRestart bool `json:"needRestart"`
}

// CombinedResult reports what a combined account turned into. The members are there for
// a caller that has to reload the daemons behind those accounts: only the panel's HTTP
// layer knows how to do that, and only this layer knows what was touched.
type CombinedResult struct {
	Group   *model.ClientGroup `json:"group"`
	Members []CombinedCreated  `json:"members"`
}

// CreateCombined provisions ONE CUSTOMER across several protocols in a single step: an
// account on each named inbound, and a group holding the quota, expiry and on/off
// switch all of them share.
//
// This is the pair to the group model. A group is what makes several accounts one
// customer; creating those accounts by hand is three visits to three inbounds, and the
// quota typed into each is then three separate quotas that only LOOK shared — the
// customer gets three times what was sold. Here the allowance is entered once, lives on
// the group, and the accounts are created against it.
//
// Order is group, then accounts, then membership, and each step is recoverable from the
// one before it:
//   - the group first because its name is unique, so a clash fails while there is still
//     nothing to undo;
//   - membership last because it can only touch rows that already exist. Until it lands
//     the accounts are merely ungrouped, billed on the totals they were created with —
//     which are the group's — so even a crash in between leaves working accounts rather
//     than broken ones.
func (s *ClientGroupService) CreateCombined(group *model.ClientGroup, members []CombinedMember) (*CombinedResult, error) {
	if group == nil || strings.TrimSpace(group.Name) == "" {
		return nil, common.NewError("a combined account needs a name")
	}
	group.Name = strings.TrimSpace(group.Name)
	if len(members) == 0 {
		return nil, common.NewError("a combined account needs at least one protocol")
	}
	// A delayed start (a NEGATIVE expiry, turned into a real date when the account first
	// carries traffic) cannot be shared. Each member would convert on its own first
	// connection, and enforceGroups would overwrite whichever date it produced with the
	// group's still-negative one on the next tick — an account that never expires.
	// Refused rather than quietly coerced to a date the operator did not choose.
	if group.ExpiryTime < 0 {
		return nil, common.NewError("a shared allowance cannot use a delayed start: give the group an expiry date, or none")
	}

	var inboundService InboundService

	// Resolve every member BEFORE writing anything. A member naming an inbound that
	// does not exist, or carrying no email, should cost nothing — not leave a group and
	// two of three accounts behind for the operator to find and clean up.
	prepared := make([]*model.Inbound, 0, len(members))
	emails := make([]string, 0, len(members))
	protocols := make([]model.Protocol, 0, len(members))
	seenInbound := make(map[int]bool, len(members))
	for _, m := range members {
		if seenInbound[m.InboundId] {
			return nil, common.NewError("two of these accounts land on inbound", m.InboundId,
				"- one customer needs at most one account per inbound")
		}
		seenInbound[m.InboundId] = true

		dbInbound, err := inboundService.GetInbound(m.InboundId)
		if err != nil {
			return nil, err
		}
		posted := &model.Inbound{Id: m.InboundId, Protocol: dbInbound.Protocol, Settings: m.Settings}
		clients, err := inboundService.GetClients(posted)
		if err != nil {
			return nil, err
		}
		// Exactly one, per member: this is one customer's account on one inbound, and a
		// member carrying several would put accounts in the group that the operator
		// never saw priced against the shared quota.
		if len(clients) != 1 {
			return nil, common.NewError("each protocol of a combined account carries exactly one account")
		}
		email := strings.TrimSpace(clients[0].Email)
		if email == "" {
			return nil, common.NewError("every account in a combined account needs an email")
		}

		prepared = append(prepared, posted)
		emails = append(emails, email)
		protocols = append(protocols, dbInbound.Protocol)
	}

	if err := s.AddGroup(group); err != nil {
		return nil, err
	}

	created := make([]CombinedCreated, 0, len(prepared))
	// undo unwinds a partial create. Half a customer is worse than none: the operator
	// would see two working protocols, no error against the third, and a shared quota
	// already being spent by accounts they do not know exist.
	//
	// Best effort, and it says so in the log rather than replacing the real error with
	// its own. One case genuinely cannot be undone: the panel refuses to remove an
	// inbound's LAST account ("no client remained in Inbound"), so an account created
	// on an otherwise empty inbound stays. It is a working, ungrouped account with the
	// quota that was typed — visible in the client list, deletable by hand — not a
	// broken one, which is why the original failure is still what the operator is told.
	undo := func(cause error) (*CombinedResult, error) {
		for i := len(created) - 1; i >= 0; i-- {
			if _, err := inboundService.DelInboundClientByEmail(created[i].InboundId, created[i].Email); err != nil {
				logger.Warning("combined account: cannot undo the account added to inbound ",
					created[i].InboundId, ": ", err)
			}
		}
		if err := s.DelGroup(group.Id); err != nil {
			logger.Warning("combined account: cannot undo the group: ", err)
		}
		return nil, cause
	}

	for i, posted := range prepared {
		needRestart, err := inboundService.AddInboundClient(posted)
		if err != nil {
			return undo(err)
		}
		created = append(created, CombinedCreated{
			InboundId:   posted.Id,
			Protocol:    protocols[i],
			Email:       emails[i],
			NeedRestart: needRestart,
		})
	}

	if err := s.SetMembership(group.Id, emails); err != nil {
		return undo(err)
	}

	return &CombinedResult{Group: group, Members: created}, nil
}
