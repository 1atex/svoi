//go:build windows

package backend

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestWindowsStartupPrincipalKeepsUnambiguousSID(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	script := `
$ErrorActionPreference = 'Stop'
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
` + startupPrincipalScript + `
if ($principal.UserId -ne $sid) { throw 'Principal was shortened to an ambiguous account name' }
$service = New-Object -ComObject 'Schedule.Service'
$service.Connect()
$definition = $service.NewTask(0)
$definition.Principal.UserId = $principal.UserId
$definition.Principal.LogonType = [int]$principal.LogonType
$definition.Principal.RunLevel = [int]$principal.RunLevel
$trigger = $definition.Triggers.Create(9)
$trigger.UserId = $sid
$action = $definition.Actions.Create(0)
$action.Path = Join-Path $env:SystemRoot 'System32/notepad.exe'
$null = $service.GetFolder('\').RegisterTaskDefinition('SVOI-Test-ValidateOnly', $definition, 1, $null, $null, 3)
Write-Output 'SID validation passed'
`
	cmd := exec.CommandContext(ctx, filepath.Join(os.Getenv("SystemRoot"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe"), "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script)
	hideCommand(cmd)
	output, err := cmd.CombinedOutput()
	if err != nil || !strings.Contains(string(output), "SID validation passed") {
		t.Fatalf("principal validation: %v; %s", err, output)
	}
}

func TestWindowsStartupTaskLifecycle(t *testing.T) {
	if !isElevated() {
		if os.Getenv("GITHUB_ACTIONS") == "true" {
			t.Fatal("Windows release CI must verify task registration with administrator rights")
		}
		t.Skip("Task registration requires administrator; covered on Windows CI")
	}
	name := "SVOI-Test-" + secret()
	exe := filepath.Join(t.TempDir(), "SVOI с пробелами", "svoi.exe")
	if err := os.MkdirAll(filepath.Dir(exe), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(exe, []byte("test fixture, never execute"), 0600); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if _, err := startupTaskNamed(exe, "disable", name); err != nil {
			t.Error(err)
		}
	})
	if enabled, err := startupTaskNamed(exe, "query", name); err != nil || enabled {
		t.Fatal(enabled, err)
	}
	if enabled, err := startupTaskNamed(exe, "enable", name); err != nil || !enabled {
		t.Fatal(enabled, err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, filepath.Join(os.Getenv("SystemRoot"), "System32", "schtasks.exe"), "/Query", "/TN", name, "/XML")
	hideCommand(cmd)
	xml, err := cmd.Output()
	if err != nil {
		t.Fatal(err)
	}
	text := strings.ReplaceAll(string(xml), "\x00", "")
	for _, want := range []string{"InteractiveToken", "HighestAvailable", "LogonTrigger", "--startup", "PT0S", "IgnoreNew"} {
		if !strings.Contains(text, want) {
			t.Fatalf("task missing %s", want)
		}
	}
	verify := exec.CommandContext(ctx, filepath.Join(os.Getenv("SystemRoot"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe"), "-NoProfile", "-NonInteractive", "-Command", `
$ErrorActionPreference = 'Stop'
$task = Get-ScheduledTask -TaskPath '\' -TaskName $env:SVOI_STARTUP_TEST_NAME
$expected = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$users = @($task.Principal.UserId) + @($task.Triggers | ForEach-Object { $_.UserId })
if ($users.Count -ne 2) { throw 'Expected principal and logon trigger' }
foreach ($user in $users) {
  if ($user -eq $expected) { continue }
  $resolved = ([Security.Principal.NTAccount]::new($user)).Translate([Security.Principal.SecurityIdentifier]).Value
  if ($resolved -ne $expected) { throw 'Task belongs to a different account' }
}
Write-Output 'Identity verified'
`)
	verify.Env = append(os.Environ(), "SVOI_STARTUP_TEST_NAME="+name)
	hideCommand(verify)
	if output, err := verify.CombinedOutput(); err != nil || !strings.Contains(string(output), "Identity verified") {
		t.Fatalf("task account verification: %v; %s", err, output)
	}
	if enabled, err := startupTaskNamed(exe, "disable", name); err != nil || enabled {
		t.Fatal(enabled, err)
	}
	if enabled, err := startupTaskNamed(exe, "query", name); err != nil || enabled {
		t.Fatal(enabled, err)
	}
}
