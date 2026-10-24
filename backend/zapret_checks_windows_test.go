//go:build windows

package backend

import (
	"context"
	"os"
	"testing"
)

func TestWindowsZapretDiagnosticsOptIn(t *testing.T) {
	if os.Getenv("SVOI_TEST_ZAPRET_DIAGNOSTICS") != "1" {
		t.Skip("read-only system diagnostics disabled")
	}
	rows, e := systemZapretDiagnostics(context.Background(), "")
	if e != nil {
		t.Fatal(e)
	}
	if len(rows) < 15 {
		t.Fatalf("incomplete diagnostics: %d checks", len(rows))
	}
	found := false
	for _, r := range rows {
		if r.Check == "Base Filtering Engine" {
			found = true
		}
		if r.State == "" || r.Detail == "" {
			t.Fatal("empty diagnostic result")
		}
	}
	if !found {
		t.Fatal("BFE missing")
	}
	t.Logf("Read-only Windows diagnostics: %d checks", len(rows))
}
