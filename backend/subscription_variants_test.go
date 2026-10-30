package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func variantTestCore(request *http.Request) string {
	ua := request.Header.Get("User-Agent")
	if ua == "singbox" {
		return "sing-box"
	}
	if ua == "murge" {
		return "mihomo"
	}
	return "xray"
}
func variantTestBody(core string, generation int) string {
	switch core {
	case "sing-box":
		return fmt.Sprintf(`{"outbounds":[{"type":"selector","tag":"entry","outbounds":["node"]},{"type":"vless","tag":"node","server":"sb-%d.invalid","server_port":443,"uuid":"90e3da82-374e-46ef-9099-761d39b86b82"}],"route":{"final":"entry"},"dns":{"servers":[{"type":"local","tag":"local"}]}}`, generation)
	case "mihomo":
		return fmt.Sprintf("proxies:\n  - name: node\n    type: vless\n    server: mh-%d.invalid\n    port: 443\n    uuid: 90e3da82-374e-46ef-9099-761d39b86b82\nproxy-groups:\n  - name: entry\n    type: select\n    proxies: [node]\nrules: [\"MATCH,entry\"]\ndns: {enable: false}\n", generation)
	}
	body := "vless://90e3da82-374e-46ef-9099-761d39b86b82@xray.invalid:443?security=tls#Stable"
	if generation > 1 {
		body += "\ntrojan://private-test-password@new.invalid:443#New"
	}
	return body
}
func variantTestSubscription(t *testing.T) (*App, string, string) {
	t.Helper()
	a := newTestApp(t)
	token := create(t, a)
	id := expect(t, call(a, "POST", "/api/subscriptions", token, input{Name: "Provider", URL: "https://provider.invalid/private-token"}), 201)["id"].(string)
	return a, token, id
}
func variantTestRows(group Group, id string) map[string][]ServerConfig {
	result := map[string][]ServerConfig{}
	for _, server := range group.Servers {
		if server.SubscriptionID == id {
			result[subscriptionServerCore(server)] = append(result[subscriptionServerCore(server)], server)
		}
	}
	return result
}

func TestSubscriptionVariantsAllFormatsAndPartialLastGood(t *testing.T) {
	a, token, id := variantTestSubscription(t)
	generation := 1
	failedCore := ""
	a.client = &http.Client{Transport: transportFunc(func(request *http.Request) (*http.Response, error) {
		core := variantTestCore(request)
		if core == failedCore {
			return fakeResponse(503, "private-upstream-body"), nil
		}
		response := fakeResponse(200, variantTestBody(core, generation))
		response.Header.Set("check-url-via-proxy", "https://"+core+"-check.invalid/")
		response.Header.Set("profile-title", core+" title")
		return response, nil
	})}
	expect(t, call(a, "POST", "/api/subscription/refresh?id="+id, token, nil), 200)
	group := &a.state.Groups[0]
	source := subscriptionByID(group, id)
	rows := variantTestRows(*group, id)
	if len(group.Servers) != 3 || len(source.Variants) != 3 {
		t.Fatal("missing variant caches", len(group.Servers), source.Variants)
	}
	for _, core := range subscriptionVariantCores {
		status := source.Variants[core]
		if len(rows[core]) != 1 || rows[core][0].SubscriptionCore != core || status.State != "ready" || status.Count != 1 || status.Stale || status.Error != "" || status.Report == nil || status.Metadata == nil || status.Metadata.Hints["check-url-via-proxy"] != "https://"+core+"-check.invalid/" {
			t.Fatal("incorrect variant metadata/status", core, status)
		}
		if core != "xray" && (!rows[core][0].FullProfile || rows[core][0].SourceProfileCore != core || !strings.HasPrefix(rows[core][0].ID, id+"-"+core+"-")) {
			t.Fatal("native variant flattened or not namespaced")
		}
		if got := serverProbeSettings(ProbeSettings{}, group, rows[core][0]); got.URL != "https://"+core+"-check.invalid/" {
			t.Fatal("variant selected wrong provider check URL", core, got.URL)
		}
	}
	legacy, err := parseSubscription([]byte(variantTestBody("xray", 1)))
	if err != nil {
		t.Fatal(err)
	}
	if rows["xray"][0].ID != id+"-"+legacy.Servers[0].ID {
		t.Fatal("existing Xray selection/favorite ID changed")
	}
	beforeMihomo := rows["mihomo"][0]
	beforeReport := *source.Variants["mihomo"].Report
	stableXrayID := rows["xray"][0].ID
	generation, failedCore = 2, "mihomo"
	response := expect(t, call(a, "POST", "/api/subscription/refresh?id="+id, token, nil), 200)
	rows = variantTestRows(*group, id)
	source = subscriptionByID(group, id)
	if len(rows["xray"]) != 2 || rows["xray"][0].ID != stableXrayID || bytes.Equal(rows["sing-box"][0].Profile, []byte(variantTestBody("sing-box", 1))) {
		t.Fatal("successful variants were not replaced correctly")
	}
	if rows["mihomo"][0].ID != beforeMihomo.ID || !bytes.Equal(rows["mihomo"][0].Profile, beforeMihomo.Profile) {
		t.Fatal("partial failure destroyed last-good native graph")
	}
	status := source.Variants["mihomo"]
	if status.State != "error" || !status.Stale || status.Count != 1 || status.Error == "" || !reflect.DeepEqual(*status.Report, beforeReport) {
		t.Fatal("last-good status lost", status)
	}
	if len(response["warnings"].([]any)) == 0 {
		t.Fatal("partial failure hidden in refresh response")
	}
	view := expect(t, call(a, "GET", "/api/me", token, nil), 200)
	encoded := string(mustJSON(t, view))
	if !strings.Contains(encoded, `"variants"`) || strings.Contains(encoded, "private-token") || strings.Contains(encoded, "private-test-password") || strings.Contains(encoded, "private-upstream-body") {
		t.Fatal("variant summary missing or leaked credentials")
	}
	restored, err := openApp(a.path)
	if err != nil {
		t.Fatal(err)
	}
	if restored.state.Groups[0].Subscriptions[0].Variants["mihomo"].State != "error" || len(restored.state.Groups[0].Servers) != 4 {
		t.Fatal("variant cache/status not persistent")
	}
}

