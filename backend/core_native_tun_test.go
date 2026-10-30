package main

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"regexp"
	"testing"
)

func nativeTunConfigObject(t *testing.T, raw []byte) object {
	t.Helper()
	var result object
	if err := json.Unmarshal(raw, &result); err != nil {
		t.Fatal(err)
	}
	return result
}

func TestNativeWindowsTunOverlayPreservesLocalDataPlane(t *testing.T) {
	for _, core := range []string{"sing-box", "mihomo"} {
		t.Run(core, func(t *testing.T) {
			for name, server := range nativeDirectDomainSources(t, core) {
				t.Run(name, func(t *testing.T) {
					server.RuntimeDirectDomains = []string{"example.com"}
					local, err := buildCoreConfig(core, server, 21081, 21082, "local")
					if err != nil {
						t.Fatal(err)
					}
					source := bytes.Clone(local)
					raw, err := nativeWindowsTunConfig(core, local)
					if err != nil {
						t.Fatal(err)
					}
					if !bytes.Equal(source, local) {
						t.Fatal("local JSON mutated")
					}
					base, got := nativeTunConfigObject(t, local), nativeTunConfigObject(t, raw)
					if core == "sing-box" {
						if !reflect.DeepEqual(base["outbounds"], got["outbounds"]) {
							t.Fatal("outbound security/selection changed")
						}
						before, after := obj(base["route"]), obj(got["route"])
						if !reflect.DeepEqual(before["rules"], after["rules"]) || before["final"] != after["final"] {
							t.Fatal("provider/direct-domain routing changed")
						}
						if after["auto_detect_interface"] != true {
							t.Fatal("outbound TUN loop not prevented")
						}
						inbounds := got["inbounds"].([]any)
						old := base["inbounds"].([]any)
						if !reflect.DeepEqual(old, inbounds[:len(old)]) {
							t.Fatal("local listeners changed")
						}
						tun := obj(inbounds[len(inbounds)-1])
						if tun["type"] != "tun" || !regexp.MustCompile(`^SVOI-SB-[0-9a-f]{8}$`).MatchString(str(tun["interface_name"])) || tun["auto_route"] != true || tun["strict_route"] != true || tun["dns_mode"] != "hijack" {
							t.Fatal("uncontrolled TUN configuration")
						}
						if !reflect.DeepEqual(tun["address"], []any{nativeTunIPv4, nativeTunIPv6}) {
							t.Fatal("TUN addresses changed")
						}
						if base["dns"] != nil && !reflect.DeepEqual(base["dns"], got["dns"]) {
							t.Fatal("provider DNS changed")
						}
						if obj(got["log"])["level"] != "info" {
							t.Fatal("final startup log suppressed")
						}
					} else {
						for _, key := range []string{"proxies", "proxy-groups", "rules", "mode", "hosts", "ipv6", "rule-providers"} {
							if !reflect.DeepEqual(base[key], got[key]) {
								t.Fatalf("provider data plane changed: %s", key)
							}
						}
						tun := obj(got["tun"])
						if tun["enable"] != true || tun["auto-route"] != true || tun["auto-detect-interface"] != true || tun["strict-route"] != true || !regexp.MustCompile(`^SVOI-MH-[0-9a-f]{8}$`).MatchString(str(tun["device"])) {
							t.Fatal("uncontrolled TUN configuration")
						}
						if tun["inet4-address"] != nil {
							t.Fatal("v1.19.33 ignores inet4-address; must not pretend it works")
						}
						if !reflect.DeepEqual(tun["inet6-address"], []any{nativeTunIPv6}) {
							t.Fatal("IPv6 address changed")
						}
						if got["log-level"] != "info" || obj(got["dns"])["enable"] != true {
							t.Fatal("TUN DNS/logs not enabled")
						}
						before, after := obj(base["dns"]), obj(got["dns"])
						for key, value := range before {
							if key != "enable" && !reflect.DeepEqual(value, after[key]) {
								t.Fatalf("provider DNS option changed: %s", key)
							}
						}
					}
					// The overlay is opt-in: rebuilding LOCAL produces byte-for-byte
					// identical output after constructing the separate TUN config.
					again, err := buildCoreConfig(core, server, 21081, 21082, "local")
					if err != nil || !bytes.Equal(local, again) {
						t.Fatal("local mode changed after TUN overlay")
					}
					if _, err = nativeWindowsTunConfig(core, raw); err == nil {
						t.Fatal("second TUN overlay would overwrite an existing adapter")
					}
				})
			}
		})
	}
}

