package backend

import (
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

type transportFunc func(*http.Request) (*http.Response, error)

func TestExistingInstance(t *testing.T) {
	srv := httptest.NewServer(newTestApp(t).handler())
	defer srv.Close()
	if !existingInstance(strings.TrimPrefix(srv.URL, "http://")) {
		t.Fatal("running SVOI not recognized")
	}
	other := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]string{"status": "ok", "service": "other"})
	}))
	defer other.Close()
	if existingInstance(strings.TrimPrefix(other.URL, "http://")) {
		t.Fatal("unrelated server recognized as SVOI")
	}
	for _, address := range []string{"example.com:8787", "0.0.0.0:8787", "invalid"} {
		if existingInstance(address) {
			t.Fatalf("unexpected probe: %s", address)
		}
	}
}

func (f transportFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func newTestApp(t *testing.T) *App {
	t.Helper()
	a, err := openApp(filepath.Join(t.TempDir(), "groups.json"))
	if err != nil {
		t.Fatal(err)
	}
	return a
}
func call(a *App, method, path, token string, body any) *httptest.ResponseRecorder {
	b, _ := json.Marshal(body)
	r := httptest.NewRequest(method, path, strings.NewReader(string(b)))
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	w := httptest.NewRecorder()
	a.handler().ServeHTTP(w, r)
	return w
}
func expect(t *testing.T, w *httptest.ResponseRecorder, status int) map[string]any {
	t.Helper()
	if w.Code != status {
		t.Fatalf("want %d got %d: %s", status, w.Code, w.Body.String())
	}
	var v map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &v)
	return v
}
func create(t *testing.T, a *App) string {
	t.Helper()
	v := expect(t, call(a, "POST", "/api/groups", "", input{Name: "Home", DeviceName: "PC", Platform: "Windows"}), 201)
	return v["token"].(string)
}
func join(t *testing.T, a *App, owner string) string {
	t.Helper()
	v := expect(t, call(a, "POST", "/api/invites", owner, nil), 201)
	j := expect(t, call(a, "POST", "/api/join", "", input{Invite: v["code"].(string), DeviceName: "Phone", Platform: "iOS"}), 201)
	return j["token"].(string)
}
func fakeResponse(status int, body string) *http.Response {
	return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader(body)), Header: http.Header{}}
}

func TestGroupLifecycle(t *testing.T) {
	a := newTestApp(t)
	owner := create(t, a)
	invite := expect(t, call(a, "POST", "/api/invites", owner, nil), 201)["code"].(string)
	member := expect(t, call(a, "POST", "/api/join", "", input{Invite: invite, DeviceName: "iPhone", Platform: "iOS"}), 201)["token"].(string)
	expect(t, call(a, "POST", "/api/join", "", input{Invite: invite, DeviceName: "Replay", Platform: "Android"}), 400)
	own := expect(t, call(a, "GET", "/api/me", owner, nil), 200)
	mem := expect(t, call(a, "GET", "/api/me", member, nil), 200)
	if !reflect.DeepEqual(own["identity"], mem["identity"]) {
		t.Fatal("identity differs across devices")
	}
	if len(mem["devices"].([]any)) != 2 {
		t.Fatal("missing member")
	}
	if mem["owner"] != false {
		t.Fatal("joined member became owner")
	}
	expect(t, call(a, "POST", "/api/invites", member, nil), 403)
	expect(t, call(a, "PUT", "/api/identity", member, input{Identity: Identity{}}), 403)
	expect(t, call(a, "DELETE", "/api/devices/"+own["self"].(string), owner, nil), 409)
	expect(t, call(a, "DELETE", "/api/devices/"+mem["self"].(string), owner, nil), 200)
	expect(t, call(a, "GET", "/api/me", member, nil), 401)
	restarted, err := openApp(a.path)
	if err != nil {
		t.Fatal(err)
	}
	expect(t, call(restarted, "GET", "/api/me", owner, nil), 200)
	expect(t, call(restarted, "GET", "/api/me", member, nil), 401)
	b, _ := os.ReadFile(a.path)
	if strings.Contains(string(b), owner) || strings.Contains(string(b), member) || strings.Contains(string(b), invite) {
		t.Fatal("raw access token stored on disk")
	}
	if strings.Contains(string(mustJSON(t, own)), "tokenHash") {
		t.Fatal("token hash leaked to API")
	}
}
func mustJSON(t *testing.T, v any) []byte {
	t.Helper()
	b, e := json.Marshal(v)
	if e != nil {
		t.Fatal(e)
	}
	return b
}

