package main

import (
	"context"
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
)

//go:embed warp_components.json
var warpComponentsJSON []byte

type warpComponent struct {
	Name   string `json:"name"`
	SHA256 string `json:"sha256"`
}

func warpComponentPath() (string, warpComponent) {
	var config struct {
		Assets map[string]warpComponent `json:"assets"`
	}
	_ = json.Unmarshal(warpComponentsJSON, &config)
	target := map[string]string{"windows": "windows-x64", "linux": "linux-x64", "darwin": "macos-arm64"}[runtime.GOOS]
	entry := config.Assets[target]
	exe, _ := os.Executable()
	return filepath.Join(filepath.Dir(exe), "components", entry.Name), entry
}

func verifyWarpComponent(path string, component warpComponent) error {
	if component.Name == "" || len(component.SHA256) != 64 {
		return fmt.Errorf("Компонент WARP для этой системы не подготовлен")
	}
	f, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("Компонент WARP отсутствует. Установите полную сборку SVOI")
	}
	defer f.Close()
	h := sha256.New()
	if _, err = io.Copy(h, io.LimitReader(f, 256*1024*1024+1)); err != nil {
		return err
	}
	if hex.EncodeToString(h.Sum(nil)) != component.SHA256 {
		return fmt.Errorf("Компонент WARP повреждён. Переустановите SVOI из официального релиза")
	}
	return nil
}

func installBundledWarp(ctx context.Context) error {
	path, entry := warpComponentPath()
	if err := verifyWarpComponent(path, entry); err != nil {
		return err
	}
	return launchWarpComponent(ctx, path)
}
