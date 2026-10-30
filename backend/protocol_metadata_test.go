package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestProtocolMetadataPreservesMixedProfileAndMigratesSavedServers(t *testing.T) {
	vless, err := parseServerURI("vless://90e3da82-374e-46ef-9099-761d39b86b82@example.com:443?security=tls#Node")
	if err != nil {
		t.Fatal(err)
	}
	hy2, err := parseServerURI("hysteria2://test@example.org:443#HY2")
	if err != nil {
		t.Fatal(err)
	}
	var v, h object
	json.Unmarshal(vless.Outbound, &v)
	json.Unmarshal(hy2.Outbound, &h)
	v["tag"] = "vless-node"
	h["tag"] = "hy2-node"
	profile := object{"outbounds": []any{object{"protocol": "freedom", "tag": "direct"}, v, h, v, object{"protocol": "loopback", "tag": "loop", "settings": object{"inboundTag": "reroute"}}}}
	raw, _ := json.Marshal(profile)
	parsed, err := parseSubscription(raw)
	if err != nil {
		t.Fatal(err)
	}
	server := parsed.Servers[0]
	want := []string{"vless", "hysteria2"}
	if !reflect.DeepEqual(server.Protocols, want) {
		t.Fatalf("protocols: %v", server.Protocols)
	}
	if string(server.Profile) != string(raw) {
		t.Fatal("display metadata altered the original profile")
	}
	server.Protocols = nil
	app, err := openApp(filepath.Join(t.TempDir(), "state.json"))
	if err != nil {
		t.Fatal(err)
	}
	app.state.Groups = []Group{{Servers: []ServerConfig{server}}}
	state, _ := json.Marshal(app.state)
	if err := os.WriteFile(app.path, state, 0600); err != nil {
		t.Fatal(err)
	}
	loaded, err := openApp(app.path)
	if err != nil {
		t.Fatal(err)
	}
	restored := loaded.state.Groups[0].Servers[0]
	if !reflect.DeepEqual(restored.Protocols, want) {
		t.Fatalf("saved profile not migrated: %v", restored.Protocols)
	}
	if string(restored.Profile) != string(raw) || restored.ID != server.ID {
		t.Fatal("migration changed server identity or configuration")
	}
}

func TestProtocolMetadataDoesNotMislabelHysteria1(t *testing.T) {
	s := ServerConfig{ServerInfo: ServerInfo{FullProfile: true}, Profile: json.RawMessage(`{"outbounds":[{"protocol":"hysteria","settings":{"version":1}},{"protocol":"hysteria","settings":{"version":2}}]}`)}
	s.updateProtocolMetadata()
	if !reflect.DeepEqual(s.Protocols, []string{"hysteria", "hysteria2"}) {
		t.Fatal(s.Protocols)
	}
}
