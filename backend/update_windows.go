//go:build windows

package backend

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"golang.org/x/sys/windows"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
)

func launchUpdateInstaller(installer, checksum string) error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}

	src, err := os.Open(exe)
	if err != nil {
		return err
	}
	defer src.Close()
	helper := filepath.Join(filepath.Dir(installer), "svoi-update-helper.exe")
	dst, err := os.Create(helper)
	if err != nil {
		return err
	}
	_, err = io.Copy(dst, src)
	closeErr := dst.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	cmd := exec.Command(helper, "-install-update", installer, "-update-sha256", checksum, "-update-parent", strconv.Itoa(os.Getpid()))
	hideCommand(cmd)
	if err := cmd.Start(); err != nil {
		return err
	}
	return cmd.Process.Release()
}
func installUpdateAfterExit(installer, checksum string, parent int) error {
	if parent <= 0 || !filepath.IsAbs(installer) {
		return fmt.Errorf("invalid update request")
	}
	handle, err := windows.OpenProcess(windows.SYNCHRONIZE, false, uint32(parent))
	if err != nil && !errors.Is(err, windows.ERROR_INVALID_PARAMETER) {
		return err
	}

	if err == nil {
		defer windows.CloseHandle(handle)
		result, waitErr := windows.WaitForSingleObject(handle, 120000)
		if waitErr != nil || result != windows.WAIT_OBJECT_0 {
			return fmt.Errorf("SVOI не завершился, установка отменена")
		}
	}
	f, err := os.Open(installer)
	if err != nil {
		return err
	}
	h := sha256.New()
	_, err = io.Copy(h, f)
	f.Close()
	if err != nil {
		return err
	}
	if hex.EncodeToString(h.Sum(nil)) != checksum {
		return fmt.Errorf("Файл обновления изменён")
	}
	cmd := exec.Command(installer, "/SP-", "/NORESTART")
	return cmd.Run()
}