func TestNativeWindowsTunOwnedNamesAndDNSDefaults(t *testing.T) {
	for _, core := range []string{"sing-box", "mihomo"} {
		names := map[string]bool{}
		for i := 0; i < 10; i++ {
			local, err := buildCoreConfig(core, nativeTestServer(t), 21081, 21082, "local")
			if err != nil {
				t.Fatal(err)
			}
			raw, err := nativeWindowsTunConfig(core, local)
			if err != nil {
				t.Fatal(err)
			}
			config := nativeTunConfigObject(t, raw)
			var name string
			if core == "sing-box" {
				inbounds := config["inbounds"].([]any)
				name = str(obj(inbounds[len(inbounds)-1])["interface_name"])
			} else {
				name = str(obj(config["tun"])["device"])
			}
			if names[name] {
				t.Fatal("adapter identity reused")
			}
			names[name] = true
			if config["dns"] == nil {
				t.Fatal("missing TUN DNS")
			}
		}
	}
	for _, raw := range []string{"", "null", "[]", "not-json"} {
		if _, err := nativeWindowsTunConfig("sing-box", []byte(raw)); err == nil {
			t.Fatal("invalid JSON accepted")
		}
	}
	if _, err := nativeWindowsTunConfig("xray", []byte(`{}`)); err == nil {
		t.Fatal("unknown native core accepted")
	}
}

func TestNativeWindowsTunActualCoreConfigChecks(t *testing.T) {
	// Only check commands are invoked: no adapter, route, DNS or firewall is
	// created on the user's machine by these tests.
	for _, core := range []string{"sing-box", "mihomo"} {
		t.Run(core, func(t *testing.T) {
			binary := testNativeCore(t, core)
			for name, server := range nativeDirectDomainSources(t, core) {
				t.Run(name, func(t *testing.T) {
					server.RuntimeDirectDomains = []string{"example.com"}
					local, err := buildCoreConfig(core, server, 21081, 21082, "local")
					if err != nil {
						t.Fatal(err)
					}
					raw, err := nativeWindowsTunConfig(core, local)
					if err != nil {
						t.Fatal(err)
					}
					dir := t.TempDir()
					path := filepath.Join(dir, "tun-check.json")
					if err = os.WriteFile(path, raw, 0600); err != nil {
						t.Fatal(err)
					}
					cmd := exec.Command(binary, coreArgs(core, "check", path, dir)...)
					hideCommand(cmd)
					cmd.Dir = dir
					cmd.Env = coreEnvironment(core)
					if output, err := cmd.CombinedOutput(); err != nil {
						t.Fatalf("native TUN config check failed %v: %s", err, output)
					}
				})
			}
		})
	}
}

func TestNativeWindowsTunPrivateProviderChecks(t *testing.T) {
	for _, fixture := range []struct{ core, env string }{{"sing-box", "SVOI_TEST_PRIVATE_SING_BOX_PROFILE"}, {"mihomo", "SVOI_TEST_PRIVATE_MIHOMO_PROFILE"}} {
		t.Run(fixture.core, func(t *testing.T) {
			path := os.Getenv(fixture.env)
			if path == "" {
				t.Skip("private provider fixture is opt-in")
			}
			source, err := os.ReadFile(path)
			if err != nil {
				t.Fatal("cannot read private fixture")
			}
			value, err := nativeProviderDocument(source)
			if err != nil {
				t.Fatal("cannot parse private fixture")
			}
			profile, ok := value.(map[string]any)
			if !ok {
				t.Fatal("private fixture is not an object")
			}
			local, err := buildCoreConfig(fixture.core, providerRuntimeServer(t, fixture.core, profile), 21081, 21082, "local")
			if err != nil {
				t.Fatal(err)
			}
			raw, err := nativeWindowsTunConfig(fixture.core, local)
			if err != nil {
				t.Fatal(err)
			}
			dir := t.TempDir()
			config := filepath.Join(dir, "private-tun-check.json")
			if err = os.WriteFile(config, raw, 0600); err != nil {
				t.Fatal("cannot write isolated private config")
			}
			cmd := exec.Command(testNativeCore(t, fixture.core), coreArgs(fixture.core, "check", config, dir)...)
			hideCommand(cmd)
			cmd.Dir = dir
			cmd.Env = coreEnvironment(fixture.core)
			if _, err = cmd.CombinedOutput(); err != nil {
				t.Fatal("private TUN config failed native check; sensitive output suppressed")
			}
		})
	}
}
