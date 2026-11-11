package main

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func islandFixture(t *testing.T) (*App, islandPeer, string) {
	t.Helper()
	a := newTestApp(t)
	token := create(t, a)
	peer := islandPeer{Path: `C:\NightIsland\night-island.exe`, Hash: "fixture-hash", User: "fixture-user"}
	b := a.island()
	b.grant = peer
	b.view = islandContext{Authorization: "Bearer " + token, Mode: "local", Selected: "a", Servers: []string{"a", "b"}, Favorites: []string{"a", "b"}}
	a.engine = &Engine{status: EngineStatus{State: "stopped"}}
	a.state.Groups[0].Servers = []ServerConfig{
		{ServerInfo: ServerInfo{ID: "a", Name: "Финляндия", Protocol: "vless"}},
		{ServerInfo: ServerInfo{ID: "b", Name: "Германия", Protocol: "vless"}},
	}
	return a, peer, token
}

func TestIslandStateIsLimitedAndRevocationTakesEffect(t *testing.T) {
	a, peer, token := islandFixture(t)
	a.engine.status = EngineStatus{State: "running", ServerID: "a", Mode: "local", Checked: true, Latency: 37, CheckedAt: new(time.Now())}
	s := a.islandSnapshot(peer)
	if s.Active == nil || s.Active.Name != "Финляндия" || s.Latency == nil || *s.Latency != 37 || len(s.Favorites) != 2 {
		t.Fatal(s)
	}
	raw, _ := json.Marshal(s)
	for _, private := range []string{token, "outbound", "hwid", "subscription", "socksPort", "Authorization"} {
		if strings.Contains(string(raw), private) {
			t.Fatal("private data leaked", private)
		}
	}
	for _, wrong := range []islandPeer{{Path: peer.Path, Hash: "different", User: peer.User}, {Path: peer.Path, Hash: peer.Hash, User: "other"}, {Path: `C:\Other\night-island.exe`, Hash: peer.Hash, User: peer.User}} {
		denied := a.islandSnapshot(wrong)
		if denied.Access != "denied" || denied.Active != nil || len(denied.Favorites) != 0 {
			t.Fatal(denied)
		}
	}
	expect(t, localProbeCall(a, "PUT", "/api/night-island", token, map[string]any{"enabled": false}), 200)
	if a.islandCommand(context.Background(), peer, "disconnect", "").Access != "denied" || a.engine.snapshot(false).State != "running" {
		t.Fatal("revoked client changed the connection")
	}
}

func TestIslandPermissionRequiresObservedClientAndStaysLocal(t *testing.T) {
	a, peer, token := islandFixture(t)
	b := a.island()
	b.grant = islandPeer{}
	expect(t, localProbeCall(a, "PUT", "/api/night-island", token, map[string]any{"enabled": true, "candidate": peer.Hash}), 409)
	b.pending = peer
	b.pendingAt = time.Now()
	expect(t, localProbeCall(a, "PUT", "/api/night-island", token, map[string]any{"enabled": true, "candidate": peer.Hash}), 200)
	other, err := openApp(a.path)
	if err != nil || !other.island().allowed(peer) {
		t.Fatal("permission did not survive restart", err)
	}
	r := httptest.NewRequest("GET", "http://local/api/night-island", nil)
	r.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	nativeHandler(a.handler(), "private-key").ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatal("native backend is exposed")
	}
	expect(t, localProbeCall(a, "PUT", "/api/night-island", token, map[string]any{"enabled": false}), 200)
	restarted, err := openApp(a.path)
	if err != nil || restarted.island().allowed(peer) {
		t.Fatal("revocation did not persist", err)
	}
}

func TestIslandRejectsQueuedCommandAfterRevocationAndDebounces(t *testing.T) {
	a, peer, token := islandFixture(t)
	b := a.island()
	a.networkOp.Lock()
	done := make(chan islandState, 1)
	go func() { done <- a.islandCommand(context.Background(), peer, "disconnect", "") }()
	until := time.Now().Add(time.Second)
	for b.op.TryLock() {
		b.op.Unlock()
		if time.Now().After(until) {
			a.networkOp.Unlock()
			t.Fatal("request did not start")
		}
		time.Sleep(time.Millisecond)
	}
	if !a.islandCommand(context.Background(), peer, "disconnect", "").Busy {
		t.Fatal("duplicate command was queued")
	}
	expect(t, localProbeCall(a, "PUT", "/api/night-island", token, map[string]any{"enabled": false}), 200)
	a.networkOp.Unlock()
	select {
	case result := <-done:
		if result.Access != "denied" {
			t.Fatal(result)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("revoked request hung")
	}
}

func TestIslandFailedSwitchKeepsActualServer(t *testing.T) {
	a, peer, _ := islandFixture(t)
	a.engine.status = EngineStatus{State: "running", ServerID: "a", Mode: "local", Checked: true}
	s := a.islandCommand(context.Background(), peer, "switch", "unknown")
	if s.Active == nil || s.Active.ID != "a" || s.Error == "" {
		t.Fatal(s)
	}
	a.engine.status.Checked = false
	if a.islandSnapshot(peer).Latency != nil {
		t.Fatal("invented latency")
	}
}
