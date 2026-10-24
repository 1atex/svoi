package backend

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func loopbackProfile(t *testing.T, server ServerConfig) object {
	t.Helper()
	var node object
	if err := json.Unmarshal(server.Outbound, &node); err != nil {
		t.Fatal(err)
	}
	node["tag"] = "node-1"
	return object{
		"remarks": "Auto profile",
		"log":     object{"error": "untrusted-file.log", "loglevel": "debug"},
		"inbounds": []any{
			object{"tag": "original-socks", "protocol": "socks", "listen": "0.0.0.0", "port": 10808, "sniffing": object{"enabled": true, "destOverride": []string{"http", "tls"}, "routeOnly": true}},
			object{"tag": "original-http", "protocol": "http", "port": 10809},
		},
		"outbounds": []any{object{"tag": "block", "protocol": "blackhole"}, node, object{"tag": "loop", "protocol": "loopback", "settings": object{"inboundTag": "rerouted"}}},
		"dns":       object{"servers": []string{"1.1.1.1"}},
		"policy":    object{"system": object{"statsOutboundUplink": true}},
		"stats":     object{},
		"routing": object{"domainStrategy": "AsIs", "rules": []any{
			object{"type": "field", "inboundTag": []string{"original-socks", "original-http"}, "balancerTag": "entry"},
			object{"type": "field", "inboundTag": []string{"rerouted"}, "balancerTag": "exit"},
		}, "balancers": []any{object{"tag": "entry", "selector": []string{"loop"}}, object{"tag": "exit", "selector": []string{"node-"}}}},
	}
}

func TestFullProfilePreservesRoutingGraph(t *testing.T) {
	node, err := parseServerURI("vless://90e3da82-374e-46ef-9099-761d39b86b82@example.com:443?security=tls#Node")
	if err != nil {
		t.Fatal(err)
	}
	source := loopbackProfile(t, node)
	b := mustJSON(t, source)
	parsed, err := parseSubscription(b)
	if err != nil {
		t.Fatal(err)
	}
	if len(parsed.Servers) != 1 || len(parsed.Warnings) != 0 {
		t.Fatal("profile split into nodes or service outbounds reported as errors")
	}
	p := parsed.Servers[0]
	if !p.FullProfile || p.NodeCount != 1 || len(p.Profile) == 0 || len(p.Outbound) != 0 {
		t.Fatal("full profile not represented")
	}
	raw, err := buildXrayConfig(p, 21081, 21082, "local")
	if err != nil {
		t.Fatal(err)
	}
	var original, built object
	json.Unmarshal(b, &original)
	json.Unmarshal(raw, &built)
	for _, k := range []string{"outbounds", "routing", "dns", "policy", "stats"} {
		if !reflect.DeepEqual(original[k], built[k]) {
			t.Fatalf("%s was changed or lost", k)
		}
	}
	inbounds := built["inbounds"].([]any)
	for i, rawIn := range inbounds {
		in := obj(rawIn)
		if in["listen"] != "127.0.0.1" || number(in["port"]) != 21081+i {
			t.Fatal("profile opened nonlocal or old port")
		}
	}
	if obj(built["log"])["error"] != nil {
		t.Fatal("untrusted log path retained")
	}
	if !reflect.DeepEqual(obj(inbounds[0])["sniffing"], obj(original["inbounds"].([]any)[0])["sniffing"]) {
		t.Fatal("sniffing lost")
	}

	source["remarks"] = "Auto profile"
	obj(source["routing"])["domainStrategy"] = "IPIfNonMatch"
	both := append([]byte{'['}, b...)
	both = append(both, ',')
	both = append(both, mustJSON(t, source)...)
	both = append(both, ']')
	parsed, err = parseSubscription(both)
	if err != nil || len(parsed.Servers) != 2 {
		t.Fatal("distinct routing profiles deduplicated by first endpoint")
	}
	a := newTestApp(t)
	owner := create(t, a)
	summary := expect(t, call(a, "POST", "/api/subscription/import", owner, map[string]string{"content": string(both)}), 200)
	summaryJSON := string(mustJSON(t, summary))
	if strings.Contains(summaryJSON, "90e3da82") || strings.Contains(summaryJSON, `"outbounds"`) {
		t.Fatal("profile credentials leaked in summary")
	}
	restored, err := openApp(a.path)
	if err != nil || len(restored.state.Groups[0].Servers[0].Profile) == 0 {
		t.Fatal("profile not persisted")
	}
	exported := call(a, "GET", "/api/servers/"+restored.state.Groups[0].Servers[0].ID+"/export", owner, nil)
	if exported.Code != 200 || !strings.Contains(exported.Body.String(), `"loopback"`) {
		t.Fatal("export lost profile")
	}
}

