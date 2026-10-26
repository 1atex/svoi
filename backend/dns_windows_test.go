//go:build windows

package backend

import (
	"context"
	"os"
	"testing"
	"time"
)

func TestWindowsDNSReadOnly(t *testing.T) {
	if os.Getenv("SVOI_TEST_DNS") != "1" {
		t.Skip("opt-in read-only Windows DNS integration")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	adapters, err := systemDNSAdapters(ctx)
	if err != nil {
		t.Fatal(err)
	}
	for _, a := range adapters {
		if a.ID == "" || a.Index <= 0 {
			t.Fatal("invalid adapter identity")
		}
	}
	t.Logf("Read %d physical adapters; no settings changed", len(adapters))
}
