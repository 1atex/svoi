package backend

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestSubscriptionLibraryIsolation(t *testing.T) {
	a := newTestApp(t)
	owner := create(t, a)
	member := join(t, a, owner)
	add := func(name, url string) string {
		return expect(t, call(a, "POST", "/api/subscriptions", owner, input{Name: name, URL: url}), 201)["id"].(string)
	}
	first := add("First", "https://first.example/private-token")
	second := add("Second", "https://second.example/secret")
	expect(t, call(a, "POST", "/api/subscriptions", owner, input{URL: "https://first.example/private-token"}), 409)
	expect(t, call(a, "POST", "/api/subscriptions", member, input{URL: "https://third.example"}), 403)
	a.client = &http.Client{Transport: transportFunc(func(*http.Request) (*http.Response, error) {
		return fakeResponse(200, "vless://test-key@example.com:443#NL%20Node"), nil
	})}
	for _, id := range []string{first, second} {
		expect(t, call(a, "POST", "/api/subscription/refresh?id="+id, owner, nil), 200)
	}
	g := &a.state.Groups[0]
	if len(g.Servers) != 2 || g.Servers[0].ID == g.Servers[1].ID {
		t.Fatal("duplicate nodes from independent sources collide")
	}
	secondID := g.Servers[1].ID
	expect(t, call(a, "POST", "/api/subscription/refresh?id="+first, member, nil), 200)
	if len(g.Servers) != 2 || g.Servers[0].ID != secondID {
		t.Fatal("refresh changed other source")
	}
	expect(t, call(a, "POST", "/api/subscription/import", owner, map[string]string{"content": "trojan://secret@example.com:443#Imported"}), 200)
	if len(g.Servers) != 3 || len(g.Subscriptions) != 3 {
		t.Fatal("import replaced existing subscriptions")
	}
	summary := expect(t, call(a, "GET", "/api/me", member, nil), 200)
	if strings.Contains(string(mustJSON(t, summary)), "private-token") || strings.Contains(string(mustJSON(t, summary)), "test-key") {
		t.Fatal("summary leaks credentials")
	}
	config := expect(t, call(a, "GET", "/api/servers/"+secondID+"/config?mode=tun", member, nil), 200)
	if config["mode"] != "tun" || config["original"] == nil || config["effective"] == nil {
		t.Fatal("missing config details")
	}
	other := create(t, a)
	expect(t, call(a, "GET", "/api/servers/"+secondID+"/config", other, nil), 404)
	expect(t, call(a, "GET", "/api/servers/"+secondID+"/config", "", nil), 401)
	expect(t, call(a, "DELETE", "/api/subscriptions/"+first, member, nil), 403)
	expect(t, call(a, "DELETE", "/api/subscriptions/"+first, owner, nil), 200)
	restored, err := openApp(a.path)
	if err != nil {
		t.Fatal(err)
	}
	if len(restored.state.Groups[0].Servers) != 2 || len(restored.state.Groups[0].Subscriptions) != 2 {
		t.Fatal("delete or persistence affected wrong source")
	}
}

func TestLegacySubscriptionMigration(t *testing.T) {
	a := newTestApp(t)
	owner := create(t, a)
	server, err := parseServerURI("vless://old-key@example.com:443#Legacy")
	if err != nil {
		t.Fatal(err)
	}
	g := &a.state.Groups[0]
	g.SubscriptionURL = "https://legacy.example/sub"
	g.Servers = []ServerConfig{server}
	g.LastRefresh = &Report{Count: 1, Format: "URI"}
	data := mustJSON(t, a.state)
	if err = os.WriteFile(a.path, data, 0600); err != nil {
		t.Fatal(err)
	}
	restored, err := openApp(a.path)
	if err != nil {
		t.Fatal(err)
	}
	migrated := &restored.state.Groups[0]
	if len(migrated.Subscriptions) != 1 || migrated.Servers[0].ID != server.ID || migrated.Servers[0].SubscriptionID != "legacy" {
		t.Fatal("legacy selection lost")
	}
	expect(t, call(restored, "GET", "/api/servers/"+server.ID+"/config", owner, nil), 200)

	after, _ := os.ReadFile(a.path)
	if string(after) != string(data) {
		t.Fatal("read modified state file")
	}
}

