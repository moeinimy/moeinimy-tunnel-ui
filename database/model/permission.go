package model

// Permission is a bitmask of what an admin may do, stored as an integer column on
// User. A super admin bypasses the mask entirely and is the only one who may
// manage other admins.
//
// The bitmask is a storage detail. Slugs (below) are what cross the wire to the
// API and the UI, so bits may be reordered freely but a slug rename is breaking.
type Permission int64

const (
	PermAccessInbounds Permission = 1 << iota
	PermCreateInbound
	PermEditInbound
	PermDeleteInbound
	PermCreateClient
	PermEditClient
	PermDeleteClient
	PermBulkOperation
	PermCoreSettings
	PermXraySettings
	PermPanelSettings
)

// PermissionDef pairs a bit with its stable wire slug.
type PermissionDef struct {
	Bit  Permission `json:"-"`
	Slug string     `json:"slug"`
}

// AllPermissions is the canonical list, in the order the Admins UI renders it.
var AllPermissions = []PermissionDef{
	{PermAccessInbounds, "accessInbounds"},
	{PermCreateInbound, "createInbound"},
	{PermEditInbound, "editInbound"},
	{PermDeleteInbound, "deleteInbound"},
	{PermCreateClient, "createClient"},
	{PermEditClient, "editClient"},
	{PermDeleteClient, "deleteClient"},
	{PermBulkOperation, "bulkOperation"},
	{PermCoreSettings, "accessCoreSettings"},
	{PermXraySettings, "accessXraySettings"},
	{PermPanelSettings, "accessPanelSettings"},
}

// Has reports whether every bit in q is set in p.
func (p Permission) Has(q Permission) bool { return p&q == q }

// Slugs expands the mask into its wire slugs, for the API and the UI.
func (p Permission) Slugs() []string {
	out := make([]string, 0, len(AllPermissions))
	for _, d := range AllPermissions {
		if p.Has(d.Bit) {
			out = append(out, d.Slug)
		}
	}
	return out
}

// PermissionsFromSlugs folds wire slugs back into a mask. Unknown slugs are
// ignored rather than erroring: a client sending a stale slug should lose that
// one permission, not have the whole save rejected.
func PermissionsFromSlugs(slugs []string) Permission {
	var p Permission
	for _, s := range slugs {
		for _, d := range AllPermissions {
			if d.Slug == s {
				p |= d.Bit
				break
			}
		}
	}
	return p
}

// Can reports whether the user may do perm. Super admins may do anything, which
// is why they are the only account type that can reach the escalation-class
// endpoints (DB export/import, panel update, systemd unit, host reboot).
func (u *User) Can(perm Permission) bool {
	if u == nil || !u.Enable {
		return false
	}
	return u.IsSuperAdmin || u.Permissions.Has(perm)
}
