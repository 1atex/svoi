package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// Public/synthetic values only. This mirrors the legacy schema shape without
// retaining any real provider endpoint, key, UUID, selector label or credential.
func providerSBLegacyFixture() object {
	return object{
		"log":          object{"level": "info"},
		"inbounds":     []any{object{"type": "tun", "tag": "provider-tun", "auto_route": true, "strict_route": true, "sniff": true}, object{"type": "mixed", "tag": "provider-mixed", "listen": "0.0.0.0", "listen_port": 2080, "sniff": true}},
		"outbounds":    []any{object{"type": "selector", "tag": "chosen", "outbounds": []any{"node"}}, object{"type": "direct", "tag": "direct"}, object{"type": "vless", "tag": "node", "server": "fixture.invalid", "server_port": 443, "uuid": nativeTestUUID}},
		"dns":          object{"servers": []any{object{"tag": "remote", "address": "tls://1.1.1.1"}, object{"tag": "bootstrap", "address": "tcp://8.8.8.8", "detour": "direct", "address_strategy": "prefer_ipv4", "strategy": "ipv4_only"}, object{"tag": "fake", "address": "fakeip"}}, "rules": []any{object{"query_type": []any{"A", "AAAA"}, "server": "fake"}, object{"outbound": "any", "server": "bootstrap"}}, "independent_cache": true, "fakeip": object{"enabled": true, "inet4_range": "198.18.0.0/15", "inet6_range": "fc00::/18"}},
		"route":        object{"auto_detect_interface": true, "override_android_vpn": true, "rules": []any{object{"action": "sniff"}, object{"type": "logical", "mode": "or", "rules": []any{object{"port": []any{53}}, object{"protocol": []any{"dns"}}}, "action": "hijack-dns"}, object{"ip_is_private": true, "outbound": "direct"}}},
		"experimental": object{"clash_api": object{"external_controller": "0.0.0.0:9090", "external_ui": "provider-dashboard", "external_ui_download_url": "https://ui.invalid/archive.zip", "default_mode": "rule"}, "cache_file": object{"enabled": true, "store_fakeip": true, "path": "../provider-cache.db", "cache_id": "provider-controlled"}},
	}
}

func TestProviderSingBoxLegacyDNSMigrationPreservesSemantics(t *testing.T) {
	profile := providerSBLegacyFixture()
	source := providerRuntimeServer(t, "sing-box", profile)
	before := append([]byte(nil), source.Profile...)
	raw, err := buildProviderNativeConfig("sing-box", source, 21081, 21082, "local")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(before, source.Profile) {
		t.Fatal("stored provider profile changed")
	}
	var got object
	json.Unmarshal(raw, &got)
	dns := obj(got["dns"])
	servers := dns["servers"].([]any)
	if obj(servers[0])["type"] != "tls" || obj(servers[0])["server"] != "1.1.1.1" || obj(servers[0])["detour"] != "chosen" {
		t.Fatal("legacy default proxy DNS path changed")
	}
	if obj(servers[1])["type"] != "tcp" || obj(servers[1])["detour"] != nil || obj(servers[1])["address_strategy"] != nil || obj(servers[1])["strategy"] != nil {
		t.Fatal("legacy bootstrap DNS conversion failed")
	}
	if obj(servers[2])["type"] != "fakeip" || obj(servers[2])["inet4_range"] != "198.18.0.0/15" || obj(servers[2])["inet6_range"] != "fc00::/18" || dns["fakeip"] != nil || dns["independent_cache"] != nil {
		t.Fatal("FakeIP ranges removed or legacy fields remain")
	}
	resolver := obj(obj(got["route"])["default_domain_resolver"])
	if resolver["server"] != "bootstrap" || resolver["strategy"] != "ipv4_only" {
		t.Fatal("bootstrap DNS rule or strategy lost")
	}
	if len(dns["rules"].([]any)) != 1 || obj(dns["rules"].([]any)[0])["server"] != "fake" || !reflect.DeepEqual(obj(dns["rules"].([]any)[0])["query_type"], []any{"A", "AAAA"}) {
		t.Fatal("ordinary FakeIP DNS rule lost")
	}
	var original object
	json.Unmarshal(source.Profile, &original)
	if !reflect.DeepEqual(obj(got["route"])["rules"], obj(original["route"])["rules"]) || !reflect.DeepEqual(got["outbounds"], original["outbounds"]) {
		t.Fatal("routing or outbound graph changed")
	}
	if obj(got["route"])["auto_detect_interface"] != true || (runtime.GOOS == "android" && obj(got["route"])["override_android_vpn"] != true) || (runtime.GOOS != "android" && obj(got["route"])["override_android_vpn"] != nil) {
		t.Fatal("outbound interface semantics changed")
	}
	cache := obj(obj(got["experimental"])["cache_file"])
	if obj(got["experimental"])["clash_api"] != nil || cache["enabled"] != true || cache["store_fakeip"] != true || cache["path"] != providerSingBoxCachePath || !strings.HasPrefix(str(cache["cache_id"]), "svoi-") {
		t.Fatal("unsafe or missing FakeIP cache")
	}
	if filepath.IsAbs(str(cache["path"])) || strings.Contains(str(cache["path"]), "..") {
		t.Fatal("provider controls cache path")
	}
}