func TestRefreshCannotResurrectDeletedSource(t *testing.T) {
	a := newTestApp(t)
	owner := create(t, a)
	id := expect(t, call(a, "POST", "/api/subscriptions", owner, input{URL: "https://first.example/sub"}), 201)["id"].(string)
	started, release := make(chan struct{}), make(chan struct{})
	a.client = &http.Client{Transport: transportFunc(func(*http.Request) (*http.Response, error) {
		close(started)
		<-release
		return fakeResponse(200, "vless://test@example.com:443"), nil
	})}
	result := make(chan *httptest.ResponseRecorder, 1)
	go func() { result <- call(a, "POST", "/api/subscription/refresh?id="+id, owner, nil) }()
	<-started
	expect(t, call(a, "DELETE", "/api/subscriptions/"+id, owner, nil), 200)
	close(release)
	expect(t, <-result, 409)
	if len(a.state.Groups[0].Servers) != 0 || len(a.state.Groups[0].Subscriptions) != 0 {
		t.Fatal("deleted source resurrected")
	}
}

func TestProbeIsolatedAndCleanedUp(t *testing.T) {
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) }))
	defer target.Close()
	base := &Engine{binary: testCore(t), dir: t.TempDir(), checkURL: target.URL, status: EngineStatus{Available: true, State: "running", ServerID: "active-server", Mode: "tun", HTTPPort: 12345}}
	before := base.Status()
	outbound := object{"protocol": "freedom", "settings": object{"finalRules": []any{object{"action": "allow", "ip": []string{"127.0.0.1"}}}}}
	b, _ := json.Marshal(outbound)
	server := ServerConfig{ServerInfo: ServerInfo{ID: "probe", Name: "Probe"}, Outbound: b}
	if _, err := probeServer(context.Background(), base, server); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(before, base.Status()) {
		t.Fatal("probe changed live connection")
	}
	server.Outbound = json.RawMessage(`{"protocol":"invalid"}`)
	if _, err := probeServer(context.Background(), base, server); err == nil {
		t.Fatal("invalid probe accepted")
	}
	entries, err := os.ReadDir(base.dir)
	if err != nil || len(entries) != 0 {
		t.Fatal("probe left temporary configs")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err = probeServer(ctx, base, server); err == nil {
		t.Fatal("cancelled probe started")
	}
}

func TestProbeDeadlineAndCancellationReleaseResources(t *testing.T) {
	binary := testCore(t)
	for _, cancelEarly := range []bool{false, true} {
		t.Run(map[bool]string{false: "timeout", true: "cancel"}[cancelEarly], func(t *testing.T) {
			entered, release := make(chan struct{}, 1), make(chan struct{})
			target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				entered <- struct{}{}
				select {
				case <-release:
				case <-r.Context().Done():
				}
			}))
			defer target.Close()
			defer close(release)
			base := &Engine{binary: binary, dir: t.TempDir(), checkURL: target.URL, status: EngineStatus{Available: true, State: "running", ServerID: "active", Mode: "tun", HTTPPort: 12345}}
			before := base.Status()
			server := ServerConfig{Outbound: json.RawMessage(`{"protocol":"freedom","settings":{"finalRules":[{"action":"allow","ip":["127.0.0.1"]}]}}`)}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			result := make(chan error, 1)
			started := time.Now()
			go func() { _, err := probeServer(ctx, base, server); result <- err }()
			select {
			case <-entered:
			case err := <-result:
				t.Fatalf("probe failed before reaching target: %v", err)
			case <-time.After(6 * time.Second):
				t.Fatal("probe did not reach target")
			}
			want := context.DeadlineExceeded
			if cancelEarly {
				started = time.Now()
				cancel()
				want = context.Canceled
			}
			select {
			case err := <-result:
				if !errors.Is(err, want) {
					t.Fatalf("want %v, got %v", want, err)
				}
			case <-time.After(6 * time.Second):
				t.Fatal("stalled probe did not finish")
			}
			limit := 6 * time.Second
			if cancelEarly {
				limit = 2 * time.Second
			}
			if elapsed := time.Since(started); elapsed > limit {
				t.Fatalf("probe took %v", elapsed)
			}
			if !reflect.DeepEqual(before, base.Status()) {
				t.Fatal("probe changed active connection")
			}
			if files, err := os.ReadDir(base.dir); err != nil || len(files) != 0 {
				t.Fatal("probe left temporary files", err)
			}
			responsive := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) }))
			defer responsive.Close()
			base.checkURL = responsive.URL
			if _, err := probeServer(context.Background(), base, server); err != nil {
				t.Fatal("next probe failed", err)
			}
		})
	}
}
