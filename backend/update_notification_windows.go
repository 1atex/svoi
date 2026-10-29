//go:build windows

package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// A native shell notification does not require a packaged app identity. It also
// works for existing installations whose shortcuts predate an AppUserModelID.
// Windows controls whether to display it (for example, Focus Assist may suppress it).
const updateNotificationScript = `
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$icon = New-Object System.Windows.Forms.NotifyIcon
try {
  $icon.Icon = [Drawing.Icon]::ExtractAssociatedIcon($env:SVOI_NOTIFICATION_EXE)
  if (!$icon.Icon) { $icon.Icon = [Drawing.SystemIcons]::Information }
  $icon.Text = 'SVOI'
  $icon.BalloonTipTitle = 'Доступно обновление SVOI ' + $env:SVOI_NOTIFICATION_VERSION
  $icon.BalloonTipText = 'Откройте SVOI → Настройки → Обновления. Можно установить, отложить или пропустить эту версию.'
  $icon.BalloonTipIcon = [Windows.Forms.ToolTipIcon]::Info
  $icon.add_BalloonTipClicked({
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $env:SVOI_NOTIFICATION_EXE
    $start.UseShellExecute = $true
    [Diagnostics.Process]::Start($start) | Out-Null
    [Windows.Forms.Application]::ExitThread()
  })
  $timer = New-Object Windows.Forms.Timer
  $timer.Interval = 15000
  $timer.add_Tick({ [Windows.Forms.Application]::ExitThread() })
  $timer.Start()
  $icon.Visible = $true
  $icon.ShowBalloonTip(12000)
  [Windows.Forms.Application]::Run()
} finally {
  if ($timer) { $timer.Stop(); $timer.Dispose() }
  $icon.Visible = $false
  $icon.Dispose()
}
`

func windowsPowerShell(ctx context.Context, script string) *exec.Cmd {
	cmd := exec.CommandContext(ctx, filepath.Join(os.Getenv("SystemRoot"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe"), "-NoLogo", "-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-Command", script)
	hideCommand(cmd)
	return cmd
}

func showUpdateNotification(version, executable string) error {
	if _, err := versionParts(version); err != nil {
		return err
	}
	if !filepath.IsAbs(executable) {
		return fmt.Errorf("неверный путь к приложению")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	cmd := windowsPowerShell(ctx, updateNotificationScript)
	cmd.Env = append(os.Environ(), "SVOI_NOTIFICATION_VERSION="+version, "SVOI_NOTIFICATION_EXE="+executable)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("%w: %.600s", err, strings.TrimSpace(string(out)))
	}
	return nil
}