func TestProviderSingBoxLegacyDNSRejectsUntranslatableSemantics(t *testing.T) {
	cases := map[string]func(object){
		"conditional-any":      func(p object) { obj(obj(p["dns"])["rules"].([]any)[1])["domain"] = []any{"conditional.invalid"} },
		"specific-outbound":    func(p object) { obj(obj(p["dns"])["rules"].([]any)[1])["outbound"] = "node" },
		"conflicting-resolver": func(p object) { obj(p["route"])["default_domain_resolver"] = "remote" },
		"unsupported-address":  func(p object) { obj(obj(p["dns"])["servers"].([]any)[0])["address"] = "file:///private.txt" },
		"address-userinfo": func(p object) {
			obj(obj(p["dns"])["servers"].([]any)[0])["address"] = "tls://user:private-password@dns.invalid"
		},
		"address-query": func(p object) {
			obj(obj(p["dns"])["servers"].([]any)[0])["address"] = "https://dns.invalid/dns-query?private-token=secret"
		},
		"missing-address-resolver":    func(p object) { obj(obj(p["dns"])["servers"].([]any)[0])["address"] = "tls://dns.invalid" },
		"bad-fake-range":              func(p object) { obj(obj(p["dns"])["fakeip"])["inet4_range"] = "::1/128" },
		"fake-disabled":               func(p object) { obj(obj(p["dns"])["fakeip"])["enabled"] = false },
		"cache-type":                  func(p object) { obj(obj(p["experimental"])["cache_file"])["store_fakeip"] = "true" },
		"route-auto-type":             func(p object) { obj(p["route"])["auto_detect_interface"] = "true" },
		"mixed-sniff-policy":          func(p object) { obj(p["route"])["rules"] = []any{}; obj(p["inbounds"].([]any)[1])["sniff"] = false },
		"dns-strategy-query-conflict": func(p object) { obj(obj(p["dns"])["servers"].([]any)[2])["strategy"] = "ipv4_only" },
	}
	for name, change := range cases {
		t.Run(name, func(t *testing.T) {
			profile := providerSBLegacyFixture()
			change(profile)
			_, err := buildProviderNativeConfig("sing-box", providerRuntimeServer(t, "sing-box", profile), 21081, 21082, "local")
			var api apiError
			if !errors.As(err, &api) || api.status != 422 {
				t.Fatal("unsupported legacy semantics silently accepted", err)
			}
			if strings.Contains(err.Error(), "private-password") || strings.Contains(err.Error(), "private-token") {
				t.Fatal("provider credentials leaked")
			}
		})
	}
}

func TestProviderSingBoxLegacyDNSDomainResolverAndExplicitPorts(t *testing.T) {
	profile := providerSBLegacyFixture()
	dns := obj(profile["dns"])
	server := obj(dns["servers"].([]any)[0])
	server["address"] = "https://dns.invalid:8443/custom-query"
	server["address_resolver"] = "bootstrap"
	server["address_strategy"] = "prefer_ipv4"
	raw, err := buildProviderNativeConfig("sing-box", providerRuntimeServer(t, "sing-box", profile), 21081, 21082, "local")
	if err != nil {
		t.Fatal(err)
	}
	var got object
	json.Unmarshal(raw, &got)
	converted := obj(obj(got["dns"])["servers"].([]any)[0])
	if converted["type"] != "https" || converted["server_port"] != float64(8443) || converted["path"] != "/custom-query" || obj(converted["domain_resolver"])["server"] != "bootstrap" || obj(converted["domain_resolver"])["strategy"] != "prefer_ipv4" {
		t.Fatal("legacy DNS endpoint resolution changed")
	}
}

func providerSBCheckRuntime(t *testing.T, binary string, raw []byte, secret bool) {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "runtime.json")
	if err := os.WriteFile(path, raw, 0600); err != nil {
		t.Fatal("could not write private temporary runtime config")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, binary, coreArgs("sing-box", "check", path, dir)...)
	hideCommand(cmd)
	cmd.Dir = dir
	output, err := cmd.CombinedOutput()
	if err != nil {
		if secret {
			t.Fatal("private provider sing-box validation failed; diagnostic output withheld")
		}
		t.Fatalf("synthetic legacy fixture core check failed: %v %s", err, output)
	}
}

