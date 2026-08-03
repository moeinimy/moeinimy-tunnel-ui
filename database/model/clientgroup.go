package model

// ClientGroup is one shared allowance spanning several accounts.
//
// A person is one customer however they connect. They may hold an OpenVPN account
// for the phone, a VLESS account for the laptop and an L2TP account for the network
// that blocks everything else — three accounts, because the protocols cannot share
// one (VLESS authenticates by UUID, OpenVPN and L2TP by username and password), but
// one person, and so one quota and one expiry date. A group is that customer.
//
// The group owns the entitlement; the member accounts own the credentials. Total and
// ExpiryTime here REPLACE each member's own values while it belongs to a group, so
// there is exactly one place the answer to "how much is left" comes from, rather than
// three numbers an operator has to keep in step by hand.
type ClientGroup struct {
	Id   int    `json:"id" form:"id" gorm:"primaryKey;autoIncrement"`
	Name string `json:"name" form:"name" gorm:"unique;not null"`

	// Total is the shared allowance in BYTES (0 = unlimited), matching
	// xray.ClientTraffic.Total so the two are directly comparable and no conversion
	// can be forgotten at a call site. The UI takes GB and converts.
	Total int64 `json:"total" form:"total" gorm:"default:0"`

	// ExpiryTime is the shared expiry as a millisecond epoch (0 = never), again
	// matching xray.ClientTraffic.
	ExpiryTime int64 `json:"expiryTime" form:"expiryTime" gorm:"default:0"`

	// UsedCarry is traffic that a member accumulated and then took with it when the
	// row was deleted, in BYTES.
	//
	// Consumption lives on each member's ClientTraffic row, so removing a protocol
	// from a customer — or deleting the inbound it lived on — used to take that
	// protocol's usage out of the group's total as well: the shared pool refilled
	// itself by the amount of whatever was removed. The bytes were spent; changing
	// what a subscription CONTAINS must not change what it has USED.
	//
	// The departing row's usage is added here before it goes, and every reading of
	// the group's consumption adds this to the live rows. A traffic reset clears it
	// with them.
	UsedCarry int64 `json:"usedCarry" gorm:"default:0"`

	// Reset is the traffic-reset period in days (0 = never), mirroring the per-client
	// field so a group renews on the same schedule its members would have.
	Reset int `json:"reset" form:"reset" gorm:"default:0"`

	// Enable is the operator's switch for the whole customer. Turning it off disables
	// every member; it is not derived from the members, so flipping it back restores
	// exactly the set that was disabled.
	Enable bool `json:"enable" form:"enable" gorm:"default:true"`

	Comment string `json:"comment" form:"comment"`

	// PlanTotal and PlanDays are what the customer was SOLD, recorded once when the
	// group is created and never rewritten by ordinary edits.
	//
	// They exist so renewing is a single click that reinstates the original terms. The
	// live Total and ExpiryTime cannot answer that: by renewal time Total is whatever is
	// left after a top-up or a trim, and ExpiryTime is a date in the past. An operator
	// asked to "give them the same again" would otherwise have to remember what the same
	// was.
	//
	// Zero means unknown -- groups created before this existed, and any group whose plan
	// was genuinely unlimited -- and the UI offers no one-click renewal for those rather
	// than guessing a number.
	PlanTotal int64 `json:"planTotal" form:"planTotal" gorm:"default:0"`
	PlanDays  int   `json:"planDays" form:"planDays" gorm:"default:0"`
}
