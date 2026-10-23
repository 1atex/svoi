package main

import (
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestConnectionSnapshotIsolatedLogs(t *testing.T) {
	e := &Engine{status: EngineStatus{Available: true, State: "running", Logs: []string{"first"}}}
	if s := e.snapshot(false); s.Logs != nil || !s.Available || s.State != "running" {
		t.Fatal("compact status lost state or copied logs")
	}
	s := e.Status()
	s.Logs[0] = "changed"
	if e.Status().Logs[0] != "first" {
		t.Fatal("snapshot aliases engine log storage")
	}
}

func TestZapretPreviewAndFullExport(t *testing.T) {
	z := &Zapret{}
	for i := 0; i < 1000; i++ {
		state := "error"
		if i%2 == 0 {
			state = "ok"
		}
		z.addResult(CheckResult{Target: fmt.Sprint(i), State: state})
	}
	for _, summary := range []bool{true, false} {
		url := "/api/zapret"
		want := 1000
		if summary {
			url += "?summary=1"
			want = 400
		}
		w := httptest.NewRecorder()
		if err := z.API(w, httptest.NewRequest("GET", url, nil), ""); err != nil {
			t.Fatal(err)
		}
		var got struct {
			Job ZapretJob `json:"job"`
		}
		if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
			t.Fatal(err)
		}
		if len(got.Job.Results) != want || got.Job.ResultCount != 1000 || got.Job.Successful != 500 || got.Job.Completed != 1000 {
			t.Fatalf("wrong preview/export counts: results=%d total=%d successes=%d", len(got.Job.Results), got.Job.ResultCount, got.Job.Successful)
		}
		if got.Job.Results[0].Target != fmt.Sprint(1000-want) {
			t.Fatal("preview must contain the most recent results")
		}
	}
	snapshot := z.snapshot("", true)["job"].(ZapretJob)
	snapshot.Results[0].Target = "changed"
	if z.job.Results[600].Target != "600" {
		t.Fatal("preview aliases job storage")
	}
}

// Synthetic data only; these benchmarks never launch Xray or use a subscription.
func BenchmarkConnectionPolling(b *testing.B) {
	for _, count := range []int{20, 2000} {
		b.Run(fmt.Sprint(count), func(b *testing.B) {
			token := strings.Repeat("a", 32)
			a := &App{engine: &Engine{status: EngineStatus{Available: true, State: "running", Logs: make([]string, 100)}}, state: State{Groups: []Group{{Devices: []Member{{TokenHash: digest(token)}}, Servers: make([]ServerConfig, count)}}}}
			r := httptest.NewRequest("GET", "/api/connection", nil)
			r.RemoteAddr = "127.0.0.1:1234"
			r.Header.Set("Authorization", "Bearer "+token)
			b.ReportAllocs()
			b.ResetTimer()
			for b.Loop() {
				w := httptest.NewRecorder()
				if err := a.engineAPI(w, r); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}

func BenchmarkZapretPolling(b *testing.B) {
	z := &Zapret{}
	for i := 0; i < 4000; i++ {
		z.addResult(CheckResult{Strategy: "general-test.bat", Target: "example.com", Check: "TLS1.3", State: "ok", Detail: strings.Repeat("x", 100)})
	}
	r := httptest.NewRequest("GET", "/api/zapret?summary=1", nil)
	b.ReportAllocs()
	b.ResetTimer()
	for b.Loop() {
		w := httptest.NewRecorder()
		if err := z.API(w, r, ""); err != nil {
			b.Fatal(err)
		}
		b.ReportMetric(float64(w.Body.Len()), "bytes/response")
	}
}
