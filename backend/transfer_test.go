package backend

import (
	"bytes"
	"compress/gzip"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"reflect"
	"strings"
	"testing"
)

func TestOldTransferRemoteCacheIsNotUsed(t *testing.T) {
	a := newTestApp(t)
	create(t, a)
	p := portableProfile{Version: 1, Name: "Legacy code", Identity: a.state.Groups[0].Identity, Sources: []portableSource{{Name: "Remote", URL: "https://example.com/sub", Configs: []portableConfig{{Name: "Stale", Data: json.RawMessage(`{"protocol":"unsupported-cached-config"}`)}}}}}
	code, err := encodePortable(p)
	if err != nil {
		t.Fatal(err)
	}
	g, err := decodeTransfer(code)
	if err != nil {
		t.Fatal(err)
	}
	if len(g.Servers) != 0 || len(g.Subscriptions) != 1 || g.Subscriptions[0].Report != nil {
		t.Fatal("old cached server reused")
	}
}

func TestRefreshAllTransferredSources(t *testing.T) {
	a := newTestApp(t)
	create(t, a)
	p := portableProfile{Version: 1, Name: "32 sources", Identity: a.state.Groups[0].Identity}
	for i := 0; i < 32; i++ {
		p.Sources = append(p.Sources, portableSource{Name: fmt.Sprintf("Source %d", i), URL: fmt.Sprintf("https://example.com/sub/%d", i)})
	}
	code, err := encodePortable(p)
	if err != nil {
		t.Fatal(err)
	}
	result := expect(t, call(a, "POST", "/api/transfer/import", "", map[string]any{"code": code, "deviceName": "PC", "platform": "Windows"}), 201)
	token := result["token"].(string)
	a.client = &http.Client{Transport: transportFunc(func(*http.Request) (*http.Response, error) {
		return fakeResponse(200, "vless://test@example.com:443"), nil
	})}
	for _, s := range a.state.Groups[1].Subscriptions {
		expect(t, call(a, "POST", "/api/subscription/refresh?id="+s.ID, token, nil), 200)
	}
	if len(a.state.Groups[1].Servers) != 32 {
		t.Fatal("not all sources refreshed")
	}
}

func TestTransferAcrossIndependentApps(t *testing.T) {
	sender, receiver := newTestApp(t), newTestApp(t)
	owner := create(t, sender)
	expect(t, call(sender, "PUT", "/api/subscription", owner, input{URL: "https://provider.example/private-subscription"}), 200)
	node, err := parseServerURI("vless://90e3da82-374e-46ef-9099-761d39b86b82@example.com:443#NL%20Node")
	if err != nil {
		t.Fatal(err)
	}
	graph := loopbackProfile(t, node)
	sender.client = &http.Client{Transport: transportFunc(func(*http.Request) (*http.Response, error) { return fakeResponse(200, string(mustJSON(t, graph))), nil })}
	expect(t, call(sender, "POST", "/api/subscription/refresh", owner, nil), 200)
	expect(t, call(sender, "POST", "/api/subscription/import", owner, map[string]string{"content": "trojan://transfer-test@example.org:443#DE%20Imported"}), 200)
	code := expect(t, call(sender, "POST", "/api/transfer/export", owner, nil), 200)["code"].(string)

	raw, _ := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(code, "SVOI1."))
	reader, _ := gzip.NewReader(bytes.NewReader(raw))
	var portable map[string]any
	if json.NewDecoder(reader).Decode(&portable) != nil {
		t.Fatal("invalid export")
	}
	reader.Close()
	payload := string(mustJSON(t, portable))
	for _, forbidden := range []string{"devices", "invites", "tokenHash", digest(owner), owner} {
		if strings.Contains(payload, forbidden) {
			t.Fatalf("export leaks %s", forbidden)
		}
	}
	receiver.client = &http.Client{Transport: transportFunc(func(*http.Request) (*http.Response, error) {
		t.Fatal("import contacted subscription provider")
		return nil, nil
	})}

	wrapped := " \n" + code[:30] + "\r\n" + code[30:] + "\n"
	preview := expect(t, call(receiver, "POST", "/api/transfer/preview", "", map[string]any{"code": wrapped}), 200)
	if preview["servers"] != float64(1) || len(receiver.state.Groups) != 0 {
		t.Fatal("preview wrote state or lost servers")
	}
	if strings.Contains(string(mustJSON(t, preview)), "private-subscription") {
		t.Fatal("preview leaks subscription path")
	}
	result := expect(t, call(receiver, "POST", "/api/transfer/import", "", map[string]any{"code": wrapped, "deviceName": "Second PC", "platform": "Windows"}), 201)
	remoteToken := result["token"].(string)
	original := sender.state.Groups[0]
	copied := receiver.state.Groups[0]
	if copied.ID == original.ID || copied.Devices[0].TokenHash == original.Devices[0].TokenHash || remoteToken == owner {
		t.Fatal("service credentials reused")
	}
	if len(copied.Devices) != 1 || !copied.Devices[0].Device.Owner || copied.Identity != original.Identity || len(copied.Subscriptions) != 2 || len(copied.Servers) != 1 {
		t.Fatal("profile incomplete")
	}
	if copied.Subscriptions[0].URL != original.Subscriptions[0].URL {
		t.Fatal("subscription URL lost")
	}
	expect(t, call(receiver, "GET", "/api/me", owner, nil), 401)
	expect(t, call(sender, "GET", "/api/me", remoteToken, nil), 401)
	receiver.client = &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
		for key, value := range headers(original.Identity) {
			if r.Header.Get(key) != value {
				t.Errorf("different shared header: %s", key)
			}
		}
		return fakeResponse(200, string(mustJSON(t, graph))), nil
	})}
	expect(t, call(receiver, "POST", "/api/subscription/refresh?id="+copied.Subscriptions[0].ID, remoteToken, nil), 200)
	var downloaded, expected object
	_ = json.Unmarshal(mustJSON(t, graph), &expected)
	_ = json.Unmarshal(receiver.state.Groups[0].Servers[1].Profile, &downloaded)
	if !reflect.DeepEqual(expected, downloaded) {
		t.Fatal("freshly fetched routing graph changed")
	}
	if len(portable["sources"].([]any)[0].(map[string]any)["configs"].([]any)) != 0 {
		t.Fatal("remote cache included in transfer")
	}

	restarted, err := openApp(receiver.path)
	if err != nil {
		t.Fatal(err)
	}
	expect(t, call(restarted, "GET", "/api/me", remoteToken, nil), 200)
}

