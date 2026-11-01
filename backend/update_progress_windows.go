//go:build windows

package main

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
)

const updateProgressScript = `
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$form=New-Object Windows.Forms.Form
$form.Text='Обновление SVOI'
$form.ClientSize=New-Object Drawing.Size(460,210)
$form.StartPosition='CenterScreen'
$form.FormBorderStyle='FixedDialog'
$form.MaximizeBox=$false; $form.MinimizeBox=$false; $form.ControlBox=$false
$form.BackColor=[Drawing.Color]::FromArgb(16,16,19)
$form.ForeColor=[Drawing.Color]::FromArgb(244,242,237)
try { $form.Icon=[Drawing.Icon]::ExtractAssociatedIcon($env:SVOI_PROGRESS_EXE) } catch {}
$title=New-Object Windows.Forms.Label
$title.Text='SVOI'; $title.Location=New-Object Drawing.Point(24,20)
$title.Size=New-Object Drawing.Size(410,38); $title.Font=New-Object Drawing.Font('Segoe UI',22,[Drawing.FontStyle]::Bold)
$form.Controls.Add($title)
$status=New-Object Windows.Forms.Label
$status.Location=New-Object Drawing.Point(24,72); $status.Size=New-Object Drawing.Size(410,58)
$status.Font=New-Object Drawing.Font('Segoe UI',11)
$status.Text='Подготавливаем обновление. Приложение откроется автоматически.'
$form.Controls.Add($status)
$bar=New-Object Windows.Forms.ProgressBar
$bar.Location=New-Object Drawing.Point(24,140); $bar.Size=New-Object Drawing.Size(410,8)
$bar.Style='Marquee'; $bar.MarqueeAnimationSpeed=30; $form.Controls.Add($bar)
$close=New-Object Windows.Forms.Button
$close.Text='Закрыть'; $close.Location=New-Object Drawing.Point(332,166); $close.Size=New-Object Drawing.Size(102,30)
$close.Visible=$false; $close.add_Click({$form.Close()}); $form.Controls.Add($close)
$timer=New-Object Windows.Forms.Timer; $timer.Interval=500
$script:completedAt=$null
$timer.add_Tick({
  try {
    $state=[IO.File]::ReadAllText($env:SVOI_PROGRESS_FILE,[Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($state.state -eq 'completed') {
      $status.Text='Готово. Запускаем обновлённый SVOI…'
      $bar.Style='Continuous'; $bar.Value=100
      if (!$script:completedAt) {$script:completedAt=[DateTime]::UtcNow}
      if (([DateTime]::UtcNow-$script:completedAt).TotalSeconds -ge 2) {$form.Close()}
    } elseif ($state.state -eq 'error' -or $state.state -eq 'restart-required') {
      $bar.Visible=$false; $close.Visible=$true; $form.ControlBox=$true
      if ($state.state -eq 'error') {$status.Text='Не удалось завершить обновление. SVOI откроется с подробностями; журнал сохранён.'}
      else {$status.Text='Обновление установлено. Перезагрузите Windows, затем откройте SVOI.'}
    } else {
      $status.Text=switch ($state.stage) {
        'waiting' {'Завершаем работу SVOI. Подписки и настройки сохраняются.'}
        'verifying' {'Проверяем подпись и целостность обновления…'}
        'installing' {'Устанавливаем обновление. Не выключайте компьютер.'}
        default {'Подготавливаем обновление…'}
      }
      if (!(Get-Process -Id ([int]$env:SVOI_PROGRESS_PID) -ErrorAction SilentlyContinue)) {
        $status.Text='Процесс обновления завершился без подтверждения. Откройте SVOI и проверьте журнал.'
        $bar.Visible=$false; $close.Visible=$true; $form.ControlBox=$true
      }
    }
  } catch {}
})
try {$timer.Start(); [void]$form.ShowDialog()} finally {$timer.Stop();$timer.Dispose();$form.Dispose()}
`

var launchUpdateProgress = showUpdateProgress

func showUpdateProgress(installer string) {
	cmd := windowsPowerShell(context.Background(), updateProgressScript)
	cmd.Env = append(os.Environ(), "SVOI_PROGRESS_FILE="+filepath.Join(filepath.Dir(installer), "last-install.json"), "SVOI_PROGRESS_PID="+strconv.Itoa(os.Getpid()), "SVOI_PROGRESS_EXE="+desktopExecutable)
	if cmd.Start() == nil {
		_ = cmd.Process.Release()
	}
}
