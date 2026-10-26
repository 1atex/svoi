package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"
)

func localProbeCall(a *App, method, path, token string, body any) *httptest.ResponseRecorder {
	b, _ := json.Marshal(body)
	r := httptest.NewRequest(method, path, bytes.NewReader(b))
	r.RemoteAddr = "127.0.0.1:1234"
	r.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	a.handler().ServeHTTP(w, r)
	return w
}

func TestProbeSettingsMigrationValidationAndPersistence(t *testing.T) {
	a := newTestApp(t)
	if err := os.WriteFile(a.path+".settings.json", []byte(`{"routing":{"mode":"all","processes":[]},"autoRefresh":true}`), 0600); err != nil {
		t.Fatal(err)
	}
	if err := a.loadSettings(); err != nil {
		t.Fatal(err)
	}
	if got := a.localSettings().Probe; got.URL != defaultProbeURL || got.TimeoutSeconds != 4 || got.Parallel != 4 {
		t.Fatal(got)
	}
	for _, bad := range []ProbeSettings{
		{URL: "file:///tmp/example"}, {URL: "https://user:pass@example.org/"}, {URL: "https://example.org/#fragment"}, {URL: "https://"}, {URL: "https://example.org/a b"}, {TimeoutSeconds: 16}, {TimeoutSeconds: -1}, {Parallel: 11}, {Parallel: -1},
	} {
		if validateProbeSettings(&bad) == nil {
			t.Fatalf("accepted invalid settings: %+v", bad)
		}
	}
	owner := create(t, a)
	settings := a.localSettings()
	settings.Probe = ProbeSettings{URL: "http://connectivitycheck.platform.hicloud.com/generate_204", TimeoutSeconds: 8, Parallel: 10}
	expect(t, localProbeCall(a, "PUT", "/api/settings", owner, settings), 200)
	restored, err := openApp(a.path)
	if err != nil {
		t.Fatal(err)
	}
	if restored.localSettings().Probe != settings.Probe {
		t.Fatal("probe settings not persisted")
	}
}

func TestProbeSlotsRespectConfiguredLimitAndShrink(t *testing.T) {
	a := newTestApp(t)
	a.settings.Probe.Parallel = 10
	for i := 0; i < 10; i++ {
		if _, ok := a.acquireProbeSlot(); !ok {
			t.Fatal("configured slot unavailable", i)
		}
	}
	if _, ok := a.acquireProbeSlot(); ok {
		t.Fatal("limit exceeded")
	}
	a.settingsMu.Lock()
	a.settings.Probe.Parallel = 1
	a.settingsMu.Unlock()
	for i := 0; i < 9; i++ {
		<-a.probeSlots
	}
	if _, ok := a.acquireProbeSlot(); ok {
		t.Fatal("shrinking limit admitted another request")
	}
	<-a.probeSlots
	if _, ok := a.acquireProbeSlot(); !ok {
		t.Fatal("released slot unavailable")
	}
	<-a.probeSlots
}

func TestProbeAPIUsesSavedURLAndGET(t *testing.T) {
	methods := make(chan string, 1)
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { methods <- r.Method; w.WriteHeader(204) }))
	defer target.Close()
	a := newTestApp(t)
	owner := create(t, a)
	a.engine = &Engine{binary: testCore(t), dir: t.TempDir(), checkURL: "http://127.0.0.1:1/unreachable", status: EngineStatus{Available: true, State: "stopped"}}
	outbound, _ := json.Marshal(object{"protocol": "freedom", "settings": object{"finalRules": []any{object{"action": "allow", "ip": []string{"127.0.0.1"}}}}})
	server := ServerConfig{ServerInfo: ServerInfo{ID: "test", Name: "Test"}, Outbound: outbound}
	a.state.Groups[0].Servers = []ServerConfig{server}
	a.settings.Probe = ProbeSettings{URL: target.URL, TimeoutSeconds: 8, Parallel: 1}
	result := expect(t, localProbeCall(a, "POST", "/api/servers/test/probe", owner, nil), 200)
	if result["url"] != target.URL || result["method"] != "GET" {
		t.Fatal(result)
	}
	if method := <-methods; method != "GET" {
		t.Fatal(method)
	}
	if len(a.probeSlots) != 0 {
		t.Fatal("probe slot leaked")
	}
	if a.engine.Status().State != "stopped" {
		t.Fatal("probe changed active engine")
	}

	hanging := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { <-r.Context().Done() }))
	defer hanging.Close()
	start := time.Now()
	_, err := probeServer(context.Background(), a.engine, server, ProbeSettings{URL: hanging.URL, TimeoutSeconds: 2, Parallel: 1})
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatal(err)
	}
	if elapsed := time.Since(start); elapsed > 4*time.Second {
		t.Fatalf("configured timeout ignored: %v", elapsed)
	}
}
