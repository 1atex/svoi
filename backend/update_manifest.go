package main

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
)

const maxUpdateManifestSize = 16 << 10

// The envelope encodes the exact signed bytes, avoiding dependence on JSON
// whitespace, field ordering, or a particular serializer's canonicalization.
type signedUpdateEnvelope struct {
	Payload   string `json:"payload"`
	Signature string `json:"signature"`
}
type updateManifest struct {
	Version  string `json:"version"`
	Channel  string `json:"channel"`
	Platform string `json:"platform"`
	Asset    string `json:"asset"`
	Size     int64  `json:"size"`
	SHA256   string `json:"sha256"`
}

func decodeSignedUpdateManifest(data []byte, publicKey string) (updateManifest, error) {
	var manifest updateManifest
	if len(data) > maxUpdateManifestSize {
		return manifest, fmt.Errorf("Манифест обновления слишком велик")
	}
	var envelope signedUpdateEnvelope
	if err := json.Unmarshal(data, &envelope); err != nil {
		return manifest, fmt.Errorf("Некорректный манифест обновления")
	}
	key, err := base64.StdEncoding.DecodeString(publicKey)
	if err != nil || len(key) != ed25519.PublicKeySize {
		return manifest, fmt.Errorf("Ключ проверки обновлений не настроен")
	}
	payload, err := base64.StdEncoding.DecodeString(envelope.Payload)
	if err != nil || len(payload) > maxUpdateManifestSize {
		return manifest, fmt.Errorf("Некорректное содержимое манифеста")
	}
	signature, err := base64.StdEncoding.DecodeString(envelope.Signature)
	if err != nil || len(signature) != ed25519.SignatureSize || !ed25519.Verify(ed25519.PublicKey(key), payload, signature) {
		return manifest, fmt.Errorf("Подпись манифеста обновления не подтверждена")
	}
	if err := json.Unmarshal(payload, &manifest); err != nil {
		return manifest, fmt.Errorf("Некорректное описание обновления")
	}
	if _, err := versionParts(manifest.Version); err != nil || strings.HasPrefix(manifest.Version, "v") {
		return manifest, fmt.Errorf("Некорректная версия манифеста")
	}
	channel := "stable"
	if strings.Contains(manifest.Version, "-") {
		channel = "prerelease"
	}
	if manifest.Channel != channel || manifest.Platform != "windows-x64" || manifest.Asset != releaseAssetPrefix+"-"+manifest.Version+"-windows-x64-setup.exe" || manifest.Size <= 0 || manifest.Size > 512<<20 {
		return manifest, fmt.Errorf("Манифест не соответствует каналу, платформе или файлу обновления")
	}
	hash, err := hex.DecodeString(manifest.SHA256)
	if err != nil || len(hash) != sha256.Size || strings.ToLower(manifest.SHA256) != manifest.SHA256 {
		return manifest, fmt.Errorf("Некорректная SHA-256 манифеста")
	}
	return manifest, nil
}

func verifySignedUpdateFile(installer string) error {
	return verifySignedUpdateFileWithKey(installer, updateManifestPublicKey)
}
func verifySignedUpdateFileWithKey(installer, publicKey string) error {
	f, err := os.Open(installer + ".update.json")
	if err != nil {
		return fmt.Errorf("Подписанный манифест обновления отсутствует: %w", err)
	}
	data, err := io.ReadAll(io.LimitReader(f, maxUpdateManifestSize+1))
	f.Close()
	if err != nil {
		return err
	}
	manifest, err := decodeSignedUpdateManifest(data, publicKey)
	if err != nil {
		return err
	}
	if filepath.Base(installer) != manifest.Asset {
		return fmt.Errorf("Подписанный манифест предназначен для другого файла")
	}
	file, err := os.Open(installer)
	if err != nil {
		return err
	}
	defer file.Close()
	hash := sha256.New()
	size, err := io.Copy(hash, io.LimitReader(file, manifest.Size+1))
	if err != nil {
		return err
	}
	if size != manifest.Size || hex.EncodeToString(hash.Sum(nil)) != manifest.SHA256 {
		return fmt.Errorf("Обновление не соответствует подписанному манифесту")
	}
	return nil
}

func verifyUpdateAuthenticity(installer string) (string, error) {
	manifestErr := verifySignedUpdateFile(installer)
	if manifestErr == nil {
		return "ed25519", nil
	}
	if err := verifyUpdateInstaller(installer); err == nil {
		return "authenticode", nil
	} else {
		return "blocked", fmt.Errorf("Автоматическая установка заблокирована: %v. Проверка подписи Windows: %v. Откройте официальную страницу релиза для ручной проверки", manifestErr, err)
	}
}

func validUpdateManifestAsset(asset releaseAsset, version, tag string) bool {
	parsed, err := url.Parse(asset.URL)
	return err == nil && parsed.Scheme == "https" && parsed.Host == "github.com" && parsed.User == nil && parsed.RawQuery == "" && parsed.Fragment == "" && parsed.Path == "/"+releaseRepository+"/releases/download/"+tag+"/"+asset.Name && asset.Name == releaseAssetPrefix+"-"+version+"-windows-x64-update.json" && asset.Size > 0 && asset.Size <= maxUpdateManifestSize
}

func (u *Updater) stageUpdateManifest(asset, manifestAsset releaseAsset) error {
	if manifestAsset.Name == "" {
		return nil
	}
	req, err := http.NewRequest("GET", manifestAsset.URL, nil)
	if err != nil {
		return err
	}
	resp, err := u.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("Не удалось загрузить подписанный манифест: HTTP %d", resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxUpdateManifestSize+1))
	if err != nil {
		return err
	}
	manifest, err := decodeSignedUpdateManifest(data, updateManifestPublicKey)
	if err != nil {
		return err
	}
	if manifest.Asset != asset.Name || manifest.Size != asset.Size || "sha256:"+manifest.SHA256 != asset.Digest {
		return fmt.Errorf("Данные релиза не соответствуют подписанному манифесту")
	}
	path := filepath.Join(u.dir, asset.Name) + ".update.json"
	if err := os.WriteFile(path+".tmp", data, 0600); err != nil {
		return err
	}
	return os.Rename(path+".tmp", path)
}
