package main

import (
	"encoding/json"
	"os"
	"testing"
)

func TestSubscriptionDefaultUserAgent(t *testing.T) {
	a := newTestApp(t)
	create(t, a)
	if a.state.Groups[0].Identity.UserAgent != "Happ/0.4.1" {
		t.Fatal("new profile has wrong default UA")
	}
	for _, ua := range []string{"", "SVOI/0.2", "Custom/2.0"} {
		want := "Happ/0.4.1"
		if ua == "Custom/2.0" {
			want = ua
		}
		identity := Identity{HWID: "shared", OS: "Android", UserAgent: ua}
		if headers(identity)["User-Agent"] != want {
			t.Fatal("request UA", ua)
		}
		if identity.UserAgent != ua {
			t.Fatal("mutated identity")
		}
		a.state.Groups[0].Identity = identity
		data, _ := json.Marshal(a.state)
		if err := os.WriteFile(a.path, data, 0600); err != nil {
			t.Fatal(err)
		}
		loaded, err := openApp(a.path)
		if err != nil {
			t.Fatal(err)
		}
		if loaded.state.Groups[0].Identity.UserAgent != want {
			t.Fatal("saved profile migration", ua)
		}
	}
}
