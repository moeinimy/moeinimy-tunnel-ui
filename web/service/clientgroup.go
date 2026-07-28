package service

import (
	"encoding/json"
	"strings"
	"time"

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

// GetGroup loads one group.
func (s *ClientGroupService) GetGroup(id int) (*model.ClientGroup, error) {
	g := &model.ClientGroup{}
	if err := database.GetDB().Model(model.ClientGroup{}).Where("id = ?", id).
		First(g).Error; err != nil {
		return nil, err
	}
	return g, nil
}

// MirrorToMembers pushes a group's entitlement onto its accounts immediately.
//
// enforceGroups does this on every traffic tick anyway, so this is not what makes a
// change take effect — it is what makes it VISIBLE now. A customer who has just paid
// opens their subscription page within seconds, and being told they are still out of
// traffic until the next tick is the renewal appearing not to have worked.
//
// It writes only what the group owns, and re-enables accounts the system disabled while
// leaving alone any the operator switched off by hand — the same distinction
// enforceGroups draws, for the same reason.
func (s *ClientGroupService) MirrorToMembers(id int) error {
	g, err := s.GetGroup(id)
	if err != nil {
		return err
	}
	db := database.GetDB()
	return db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Model(xray.ClientTraffic{}).Where("group_id = ?", id).
			Updates(map[string]any{
				"total":       g.Total,
				"expiry_time": g.ExpiryTime,
				// Members never carry the renewal period: the GROUP renews itself, and a
				// member that renewed on its own would wipe the counters the shared usage
				// is summed from.
				"reset": 0,
			}).Error; err != nil {
			return err
		}
		if !g.Enable {
			return nil
		}
		revivable, rerr := operatorEnabledMembers(tx, id)
		if rerr != nil || len(revivable) == 0 {
			return rerr
		}
		return tx.Model(xray.ClientTraffic{}).
			Where("group_id = ? AND enable = 0 AND email IN (?)", id, revivable).
			Update("enable", true).Error
	})
}

// SetPlan records new sale terms for a group, which is what renewing at different terms
// is. Kept apart from UpdateGroup because an ordinary edit — trimming a quota, nudging a
// date — is not a new sale, and must not quietly redefine what "the same again" means
// the next time the customer renews.
func (s *ClientGroupService) SetPlan(id int, planTotal int64, planDays int) error {
	if id == 0 {
		return common.NewError("group id is required")
	}
	return database.GetDB().Model(model.ClientGroup{}).Where("id = ?", id).
		Updates(map[string]any{"plan_total": planTotal, "plan_days": planDays}).Error
}

// DelGroup removes a group and releases its members, who go back to being billed on
// their own totals. Membership is cleared explicitly rather than left to a foreign
// key: a stale group_id would leave those accounts pointing at nothing, and the
// enforcement below would stop mirroring an entitlement onto them while their own
// expiry still read whatever the group last wrote.
// It is deliberately TWO transactions, not one.
//
// The obvious single transaction bundles the delete with restoring each member's own
// quota — and then any failure in the restore rolls the delete back too. The operator
// pressed Delete, the group is still there, and the only sign anything happened is a
// toast. That is precisely how deleting a customer came to appear to do nothing after
// the restore step was added: the delete itself was never the part that failed.
//
// So the deletion the operator asked for commits on its own, and the restore follows as
// a separate, best-effort step. Its failure mode is a member left carrying the departed
// group's quota, which an operator can fix by editing the account; the alternative
// failure mode is a customer that cannot be deleted at all, which they cannot.
func (s *ClientGroupService) DelGroup(id int) error {
	db := database.GetDB()

	// Collected before the membership is cleared: afterwards there is no way left to
	// tell which accounts used to belong to this group.
	var emails []string
	if err := db.Model(xray.ClientTraffic{}).Where("group_id = ?", id).
		Pluck("email", &emails).Error; err != nil {
		return err
	}

	if err := db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Model(xray.ClientTraffic{}).Where("group_id = ?", id).
			Update("group_id", 0).Error; err != nil {
			return err
		}
		return tx.Delete(model.ClientGroup{}, id).Error
	}); err != nil {
		return err
	}

	// The members' rows still carry the deleted group's quota and expiry; without this
	// a customer whose group was removed keeps whatever that group last wrote onto them,
	// including a spent quota nothing would ever lift.
	if err := restoreOwnEntitlement(db, emails); err != nil {
		logger.Warning("client group ", id, " was deleted but its members kept its "+
			"entitlement; edit those accounts to reset their own quota: ", err)
	}
	return nil
}

