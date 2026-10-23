package main

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

func TestApplicationGatePreservesProfileAndCoreAccepts(t *testing.T) {
	node, _ := parseServerURI("vless://90e3da82-374e-46ef-9099-761d39b86b82@example.com:443?security=tls#Test")
	profile, err := serverFromProfile(loopbackProfile(t, node), 1)
	if err != nil {
		t.Fatal(err)
	}
	base, err := buildXrayConfig(profile, 21081, 21082, "tun")
	if err != nil {
		t.Fatal(err)
	}
	var original object
	json.Unmarshal(base, &original)
	for _, mode := range []string{"include", "exclude"} {
		t.Run(mode, func(t *testing.T) {
			profile.RuntimeApps = &AppRouting{Mode: mode, Processes: []string{"chrome.exe", "Discord.exe"}}
			raw, err := buildXrayConfig(profile, 21081, 21082, "tun")
			if err != nil {
				t.Fatal(err)
			}
			var config object
			json.Unmarshal(raw, &config)
			originalRouting := obj(original["routing"])
			routing := obj(config["routing"])
			rules := routing["rules"].([]any)
			if !reflect.DeepEqual(originalRouting["rules"], rules[3:]) || !reflect.DeepEqual(originalRouting["balancers"], routing["balancers"]) {
				t.Fatal("original routing graph changed")
			}
			out := config["outbounds"].([]any)
			old := original["outbounds"].([]any)
			if !reflect.DeepEqual(old, out[:len(old)]) {
				t.Fatal("default outbound or loopbacks changed")
			}
			rule := obj(rules[1])
			want := "svoi-app-loop"
			if mode == "exclude" {
				want = "svoi-app-direct"
			}
			if rule["outboundTag"] != want || !reflect.DeepEqual(rule["process"], []any{"chrome", "Discord"}) {
				t.Fatal(rule)
			}
			// Xray test mode validates configuration without opening a TUN adapter.
			file := filepath.Join(t.TempDir(), "config.json")
			os.WriteFile(file, raw, 0600)
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			if out, err := exec.CommandContext(ctx, testCore(t), "run", "-test", "-config", file).CombinedOutput(); err != nil {
				t.Fatalf("core rejected config: %s %v", out, err)
			}
			local, err := buildXrayConfig(profile, 21081, 21082, "local")
			if err != nil {
				t.Fatal(err)
			}
			plain, err := buildBaseXrayConfig(profile, 21081, 21082, "local")
			if err != nil {
				t.Fatal(err)
			}
			if string(local) != string(plain) {
				t.Fatal("app gate applied to proxy mode")
			}
		})
	}
}