func TestProviderSingBoxLegacyDNSBundledValidation(t *testing.T) {
	binary := testNativeCore(t, "sing-box")
	profile := providerSBLegacyFixture()
	raw, err := buildProviderNativeConfig("sing-box", providerRuntimeServer(t, "sing-box", profile), 21081, 21082, "local")
	if err != nil {
		t.Fatal(err)
	}
	providerSBCheckRuntime(t, binary, raw, false)
}

func TestProviderSingBoxPrivateFixtureValidation(t *testing.T) {
	path := os.Getenv("SVOI_TEST_PROVIDER_SINGBOX_FILE")
	if path == "" {
		t.Skip("opt in with a local private provider fixture; content and diagnostics are never printed")
	}
	binary := testNativeCore(t, "sing-box")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal("could not read private provider fixture")
	}
	parsed, err := parseSubscriptionWithFormat(data, "sing-box")
	if err != nil || len(parsed.Servers) != 1 {
		t.Fatal("private provider fixture could not be parsed")
	}
	raw, err := buildProviderNativeConfig("sing-box", parsed.Servers[0], 21081, 21082, "local")
	if err != nil {
		t.Fatal("private provider fixture runtime normalization failed")
	}
	providerSBCheckRuntime(t, binary, raw, true)
}

func TestProviderSingBoxEmptyDirectDNSDetours(t *testing.T) {
	for _, typed := range []bool{false, true} {
		profile := providerSBLegacyFixture()
		if typed {
			profile["dns"] = object{"servers": []any{object{"type": "tcp", "tag": "bootstrap", "server": "127.0.0.1", "server_port": 1, "detour": "direct"}}, "final": "bootstrap"}
		}
		server := providerRuntimeServer(t, "sing-box", profile)
		raw, err := buildProviderNativeConfig("sing-box", server, 21081, 21082, "local")
		if err != nil {
			t.Fatal(err)
		}
		var got object
		json.Unmarshal(raw, &got)
		var bootstrap object
		for _, value := range obj(got["dns"])["servers"].([]any) {
			candidate := obj(value)
			if candidate["tag"] == "bootstrap" {
				bootstrap = candidate
			}
		}
		if bootstrap["detour"] != nil {
			t.Fatal("empty direct DNS detour retained", typed)
		}
		// A real configured direct dialer must never be replaced by default direct.
		obj(profile["outbounds"].([]any)[1])["connect_timeout"] = "5s"
		raw, err = buildProviderNativeConfig("sing-box", providerRuntimeServer(t, "sing-box", profile), 21081, 21082, "local")
		if err != nil {
			t.Fatal(err)
		}
		json.Unmarshal(raw, &got)
		for _, value := range obj(got["dns"])["servers"].([]any) {
			candidate := obj(value)
			if candidate["tag"] == "bootstrap" && candidate["detour"] != "direct" {
				t.Fatal("configured direct DNS detour removed", typed)
			}
		}
		if obj(got["outbounds"].([]any)[1])["connect_timeout"] != "5s" {
			t.Fatal("configured direct option changed")
		}
	}
	// Duplicate tags cannot establish that a reference points to an empty direct.
	p := object{"outbounds": []any{object{"type": "direct", "tag": "duplicate"}, object{"type": "vless", "tag": "duplicate"}}}
	dns := object{"detour": "duplicate"}
	providerSBNormalizeEmptyDirectDNSDetours(p, []object{dns})
	if dns["detour"] != "duplicate" {
		t.Fatal("ambiguous detour silently removed")
	}
}

type providerSBStartupSignal struct {
	mu      sync.Mutex
	tail    string
	started bool
}

func (s *providerSBStartupSignal) Write(data []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	combined := s.tail + string(data)
	s.started = s.started || strings.Contains(combined, "sing-box started")
	if len(combined) > 512 {
		combined = combined[len(combined)-512:]
	}
	s.tail = combined
	return len(data), nil
}
func (s *providerSBStartupSignal) Ready() bool { s.mu.Lock(); defer s.mu.Unlock(); return s.started }