// SetMembership puts the named accounts in a group (id 0 removes them from any).
func (s *ClientGroupService) SetMembership(groupId int, emails []string) error {
	if len(emails) == 0 {
		return nil
	}
	return database.GetDB().Transaction(func(tx *gorm.DB) error {
		if err := tx.Model(xray.ClientTraffic{}).
			Where("email IN (?)", emails).Update("group_id", groupId).Error; err != nil {
			return err
		}
		if groupId != 0 {
			// Joining: enforceGroups overwrites the entitlement on the next tick, so
			// there is nothing to write here.
			return nil
		}
		// Leaving hands the account back its OWN entitlement.
		return restoreOwnEntitlement(tx, emails)
	})
}

// restoreOwnEntitlement copies each account's own quota, expiry and renewal period out
// of its inbound's settings JSON and back onto its traffic row.
//
// It exists because a group OWNS those three while an account belongs to one: every tick
// of enforceGroups overwrites them with the group's. Nothing else would ever put the
// account's own figures back, so an account released from a spent group would stay spent
// for good, and one released from a live group would go on spending an allowance it no
// longer belongs to. The settings JSON is the only place its own figures survived.
//
// An account whose client entry has since been removed keeps what it had, rather than
// silently becoming unlimited.
//
// Done in Go rather than SQL, and that is the whole point of this shape. The obvious
// version is one UPDATE with correlated JSON_EACH subqueries — and it is a trap:
// json_each() raises "malformed JSON" on anything that is not a JSON array, so a single
// inbound whose settings carry no clients key (a dokodemo tunnel endpoint, say) makes the
// statement fail for EVERY account. Inside a transaction that means the whole operation
// rolls back, which is exactly how deleting a customer came to do nothing at all.
//
// Reading the inbounds and walking them here cannot fail that way: an inbound that does
// not parse is skipped, and every other account is still restored.
func restoreOwnEntitlement(tx *gorm.DB, emails []string) error {
	if len(emails) == 0 {
		return nil
	}
	wanted := make(map[string]bool, len(emails))
	for _, e := range emails {
		wanted[e] = true
	}

	var inbounds []*model.Inbound
	if err := tx.Model(model.Inbound{}).Find(&inbounds).Error; err != nil {
		return err
	}

	for _, inbound := range inbounds {
		var settings struct {
			Clients []struct {
				Email      string `json:"email"`
				TotalGB    int64  `json:"totalGB"`
				ExpiryTime int64  `json:"expiryTime"`
				Reset      int    `json:"reset"`
			} `json:"clients"`
		}
		// Not an error worth failing on: plenty of inbounds legitimately have no
		// clients array, and one that is genuinely corrupt should not stop the rest.
		if err := json.Unmarshal([]byte(inbound.Settings), &settings); err != nil {
			continue
		}
		for _, c := range settings.Clients {
			if c.Email == "" || !wanted[c.Email] {
				continue
			}
			if err := tx.Model(xray.ClientTraffic{}).
				Where("email = ? AND inbound_id = ?", c.Email, inbound.Id).
				Updates(map[string]any{
					"total":       c.TotalGB,
					"expiry_time": c.ExpiryTime,
					"reset":       c.Reset,
				}).Error; err != nil {
				return err
			}
		}
	}
	return nil
}