func TestTransferReplaceRequiresOwner(t *testing.T) {
	a := newTestApp(t)
	owner := create(t, a)
	member := join(t, a, owner)
	expect(t, call(a, "POST", "/api/transfer/export", member, nil), 403)
	p := portableProfile{Version: 1, Name: "Updated", Identity: a.state.Groups[0].Identity}
	p.Identity.HWID = "new-shared-hwid"
	code, err := encodePortable(p)
	if err != nil {
		t.Fatal(err)
	}
	body := map[string]any{"code": code, "replace": true}
	expect(t, call(a, "POST", "/api/transfer/import", "", body), 401)
	expect(t, call(a, "POST", "/api/transfer/import", member, body), 403)
	before := a.state.Groups[0]
	expect(t, call(a, "POST", "/api/transfer/import", owner, body), 200)
	after := a.state.Groups[0]
	if after.ID != before.ID || !reflect.DeepEqual(after.Devices, before.Devices) || after.Identity != p.Identity || after.Name != "Updated" {
		t.Fatal("replace lost local sessions")
	}
	expect(t, call(a, "GET", "/api/me", member, nil), 200)
}

func TestTransferRejectsInvalidData(t *testing.T) {
	a := newTestApp(t)
	owner := create(t, a)
	valid := portableProfile{Version: 1, Name: "Example", Identity: a.state.Groups[0].Identity}
	cases := map[string]string{"old invite": secret(), "damaged": "SVOI1.broken", "oversize text": strings.Repeat("a", transferCodeLimit+1)}
	wrong := valid
	wrong.Version = 2
	cases["version"], _ = encodePortable(wrong)
	wrong = valid
	wrong.Identity.HWID = "bad\r\nheader"
	cases["identity"], _ = encodePortable(wrong)
	wrong = valid
	wrong.Sources = []portableSource{{Name: "Bad URL", URL: "http://example.com"}}
	cases["URL"], _ = encodePortable(wrong)
	wrong = valid
	wrong.Sources = []portableSource{{Name: "Bad graph", Configs: []portableConfig{{Data: json.RawMessage(`{"api":{},"outbounds":[]}`)}}}}
	cases["graph"], _ = encodePortable(wrong)
	var compressed bytes.Buffer
	writer := gzip.NewWriter(&compressed)
	_, _ = writer.Write(bytes.Repeat([]byte("x"), transferLimit+1))
	writer.Close()
	cases["compressed bomb"] = "SVOI1." + base64.RawURLEncoding.EncodeToString(compressed.Bytes())
	for name, code := range cases {
		t.Run(name, func(t *testing.T) {
			before := string(mustJSON(t, a.state))
			w := call(a, "POST", "/api/transfer/import", owner, map[string]any{"code": code, "replace": true})
			if w.Code < 400 {
				t.Fatal("invalid transfer accepted")
			}
			if string(mustJSON(t, a.state)) != before {
				t.Fatal("invalid import mutated state")
			}
		})
	}
}
