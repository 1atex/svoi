package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"testing"
)

type fakeDNSHost struct {
	values []dnsAdapter
	sets   [][]string
	fail   bool
	admin  bool
}

func (d *fakeDNSHost) adapters(context.Context) ([]dnsAdapter, error) { return d.values, nil }
func (d *fakeDNSHost) elevated() bool                                 { return d.admin }
func (d *fakeDNSHost) set(_ context.Context, index int, addresses []string) error {
	if d.fail {
		return errors.New("failed")
	}
	d.sets = append(d.sets, append([]string{}, addresses...))
	return nil
}
func dnsCall(t *testing.T, a *App, path string, body any) error {
	t.Helper()
	data, _ := json.Marshal(body)
	r := httptest.NewRequest("POST", path, strings.NewReader(string(data)))
	return a.dnsAPI(httptest.NewRecorder(), r)
}
func TestDNSBackupSurvivesReapplyAndRestart(t *testing.T) {
	for _, original := range [][]string{{}, {"192.0.2.1", "192.0.2.2"}} {
		a := newTestApp(t)
		h := &fakeDNSHost{admin: true, values: []dnsAdapter{{Index: 2, ID: "adapter", Name: "Ethernet", Static: original}}}
		a.dnsHost = h
		for _, address := range []string{"1.1.1.1", "8.8.8.8"} {
			if err := dnsCall(t, a, "/api/dns/apply", map[string]string{"id": "adapter", "address": address}); err != nil {
				t.Fatal(err)
			}
			h.values[0].Static = []string{address}
		}
		reopened, err := openApp(a.path)
		if err != nil {
			t.Fatal(err)
		}
		reopened.dnsHost = h
		if err := dnsCall(t, reopened, "/api/dns/restore", nil); err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(h.sets[2], original) {
			t.Fatalf("original lost: %v != %v", h.sets[2], original)
		}
		if _, err := os.Stat(a.path + ".dns-backup.json"); !os.IsNotExist(err) {
			t.Fatal("backup not cleared")
		}
	}
}
func TestDNSFailedApplyKeepsBackupAndRejectsOtherAdapter(t *testing.T) {
	a := newTestApp(t)
	h := &fakeDNSHost{admin: true, fail: true, values: []dnsAdapter{{Index: 2, ID: "a"}, {Index: 3, ID: "b"}}}
	a.dnsHost = h
	if dnsCall(t, a, "/api/dns/apply", map[string]string{"id": "a", "address": "1.1.1.1"}) == nil {
		t.Fatal("missing failure")
	}
	if _, err := os.Stat(a.path + ".dns-backup.json"); err != nil {
		t.Fatal(err)
	}
	h.fail = false
	if dnsCall(t, a, "/api/dns/apply", map[string]string{"id": "b", "address": "1.1.1.1"}) == nil {
		t.Fatal("overwrote backup")
	}
	if err := dnsCall(t, a, "/api/dns/restore", nil); err != nil {
		t.Fatal(err)
	}
}
func TestDNSCannotChangeDuringVPNOrWithoutElevation(t *testing.T) {
	a := newTestApp(t)
	h := &fakeDNSHost{values: []dnsAdapter{{Index: 2, ID: "a"}}}
	a.dnsHost = h
	if dnsCall(t, a, "/api/dns/apply", map[string]string{"id": "a", "address": "1.1.1.1"}) == nil {
		t.Fatal("no privilege check")
	}
	h.admin = true
	a.engine = &Engine{status: EngineStatus{State: "running", Mode: "tun"}}
	if dnsCall(t, a, "/api/dns/apply", map[string]string{"id": "a", "address": "1.1.1.1"}) == nil {
		t.Fatal("changed active VPN DNS")
	}
	if len(h.sets) != 0 {
		t.Fatal("unexpected system mutation")
	}
}
func TestDNSMeasurementReportsFailuresAndCancellation(t *testing.T) {
	queries := 0
	r, err := measureDNS(context.Background(), "1.1.1.1", "direct", func(context.Context, string) error {
		queries++
		if queries%2 == 0 {
			return errors.New("no answer")
		}
		return nil
	})
	if err != nil || r.Total != 6 || r.Success != 3 {
		t.Fatalf("%+v %v", r, err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err = measureDNS(ctx, "1.1.1.1", "direct", func(context.Context, string) error { t.Fatal("request after cancel"); return nil })
	if !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
}
func TestDNSStaticParsing(t *testing.T) {
	if !reflect.DeepEqual(dnsStaticAddresses("1.1.1.1,8.8.8.8 invalid ::1"), []string{"1.1.1.1", "8.8.8.8"}) {
		t.Fatal("invalid parsing")
	}
}
