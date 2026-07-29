package model

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// The customer-group routes are gated by PermEditClient and PermCreateClient, and a
// reseller HOLDS both -- they are in resellerPerms because a reseller must be able to
// sell and top up ordinary accounts. So the permission mask does not keep them out of
// the group routes; only an explicit deny in each handler does.
//
// That is a fragile arrangement to leave undefended. A group's Total is a shared
// allowance that nothing charges to anyone: ClientGroup has no owner column, and the
// reseller ledger reserves against a client email, which a group has none of. A reseller
// reaching updateClientGroup or renewClientGroup would be minting traffic for free, and
// with no owner to scope by, on any customer in the panel -- another reseller's, or the
// house's.
//
// These two tests are the pair that keeps that shut: the first states that the routes
// really are reachable (so the guard is doing the work, not the permission bits), and
// the second reads the controller source to confirm every one of them still carries it.
// A handler added later, or a guard deleted as redundant, fails here.

func TestResellerHoldsTheBitsGuardingGroupRoutes(t *testing.T) {
	reseller := &User{Enable: true, IsReseller: true}

	// If either of these ever becomes false, the explicit denies below are dead code
	// and this comment is a lie -- which is worth failing over, so it gets revisited
	// rather than quietly rotting.
	if !reseller.Can(PermEditClient) {
		t.Error("reseller lost PermEditClient: the group-route denies may now be redundant")
	}
	if !reseller.Can(PermCreateClient) {
		t.Error("reseller lost PermCreateClient: the combined-account deny may now be redundant")
	}

	// The role is derived, never read from the stored mask, so a tampered or
	// hand-edited permissions column cannot widen it.
	tampered := &User{Enable: true, IsReseller: true, Permissions: ^Permission(0)}
	for _, p := range []Permission{PermPanelSettings, PermXraySettings, PermCoreSettings,
		PermManageResellers, PermCreateInbound, PermEditInbound, PermDeleteInbound} {
		if tampered.Can(p) {
			t.Errorf("a reseller with every bit set was granted %v", p)
		}
	}

	// A disabled reseller can do nothing at all, whatever the role says.
	off := &User{Enable: false, IsReseller: true}
	if off.Can(PermEditClient) {
		t.Error("a disabled reseller was granted PermEditClient")
	}
}

func TestEveryClientGroupHandlerDeniesResellers(t *testing.T) {
	src, err := os.ReadFile("../../web/controller/inbound.go")
	if err != nil {
		t.Fatalf("read controller: %v", err)
	}
	text := string(src)

	// Every mutating group handler. getClientGroups is deliberately absent: it does
	// not refuse, it answers a reseller with an empty list, which is checked below.
	handlers := []string{
		"addClientGroup",
		"updateClientGroup",
		"delClientGroup",
		"setClientGroupMembership",
		"renewClientGroup",
	}
	for _, name := range handlers {
		t.Run(name, func(t *testing.T) {
			body, ok := handlerBody(text, name)
			if !ok {
				t.Fatalf("handler %s not found -- renamed? the guard must move with it", name)
			}
			if !strings.Contains(body, "denyForReseller(c, msgResellerNoGroups)") {
				t.Errorf("%s does not deny resellers: a reseller holds PermEditClient, "+
					"so this route would let them set a shared allowance nothing charges for, "+
					"on a group with no owner to scope it to", name)
			}
		})
	}

	// The read path must not hand a reseller every combined customer in the panel.
	body, ok := handlerBody(text, "getClientGroups")
	if !ok {
		t.Fatal("getClientGroups not found")
	}
	if !strings.Contains(body, "IsReseller") {
		t.Error("getClientGroups does not scope by role: GetGroups returns every group " +
			"in the panel, which is every combined customer's name, allowance and expiry")
	}
}

// handlerBody returns the source of one InboundController method, from its signature to
// the closing brace in column 0. Crude on purpose: a real parser would be more code than
// the thing it checks, and gofmt guarantees the terminator.
func handlerBody(src, name string) (string, bool) {
	sig := regexp.MustCompile(`func \(a \*InboundController\) ` + regexp.QuoteMeta(name) + `\(`)
	loc := sig.FindStringIndex(src)
	if loc == nil {
		return "", false
	}
	rest := src[loc[0]:]
	if end := strings.Index(rest, "\n}\n"); end >= 0 {
		return rest[:end], true
	}
	return rest, true
}