// Start the real core, but never request a proxy connection or a DNS query.
// Configuration/check alone does not execute sing-box's DNS detour start hook.
func providerSBStartLocalRuntime(t *testing.T, server ServerConfig) {
	t.Helper()
	binary := testNativeCore(t, "sing-box")
	socksTCP, socksUDP, sp, err := reserveSocksPort()
	if err != nil {
		t.Fatal("could not reserve isolated SOCKS port")
	}
	defer socksTCP.Close()
	defer socksUDP.Close()
	httpListener, hp, err := reservePort()
	if err != nil {
		t.Fatal("could not reserve isolated HTTP port")
	}
	defer httpListener.Close()
	raw, err := buildProviderNativeConfig("sing-box", server, sp, hp, "local")
	if err != nil {
		t.Fatal("isolated sing-box runtime normalization failed")
	}
	var config object
	if json.Unmarshal(raw, &config) != nil {
		t.Fatal("isolated sing-box runtime is invalid")
	}
	inbounds, err := providerObjects(config["inbounds"], "inbounds", true)
	if err != nil || len(inbounds) != 2 {
		t.Fatal("unexpected isolated listener configuration")
	}
	for _, inbound := range inbounds {
		if (inbound["type"] != "socks" && inbound["type"] != "http") || inbound["listen"] != "127.0.0.1" || inbound["set_system_proxy"] == true {
			t.Fatal("isolated startup would alter network settings")
		}
	}
	// Only a small readiness flag is retained from private process output.
	// No provider labels, endpoints, credentials or diagnostic lines are printed.
	config["log"] = object{"level": "info"}
	raw, _ = json.Marshal(config)
	dir := t.TempDir()
	path := filepath.Join(dir, "runtime.json")
	if err = os.WriteFile(path, raw, 0600); err != nil {
		t.Fatal("could not write private isolated runtime")
	}
	socksTCP.Close()
	socksUDP.Close()
	httpListener.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, binary, coreArgs("sing-box", "run", path, dir)...)
	hideCommand(cmd)
	cmd.Dir = dir
	signal := &providerSBStartupSignal{}
	cmd.Stdout, cmd.Stderr = signal, signal
	if err = cmd.Start(); err != nil {
		t.Fatal("isolated sing-box process could not start")
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait(); close(done) }()
	defer func() {
		cmd.Process.Kill()
		cancel()
		select {
		case <-done:
		case <-time.After(2 * time.Second):
			t.Error("isolated sing-box process did not stop")
		}
	}()
	ticker := time.NewTicker(15 * time.Millisecond)
	defer ticker.Stop()
	for !signal.Ready() {
		select {
		case <-done:
			t.Fatal("isolated sing-box exited during startup; private diagnostics withheld")
		case <-ctx.Done():
			t.Fatal("isolated sing-box startup exceeded 10 seconds; private diagnostics withheld")
		case <-ticker.C:
		}
	}
	control, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(sp)), time.Second)
	if err != nil {
		t.Fatal("isolated SOCKS listener unavailable")
	}
	defer control.Close()
	control.SetDeadline(time.Now().Add(time.Second))
	if _, err = control.Write([]byte{5, 1, 0}); err != nil {
		t.Fatal("isolated SOCKS greeting failed")
	}
	response := make([]byte, 2)
	if _, err = io.ReadFull(control, response); err != nil || !bytes.Equal(response, []byte{5, 0}) {
		t.Fatal("isolated SOCKS negotiation failed")
	}
	connection, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(hp)), time.Second)
	if err != nil {
		t.Fatal("isolated HTTP listener unavailable")
	}
	connection.Close()
	select {
	case <-done:
		t.Fatal("isolated sing-box stopped after readiness")
	default:
	}
}

func TestProviderSingBoxLegacyAndTypedDNSActualStartup(t *testing.T) {
	for _, typed := range []bool{false, true} {
		for _, configured := range []bool{false, true} {
			profile := providerSBLegacyFixture()
			if typed {
				profile["dns"] = object{"servers": []any{object{"type": "tcp", "tag": "bootstrap", "server": "127.0.0.1", "server_port": 1, "detour": "direct"}}, "final": "bootstrap"}
			}
			if configured {
				obj(profile["outbounds"].([]any)[1])["connect_timeout"] = "5s"
			}
			providerSBStartLocalRuntime(t, providerRuntimeServer(t, "sing-box", profile))
		}
	}
}

func TestProviderSingBoxPrivateFixtureActualStartup(t *testing.T) {
	path := os.Getenv("SVOI_TEST_PROVIDER_SINGBOX_FILE")
	if path == "" {
		t.Skip("opt in for isolated local startup of private provider fixture")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal("could not read private provider fixture")
	}
	parsed, err := parseSubscriptionWithFormat(data, "sing-box")
	if err != nil || len(parsed.Servers) != 1 {
		t.Fatal("private provider fixture could not be parsed")
	}
	providerSBStartLocalRuntime(t, parsed.Servers[0])
}
