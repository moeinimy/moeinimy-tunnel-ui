package xray

import (
	"encoding/json"
	"regexp"
	"strconv"
)

// ParseStatsJSON turns what `xray api statsquery` prints into the same slices
// GetTraffic returns from the gRPC API.
//
// A foreign node's core cannot be reached over gRPC from here — the node dials
// out and accepts nothing inbound — so its counters come back as the CLI's JSON,
// read by the agent on the node itself. Parsing it into the identical shapes is
// what lets a node's traffic go through the panel's ONE accounting path: quotas,
// expiry and the disabling that follows must not be a second implementation that
// drifts from the local one.
//
// The counter names are the same either way, so the same expressions read them.
func ParseStatsJSON(raw []byte) ([]*Traffic, []*ClientTraffic, error) {
	var payload struct {
		Stat []struct {
			Name string `json:"name"`
			// Xray prints the value as a JSON string, and omits it entirely at
			// zero — hence a string here rather than a number.
			Value string `json:"value"`
		} `json:"stat"`
	}
	if err := json.Unmarshal(raw, &payload); err != nil {
		return nil, nil, err
	}

	trafficRegex := regexp.MustCompile(`(inbound|outbound)>>>([^>]+)>>>traffic>>>(downlink|uplink)`)
	clientTrafficRegex := regexp.MustCompile(`user>>>([^>]+)>>>traffic>>>(downlink|uplink)`)

	tagTrafficMap := make(map[string]*Traffic)
	emailTrafficMap := make(map[string]*ClientTraffic)

	for _, stat := range payload.Stat {
		value, err := strconv.ParseInt(stat.Value, 10, 64)
		if err != nil || value == 0 {
			continue
		}
		if matches := trafficRegex.FindStringSubmatch(stat.Name); len(matches) == 4 {
			processTraffic(matches, value, tagTrafficMap)
		} else if matches := clientTrafficRegex.FindStringSubmatch(stat.Name); len(matches) == 3 {
			processClientTraffic(matches, value, emailTrafficMap)
		}
	}
	return mapToSlice(tagTrafficMap), mapToSlice(emailTrafficMap), nil
}