func TestSubscriptionVariantsLegacyFallbackDoesNotFakeNative(t *testing.T) {
	a, token, id := variantTestSubscription(t)
	a.client = &http.Client{Transport: transportFunc(func(*http.Request) (*http.Response, error) { return fakeResponse(200, variantTestBody("xray", 1)), nil })}
	expect(t, call(a, "POST", "/api/subscription/refresh?id="+id, token, nil), 200)
	group := &a.state.Groups[0]
	source := subscriptionByID(group, id)
	if len(group.Servers) != 1 || group.Servers[0].SubscriptionCore != "xray" {
		t.Fatal("legacy response duplicated as native")
	}
	for _, core := range []string{"sing-box", "mihomo"} {
		status := source.Variants[core]
		if status.State != "unavailable" || status.Count != 0 || status.Stale || status.Error == "" {
			t.Fatal("native fallback falsely ready", core, status)
		}
	}
	// After native variants were genuinely obtained, fallback keeps their old
	// cache but marks it stale rather than rewriting it as a legacy node.
	a.client = &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
		return fakeResponse(200, variantTestBody(variantTestCore(r), 1)), nil
	})}
	expect(t, call(a, "POST", "/api/subscription/refresh?id="+id, token, nil), 200)
	previous := variantTestRows(*group, id)
	a.client = &http.Client{Transport: transportFunc(func(*http.Request) (*http.Response, error) { return fakeResponse(200, variantTestBody("xray", 2)), nil })}
	expect(t, call(a, "POST", "/api/subscription/refresh?id="+id, token, nil), 200)
	current := variantTestRows(*group, id)
	for _, core := range []string{"sing-box", "mihomo"} {
		status := source.Variants[core]
		if !status.Stale || status.State != "unavailable" || current[core][0].ID != previous[core][0].ID || !bytes.Equal(current[core][0].Profile, previous[core][0].Profile) {
			t.Fatal("fallback replaced native cache", core)
		}
	}
}

func TestSubscriptionVariantsRefreshContinuesWhenXrayFails(t *testing.T) {
	a, token, id := variantTestSubscription(t)
	a.client = &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
		core := variantTestCore(r)
		if core == "xray" {
			return fakeResponse(503, ""), nil
		}
		return fakeResponse(200, variantTestBody(core, 1)), nil
	})}
	expect(t, call(a, "POST", "/api/subscription/refresh?id="+id, token, nil), 200)
	if len(a.state.Groups[0].Servers) != 2 || a.state.Groups[0].Subscriptions[0].Variants["xray"].State != "error" {
		t.Fatal("native progress discarded because default format failed")
	}
}