func TestSubscriptionUsesIdenticalHeaders(t *testing.T) {
	a := newTestApp(t)
	owner := create(t, a)
	member := join(t, a, owner)
	identity := Identity{HWID: "0123456789abcdef", OS: "Android", Model: "Shared Device", Locale: "en-US", UserAgent: "SVOI-Test/1"}
	expect(t, call(a, "PUT", "/api/identity", owner, input{Identity: identity}), 200)
	expect(t, call(a, "PUT", "/api/subscription", owner, input{URL: "https://vpn.example/sub/private-key"}), 200)
	var requests []http.Header
	a.client = &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
		requests = append(requests, r.Header.Clone())
		if r.Header.Get("Authorization") != "" {
			t.Error("member token sent upstream")
		}
		return fakeResponse(200, base64.StdEncoding.EncodeToString([]byte("vless://test@example.com:443#Server"))), nil
	})}
	for _, token := range []string{owner, member} {
		v := expect(t, call(a, "POST", "/api/subscription/refresh", token, nil), 200)
		if v["count"] != float64(1) {
			t.Fatal(v)
		}
	}
	if !reflect.DeepEqual(requests[0], requests[1]) {
		t.Fatal("headers differ")
	}
	for k, v := range headers(identity) {
		if requests[0].Get(k) != v {
			t.Errorf("header %s mismatch", k)
		}
	}
	w := call(a, "GET", "/api/subscription/export", member, nil)
	if w.Code != 200 || !strings.Contains(w.Header().Get("Content-Disposition"), "attachment") {
		t.Fatal("export failed")
	}
	v := expect(t, call(a, "GET", "/api/me", member, nil), 200)
	if v["subscriptionHost"] != "vpn.example" {
		t.Fatal("missing host")
	}
	if strings.Contains(string(mustJSON(t, v)), "private-key") {
		t.Fatal("subscription URL leaked")
	}
}

func TestRevocationDuringRefresh(t *testing.T) {
	a := newTestApp(t)
	owner := create(t, a)
	member := join(t, a, owner)
	m := expect(t, call(a, "GET", "/api/me", member, nil), 200)
	expect(t, call(a, "PUT", "/api/subscription", owner, input{URL: "https://vpn.example/sub"}), 200)
	started := make(chan struct{})
	release := make(chan struct{})
	var once sync.Once
	a.client = &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
		once.Do(func() { close(started) })
		<-release
		return fakeResponse(200, "vless://key@example.com:443"), nil
	})}
	result := make(chan *httptest.ResponseRecorder, 1)
	go func() { result <- call(a, "POST", "/api/subscription/refresh", member, nil) }()
	<-started
	expect(t, call(a, "DELETE", "/api/devices/"+m["self"].(string), owner, nil), 200)
	close(release)
	expect(t, <-result, 401)
}

