package main

import (
	"encoding/json"
	"net"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestDNSCatalogIsAvailableBeforeAdapterEnumeration(t *testing.T) {
	a := newTestApp(t)
	a.dnsHost = &fakeDNSHost{fail: true}
	w := httptest.NewRecorder()
	if err := a.dnsAPI(w, httptest.NewRequest("GET", "/api/dns/catalog", nil)); err != nil {
		t.Fatal(err)
	}
	var data struct{ Candidates []dnsCandidate }
	if err := json.Unmarshal(w.Body.Bytes(), &data); err != nil || len(data.Candidates) != 12 {
		t.Fatalf("catalog: %s, %v", w.Body, err)
	}
	seen := map[string]bool{}
	for _, candidate := range data.Candidates {
		ip := net.ParseIP(candidate.Address)
		if ip == nil || ip.To4() == nil || ip.IsPrivate() || seen[candidate.Address] || candidate.Name == "" {
			t.Fatalf("invalid provider: %+v", candidate)
		}
		seen[candidate.Address] = true
	}
}

func TestDNSMemberCanCompareButCannotChangeSystemSettings(t *testing.T) {
	a := newTestApp(t)
	member := join(t, a, create(t, a))
	for _, item := range []struct {
		method, path, body string
		status             int
	}{
		{"GET", "/api/dns/catalog", "", 200},
		{"POST", "/api/dns/benchmark", `{"address":"invalid"}`, 400},
		{"POST", "/api/dns/apply", `{"address":"1.1.1.1"}`, 403},
	} {
		r := httptest.NewRequest(item.method, item.path, strings.NewReader(item.body))
		r.RemoteAddr = "127.0.0.1:1234"
		r.Header.Set("Authorization", "Bearer "+member)
		w := httptest.NewRecorder()
		a.handler().ServeHTTP(w, r)
		if w.Code != item.status {
			t.Fatalf("%s: got %d: %s", item.path, w.Code, w.Body)
		}
	}
}
