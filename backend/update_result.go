package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"
)

type UpdateInstallResult struct {
	State     string    `json:"state"`
	Time      time.Time `json:"time"`
	Installer string    `json:"installer"`
	Log       string    `json:"log"`
	Error     string    `json:"error,omitempty"`
}

func readUpdateInstallResult(dir string) *UpdateInstallResult {
	f, err := os.Open(filepath.Join(dir, "last-install.json"))
	if err != nil {
		return nil
	}
	defer f.Close()
	var result UpdateInstallResult
	if json.NewDecoder(io.LimitReader(f, 16384)).Decode(&result) != nil {
		return nil
	}
	return &result
}

func writeUpdateInstallResult(installer string, result UpdateInstallResult) error {
	data, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		return err
	}
	path := filepath.Join(filepath.Dir(installer), "last-install.json")
	if err = os.WriteFile(path+".tmp", data, 0600); err != nil {
		return err
	}
	return os.Rename(path+".tmp", path)
}

// Keep a recovery copy of the two app-owned data files. Setup updates program
// files only; this backup is for manual recovery, not a binary transaction/rollback.
func (u *Updater) backupUpdateData() (string, error) {
	u.app.mu.Lock()
	defer u.app.mu.Unlock()
	u.app.settingsMu.Lock()
	defer u.app.settingsMu.Unlock()
	if err := os.MkdirAll(u.dir, 0700); err != nil {
		return "", err
	}
	dir, err := os.MkdirTemp(u.dir, "profile-backup-")
	if err != nil {
		return "", err
	}
	for _, path := range []string{u.app.path, u.app.path + ".settings.json"} {
		in, err := os.Open(path)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return "", err
		}
		out, err := os.OpenFile(filepath.Join(dir, filepath.Base(path)), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
		if err != nil {
			in.Close()
			return "", err
		}
		n, copyErr := io.Copy(out, io.LimitReader(in, (64<<20)+1))
		in.Close()
		if copyErr == nil {
			copyErr = out.Sync()
		}
		closeErr := out.Close()
		if copyErr != nil {
			return "", copyErr
		}
		if closeErr != nil {
			return "", closeErr
		}
		if n > 64<<20 {
			return "", fmt.Errorf("Файл данных слишком велик для резервной копии обновления")
		}
	}
	return dir, nil
}
