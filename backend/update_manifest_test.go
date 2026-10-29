package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func manifestFixture(t *testing.T) (updateManifest, ed25519.PublicKey, ed25519.PrivateKey) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256([]byte("unsigned genuine installer"))
	return updateManifest{Version: "9.1.0-rc.1", Channel: "prerelease", Platform: "windows-x64", Asset: releaseAssetPrefix + "-9.1.0-rc.1-windows-x64-setup.exe", Size: int64(len("unsigned genuine installer")), SHA256: hex.EncodeToString(sum[:])}, pub, priv
}
func signedManifestFixture(t *testing.T, manifest updateManifest, priv ed25519.PrivateKey) []byte {
	t.Helper()
	payload, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	envelope, _ := json.Marshal(signedUpdateEnvelope{Payload: base64.StdEncoding.EncodeToString(payload), Signature: base64.StdEncoding.EncodeToString(ed25519.Sign(priv, payload))})
	return envelope
}

func TestUpdateManifestExactPayloadSignatureAndBinding(t *testing.T) {
	m, pub, priv := manifestFixture(t)
	key := base64.StdEncoding.EncodeToString(pub)
	data := signedManifestFixture(t, m, priv)
	if got, err := decodeSignedUpdateManifest(data, key); err != nil || got != m {
		t.Fatal(got, err)
	}
	var changed signedUpdateEnvelope
	json.Unmarshal(data, &changed)
	payload, _ := base64.StdEncoding.DecodeString(changed.Payload)
	changed.Payload = base64.StdEncoding.EncodeToString(append(payload, ' '))
	tampered, _ := json.Marshal(changed)
	if _, err := decodeSignedUpdateManifest(tampered, key); err == nil {
		t.Fatal("changed exact payload accepted")
	}
	other, _, _ := ed25519.GenerateKey(rand.Reader)
	if _, err := decodeSignedUpdateManifest(data, base64.StdEncoding.EncodeToString(other)); err == nil {
		t.Fatal("different publisher key accepted")
	}
	for _, mutate := range []func(*updateManifest){
		func(m *updateManifest) { m.Platform = "linux-x64" },
		func(m *updateManifest) { m.Channel = "stable" },
		func(m *updateManifest) { m.Asset = "../setup.exe" },
		func(m *updateManifest) { m.Version = "9.1.0-rc.2" },
		func(m *updateManifest) { m.Size = 0 },
		func(m *updateManifest) { m.SHA256 = "invalid" },
	} {
		bad := m
		mutate(&bad)
		if _, err := decodeSignedUpdateManifest(signedManifestFixture(t, bad, priv), key); err == nil {
			t.Fatal("invalid signed binding accepted", bad)
		}
	}
	if _, err := decodeSignedUpdateManifest([]byte(strings.Repeat("x", maxUpdateManifestSize+1)), key); err == nil {
		t.Fatal("unbounded manifest accepted")
	}
}

func TestUpdateSignedManifestAuthenticatesUnsignedPayload(t *testing.T) {
	m, pub, priv := manifestFixture(t)
	key := base64.StdEncoding.EncodeToString(pub)
	path := filepath.Join(t.TempDir(), m.Asset)
	if err := os.WriteFile(path, []byte("unsigned genuine installer"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path+".update.json", signedManifestFixture(t, m, priv), 0600); err != nil {
		t.Fatal(err)
	}
	if err := verifySignedUpdateFileWithKey(path, key); err != nil {
		t.Fatal("signed manifest rejected unsigned installer", err)
	}
	if err := os.WriteFile(path, []byte("unsigned altered installer"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := verifySignedUpdateFileWithKey(path, key); err == nil {
		t.Fatal("tampered signed payload accepted")
	}
}

func TestReleaseSignedUpdateManifest(t *testing.T) {
	installer := os.Getenv("SVOI_TEST_SIGNED_UPDATE_INSTALLER")
	if installer == "" {
		t.Skip("opt in after signing a built release installer")
	}
	if err := verifySignedUpdateFile(installer); err != nil {
		t.Fatal(err)
	}
}
