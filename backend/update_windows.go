//go:build windows

package main

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
	"time"
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
	dst, err := os.CreateTemp(filepath.Dir(installer), "svoi-update-helper-*.exe")
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
	helper := dst.Name()
	trusted, err := trustedUpdateExecutable()
	if err != nil {
		return err
	}
	cmd := exec.Command(helper, "-install-update", installer, "-update-sha256", checksum, "-update-parent", strconv.Itoa(os.Getpid()), "-desktop-exe", trusted)
	hideCommand(cmd)
	if err := cmd.Start(); err != nil {
		return err
	}
	return cmd.Process.Release()
}
func installUpdateAfterExit(installer, checksum string, parent int) (resultErr error) {
	if parent <= 0 || !filepath.IsAbs(installer) {
		return fmt.Errorf("invalid update request")
	}
	result := UpdateInstallResult{State: "installing", Time: time.Now().UTC(), Installer: filepath.Base(installer), Log: installer + ".install.log"}
	parentExited := false
	if err := writeUpdateInstallResult(installer, result); err != nil {
		return fmt.Errorf("Не удалось сохранить журнал обновления: %w", err)
	}
	defer func() {
		result.Time = time.Now().UTC()
		if resultErr != nil {
			result.State, result.Error = "error", resultErr.Error()
		} else if result.State == "installing" {
			result.State = "completed"
		}
		if err := writeUpdateInstallResult(installer, result); err != nil && resultErr == nil {
			resultErr = err
		}
		// The old app remains the recovery entry point on setup failure. We do
		// not delete program files or claim that setup is a binary rollback.
		if parentExited && desktopExecutable != "" && result.State != "restart-required" {
			cmd := exec.Command(desktopExecutable)
			cmd.Dir = filepath.Dir(desktopExecutable)
			if err := cmd.Start(); err == nil {
				_ = cmd.Process.Release()
			}
		}
	}()
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
	parentExited = true
	name, err := windows.UTF16PtrFromString(installer)
	if err != nil {
		return err
	}
	// Keep the verified file immutable until Setup has exited.
	fileHandle, err := windows.CreateFile(name, windows.GENERIC_READ, windows.FILE_SHARE_READ, nil, windows.OPEN_EXISTING, windows.FILE_ATTRIBUTE_NORMAL, 0)
	if err != nil {
		return err
	}
	f := os.NewFile(uintptr(fileHandle), installer)
	defer f.Close()
	h := sha256.New()
	_, err = io.Copy(h, f)
	if err != nil {
		return err
	}
	if hex.EncodeToString(h.Sum(nil)) != checksum {
		return fmt.Errorf("Файл обновления изменён")
	}
	if _, err := verifyUpdateAuthenticity(installer); err != nil {
		return err
	}
	trusted, err := trustedUpdateExecutable()
	if err != nil {
		return err
	}
	cmd := exec.Command(installer, silentUpdateArguments(filepath.Dir(trusted), result.Log)...)
	hideCommand(cmd)
	if err := cmd.Run(); err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) && exit.ExitCode() == 3010 {
			result.State = "restart-required"
			return nil
		}
		return fmt.Errorf("Установщик не завершил обновление: %w. Журнал: %s", err, result.Log)
	}
	return nil
}

func silentUpdateArguments(directory, log string) []string {
	return []string{"/SP-", "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/NOCLOSEAPPLICATIONS", "/RESTARTEXITCODE=3010", "/DIR=" + directory, "/LOG=" + log}
}
