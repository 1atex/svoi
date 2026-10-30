package main

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

func TestProviderPrivateSelectableNodes(t *testing.T) {
	for _, core := range []string{"sing-box", "mihomo"} {
		t.Run(core, func(t *testing.T) {
			variable := "SVOI_TEST_PROVIDER_SINGBOX_FILE"
			if core == "mihomo" {
				variable = "SVOI_TEST_PRIVATE_MIHOMO_PROFILE"
			}
			path := os.Getenv(variable)
			if path == "" {
				t.Skip("private fixture is opt-in")
			}
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatal("cannot read private fixture")
			}
			parsed, err := parseSubscriptionWithFormat(data, core)
			if err != nil || len(parsed.Servers) != 1 {
				t.Fatal("private fixture parse failed")
			}
			views := providerServerViews(parsed.Servers[0])
			if len(views) < 2 {
				t.Fatal("private fixture exposes no node choices")
			}
			checked := map[string]bool{}
			for _, view := range views[1:] {
				if checked[view.Protocol] {
					continue
				}
				checked[view.Protocol] = true
				raw, err := buildCoreConfig(core, view, 21081, 21082, "local")
				if err != nil {
					t.Fatal("selected node normalization failed; diagnostics withheld")
				}
				dir := t.TempDir()
				config := filepath.Join(dir, "config.json")
				if err := os.WriteFile(config, raw, 0600); err != nil {
					t.Fatal("cannot write private runtime")
				}
				ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
				cmd := exec.CommandContext(ctx, testNativeCore(t, core), coreArgs(core, "check", config, dir)...)
				hideCommand(cmd)
				cmd.Dir, cmd.Env = dir, coreEnvironment(core)
				_, err = cmd.CombinedOutput()
				cancel()
				if err != nil {
					t.Fatal("selected node native check failed; sensitive output withheld")
				}
			}
			t.Logf("%d selectable nodes; native configuration accepted for %d protocol types", len(views)-1, len(checked))
		})
	}
}

func TestProviderNodeViewsPreserveCanonicalGraphAndSelection(t *testing.T) {
	for _, core := range []string{"sing-box", "mihomo"} {
		t.Run(core, func(t *testing.T) {
			parent := providerRuntimeServer(t, core, providerRuntimeFixture(core, 12345, "http://127.0.0.1:1/"))
			parent.ID, parent.SubscriptionID, parent.SubscriptionCore = "original", "source", core
			original := append([]byte(nil), parent.Profile...)
			group := Group{Servers: []ServerConfig{parent}}
			views := groupServerViews(&group)
			if len(views) != 3 || len(group.Servers) != 1 || views[0].ProfileNode {
				t.Fatal("expected canonical profile plus two virtual node choices")
			}
			seen := map[string]bool{}
			for _, view := range views {
				if seen[view.ID] {
					t.Fatal("duplicate view id")
				}
				seen[view.ID] = true
				if !bytes.Equal(view.Profile, original) {
					t.Fatal("view lost original graph")
				}
				if !view.ProfileNode {
					continue
				}
				if view.Protocol != "vless" || view.Address == "" || view.Port < 1 || view.NativeTarget != view.Name {
					t.Fatal("node metadata missing")
				}
				data, err := buildCoreConfig(core, view, 10808, 10809, "local")
				if err != nil {
					t.Fatal(err)
				}
				var effective, source object
				_ = json.Unmarshal(data, &effective)
				_ = json.Unmarshal(original, &source)
				selector := providerPrimarySelector(core, effective)
				if core == "sing-box" {
					if selector["default"] != view.NativeTarget {
						t.Fatal("selected outbound not applied")
					}
				} else if selector["proxies"].([]any)[0] != view.NativeTarget {
					t.Fatal("selected proxy not applied")
				}
				for _, key := range []string{"dns", "route", "rules"} {
					if !reflect.DeepEqual(source[key], effective[key]) {
						t.Fatalf("provider %s changed", key)
					}
				}
			}
			if !bytes.Equal(parent.Profile, original) {
				t.Fatal("canonical graph mutated")
			}
			group.Servers[0].ID = "updated-payload-hash"
			refreshed := groupServerViews(&group)
			if refreshed[1].ID != views[1].ID || refreshed[2].ID != views[2].ID {
				t.Fatal("refresh changed stable node IDs")
			}
		})
	}
}

func TestProviderNodeSelectionRequiresUnambiguousPrimaryGroup(t *testing.T) {
	for _, core := range []string{"sing-box", "mihomo"} {
		t.Run(core, func(t *testing.T) {
			profile := providerRuntimeFixture(core, 12345, "http://127.0.0.1:1/")
			if err := applyProviderNodeSelection(core, profile, "missing"); err == nil {
				t.Fatal("unknown target accepted")
			}
			if err := applyProviderNodeSelection(core, profile, "automatic"); err == nil {
				t.Fatal("service group exposed as a node")
			}
			if core == "sing-box" {
				obj(profile["route"])["final"] = "automatic"
			} else {
				profile["rules"] = []any{"MATCH,automatic"}
			}
			if nodes := providerSelectableNodes(core, profile); len(nodes) != 0 {
				t.Fatal("url-test guessed as manual selector")
			}
			if err := applyProviderNodeSelection(core, profile, "live"); err == nil {
				t.Fatal("unrelated selector changed")
			}
		})
	}
}

func TestProviderNodeAPIExportsSelectionAndRejectsRemovedNode(t *testing.T) {
	for _, core := range []string{"sing-box", "mihomo"} {
		t.Run(core, func(t *testing.T) {
			a := newTestApp(t)
			token := create(t, a)
			profile := providerRuntimeFixture(core, 12345, "http://127.0.0.1:1/")
			parent := providerRuntimeServer(t, core, profile)
			parent.ID, parent.SubscriptionID, parent.SubscriptionCore = "canonical", "source", core
			a.state.Groups[0].Servers = []ServerConfig{parent}
			a.state.Groups[0].Subscriptions = []Subscription{{ID: "source", Name: "Provider"}}
			views := groupServerViews(&a.state.Groups[0])
			me := expect(t, call(a, "GET", "/api/me", token, nil), 200)
			if len(me["servers"].([]any)) != 3 {
				t.Fatal("API hid virtual nodes")
			}
			view := views[2]
			response := call(a, "GET", "/api/servers/"+view.ID+"/export", token, nil)
			if response.Code != 200 {
				t.Fatalf("export status: %d", response.Code)
			}
			var exported object
			_ = json.Unmarshal(response.Body.Bytes(), &exported)
			selector := providerPrimarySelector(core, exported)
			if core == "sing-box" {
				if selector["default"] != view.NativeTarget {
					t.Fatal("export lost selection")
				}
			} else if selector["proxies"].([]any)[0] != view.NativeTarget {
				t.Fatal("export lost selection")
			}
			selector = providerPrimarySelector(core, profile)
			if core == "sing-box" {
				selector["outbounds"] = []any{"dead"}
			} else {
				selector["proxies"] = []any{"dead"}
			}
			a.state.Groups[0].Servers[0].Profile, _ = json.Marshal(profile)
			if response := call(a, "GET", "/api/servers/"+view.ID+"/export", token, nil); response.Code != 404 {
				t.Fatal("removed node silently resolved to another node")
			}
		})
	}
}
