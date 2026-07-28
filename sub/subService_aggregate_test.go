package sub

import (
	"testing"

	"github.com/mhsanaei/3x-ui/v2/xray"
)

const gb = int64(1 << 30)

func TestAggregateTraffic(t *testing.T) {
	tests := []struct {
		name    string
		in      []xray.ClientTraffic
		wantUp  int64
		wantDwn int64
		wantTot int64
		wantExp int64
	}{
		{
			name: "one account is itself",
			in: []xray.ClientTraffic{
				{Up: 1 * gb, Down: 4 * gb, Total: 50 * gb, ExpiryTime: 111},
			},
			wantUp: 1 * gb, wantDwn: 4 * gb, wantTot: 50 * gb, wantExp: 111,
		},
		{
			// The case this function exists for: a combined customer whose accounts
			// share ONE 50 GB group. enforceGroups writes 50 GB onto both rows, and
			// summing them would sell the customer their own quota twice.
			name: "grouped accounts share one allowance",
			in: []xray.ClientTraffic{
				{Up: 2 * gb, Down: 8 * gb, Total: 50 * gb, ExpiryTime: 222, GroupId: 7},
				{Up: 5 * gb, Down: 20 * gb, Total: 50 * gb, ExpiryTime: 222, GroupId: 7},
			},
			wantUp: 7 * gb, wantDwn: 28 * gb, wantTot: 50 * gb, wantExp: 222,
		},
		{
			name: "two different groups each count once",
			in: []xray.ClientTraffic{
				{Up: 1 * gb, Total: 50 * gb, ExpiryTime: 333, GroupId: 7},
				{Up: 1 * gb, Total: 50 * gb, ExpiryTime: 333, GroupId: 7},
				{Up: 1 * gb, Total: 30 * gb, ExpiryTime: 333, GroupId: 8},
			},
			wantUp: 3 * gb, wantTot: 80 * gb, wantExp: 333,
		},
		{
			name: "an ungrouped account beside a group adds its own",
			in: []xray.ClientTraffic{
				{Down: 1 * gb, Total: 50 * gb, ExpiryTime: 444, GroupId: 7},
				{Down: 1 * gb, Total: 50 * gb, ExpiryTime: 444, GroupId: 7},
				{Down: 1 * gb, Total: 20 * gb, ExpiryTime: 444},
			},
			wantDwn: 3 * gb, wantTot: 70 * gb, wantExp: 444,
		},
		{
			name: "one unlimited account makes the subscription unlimited",
			in: []xray.ClientTraffic{
				{Up: 1 * gb, Total: 50 * gb, ExpiryTime: 555},
				{Up: 1 * gb, Total: 0, ExpiryTime: 555},
			},
			wantUp: 2 * gb, wantTot: 0, wantExp: 555,
		},
		{
			// A group whose quota is unlimited must not be rescued by a second member
			// row that happens to be counted first.
			name: "unlimited group",
			in: []xray.ClientTraffic{
				{Up: 1 * gb, Total: 0, ExpiryTime: 666, GroupId: 9},
				{Up: 1 * gb, Total: 0, ExpiryTime: 666, GroupId: 9},
			},
			wantUp: 2 * gb, wantTot: 0, wantExp: 666,
		},
		{
			name: "accounts that disagree on the date report none",
			in: []xray.ClientTraffic{
				{Total: 10 * gb, ExpiryTime: 777},
				{Total: 10 * gb, ExpiryTime: 888},
			},
			wantTot: 20 * gb, wantExp: 0,
		},
		{
			// Members of one group share an expiry, so a second row disagreeing cannot
			// happen — but the row is skipped for quota purposes and must not be
			// skipped in a way that changes the date either.
			name: "grouped accounts keep their shared date",
			in: []xray.ClientTraffic{
				{Total: 10 * gb, ExpiryTime: 999, GroupId: 3},
				{Total: 10 * gb, ExpiryTime: 999, GroupId: 3},
			},
			wantTot: 10 * gb, wantExp: 999,
		},
		{
			name:    "no accounts",
			in:      nil,
			wantTot: 0, wantExp: 0,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := aggregateTraffic(tt.in)
			if got.Up != tt.wantUp {
				t.Errorf("Up = %d, want %d", got.Up, tt.wantUp)
			}
			if got.Down != tt.wantDwn {
				t.Errorf("Down = %d, want %d", got.Down, tt.wantDwn)
			}
			if got.Total != tt.wantTot {
				t.Errorf("Total = %d, want %d", got.Total, tt.wantTot)
			}
			if got.ExpiryTime != tt.wantExp {
				t.Errorf("ExpiryTime = %d, want %d", got.ExpiryTime, tt.wantExp)
			}
		})
	}
}
