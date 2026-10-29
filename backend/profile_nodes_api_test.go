package main

import (
	"bytes"
	"encoding/json"
	"testing"
)

func TestExtractNodesAPIRequiresExplicitOwnerAndKeepsSource(t *testing.T) {
	a := newTestApp(t)
	owner := create(t, a)
	node, err := parseServerURI("vless://00000000-0000-4000-8000-000000000001@example.com:443?security=none&type=tcp#Fixture")
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(object{"outbounds": []any{json.RawMessage(node.Outbound)}, "routing": object{"rules": []any{object{"outboundTag": "proxy", "domain": []string{"example.com"}}}}, "dns": object{"servers": []string{"localhost"}}})
	source := ServerConfig{ServerInfo: ServerInfo{ID: "full", Name: "Profile", FullProfile: true}, Profile: raw}
	a.state.Groups[0].Servers = []ServerConfig{source}
	path := "/api/servers/full/extract-nodes"
	expect(t, localProbeCall(a, "POST", path, owner, map[string]bool{}), 400)
	if len(a.state.Groups[0].Servers) != 1 {
		t.Fatal("unacknowledged extraction changed source")
	}
	a.state.Groups[0].Devices = append(a.state.Groups[0].Devices, Member{Device: Device{ID: "reader", Owner: false}, TokenHash: digest("01234567890123456789012345678901")})
	ack := map[string]bool{"acknowledgeProfileRulesOmitted": true}
	expect(t, localProbeCall(a, "POST", path, "01234567890123456789012345678901", ack), 403)
	expect(t, localProbeCall(a, "POST", path, owner, ack), 200)
	g := &a.state.Groups[0]
	if len(g.Servers) != 2 || !g.Servers[0].FullProfile || !bytes.Equal(g.Servers[0].Profile, raw) {
		t.Fatal("source profile was replaced")
	}
	copy := g.Servers[1]
	if copy.FullProfile || len(copy.Profile) > 0 || copy.SubscriptionID == g.Servers[0].SubscriptionID {
		t.Fatal("copy retained provider route/source")
	}
	if len(g.Subscriptions) != 2 || g.Subscriptions[1].URL != "" {
		t.Fatal("node copies must be a separate manual source")
	}
	reopened, err := openApp(a.path)
	if err != nil || len(reopened.state.Groups[0].Servers) != 2 {
		t.Fatal("copies were not persisted")
	}
	if a.engine != nil {
		t.Fatal("extraction unexpectedly started a connection")
	}
}
