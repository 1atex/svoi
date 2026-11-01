package main

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"
)

func TestWarpComponentRejectsTampering(t *testing.T) {
	path := filepath.Join(t.TempDir(), "component")
	content := []byte("test component")
	sum := sha256.Sum256(content)
	c := warpComponent{Name: "component", SHA256: hex.EncodeToString(sum[:])}
	if err := os.WriteFile(path, content, 0600); err != nil {
		t.Fatal(err)
	}
	if err := verifyWarpComponent(path, c); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("modified"), 0600); err != nil {
		t.Fatal(err)
	}
	if verifyWarpComponent(path, c) == nil {
		t.Fatal("modified package accepted")
	}
}
