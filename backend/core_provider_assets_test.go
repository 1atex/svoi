package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func mihomoRuleAssetFixture(t *testing.T, remoteURL string) object {
	t.Helper()
	p := providerRuntimeFixture("mihomo", 12345, "http://127.0.0.1:1/")
	p["rule-providers"] = object{"local-domain-rules": object{"type": "http", "url": remoteURL, "path": "../../provider-chosen.yml", "proxy": "DIRECT", "interval": 3600, "behavior": "domain", "format": "yaml", "header": object{"User-Agent": []any{"fixture-murge"}, "Authorization": []any{"Bearer synthetic-fixture-token"}}}, "geoip-fixture": object{"type": "http", "url": remoteURL, "proxy": "DIRECT", "interval": 3600, "behavior": "domain", "format": "yaml"}}
	obj(obj(p["rule-providers"])["geoip-fixture"])["header"] = object{"User-Agent": []any{"fixture-murge"}, "Authorization": []any{"Bearer synthetic-fixture-token"}}
	p["find-process-mode"] = "strict"
	p["skip-dst"] = []any{"127.0.0.0/8"}
	p["rules"] = []any{"OR,((PROCESS-NAME-REGEX,^nonexistent-fixture-process$),(RULE-SET,local-domain-rules)),REJECT", "AND,((NETWORK,UDP),(RULE-SET,geoip-fixture)),REJECT", "MATCH,chosen"}
	groups := p["proxy-groups"].([]any)
	automatic := obj(groups[1])
	delete(automatic, "proxies")
	automatic["include-all-proxies"], automatic["filter"], automatic["exclude-filter"], automatic["empty-fallback"] = true, "^live$", "^dead$", "DIRECT"
	dns := obj(p["dns"])
	dns["enhanced-mode"], dns["fake-ip-range"], dns["fake-ip-filter"] = "fake-ip", "198.18.0.1/16", []any{"+.fixture.invalid"}
	return p
}

func TestNativeMihomoRemoteRuleAssetsPreserveGraphAndValidate(t *testing.T) {
	p := mihomoRuleAssetFixture(t, "https://rules.example.invalid/domain.yaml")
	server := providerRuntimeServer(t, "mihomo", p)
	source := bytes.Clone(server.Profile)
	raw, err := buildCoreConfig("mihomo", server, 21081, 21082, "local")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(source, server.Profile) {
		t.Fatal("source mutated")
	}
	var result object
	json.Unmarshal(raw, &result)
	for _, key := range []string{"proxies", "proxy-groups", "rules", "dns", "hosts", "skip-dst", "find-process-mode"} {
		var before any
		b, _ := json.Marshal(p[key])
		json.Unmarshal(b, &before)
		if !reflect.DeepEqual(before, result[key]) {
			t.Fatalf("provider semantics changed: %s", key)
		}
	}
	provider := obj(obj(result["rule-providers"])["local-domain-rules"])
	cache := str(provider["path"])
	if filepath.IsAbs(cache) || !strings.HasPrefix(cache, "svoi-rule-assets/") || strings.Contains(cache, "..") || strings.Contains(cache, "fixture-token") {
		t.Fatal("uncontrolled cache path")
	}
	if len(filepath.Base(cache)) != 64+len(".yaml") {
		t.Fatal("cache name is not opaque digest")
	}
	delete(provider, "path")
	original := obj(obj(p["rule-providers"])["local-domain-rules"])
	delete(original, "path")
	var expected any
	b, _ := json.Marshal(original)
	json.Unmarshal(b, &expected)
	if !reflect.DeepEqual(expected, provider) {
		t.Fatal("rule download semantics changed")
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	if err = os.WriteFile(path, raw, 0600); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(testNativeCore(t, "mihomo"), coreArgs("mihomo", "check", path, dir)...)
	hideCommand(cmd)
	cmd.Dir = dir
	cmd.Env = coreEnvironment("mihomo")
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("actual Mihomo check %v: %s", err, output)
	}
}

func TestNativeMihomoRemoteRuleAssetBoundaries(t *testing.T) {
	edits := map[string]func(object){
		"local-file":       func(p object) { p["type"] = "file" },
		"file-scheme":      func(p object) { p["url"] = "file:///private/rules.yaml" },
		"ftp-scheme":       func(p object) { p["url"] = "ftp://example.invalid/rules" },
		"schemeless":       func(p object) { p["url"] = "//example.invalid/rules" },
		"shell-hook":       func(p object) { p["post-up"] = "arbitrary-shell-command" },
		"bundle-file":      func(p object) { p["path-in-bundle"] = "private.file" },
		"bad-format":       func(p object) { p["format"] = "script" },
		"bad-behavior":     func(p object) { p["behavior"] = "script" },
		"mrs-classical":    func(p object) { p["format"], p["behavior"] = "mrs", "classical" },
		"header-injection": func(p object) { p["header"] = object{"User-Agent": []any{"safe\r\nInjected: yes"}} },
	}
	for name, edit := range edits {
		t.Run(name, func(t *testing.T) {
			p := mihomoRuleAssetFixture(t, "https://example.invalid/rules")
			edit(obj(obj(p["rule-providers"])["local-domain-rules"]))
			if _, err := buildCoreConfig("mihomo", providerRuntimeServer(t, "mihomo", p), 21081, 21082, "local"); err == nil {
				t.Fatal("unsafe provider accepted")
			}
		})
	}
	paths := map[string]bool{}
	for _, token := range []string{"one", "two"} {
		p := mihomoRuleAssetFixture(t, "https://example.invalid/rules")
		obj(obj(obj(p["rule-providers"])["local-domain-rules"])["header"])["Authorization"] = []any{token}
		raw, err := buildCoreConfig("mihomo", providerRuntimeServer(t, "mihomo", p), 21081, 21082, "local")
		if err != nil {
			t.Fatal(err)
		}
		var result object
		json.Unmarshal(raw, &result)
		path := str(obj(obj(result["rule-providers"])["local-domain-rules"])["path"])
		if paths[path] {
			t.Fatal("different authorization reuses rule cache")
		}
		paths[path] = true
	}
}

