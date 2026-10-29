package main

import (
	"bytes"
	"encoding/json"
	"testing"
)

func TestExtractProfileNodesPreservesOriginalAndRawValues(t *testing.T) {
	realShape := providerDefaultNode(t, 443, "FbzRLPlQIpk7z1rfW4mG0mFBQ9LB9nc8LmGvzKDSRCE")
	vmessOut := object{
		"protocol": "vmess", "tag": "vmess-copy",
		"settings": object{"vnext": []any{
			object{"address": "example.com", "port": 443, "users": []any{object{"id": nativeTestUUID, "alterId": 0, "security": "auto"}}},
		}},
	}
	vmess, err := serverFromOutbound("VMess", vmessOut)
	if err != nil {
		t.Fatal(err)
	}
	trojan, err := parseServerURI("trojan://test-only-password@example.com:443?sni=example.com")
	if err != nil {
		t.Fatal(err)
	}
	ss, err := parseServerURI("ss://aes-128-gcm:test-only-password@example.com:8388")
	if err != nil {
		t.Fatal(err)
	}
	outboundSources := []json.RawMessage{realShape.Outbound, vmess.Outbound, trojan.Outbound, ss.Outbound}
	profile := object{"remarks": "Synthetic provider profile", "dns": object{"servers": []string{"localhost"}}, "routing": object{"balancers": []any{object{"tag": "provider-balancer", "selector": []string{"proxy"}, "strategy": object{"type": "random"}}}, "rules": []any{object{"type": "field", "balancerTag": "provider-balancer", "network": "tcp"}}}, "outbounds": []any{json.RawMessage(realShape.Outbound), object{"protocol": "freedom", "tag": "direct"}, json.RawMessage(vmess.Outbound), json.RawMessage(trojan.Outbound), json.RawMessage(ss.Outbound), object{"protocol": "loopback", "tag": "fallback"}, object{"protocol": "http", "settings": object{}}}}
	raw, _ := json.MarshalIndent(profile, "", "  ")
	source := ServerConfig{ServerInfo: ServerInfo{ID: "original-profile", Name: "Synthetic profile", FullProfile: true, SubscriptionID: "original-source", NodeCount: 5}, Profile: raw}
	before := append([]byte(nil), source.Profile...)
	nodes, err := extractProfileNodes(source)
	if err != nil {
		t.Fatal(err)
	}
	if len(nodes) != 4 {
		t.Fatalf("expected four supported protocol copies, got %d", len(nodes))
	}
	if !bytes.Equal(source.Profile, before) || !source.FullProfile || source.ID != "original-profile" || source.Outbound != nil {
		t.Fatal("original profile modified")
	}
	var original struct {
		Outbounds []json.RawMessage `json:"outbounds"`
	}
	_ = json.Unmarshal(raw, &original)
	positions := []int{0, 2, 3, 4}
	for index, node := range nodes {
		if node.FullProfile || len(node.Profile) != 0 || node.RuntimeApps != nil || len(node.RuntimeDirectDomains) != 0 || node.SubscriptionID != "" {
			t.Fatal("standalone node inherited provider policy/source state")
		}
		if !bytes.Equal(node.Outbound, original.Outbounds[positions[index]]) {
			t.Fatal("raw outbound was changed")
		}
		var want, got any
		_ = json.Unmarshal(outboundSources[index], &want)
		_ = json.Unmarshal(node.Outbound, &got)
		wantBytes, _ := json.Marshal(want)
		gotBytes, _ := json.Marshal(got)
		if !bytes.Equal(wantBytes, gotBytes) || node.ID == "" || node.Name == "" || node.Address == "" || node.Port == 0 {
			t.Fatal("node values or metadata missing")
		}
	}
	again, err := extractProfileNodes(source)
	if err != nil {
		t.Fatal(err)
	}
	for i := range nodes {
		if nodes[i].ID != again[i].ID {
			t.Fatal("copy IDs are not stable for caller deduplication")
		}
	}
	for _, core := range []string{"sing-box", "mihomo"} {
		if _, err := buildCoreConfig(core, nodes[0], 21081, 21082, "local"); err != nil {
			t.Fatalf("explicit provider node copy not translatable: %v", err)
		}
		if _, err := buildCoreConfig(core, source, 21081, 21082, "local"); err == nil {
			t.Fatal("full profile was silently flattened")
		}
	}
}

func TestExtractProfileNodesRejectsDependentOrInvalidNodes(t *testing.T) {
	for _, change := range []string{"chain", "interface", "dialer-chain", "bad-endpoint"} {
		t.Run(change, func(t *testing.T) {
			s := nativeTestServer(t)
			var outbound object
			_ = json.Unmarshal(s.Outbound, &outbound)
			switch change {
			case "chain":
				outbound["proxySettings"] = object{"tag": "other"}
			case "interface":
				outbound["sendThrough"] = "127.0.0.1"
			case "dialer-chain":
				obj(outbound["streamSettings"])["sockopt"] = object{"dialerProxy": "other"}
			case "bad-endpoint":
				firstObject(obj(outbound["settings"])["vnext"])["port"] = 0
			}
			raw, _ := json.Marshal(object{"outbounds": []any{outbound}})
			if nodes, err := extractProfileNodes(ServerConfig{Profile: raw}); err == nil || len(nodes) != 0 {
				t.Fatal("dependent/invalid standalone copy accepted")
			}
		})
	}
	for _, profile := range []string{"", "{broken", `{"outbounds":[null]}`, `{"outbounds":[{"protocol":"freedom"}]}`} {
		if nodes, err := extractProfileNodes(ServerConfig{Profile: json.RawMessage(profile)}); err == nil || len(nodes) != 0 {
			t.Fatal("invalid/no-node profile accepted")
		}
	}
}
