package xray

// ClientTraffic represents traffic statistics and limits for a specific client.
// It tracks upload/download usage, expiry times, and online status for inbound clients.
type ClientTraffic struct {
	Id        int  `json:"id" form:"id" gorm:"primaryKey;autoIncrement"`
	InboundId int  `json:"inboundId" form:"inboundId"`
	Enable    bool `json:"enable" form:"enable"`
	// Email is the global account identity, unique across ALL inbounds (see the email
	// helpers in web/service/inbound.go). This index is the last line of defense, not
	// a formality: ImportDB (web/service/server.go) swaps the SQLite file wholesale
	// and so bypasses every service-level check, leaving the constraint as the only
	// thing standing between a hand-edited backup and two clients sharing an identity.
	Email      string `json:"email" form:"email" gorm:"unique"`
	UUID       string `json:"uuid" form:"uuid" gorm:"-"`
	SubId      string `json:"subId" form:"subId" gorm:"-"`
	Up         int64  `json:"up" form:"up"`
	Down       int64  `json:"down" form:"down"`
	AllTime    int64  `json:"allTime" form:"allTime"`
	ExpiryTime int64  `json:"expiryTime" form:"expiryTime"`
	Total      int64  `json:"total" form:"total"`
	Reset      int    `json:"reset" form:"reset" gorm:"default:0"`
	LastOnline int64  `json:"lastOnline" form:"lastOnline" gorm:"default:0"`

	// GroupId links this account to a ClientGroup, whose quota and expiry it shares
	// with the group's other members. 0 (the default, and what every existing row
	// migrates to) means the account stands alone and is billed exactly as before.
	//
	// One person usually wants one allowance across whatever they happen to connect
	// with — OpenVPN on a phone, VLESS on a laptop, L2TP where nothing else gets
	// through. Protocols cannot share an ACCOUNT (VLESS authenticates by UUID,
	// OpenVPN and L2TP by username and password), so what is shared instead is the
	// allowance: separate accounts, one budget.
	//
	// Usage is deliberately NOT mirrored onto the member rows. Each row keeps
	// accumulating only its own bytes, exactly as it does today, and the group's
	// figure is summed on demand. Writing the group total back would double-count:
	// the next tick adds each member's delta to a row that already holds everyone's
	// bytes.
	GroupId int `json:"groupId" form:"groupId" gorm:"default:0;index"`
}