func TestNativeMihomoRemoteRuleDownloadAndRoute(t *testing.T) {
	var downloads atomic.Int32
	rules := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("User-Agent") != "fixture-murge" || r.Header.Get("Authorization") != "Bearer synthetic-fixture-token" {
			w.WriteHeader(403)
			return
		}
		downloads.Add(1)
		_, _ = io.WriteString(w, "payload:\n  - blocked.invalid\n")
	}))
	defer rules.Close()
	port, proxyHits := nativeVLESSFixture(t)
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = io.WriteString(w, "native-remote-rules-loopback") }))
	defer target.Close()
	p := mihomoRuleAssetFixture(t, rules.URL+"/domain.yaml")
	live := obj(p["proxies"].([]any)[1])
	live["port"] = port
	// Keep the include-all group, but make its lazy health check target local.
	obj(p["proxy-groups"].([]any)[1])["url"] = target.URL
	server := providerRuntimeServer(t, "mihomo", p)
	source := bytes.Clone(server.Profile)
	e := nativeTestEngine(t, "mihomo")
	e.checkURL = target.URL
	if err := e.Start(server, "local"); err != nil {
		t.Fatalf("native start %v; %v", err, e.Status().Logs)
	}
	if downloads.Load() == 0 {
		t.Fatal("native core did not download remote rule data")
	}
	files, err := filepath.Glob(filepath.Join(e.dir, "svoi-rule-assets", "*.yaml"))
	if err != nil || len(files) != 2 {
		t.Fatalf("controlled rule cache missing: count=%d error=%v", len(files), err)
	}
	if data, err := os.ReadFile(files[0]); err != nil || !bytes.Contains(data, []byte("blocked.invalid")) {
		t.Fatal("downloaded rule payload absent")
	}
	proxy, _ := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", e.Status().HTTPPort))
	tr := &http.Transport{Proxy: http.ProxyURL(proxy), DisableKeepAlives: true}
	defer tr.CloseIdleConnections()
	client := &http.Client{Transport: tr, Timeout: 3 * time.Second}
	before := proxyHits.Load()
	response, err := client.Get("http://blocked.invalid/")
	if err == nil {
		response.Body.Close()
		if response.StatusCode < 400 {
			t.Fatal("downloaded reject rule did not apply")
		}
	}
	if proxyHits.Load() != before {
		t.Fatal("blocked domain reached proxy")
	}
	response, err = client.Get(target.URL)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(response.Body)
	response.Body.Close()
	if response.StatusCode != 200 || string(body) != "native-remote-rules-loopback" || proxyHits.Load() <= before {
		t.Fatal("fallback selector lost")
	}
	if !bytes.Equal(source, server.Profile) {
		t.Fatal("source profile mutated")
	}
}

// Optional private diagnostic. Never emit provider contents or native logs,
// which may contain credentials. This validates configuration only, no VPN run.
func TestNativeMihomoPrivateProviderConfigCheck(t *testing.T) {
	path := os.Getenv("SVOI_TEST_PRIVATE_MIHOMO_PROFILE")
	if path == "" {
		t.Skip("private provider fixture is opt-in")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal("cannot read private fixture")
	}
	value, err := nativeProviderDocument(data)
	if err != nil {
		t.Fatal("private fixture parse failed")
	}
	p, ok := value.(map[string]any)
	if !ok {
		t.Fatal("private fixture is not an object")
	}
	raw, err := buildCoreConfig("mihomo", providerRuntimeServer(t, "mihomo", p), 21081, 21082, "local")
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	config := filepath.Join(dir, "private-config.json")
	if err = os.WriteFile(config, raw, 0600); err != nil {
		t.Fatal("cannot write isolated private check config")
	}
	cmd := exec.Command(testNativeCore(t, "mihomo"), coreArgs("mihomo", "check", config, dir)...)
	hideCommand(cmd)
	cmd.Dir = dir
	cmd.Env = coreEnvironment("mihomo")
	if _, err = cmd.CombinedOutput(); err != nil {
		t.Fatal("actual private Mihomo check failed; sensitive native output suppressed")
	}
	t.Logf("private native configuration accepted: %d proxies, %d groups, %d rule providers", len(p["proxies"].([]any)), len(p["proxy-groups"].([]any)), len(obj(p["rule-providers"])))
}
