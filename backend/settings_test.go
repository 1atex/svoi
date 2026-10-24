package backend

import (
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestLocalSettingsAuthorizationAndPersistence(t *testing.T) {
	a := newTestApp(t)
	owner := create(t, a)
	member := join(t, a, owner)
	s := a.localSettings()
	s.AutoRefresh = false
	s.Routing = AppRouting{Mode: "include", Processes: []string{" chrome.exe ", "chrome.exe", "Discord.exe"}}
	b, _ := json.Marshal(s)
	request := func(token, remote string) int {
		r := httptest.NewRequest("PUT", "/api/settings", strings.NewReader(string(b)))
		r.RemoteAddr = remote
		r.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		a.handler().ServeHTTP(w, r)
		return w.Code
	}
	if n := request(owner, "192.0.2.1:1234"); n != 403 {
		t.Fatal(n)
	}
	if n := request(member, "127.0.0.1:1234"); n != 403 {
		t.Fatal(n)
	}
	if n := request(owner, "127.0.0.1:1234"); n != 200 {
		t.Fatal(n)
	}
	restored, err := openApp(a.path)
	if err != nil {
		t.Fatal(err)
	}
	got := restored.localSettings()
	if got.AutoRefresh || len(got.Routing.Processes) != 2 || got.Routing.Processes[1] != "Discord" {
		t.Fatal(got)
	}
	got.Routing.Processes[0] = "changed"
	if restored.localSettings().Routing.Processes[0] == "changed" {
		t.Fatal("mutable settings escaped lock")
	}
}
