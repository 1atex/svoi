package mobile

import (
	"encoding/json"
	"testing"
)

func TestAppleConfigPreservesRoutingAndRemovesDesktopListeners(t *testing.T) {
	raw := `{"inbounds":[{"protocol":"http","port":10809},{"protocol":"socks","port":10808},{"protocol":"tun","tag":"svoi-tun","settings":{"autoOutboundsInterface":"auto","autoSystemRoutingTable":["0.0.0.0/0"]}}],"outbounds":[{"protocol":"loopback","tag":"loop"}],"routing":{"rules":[{"inboundTag":["svoi-tun"],"outboundTag":"loop"}]},"dns":{"servers":["1.1.1.1"]}}`
	result, err := appleConfig(raw)
	if err != nil {
		t.Fatal(err)
	}
	var config map[string]any
	if err := json.Unmarshal([]byte(result), &config); err != nil {
		t.Fatal(err)
	}
	inbounds := config["inbounds"].([]any)
	if len(inbounds) != 1 {
		t.Fatal("unexpected local listeners", inbounds)
	}
	inbound := inbounds[0].(map[string]any)
	settings := inbound["settings"].(map[string]any)
	if len(settings) != 2 || inbound["tag"] != "svoi-tun" {
		t.Fatal("OS route management leaked into Network Extension", inbound)
	}
	if config["routing"] == nil || config["dns"] == nil || config["outbounds"].([]any)[0].(map[string]any)["protocol"] != "loopback" {
		t.Fatal("profile routing lost")
	}
}

func TestAppleConfigRequiresExactlyOneTun(t *testing.T) {
	for _, raw := range []string{`{}`, `{"inbounds":[{"protocol":"tun"},{"protocol":"tun"}]}`, `{"inbounds":[12]}`} {
		if _, err := appleConfig(raw); err == nil {
			t.Fatal("invalid configuration accepted", raw)
		}
	}
}
