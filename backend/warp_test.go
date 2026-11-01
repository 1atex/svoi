package main

import (
	"context"
	"errors"
	"net/http/httptest"
	"reflect"
	"runtime"
	"strings"
	"testing"
)

func TestWarpStatusParsing(t *testing.T) {
	for input, want := range map[string]string{
		"Status update: Connected":                                           "connected",
		"Status update: Disconnected\nReason: Manual Disconnection":          "disconnected",
		"Status: Connecting":                                                 "connecting",
		"Status update: Disconnecting":                                       "disconnecting",
		"Error: Missing Registration. Try running warp-cli registration new": "unregistered",
		"Unable to connect":                                                  "unknown",
		"Unrelated connected and disconnected text":                          "unknown",
	} {
		if got := parseWarpStatus(input); got != want {
			t.Errorf("%q: %s != %s", input, got, want)
		}
	}
	if warpActive("disconnected") || warpActive("unknown") || !warpActive("connecting") {
		t.Fatal("incorrect active-state guard")
	}
}

func TestWarpStatusHandlesMissingClientAndService(t *testing.T) {
	var missing *warpClient
	if got := missing.status(context.Background()); got.Installed || got.State != "not-installed" {
		t.Fatal(got)
	}
	w := &warpClient{binary: "test", run: func(ctx context.Context, args ...string) (string, error) {
		return "private diagnostic text", errors.New("service down")
	}}
	s := w.status(context.Background())
	if s.State != "unknown" || !s.Installed || s.Error == "" || strings.Contains(s.Error, "private") {
		t.Fatal(s)
	}
	w.run = func(ctx context.Context, args ...string) (string, error) { <-ctx.Done(); return "", ctx.Err() }
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if w.status(ctx).Error == "" {
		t.Fatal("cancellation should not report success")
	}
}

func TestWarpRegistrationAndConnectionLifecycle(t *testing.T) {
	if runtime.GOOS != "windows" && runtime.GOOS != "darwin" && runtime.GOOS != "linux" {
		t.Skip("Desktop integration")
	}
	state := "unregistered"
	var commands []string
	a := &App{warp: &warpClient{binary: "test"}}
	a.warp.run = func(ctx context.Context, args ...string) (string, error) {
		command := strings.Join(args, " ")
		if command == "status" {
			return "Status update: " + state, nil
		}
		commands = append(commands, command)
		switch command {
		case "--accept-tos registration new":
			state = "disconnected"
		case "connect":
			state = "connecting"
		case "disconnect":
			state = "disconnected"
		}
		return "Success", nil
	}
	request := func(action, body string) error {
		return a.warpAPI(httptest.NewRecorder(), httptest.NewRequest("POST", "/api/warp/"+action, strings.NewReader(body)))
	}
	if request("register", `{"accepted":false}`) == nil || len(commands) != 0 {
		t.Fatal("registration needs explicit consent")
	}
	if err := request("register", `{"accepted":true}`); err != nil {
		t.Fatal(err)
	}
	a.engine = &Engine{status: EngineStatus{State: "running"}}
	if request("connect", "") == nil || len(commands) != 1 {
		t.Fatal("must not connect over active VPN")
	}
	a.engine = nil
	if externalZapretRunning() {
		t.Skip("a real zapret process is active")
	}
	if err := request("connect", ""); err != nil {
		t.Fatal(err)
	}
	if a.warp.status(context.Background()).State != "connecting" {
		t.Fatal("connect must not fabricate a connected state")
	}
	if err := request("disconnect", ""); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(commands, []string{"--accept-tos registration new", "mode warp+doh", "connect", "disconnect"}) {
		t.Fatal(commands)
	}
	if err := request("arbitrary", ""); err == nil {
		t.Fatal("unknown actions must be rejected")
	}
}