// operatorEnabledMembers lists the group's accounts whose own settings say enabled.
//
// It answers the one question that separates "the system disabled this" from "the
// operator did": the manual switch writes both the settings JSON and the traffic row,
// while disableInvalidClients only ever writes the row. So a member whose settings say
// enabled but whose row says disabled was switched off by enforcement and may come back,
// and one whose settings say disabled stays off however healthy the group becomes.
func operatorEnabledMembers(tx *gorm.DB, groupId int) ([]string, error) {
	var members []string
	if err := tx.Model(xray.ClientTraffic{}).
		Where("group_id = ? AND enable = 0", groupId).
		Pluck("email", &members).Error; err != nil {
		return nil, err
	}
	if len(members) == 0 {
		return nil, nil
	}
	wanted := make(map[string]bool, len(members))
	for _, e := range members {
		wanted[e] = true
	}

	var inbounds []*model.Inbound
	if err := tx.Model(model.Inbound{}).Find(&inbounds).Error; err != nil {
		return nil, err
	}
	var out []string
	for _, inbound := range inbounds {
		var settings struct {
			Clients []struct {
				Email  string `json:"email"`
				Enable *bool  `json:"enable"`
			} `json:"clients"`
		}
		if err := json.Unmarshal([]byte(inbound.Settings), &settings); err != nil {
			continue
		}
		for _, c := range settings.Clients {
			// A missing enable key means enabled, which is what every client model
			// defaults to; a pointer is what tells the two apart from false.
			if c.Email != "" && wanted[c.Email] && (c.Enable == nil || *c.Enable) {
				out = append(out, c.Email)
			}
		}
	}
	return out, nil
}

