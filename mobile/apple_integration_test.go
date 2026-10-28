package mobile

import (
	"encoding/json"
	"testing"
)

func TestAppleSessionImportIdentityAndAuthorizedConfig(t *testing.T) {
	session, err := NewSession(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	call := func(method, path, token string, body map[string]any) map[string]any {
		t.Helper()
		data, _ := json.Marshal(body)
		var response struct {
			Status int            `json:"status"`
			Body   map[string]any `json:"body"`
		}
		if err := json.Unmarshal([]byte(session.Request(method, path, token, string(data))), &response); err != nil {
			t.Fatal(err)
		}
		if response.Status >= 400 {
			t.Fatal(response)
		}
		return response.Body
	}
	created := call("POST", "/api/groups", "", map[string]any{"name": "iOS", "deviceName": "iPhone", "platform": "iOS"})
	token := created["token"].(string)
	if created["group"].(map[string]any)["identity"].(map[string]any)["os"] != "iOS" {
		t.Fatal("wrong iOS identity")
	}
	call("POST", "/api/subscription/import", token, map[string]any{"content": "vless://90e3da82-374e-46ef-9099-761d39b86b82@example.com:443?security=tls#iOS"})
	current := call("GET", "/api/me", token, nil)
	serverID := current["servers"].([]any)[0].(map[string]any)["id"].(string)
	config, err := session.AppleConfig(token, serverID)
	if err != nil {
		t.Fatal(err)
	}
	var parsed map[string]any
	if err := json.Unmarshal([]byte(config), &parsed); err != nil {
		t.Fatal(err)
	}
	for _, value := range parsed["inbounds"].([]any) {
		protocol := value.(map[string]any)["protocol"]
		if protocol == "http" || protocol == "socks" {
			t.Fatal("local listener leaked into extension")
		}
	}
	if _, err := session.AppleConfig("invalid-token", serverID); err == nil {
		t.Fatal("configuration authentication bypassed")
	}
}
