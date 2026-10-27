package main

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestDirectDomainsNormalizeAndPersist(t *testing.T) {
	got, err := normalizeDirectDomains([]string{" YANDEX.RU. ", "*.yandex.ru", "example.com"})
	if err != nil || !reflect.DeepEqual(got, []string{"yandex.ru", "example.com"}) {
		t.Fatal(got, err)
	}
	for _, bad := range []string{"localhost", "127.0.0.1", "https://example.com/path", "a..com", "-bad.com", "bad.com:443", "a/b.com", "я.рф"} {
		if _, err := normalizeDirectDomains([]string{bad}); err == nil {
			t.Fatalf("accepted %q", bad)
		}
	}
	a := newTestApp(t)
	token := create(t, a)
	settings := a.localSettings()
	settings.DirectDomains = got
	r := httptest.NewRequest("PUT", "/api/settings", strings.NewReader(string(mustJSON(t, settings))))
	r.RemoteAddr = "127.0.0.1:1234"
	r.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	a.handler().ServeHTTP(w, r)
	expect(t, w, 200)
	restored, err := openApp(a.path)
	if err != nil {
		t.Fatal(err)
	}
	s := restored.localSettings()
	if !reflect.DeepEqual(s.DirectDomains, got) {
		t.Fatal(s)
	}
	s.DirectDomains[0] = "mutated.com"
	if restored.localSettings().DirectDomains[0] != "yandex.ru" {
		t.Fatal("settings slice escaped")
	}
}

func TestDirectDomainsPreserveRulesAndCoreAccepts(t *testing.T) {
	node, _ := parseServerURI("vless://90e3da82-374e-46ef-9099-761d39b86b82@example.com:443?security=tls#Test")
	profile, err := serverFromProfile(loopbackProfile(t, node), 1)
	if err != nil {
		t.Fatal(err)
	}
	for _, mode := range []string{"local", "system", "tun"} {
		t.Run(mode, func(t *testing.T) {
			base, err := buildXrayConfig(profile, 21081, 21082, mode)
			if err != nil {
				t.Fatal(err)
			}
			var original object
			json.Unmarshal(base, &original)
			profile.RuntimeDirectDomains = []string{"yandex.ru"}
			profile.RuntimeApps = &AppRouting{Mode: "include", Processes: []string{"chrome.exe"}}
			raw, err := buildXrayConfig(profile, 21081, 21082, mode)
			if err != nil {
				t.Fatal(err)
			}
			var got object
			json.Unmarshal(raw, &got)
			rules := obj(got["routing"])["rules"].([]any)
			index := 0
			if mode == "tun" {
				index = 3
			}
			rule := obj(rules[index])
			if rule["outboundTag"] != "svoi-sites-direct" || !reflect.DeepEqual(rule["domain"], []any{"domain:yandex.ru"}) {
				t.Fatal(rule)
			}
			if !reflect.DeepEqual(rules[index+1:], obj(original["routing"])["rules"]) {
				t.Fatal("subscription rules changed")
			}
			file := filepath.Join(t.TempDir(), "config.json")
			os.WriteFile(file, raw, 0600)
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, testCore(t), "run", "-test", "-config", file)
			hideCommand(cmd)
			if b, err := cmd.CombinedOutput(); err != nil {
				t.Fatal(string(b), err)
			}
			profile.RuntimeDirectDomains = nil
			profile.RuntimeApps = nil
		})
	}
	config := object{"outbounds": []any{object{"tag": "svoi-sites-direct", "protocol": "blackhole"}}}
	if err := applyDirectDomains(config, []string{"example.com"}); err != nil {
		t.Fatal(err)
	}
	if obj(config["outbounds"].([]any)[1])["tag"] != "svoi-sites-direct-x" {
		t.Fatal(config)
	}
	if err := applyDirectDomains(object{"routing": object{"script": "return 'proxy';"}}, []string{"example.com"}); err == nil {
		t.Fatal("script routing silently changed")
	}
}

func TestDirectDomainRoutesThroughFreedomWithRealCore(t *testing.T) {
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "direct-domain-ok") }))
	defer target.Close()
	_, port, _ := net.SplitHostPort(strings.TrimPrefix(target.URL, "http://"))
	profile := object{"dns": object{"hosts": object{"direct.test": "127.0.0.1"}}, "outbounds": []any{object{"protocol": "blackhole", "tag": "blocked"}}, "routing": object{"rules": []any{object{"type": "field", "port": "1-65535", "outboundTag": "blocked"}}}}
	server := ServerConfig{ServerInfo: ServerInfo{ID: "domain-route", Name: "Direct rule"}, Profile: mustJSON(t, profile), RuntimeDirectDomains: []string{"direct.test"}}
	e := &Engine{binary: testCore(t), dir: t.TempDir(), status: EngineStatus{State: "stopped", Available: true}}
	defer e.Stop()
	if err := e.Start(server, "local"); err != nil {
		t.Fatal(err)
	}
	proxy, _ := url.Parse("http://127.0.0.1:" + strconv.Itoa(e.Status().HTTPPort))
	tr := &http.Transport{Proxy: http.ProxyURL(proxy)}
	defer tr.CloseIdleConnections()
	client := &http.Client{Transport: tr, Timeout: 3 * time.Second}
	resp, err := client.Get("http://direct.test:" + port)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	if string(b) != "direct-domain-ok" {
		t.Fatal(string(b))
	}
}
