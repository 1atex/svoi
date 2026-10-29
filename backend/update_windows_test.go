//go:build windows

package main

import (
	"context"
	"fmt"
	"golang.org/x/sys/windows"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestUpdateWaitsForDesktopWindowMutex(t *testing.T) {
	name := fmt.Sprintf(`Local\SVOI.UpdateTest.%d.%d`, os.Getpid(), time.Now().UnixNano())
	wide, _ := windows.UTF16PtrFromString(name)
	handle, err := windows.CreateMutex(nil, false, wide)
	if err != nil {
		t.Fatal(err)
	}
	if err := waitUpdateDesktopClosed(name, 10*time.Millisecond); err == nil {
		windows.CloseHandle(handle)
		t.Fatal("installer proceeded while the desktop still held its instance mutex")
	}
	windows.CloseHandle(handle)
	if err := waitUpdateDesktopClosed(name, time.Second); err != nil {
		t.Fatal(err)
	}
}

func TestInstallerStillVerifiesChecksumWhenParentAlreadyExited(t *testing.T) {
	cmd := exec.Command("cmd.exe", "/c", "exit", "0")
	hideCommand(cmd)
	if err := cmd.Run(); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "not-an-installer.exe")
	if err := os.WriteFile(path, []byte("not executable"), 0600); err != nil {
		t.Fatal(err)
	}
	err := installUpdateAfterExit(path, strings.Repeat("0", 64), cmd.Process.Pid)
	if err == nil || !strings.Contains(err.Error(), "Файл обновления изменён") {
		t.Fatalf("expected checksum rejection after parent exit, got %v", err)
	}
}

func TestWindowsRejectsUnsignedUpdatePublisher(t *testing.T) {
	old := desktopExecutable
	t.Cleanup(func() { desktopExecutable = old })
	// Windows PowerShell itself supplies a real trusted Authenticode signature.
	desktopExecutable = filepath.Join(os.Getenv("SystemRoot"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
	unsigned := filepath.Join(t.TempDir(), "unsigned.exe")
	if err := os.WriteFile(unsigned, []byte("not a signed executable"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := verifyUpdateInstaller(unsigned); err == nil {
		t.Fatal("unsigned candidate authenticated")
	}
	// Also exercise the successful Windows trust/certificate comparison without
	// executing either signed binary as an installer.
	if err := verifyUpdateInstaller(desktopExecutable); err != nil {
		t.Fatal("trusted identical publisher rejected", err)
	}
	desktopExecutable = unsigned
	if err := verifyUpdateInstaller(unsigned); err == nil {
		t.Fatal("unsigned installed app established publisher trust")
	}
}

func TestWindowsNotificationScriptParsesAndHelperIsHidden(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	script := `$tokens=$null; $errors=$null; $null=[Management.Automation.Language.Parser]::ParseInput($env:SVOI_PARSE_SCRIPT,[ref]$tokens,[ref]$errors); if ($errors.Count) { throw ($errors | Out-String) }; Add-Type -AssemblyName System.Windows.Forms; 'parsed'`
	cmd := windowsPowerShell(ctx, script)
	cmd.Env = append(os.Environ(), "SVOI_PARSE_SCRIPT="+updateNotificationScript)
	if cmd.SysProcAttr == nil || !cmd.SysProcAttr.HideWindow || cmd.SysProcAttr.CreationFlags&0x08000000 == 0 {
		t.Fatal("visible notification helper window")
	}
	if output, err := cmd.CombinedOutput(); err != nil || !strings.Contains(string(output), "parsed") {
		t.Fatalf("notification script: %v: %s", err, output)
	}
}

func TestWindowsSilentUpdateArgumentsPreserveInstallPath(t *testing.T) {
	dir := `C:\Users\Имя Пользователя\SVOI`
	log := `C:\Users\Имя Пользователя\updates\setup.log`
	args := strings.Join(silentUpdateArguments(dir, log), "|")
	for _, required := range []string{"/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/DIR=" + dir, "/LOG=" + log, "/RESTARTEXITCODE=3010"} {
		if !strings.Contains(args, required) {
			t.Fatal("missing setup safety argument", required)
		}
	}
}

func TestWindowsActualUpdateNotification(t *testing.T) {
	exe := os.Getenv("SVOI_TEST_UPDATE_NOTIFICATION_EXE")
	if exe == "" {
		t.Skip("opt in with an existing SVOI executable to display one real Windows notification")
	}
	if !strings.EqualFold(filepath.Base(exe), "svoi.exe") {
		t.Fatal("use an existing SVOI desktop executable")
	}
	if _, err := os.Stat(exe); err != nil {
		t.Fatal(err)
	}
	if err := showUpdateNotification("0.7.0-rc.1", exe); err != nil {
		t.Fatal(err)
	}
}
