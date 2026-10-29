package main

import (
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

func main() {
	keyPath := flag.String("key", "", "PEM Ed25519 private key outside source control")
	installer := flag.String("installer", "", "Canonical Windows installer")
	trustPath := flag.String("trust", "backend/update_public_key.go", "Application trust root source")
	flag.Parse()
	if err := sign(*keyPath, *installer, *trustPath); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
func sign(keyPath, installer, trustPath string) error {
	name := filepath.Base(installer)
	match := regexp.MustCompile(`^SVOI-(\d+\.\d+\.\d+(?:-[a-z]+\.\d+)?)-windows-x64-setup\.exe$`).FindStringSubmatch(name)
	if match == nil {
		return fmt.Errorf("expected canonical versioned Windows installer")
	}
	encoded, err := os.ReadFile(keyPath)
	if err != nil {
		return err
	}
	block, _ := pem.Decode(encoded)
	if block == nil {
		return fmt.Errorf("invalid PEM private key")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return err
	}
	key, ok := parsed.(ed25519.PrivateKey)
	if !ok {
		return fmt.Errorf("expected Ed25519 key")
	}
	source, err := os.ReadFile(trustPath)
	if err != nil {
		return err
	}
	trusted := regexp.MustCompile(`const updateManifestPublicKey = "([^"]+)"`).FindSubmatch(source)
	pub := base64.StdEncoding.EncodeToString(key.Public().(ed25519.PublicKey))
	if len(trusted) != 2 || string(trusted[1]) != pub {
		return fmt.Errorf("signing key does not match application trust root")
	}
	content, err := os.ReadFile(installer)
	if err != nil {
		return err
	}
	hash := sha256.Sum256(content)
	channel := "stable"
	if strings.Contains(match[1], "-") {
		channel = "prerelease"
	}
	payload, err := json.Marshal(map[string]any{"version": match[1], "channel": channel, "platform": "windows-x64", "asset": name, "size": len(content), "sha256": hex.EncodeToString(hash[:])})
	if err != nil {
		return err
	}
	signature := ed25519.Sign(key, payload)
	envelope, err := json.MarshalIndent(map[string]string{"payload": base64.StdEncoding.EncodeToString(payload), "signature": base64.StdEncoding.EncodeToString(signature)}, "", "  ")
	if err != nil {
		return err
	}
	output := filepath.Join(filepath.Dir(installer), "SVOI-"+match[1]+"-windows-x64-update.json")
	if err = os.WriteFile(output, append(envelope, '\n'), 0644); err != nil {
		return err
	}
	fmt.Println("Signed update manifest:", output)
	return nil
}