func TestSubscriptionVariantsAllFailureRetainsCachesAndDiagnostics(t *testing.T) {
	a, token, id := variantTestSubscription(t)
	a.client = &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
		return fakeResponse(200, variantTestBody(variantTestCore(r), 1)), nil
	})}
	expect(t, call(a, "POST", "/api/subscription/refresh?id="+id, token, nil), 200)
	before := mustJSON(t, a.state.Groups[0].Servers)
	a.client = &http.Client{Transport: transportFunc(func(*http.Request) (*http.Response, error) {
		return nil, errors.New("private-provider-token and private-password")
	})}
	expect(t, call(a, "POST", "/api/subscription/refresh?id="+id, token, nil), 502)
	if !bytes.Equal(before, mustJSON(t, a.state.Groups[0].Servers)) {
		t.Fatal("all-failure refresh changed cached payloads")
	}
	for _, status := range a.state.Groups[0].Subscriptions[0].Variants {
		if !status.Stale || status.State != "error" || status.Error == "" || strings.Contains(status.Error, "private-") {
			t.Fatal("unsafe/missing persisted failure status", status)
		}
	}
}

func TestSubscriptionVariantsConcurrencyAndCancellation(t *testing.T) {
	for _, cancelRequest := range []bool{false, true} {
		t.Run(fmt.Sprint(cancelRequest), func(t *testing.T) {
			a, token, id := variantTestSubscription(t)
			started := make(chan string, 3)
			release := make(chan struct{})
			var active, peak atomic.Int32
			a.client = &http.Client{Transport: transportFunc(func(request *http.Request) (*http.Response, error) {
				current := active.Add(1)
				defer active.Add(-1)
				for old := peak.Load(); current > old; old = peak.Load() {
					if peak.CompareAndSwap(old, current) {
						break
					}
				}
				if deadline, ok := request.Context().Deadline(); !ok || time.Until(deadline) > 23*time.Second {
					t.Error("missing bounded shared request context")
				}
				core := variantTestCore(request)
				started <- core
				select {
				case <-release:
					return fakeResponse(200, variantTestBody(core, 1)), nil
				case <-request.Context().Done():
					return nil, request.Context().Err()
				}
			})}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			request := httptest.NewRequest("POST", "/api/subscription/refresh?id="+id, nil).WithContext(ctx)
			request.RemoteAddr = "127.0.0.1:1234"
			request.Header.Set("Authorization", "Bearer "+token)
			recorder := httptest.NewRecorder()
			done := make(chan struct{})
			go func() { a.handler().ServeHTTP(recorder, request); close(done) }()
			seen := map[string]bool{}
			for range subscriptionVariantCores {
				select {
				case core := <-started:
					seen[core] = true
				case <-time.After(2 * time.Second):
					t.Fatal("format requests were serialized or missing")
				}
			}
			if len(seen) != 3 || peak.Load() != 3 {
				t.Fatal("expected exactly three concurrent formats")
			}
			if cancelRequest {
				cancel()
			} else {
				close(release)
			}
			select {
			case <-done:
			case <-time.After(2 * time.Second):
				t.Fatal("cancellation/refresh did not complete")
			}
			if cancelRequest {
				if len(a.state.Groups[0].Servers) != 0 || a.state.Groups[0].Subscriptions[0].Variants != nil {
					t.Fatal("cancelled request changed cached state")
				}
			} else if recorder.Code != 200 {
				t.Fatal(recorder.Code, recorder.Body.String())
			}
		})
	}
}

func TestSubscriptionVariantsStaleIdentityURLAndPreferenceGuard(t *testing.T) {
	for _, change := range []string{"identity", "url", "preference"} {
		t.Run(change, func(t *testing.T) {
			a, token, id := variantTestSubscription(t)
			started := make(chan struct{}, 3)
			release := make(chan struct{})
			a.client = &http.Client{Transport: transportFunc(func(request *http.Request) (*http.Response, error) {
				started <- struct{}{}
				<-release
				return fakeResponse(200, variantTestBody(variantTestCore(request), 1)), nil
			})}
			done := make(chan *httptest.ResponseRecorder, 1)
			go func() { done <- call(a, "POST", "/api/subscription/refresh?id="+id, token, nil) }()
			for range subscriptionVariantCores {
				<-started
			}
			switch change {
			case "identity":
				identity := a.state.Groups[0].Identity
				identity.HWID = "changed-hwid"
				expect(t, call(a, "PUT", "/api/identity", token, input{Identity: identity}), 200)
			case "url":
				expect(t, call(a, "PUT", "/api/subscriptions/"+id, token, input{Name: "Provider", URL: "https://new-provider.invalid/new-token"}), 200)
			case "preference":
				format := "mihomo"
				expect(t, call(a, "PUT", "/api/subscriptions/"+id, token, input{Name: "Provider", ResponseFormat: &format}), 200)
			}
			before := mustJSON(t, a.state)
			close(release)
			expect(t, <-done, 409)
			if !bytes.Equal(before, mustJSON(t, a.state)) {
				t.Fatal("stale response wrote cache or statuses")
			}
		})
	}
}