// enforceGroups mirrors each group's entitlement onto its members and expires them
// together when the group's SHARED usage runs out.
//
// The group owns every part of the entitlement that has state: the quota, the expiry
// date, the delayed-start clock and the renewal period. Members own only their
// credentials. Anything with state that were left to the members would be N copies of
// it for one customer, drifting apart — three different start dates from three first
// connections, or three renewals each wiping the counters the shared usage is summed
// from.
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
// It reports whether Xray needs restarting: only re-enabling an account requires it,
// because Xray keeps its accounts in memory and was told to drop this one.
func (s *ClientGroupService) enforceGroups(tx *gorm.DB) (bool, error) {
	needRestart := false
	var groups []*model.ClientGroup
	if err := tx.Model(model.ClientGroup{}).Find(&groups).Error; err != nil {
		return false, err
	}
	// One reading of the clock for the whole pass, so every group in this tick is
	// judged against the same instant.
	now := time.Now().UnixMilli()
	for _, g := range groups {
		var agg struct{ Used int64 }
		if err := tx.Model(xray.ClientTraffic{}).
			Select("COALESCE(SUM(up),0) + COALESCE(SUM(down),0) as used").
			Where("group_id = ?", g.Id).Scan(&agg).Error; err != nil {
			return needRestart, err
		}

		// A delayed start (expiry stored NEGATIVE, as minus the duration) becomes a
		// real date the moment the customer first sends traffic — and it is the
		// GROUP's clock that starts, once, on whichever protocol they happened to
		// open first. Converting here rather than letting each member convert itself
		// is the whole point: three accounts converting independently would give one
		// customer three different expiry dates, and this loop would then overwrite
		// each of them with the group's still-negative value on the next tick, which
		// is an account that never expires at all.
		//
		// Written back to the group, so it converts exactly once and every later tick
		// sees an ordinary date.
		if g.ExpiryTime < 0 && agg.Used > 0 {
			g.ExpiryTime = now - g.ExpiryTime
			if err := tx.Model(model.ClientGroup{}).Where("id = ?", g.Id).
				Update("expiry_time", g.ExpiryTime).Error; err != nil {
				return needRestart, err
			}
		}

		// Renewal is the GROUP's too. One period for the customer: the allowance
		// refills once and the next one starts for all of their accounts together.
		if g.Reset > 0 && g.ExpiryTime > 0 && g.ExpiryTime <= now {
			next := g.ExpiryTime
			for next <= now {
				next += int64(g.Reset) * 86400000
			}
			if err := tx.Model(xray.ClientTraffic{}).Where("group_id = ?", g.Id).
				Updates(map[string]any{"up": 0, "down": 0}).Error; err != nil {
				return needRestart, err
			}
			if err := tx.Model(model.ClientGroup{}).Where("id = ?", g.Id).
				Update("expiry_time", next).Error; err != nil {
				return needRestart, err
			}
			g.ExpiryTime = next
			// The counters the sum was taken from are now zero, so the group is not
			// spent any more: recompute from this tick rather than the previous one.
			agg.Used = 0
		}

		spent := g.Total > 0 && agg.Used >= g.Total
		expiry := g.ExpiryTime
		if spent || !g.Enable {
			// 1ms after the epoch: unambiguously past, and distinct from 0, which
			// disableInvalidClients reads as "never expires".
			expiry = 1
		}

		// A group that is healthy again brings its accounts back. Renew the period,
		// raise the quota or flip the group on, and the members return — which is the
		// whole promise of the group owning the entitlement. Writing a future expiry is
		// NOT enough on its own: disableInvalidClients flipped enable to false and
		// nothing ever flips it back, so without this a renewed group renews into three
		// permanently dead accounts.
		//
		// "settings say enabled, traffic row says disabled" is precisely "the system
		// disabled this, the operator did not": the manual switch writes both, while
		// disableInvalidClients only ever writes the row. So an account an operator
		// turned off by hand stays off, and RADIUS already draws the same distinction
		// on every login.
		//
		// Resolved in Go for the same reason restoreOwnEntitlement is: json_each()
		// raises on anything that is not a JSON array, so one inbound with no clients
		// key would make this fail — and this runs on EVERY traffic tick, inside the
		// transaction that enforces every group. The blast radius of that SQL was the
		// whole feature.
		if !spent && g.Enable {
			revivable, rerr := operatorEnabledMembers(tx, g.Id)
			if rerr != nil {
				return needRestart, rerr
			}
			var res *gorm.DB
			if len(revivable) > 0 {
				res = tx.Model(xray.ClientTraffic{}).
					Where("group_id = ? AND enable = 0 AND email IN (?)", g.Id, revivable).
					Update("enable", true)
			} else {
				res = &gorm.DB{RowsAffected: 0}
			}
			if res.Error != nil {
				return needRestart, res.Error
			}
			// Xray holds its accounts in memory and was told to remove these; the VPN
			// backends re-read enable from the row on every login and need nothing.
			if res.RowsAffected > 0 {
				needRestart = true
			}
		}

		if err := tx.Model(xray.ClientTraffic{}).Where("group_id = ?", g.Id).
			Updates(map[string]any{
				"total":       g.Total,
				"expiry_time": expiry,
				// Deliberately ZERO, never g.Reset. autoRenewClients renews an account
				// by pushing ITS expiry forward and zeroing ITS counters, and a member
				// carrying a reset period would be renewed the moment the group's
				// expiry passed — zeroing the very counters the group's usage is summed
				// from. The allowance would refill itself every tick and the customer
				// would never run out. The group renews itself above instead; members
				// are told not to.
				"reset": 0,
			}).Error; err != nil {
			return needRestart, err
		}
	}
	return needRestart, nil
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

	// Record what is being sold, once, so renewing later can reinstate these terms
	// rather than whatever the allowance has been edited to by then. A delayed start is
	// stored as a negative duration, which is already a number of days.
	group.PlanTotal = group.Total
	switch {
	case group.ExpiryTime < 0:
		group.PlanDays = int(-group.ExpiryTime / 86400000)
	case group.ExpiryTime > 0:
		days := (group.ExpiryTime - time.Now().UnixMilli()) / 86400000
		if days > 0 {
			group.PlanDays = int(days)
		}
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
