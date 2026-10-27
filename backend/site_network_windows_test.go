//go:build windows

package main

import (
	"context"
	"os"
	"testing"
	"time"
)

func TestSitePhysicalAdapterNetwork(t *testing.T) {
	if os.Getenv("SVOI_SITE_NETWORK_TEST") != "1" {
		t.Skip("manual network integration test")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	target, err := siteTarget("https://example.com")
	if err != nil {
		t.Fatal(err)
	}
	steps, label, err := siteDirect(ctx, target)
	if err != nil {
		t.Fatal(err)
	}
	t.Log(label, steps)
	if len(steps) != 3 || !steps[0].OK || !steps[1].OK || !steps[2].Responded {
		t.Fatal("physical route did not reach the public test site", steps)
	}
}