func TestValidationAndIsolation(t *testing.T) {
	a := newTestApp(t)
	owner := create(t, a)
	otherOwner := create(t, a)
	other := expect(t, call(a, "GET", "/api/me", otherOwner, nil), 200)
	expect(t, call(a, "DELETE", "/api/devices/"+other["self"].(string), owner, nil), 404)
	expect(t, call(a, "PUT", "/api/identity", owner, input{Identity: Identity{HWID: "x\r\nInjected: true", OS: "a", Model: "b", Locale: "c", UserAgent: "d"}}), 400)
	for _, raw := range []string{"http://example.com/sub", "https://user:pass@example.com/sub", "https://example.com:8080/sub", "https://example.com/#fragment"} {
		expect(t, call(a, "PUT", "/api/subscription", owner, input{URL: raw}), 400)
	}
	expect(t, call(a, "POST", "/api/leave", owner, nil), 409)
	r := httptest.NewRequest("POST", "http://service.example/api/groups", strings.NewReader(`{"name":"X"}`))
	r.Header.Set("Origin", "https://evil.example")
	w := httptest.NewRecorder()
	a.handler().ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatal("cross-origin mutation allowed")
	}
}
func TestExpiredInvite(t *testing.T) {
	a := newTestApp(t)
	owner := create(t, a)
	v := expect(t, call(a, "POST", "/api/invites", owner, nil), 201)
	a.state.Groups[0].Invites[0].Expires = time.Now().Add(-time.Minute)
	expect(t, call(a, "POST", "/api/join", "", input{Invite: v["code"].(string), DeviceName: "Phone", Platform: "Android"}), 400)
}
func TestPrivateAddressesBlocked(t *testing.T) {
	for _, s := range []string{"127.0.0.1", "10.0.1.1", "169.254.169.254", "100.64.1.1", "192.168.1.1", "::1", "::ffff:127.0.0.1", "fc00::1", "fe80::1", "2002:7f00:1::1", "64:ff9b::7f00:1"} {
		if publicIP(netip.MustParseAddr(s)) {
			t.Errorf("allowed %s", s)
		}
	}
	for _, s := range []string{"1.1.1.1", "2606:4700:4700::1111"} {
		if !publicIP(netip.MustParseAddr(s)) {
			t.Errorf("blocked public address %s", s)
		}
	}
}
func TestSubscriptionFormats(t *testing.T) {
	for _, s := range []string{"vless://uuid@example.com:443#Test\ntrojan://pass@example.com:443", base64.RawStdEncoding.EncodeToString([]byte("vless://uuid@example.com:443")), `{"outbounds":[{"protocol":"vless","settings":{"address":"example.com","port":443,"id":"uuid","encryption":"none"}}]}`, `[{"outbounds":[{"protocol":"vless","settings":{"address":"example.com","port":443,"id":"uuid","encryption":"none"}}]}]`} {
		if _, err := inspectSubscription([]byte(s)); err != nil {
			t.Fatal(err)
		}
	}
	for _, s := range []string{"<html>Login</html>", `{"error":"expired"}`, `{"outbounds":`, ""} {
		if _, err := inspectSubscription([]byte(s)); err == nil {
			t.Errorf("accepted invalid config: %s", s)
		}
	}
}
func TestPersistenceFailureRollsBack(t *testing.T) {
	a := newTestApp(t)
	owner := create(t, a)
	before := a.state.Groups[0].Identity
	a.path = filepath.Join(t.TempDir(), "directory")
	if err := os.Mkdir(a.path, 0700); err != nil {
		t.Fatal(err)
	}
	next := before
	next.HWID = "changed"
	expect(t, call(a, "PUT", "/api/identity", owner, input{Identity: next}), 500)
	if a.state.Groups[0].Identity != before {
		t.Fatal("failed write changed live state")
	}
}
func TestUpstreamErrors(t *testing.T) {
	a := newTestApp(t)
	owner := create(t, a)
	expect(t, call(a, "PUT", "/api/subscription", owner, input{URL: "https://vpn.example/sub"}), 200)
	a.client = &http.Client{Transport: transportFunc(func(*http.Request) (*http.Response, error) { return fakeResponse(302, "redirect"), nil })}
	expect(t, call(a, "POST", "/api/subscription/refresh", owner, nil), 502)
	a.client = &http.Client{Transport: transportFunc(func(*http.Request) (*http.Response, error) {
		return fakeResponse(200, strings.Repeat("x", (4<<20)+1)), nil
	})}
	expect(t, call(a, "POST", "/api/subscription/refresh", owner, nil), 413)
}
