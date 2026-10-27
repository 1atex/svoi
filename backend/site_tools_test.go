package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestSiteTargetValidation(t *testing.T) {
	for _, raw := range []string{"file:///etc/passwd", "ftp://example.com", "http://user:pass@example.com", "http://127.0.0.1", "http://[::1]", "http://192.168.1.1", "https://example.com/#token", "example.com/hello world", ""} {
		if _, err := siteTarget(raw); err == nil {
			t.Fatalf("accepted %q", raw)
		}
	}
	for _, raw := range []string{"example.com", "https://example.com/path?x=1", "http://1.1.1.1/"} {
		if _, err := siteTarget(raw); err != nil {
			t.Fatal(raw, err)
		}
	}
}

func TestSiteHTTPSeparatesResponseAndAccessAndDoesNotFollowRedirects(t *testing.T) {
	var hits atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		switch r.URL.Path {
		case "/redirect":
			http.Redirect(w, r, "/final", 302)
		case "/denied":
			w.WriteHeader(403)
		default:
			w.WriteHeader(204)
		}
	}))
	defer server.Close()
	for _, tc := range []struct {
		path   string
		ok     bool
		detail string
	}{{"/redirect", true, "следующий адрес не проверялся"}, {"/denied", false, "сервер доступен"}, {"/", true, "HTTP 204"}} {
		target, _ := url.Parse(server.URL + tc.path)
		before := hits.Load()
		step := siteHTTP(context.Background(), target, &http.Transport{Proxy: nil})
		if !step.Responded || step.OK != tc.ok || !strings.Contains(step.Detail, tc.detail) || hits.Load() != before+1 {
			t.Fatal(step, hits.Load())
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	target, _ := url.Parse(server.URL)
	step := siteHTTP(ctx, target, &http.Transport{Proxy: nil})
	if step.Responded || step.OK {
		t.Fatal(step)
	}
}

func TestSiteProfileReusesActiveCoreAndRejectsNestedTUN(t *testing.T) {
	a := newTestApp(t)
	token := create(t, a)
	node, _ := parseServerURI("vless://90e3da82-374e-46ef-9099-761d39b86b82@example.com:443?security=tls#Site")
	a.mu.Lock()
	for i := range a.state.Groups {
		a.state.Groups[i].Servers = []ServerConfig{node}
	}
	a.mu.Unlock()
	var hits atomic.Int32
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { hits.Add(1); w.WriteHeader(204) }))
	defer proxy.Close()
	parsed, _ := url.Parse(proxy.URL)
	port, _ := strconv.Atoi(parsed.Port())
	now := time.Now()
	a.engine = &Engine{status: EngineStatus{Available: true, State: "running", Mode: "tun", ServerID: node.ID, HTTPPort: port, StartedAt: &now}}
	request := func(id string) *httptest.ResponseRecorder {
		r := httptest.NewRequest("POST", "/api/tools/site", strings.NewReader(string(mustJSON(t, object{"url": "http://example.com", "route": "profile", "serverId": id}))))
		r.RemoteAddr = "127.0.0.1:1234"
		r.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		a.handler().ServeHTTP(w, r)
		return w
	}
	data := expect(t, request(node.ID), 200)
	if hits.Load() != 1 || len(data["steps"].([]any)) != 1 {
		t.Fatal(data, hits.Load())
	}
	a.engine.status.ServerID = "another"
	expect(t, request(node.ID), 409)
	if hits.Load() != 1 {
		t.Fatal("nested profile reached network")
	}
}
