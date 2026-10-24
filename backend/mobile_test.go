package backend

import (
	"encoding/json"
	"testing"
)

func TestMobileImportAndTunConfig(t *testing.T) {
	app, err := OpenMobile(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	call := func(method, path, token string, body any) object {
		t.Helper()
		raw, _ := json.Marshal(body)
		var response object
		if err := json.Unmarshal([]byte(app.Request(method, path, token, string(raw))), &response); err != nil {
			t.Fatal(err)
		}
		if number(response["status"]) >= 400 {
			t.Fatal(response)
		}
		return obj(response["body"])
	}
	created := call("POST", "/api/groups", "", object{"name": "Mobile", "deviceName": "Android", "platform": "Android"})
	token := str(created["token"])
	if str(obj(obj(created["group"])["identity"])["os"]) != "Android" {
		t.Fatal("wrong initial platform")
	}
	node, err := parseServerURI("vless://90e3da82-374e-46ef-9099-761d39b86b82@example.com:443?security=tls#Node")
	if err != nil {
		t.Fatal(err)
	}
	profile := loopbackProfile(t, node)
	encoded, _ := json.Marshal(profile)
	call("POST", "/api/subscription/import", token, object{"content": string(encoded)})
	current := call("GET", "/api/me", token, nil)
	servers := current["servers"].([]any)
	id := str(obj(servers[0])["id"])
	config, err := app.TunnelConfig(token, id)
	if err != nil {
		t.Fatal(err)
	}
	var parsed object
	if err = json.Unmarshal([]byte(config), &parsed); err != nil {
		t.Fatal(err)
	}
	found := false
	for _, raw := range parsed["inbounds"].([]any) {
		inbound := obj(raw)
		if str(inbound["protocol"]) == "tun" {
			found = true
			settings := obj(inbound["settings"])
			if len(settings) != 2 || settings["autoOutboundsInterface"] != nil {
				t.Fatal("desktop route management leaked into Android config")
			}
		}
	}
	if !found {
		t.Fatal("TUN missing")
	}
	if len(obj(parsed["routing"])["balancers"].([]any)) != 2 {
		t.Fatal("routing graph lost")
	}
	if _, err = app.TunnelConfig("invalid", id); err == nil {
		t.Fatal("missing auth check")
	}
	if _, err = app.TunnelConfig(token, "missing"); err == nil {
		t.Fatal("missing server check")
	}
}
