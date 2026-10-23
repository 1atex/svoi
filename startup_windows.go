//go:build windows

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const startupPrincipalScript = `
    $principal = New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Highest
    $principal.UserId = $sid
`

const startupScript = `
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
try {
  $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $name = 'SVOI-' + $sid
  if ($env:SVOI_STARTUP_TEST_NAME) { $name = $env:SVOI_STARTUP_TEST_NAME }
  $task = Get-ScheduledTask -TaskPath '\' | Where-Object { $_.TaskName -eq $name } | Select-Object -First 1
  if ($env:SVOI_STARTUP_ACTION -eq 'enable') {
    $action = New-ScheduledTaskAction -Execute $env:SVOI_STARTUP_EXE -Argument '--startup' -WorkingDirectory ([IO.Path]::GetDirectoryName($env:SVOI_STARTUP_EXE))
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $sid
` + startupPrincipalScript + `
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    $task = Register-ScheduledTask -TaskName $name -TaskPath '\' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'SVOI: запуск при входе в Windows' -Force
  } elseif ($env:SVOI_STARTUP_ACTION -eq 'disable') {
    if ($task) { Unregister-ScheduledTask -TaskName $name -TaskPath '\' -Confirm:$false }
    $task = $null
  }
  $enabled = $null -ne $task -and $task.Settings.Enabled -and @($task.Actions | Where-Object { $_.Execute -eq $env:SVOI_STARTUP_EXE -and $_.Arguments -eq '--startup' }).Count -eq 1
  @{ enabled = [bool]$enabled } | ConvertTo-Json -Compress
} catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
`

func startupTask(executable, action string) (bool, error) {
	return startupTaskNamed(executable, action, "")
}

func startupTaskNamed(executable, action, testName string) (bool, error) {
	if testName != "" && !strings.HasPrefix(testName, "SVOI-Test-") {
		return false, fmt.Errorf("invalid test task name")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, filepath.Join(os.Getenv("SystemRoot"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe"), "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", startupScript)
	cmd.Env = append(os.Environ(), "SVOI_STARTUP_ACTION="+action, "SVOI_STARTUP_EXE="+executable, "SVOI_STARTUP_TEST_NAME="+testName)
	hideCommand(cmd)
	output, err := cmd.CombinedOutput()
	if err != nil {
		if ctx.Err() != nil {
			return false, fmt.Errorf("Планировщик Windows не ответил за 15 секунд")
		}
		detail := strings.TrimSpace(string(output))
		if detail == "" {
			detail = err.Error()
		}
		return false, fmt.Errorf("Планировщик Windows: %s", detail)
	}
	var result struct {
		Enabled bool `json:"enabled"`
	}
	if err := json.Unmarshal(output, &result); err != nil {
		return false, fmt.Errorf("Не удалось прочитать состояние автозапуска")
	}
	return result.Enabled, nil
}

func startupEnabled(executable string) (bool, error) { return startupTask(executable, "query") }

func setStartup(executable string, enabled bool) error {
	if !isElevated() {
		return fail(409, "Для изменения автозапуска откройте SVOI от имени администратора")
	}
	action := "disable"
	if enabled {
		if !filepath.IsAbs(executable) || !strings.EqualFold(filepath.Base(executable), "svoi.exe") {
			return fmt.Errorf("Неверный путь к приложению SVOI")
		}
		if info, err := os.Stat(executable); err != nil || info.IsDir() {
			return fmt.Errorf("Приложение SVOI не найдено")
		}
		action = "enable"
	}
	state, err := startupTask(executable, action)
	if err == nil && state != enabled {
		return fmt.Errorf("Windows не применила настройку автозапуска")
	}
	return err
}