func TestFullProfileTunRouting(t *testing.T) {
	node, _ := parseServerURI("vless://90e3da82-374e-46ef-9099-761d39b86b82@example.com:443#Node")
	p, err := serverFromProfile(loopbackProfile(t, node), 1)
	if err != nil {
		t.Fatal(err)
	}
	data, err := buildXrayConfig(p, 10808, 10809, "tun")
	if err != nil {
		t.Fatal(err)
	}
	var config object
	json.Unmarshal(data, &config)
	tunTag := str(obj(config["inbounds"].([]any)[2])["tag"])
	rules := obj(config["routing"])["rules"].([]any)
	first := obj(rules[1])["inboundTag"].([]any)
	if !strings.Contains(string(mustJSON(t, first)), tunTag) {
		t.Fatal("TUN bypasses profile entry routing")
	}
	if string(mustJSON(t, obj(rules[2])["inboundTag"])) != `["rerouted"]` {
		t.Fatal("synthetic loopback tag rewritten")
	}
}

func TestLocalSubscriptionProfiles(t *testing.T) {
	file := os.Getenv("SVOI_VALIDATE_SUBSCRIPTION")
	if file == "" {
		t.Skip("no local subscription supplied")
	}
	data, err := os.ReadFile(file)
	if err != nil {
		t.Fatal("cannot read local subscription")
	}
	parsed, err := parseSubscription(data)
	if err != nil {
		t.Fatal("local subscription parse failed")
	}
	if len(parsed.Warnings) != 0 {
		t.Fatalf("unexpected warnings: %d", len(parsed.Warnings))
	}
	binary := testCore(t)
	for i, profile := range parsed.Servers {
		for _, mode := range []string{"local", "tun"} {
			config, err := buildXrayConfig(profile, 10808, 10809, mode)
			if err != nil {
				t.Fatalf("profile %d build failed", i+1)
			}
			name := filepath.Join(t.TempDir(), "profile.json")
			os.WriteFile(name, config, 0600)
			cmd := exec.Command(binary, "run", "-test", "-c", name)
			cmd.Dir = filepath.Dir(binary)
			hideCommand(cmd)
			if output, err := cmd.CombinedOutput(); err != nil {
				os.WriteFile(filepath.Join(filepath.Dir(name), "validation.log"), output, 0600)
				t.Fatalf("Xray rejected profile %d in %s mode (details in local test directory)", i+1, mode)
			}
		}
	}
	t.Logf("Validated %d complete profiles with Xray; warnings: 0", len(parsed.Servers))
	checkMode := os.Getenv("SVOI_CHECK_PROFILE")
	if checkMode == "1" || checkMode == "all" {
		engine, err := newEngine(binary, t.TempDir())
		if err != nil {
			t.Fatal("could not initialize local engine")
		}
		defer engine.Stop()
		profiles := parsed.Servers[:1]
		if checkMode == "all" {
			profiles = parsed.Servers
		}
		for i, profile := range profiles {
			if err = engine.Start(profile, "local"); err != nil {
				t.Errorf("profile %d could not start", i+1)
				continue
			}
			for _, endpoint := range []string{"https://www.gstatic.com/generate_204", "https://www.youtube.com/", "https://2ip.ru/"} {
				engine.checkURL = endpoint
				latency, err := engine.Check(context.Background())
				if err != nil {
					t.Errorf("profile %d: %s", i+1, engine.Status().Error)
				} else {
					t.Logf("profile %d: %s OK, %d ms", i+1, endpoint, latency)
				}
			}
			if err = engine.Stop(); err != nil {
				t.Fatal("local core cleanup failed")
			}
		}
	}
}
