package service

import "testing"

func intp(v int) *int { return &v }

// The per-account User Limit must never exceed the inbound's, because the inbound's
// value is the address-pool stride: an account allowed more devices than that would
// lease addresses out of the NEXT account's block, putting two accounts on one IP.
func TestResolveOvpnUserLimit(t *testing.T) {
	cases := []struct {
		name     string
		client   *int
		inboundK int
		want     int
	}{
		{"absent inherits the inbound", nil, 4, 4},
		{"zero inherits rather than meaning unlimited", intp(0), 4, 4},
		{"one device caps a shared account", intp(1), 4, 1},
		{"below the inbound is honoured", intp(3), 4, 3},
		{"above the inbound is clamped to it", intp(9), 4, 4},
		{"equal to the inbound is unchanged", intp(4), 4, 4},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := resolveOvpnUserLimit(openvpnClient{UserLimit: c.client}, c.inboundK)
			if got != c.want {
				t.Errorf("resolveOvpnUserLimit(%v, K=%d) = %d, want %d", c.client, c.inboundK, got, c.want)
			}
		})
	}
}