func TestSubscriptionVariantsURLChangeClearsEveryCache(t *testing.T) {
	a, token, id := variantTestSubscription(t)
	a.client = &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
		return fakeResponse(200, variantTestBody(variantTestCore(r), 1)), nil
	})}
	expect(t, call(a, "POST", "/api/subscription/refresh?id="+id, token, nil), 200)
	expect(t, call(a, "PUT", "/api/subscriptions/"+id, token, input{Name: "Provider", URL: "https://new-provider.invalid/new-token"}), 200)
	sub := a.state.Groups[0].Subscriptions[0]
	if len(a.state.Groups[0].Servers) != 0 || sub.Variants != nil || sub.Metadata != nil || sub.Report != nil {
		t.Fatal("new URL retained old variants/metadata")
	}
}

func TestSubscriptionVariantsPersistenceFailureRollsBack(t *testing.T) {
	a, token, id := variantTestSubscription(t)
	a.client = &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
		return fakeResponse(200, variantTestBody(variantTestCore(r), 1)), nil
	})}
	before := mustJSON(t, a.state)
	a.path = filepath.Join(t.TempDir(), "directory")
	if err := os.Mkdir(a.path, 0700); err != nil {
		t.Fatal(err)
	}
	expect(t, call(a, "POST", "/api/subscription/refresh?id="+id, token, nil), 500)
	if !bytes.Equal(before, mustJSON(t, a.state)) {
		t.Fatal("failed persistence partially committed variants")
	}
}

func TestSubscriptionVariantsExportOnlySelectedResponse(t *testing.T) {
	a, token, id := variantTestSubscription(t)
	format := "mihomo"
	a.state.Groups[0].Subscriptions[0].ResponseFormat = format
	var calls atomic.Int32
	a.client = &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
		calls.Add(1)
		if variantTestCore(r) != "mihomo" {
			t.Error("export requested another format")
		}
		return fakeResponse(200, variantTestBody("mihomo", 1)), nil
	})}
	before := mustJSON(t, a.state)
	response := call(a, "GET", "/api/subscription/export?id="+id, token, nil)
	if response.Code != 200 || calls.Load() != 1 || response.Body.String() != variantTestBody("mihomo", 1) || !bytes.Equal(before, mustJSON(t, a.state)) {
		t.Fatal("export modified caches or mixed formats", response.Code)
	}
}

func TestSubscriptionVariantsSharedTimeoutRetainsCompletedResults(t *testing.T) {
	a, token, id := variantTestSubscription(t)
	a.client = &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
		return fakeResponse(200, variantTestBody(variantTestCore(r), 1)), nil
	})}
	expect(t, call(a, "POST", "/api/subscription/refresh?id="+id, token, nil), 200)
	group := &a.state.Groups[0]
	before := variantTestRows(*group, id)
	client := &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
		if variantTestCore(r) == "xray" {
			return fakeResponse(200, variantTestBody("xray", 2)), nil
		}
		<-r.Context().Done()
		return nil, r.Context().Err()
	})}
	results, err := fetchSubscriptionVariantsWithin(context.Background(), client, "https://provider.invalid/private-token", group.Identity, 60*time.Millisecond)
	if err != nil || len(results) != 3 || results["xray"].Err != nil {
		t.Fatal("shared timeout discarded completed result", err)
	}
	a.mu.Lock()
	var report *Report
	err = a.transaction(func() error {
		var applyErr error
		report, applyErr = applySubscriptionVariants(group, subscriptionByID(group, id), results, "auto")
		return applyErr
	})
	a.mu.Unlock()
	if err != nil || report.Count != 2 {
		t.Fatal("partial timeout progress not committed", err)
	}
	after := variantTestRows(*group, id)
	for _, core := range []string{"sing-box", "mihomo"} {
		status := group.Subscriptions[0].Variants[core]
		if !status.Stale || status.Error == "" || !bytes.Equal(before[core][0].Profile, after[core][0].Profile) {
			t.Fatal("timeout destroyed native last-good cache", core, status)
		}
	}
}

