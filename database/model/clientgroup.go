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

	// Reset is the traffic-reset period in days (0 = never), mirroring the per-client
	// field so a group renews on the same schedule its members would have.
	Reset int `json:"reset" form:"reset" gorm:"default:0"`

	// Enable is the operator's switch for the whole customer. Turning it off disables
	// every member; it is not derived from the members, so flipping it back restores
	// exactly the set that was disabled.
	Enable bool `json:"enable" form:"enable" gorm:"default:true"`

	Comment string `json:"comment" form:"comment"`
}