func TestSubscriptionVariantsCachedNativeConfigUsesExactCore(t *testing.T) {
	a, token, id := variantTestSubscription(t)
	a.client = &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
		return fakeResponse(200, variantTestBody(variantTestCore(r), 1)), nil
	})}
	expect(t, call(a, "POST", "/api/subscription/refresh?id="+id, token, nil), 200)
	rows := variantTestRows(a.state.Groups[0], id)
	for _, core := range []string{"sing-box", "mihomo"} {
		t.Run(core, func(t *testing.T) {
			server := rows[core][0]
			raw, err := buildCoreConfig(core, server, 21081, 21082, "local")
			if err != nil {
				t.Fatal("cached native variant cannot build for its core", err)
			}
			other := "sing-box"
			if core == other {
				other = "mihomo"
			}
			if _, err := buildCoreConfig(other, server, 21081, 21082, "local"); err == nil {
				t.Fatal("cached native variant crossed cores")
			}
			binary := testNativeCore(t, core)
			dir := t.TempDir()
			path := filepath.Join(dir, "config.json")
			if err = os.WriteFile(path, raw, 0600); err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, binary, coreArgs(core, "check", path, dir)...)
			hideCommand(cmd)
			if out, err := cmd.CombinedOutput(); err != nil {
				t.Fatalf("bundled core rejected refreshed cached variant: %v %s", err, out)
			}
		})
	}
}

func TestSubscriptionVariantsTimeoutDrainsQueuedCompletedResult(t *testing.T) {
	completed := make(chan subscriptionVariantResult, 3)
	ready := subscriptionVariantResult{Core: "sing-box", Report: &Report{Count: 1}, Parsed: ParsedSubscription{Servers: []ServerConfig{{ServerInfo: ServerInfo{SourceProfileCore: "sing-box"}}}}}
	completed <- ready
	close(completed)
	results := map[string]subscriptionVariantResult{"xray": {Core: "xray", Report: &Report{Count: 2}}}
	finishSubscriptionVariantTimeout(results, completed)
	if len(results) != 3 || results["sing-box"].Err != nil || results["sing-box"].Report != ready.Report || results["mihomo"].Err == nil {
		t.Fatal("queued completed result was replaced by synthetic timeout")
	}
}

func TestSubscriptionVariantsNewerRefreshWinsOutOfOrder(t *testing.T) {
	a, token, id := variantTestSubscription(t)
	oldStarted := make(chan struct{}, 3)
	releaseOld := make(chan struct{})
	var calls atomic.Int32
	a.client = &http.Client{Transport: transportFunc(func(request *http.Request) (*http.Response, error) {
		generation := 2
		if calls.Add(1) <= 3 {
			generation = 1
			oldStarted <- struct{}{}
			<-releaseOld
		}
		return fakeResponse(200, variantTestBody(variantTestCore(request), generation)), nil
	})}
	old := make(chan *httptest.ResponseRecorder, 1)
	go func() { old <- call(a, "POST", "/api/subscription/refresh?id="+id, token, nil) }()
	for range subscriptionVariantCores {
		<-oldStarted
	}
	expect(t, call(a, "POST", "/api/subscription/refresh?id="+id, token, nil), 200)
	before := mustJSON(t, a.state)
	close(releaseOld)
	expect(t, <-old, 409)
	if !bytes.Equal(before, mustJSON(t, a.state)) {
		t.Fatal("older refresh overwrote newer cache or status")
	}
	if len(variantTestRows(a.state.Groups[0], id)["xray"]) != 2 {
		t.Fatal("newer Xray response lost")
	}
}

func TestSubscriptionVariantsRefreshGenerationIsPerSource(t *testing.T) {
	a, token, first := variantTestSubscription(t)
	second := expect(t, call(a, "POST", "/api/subscriptions", token, input{Name: "Second", URL: "https://second.invalid/private"}), 201)["id"].(string)
	started := make(chan struct{}, 3)
	release := make(chan struct{})
	a.client = &http.Client{Transport: transportFunc(func(request *http.Request) (*http.Response, error) {
		generation := 2
		if request.URL.Host == "provider.invalid" {
			generation = 1
			started <- struct{}{}
			<-release
		}
		return fakeResponse(200, variantTestBody(variantTestCore(request), generation)), nil
	})}
	firstResult := make(chan *httptest.ResponseRecorder, 1)
	go func() { firstResult <- call(a, "POST", "/api/subscription/refresh?id="+first, token, nil) }()
	for range subscriptionVariantCores {
		<-started
	}
	expect(t, call(a, "POST", "/api/subscription/refresh?id="+second, token, nil), 200)
	close(release)
	expect(t, <-firstResult, 200)
	if len(variantTestRows(a.state.Groups[0], first)["xray"]) != 1 || len(variantTestRows(a.state.Groups[0], second)["xray"]) != 2 {
		t.Fatal("another source invalidated or overwrote refresh")
	}
}
