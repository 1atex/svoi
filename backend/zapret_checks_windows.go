//go:build windows

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

func pingHost(ctx context.Context, ip string) (string, error) {
	cmd := exec.CommandContext(ctx, filepath.Join(os.Getenv("SystemRoot"), "System32", "ping.exe"), "-n", "1", "-w", "1000", ip)
	hideCommand(cmd)
	e := cmd.Run()
	if e != nil {
		return "ICMP-ответ не получен (узел может не отвечать на ping)", e
	}
	return "Получен ICMP-ответ", nil
}
func systemZapretDiagnostics(ctx context.Context, folder string) ([]CheckResult, error) {
	ctx, cancel := context.WithTimeout(ctx, 25*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", zapretDiagnosticScript)
	hideCommand(cmd)
	cmd.Env = append(os.Environ(), "SVOI_DIAG_DIR="+folder)
	output, e := cmd.Output()
	if e != nil {
		return nil, fmt.Errorf("Не удалось получить диагностику Windows: %w", e)
	}
	var rows []CheckResult
	if e = json.Unmarshal(output, &rows); e != nil {
		return nil, fmt.Errorf("Некорректный ответ диагностики: %w", e)
	}
	return rows, nil
}

const zapretDiagnosticScript = `
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$rows=[Collections.Generic.List[object]]::new()
function Add-Result($name,$state,$detail){$rows.Add(@{target='Windows';check=$name;state=$state;detail=[string]$detail})}
try {$services=@(Get-CimInstance Win32_Service);$drivers=@(Get-CimInstance Win32_SystemDriver)} catch {throw 'Service inventory unavailable'}
$processes=@(Get-Process -ErrorAction SilentlyContinue)
$bfe=$services | Where-Object Name -eq 'BFE'
if($bfe.State -eq 'Running'){Add-Result 'Base Filtering Engine' 'ok' 'Служба работает'}else{Add-Result 'Base Filtering Engine' 'error' 'Служба BFE не работает'}
foreach($name in @('zapret','WinDivert','WinDivert14')){
 $svc=@($services+$drivers | Where-Object Name -eq $name)
 if($svc.Count){Add-Result ('Служба '+$name) 'info' (($svc | ForEach-Object State)-join ', ')}else{Add-Result ('Служба '+$name) 'info' 'Не установлена'}
}
$winws=@($processes | Where-Object ProcessName -eq 'winws')
Add-Result 'winws' 'info' ('Запущено процессов: '+$winws.Count)
try {$proxy=Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings';if($proxy.ProxyEnable -eq 1){Add-Result 'Системный прокси' 'warning' 'Включён; может повлиять на приложения'}else{Add-Result 'Системный прокси' 'ok' 'Отключён'}}catch{Add-Result 'Системный прокси' 'unknown' 'Не удалось прочитать настройки'}
try {$tcp=@(Get-NetTCPSetting | Select-Object -ExpandProperty Timestamps -Unique);if($tcp -contains 'Enabled'){Add-Result 'TCP timestamps' 'ok' ($tcp -join ', ')}else{Add-Result 'TCP timestamps' 'warning' ('Состояние: '+($tcp -join ', '))}}catch{Add-Result 'TCP timestamps' 'unknown' 'Get-NetTCPSetting недоступен'}
if(@($processes|Where-Object ProcessName -eq 'AdguardSvc').Count){Add-Result 'AdGuard' 'warning' 'Обнаружен процесс AdguardSvc; возможен конфликт'}else{Add-Result 'AdGuard' 'ok' 'Процесс не найден'}
foreach($entry in @(
 @{Name='Killer';Pattern='Killer'},@{Name='Intel Connectivity Network';Pattern='Intel.*Connectivity.*Network'},@{Name='Check Point';Pattern='TracSrvWrapper|EPWD'},@{Name='SmartByte';Pattern='SmartByte'},@{Name='VPN-службы';Pattern='VPN|HappService'},@{Name='Другие обходы DPI';Pattern='GoodbyeDPI|discordfix_zapret|^winws[12]$'})){
 $found=@($services|Where-Object {($_.Name+' '+$_.DisplayName) -match $entry.Pattern})
 if($found.Count){Add-Result $entry.Name 'warning' (($found|ForEach-Object { $_.Name+': '+$_.State })-join '; ')}else{Add-Result $entry.Name 'ok' 'Совпадений не найдено'}
}
$folder=$env:SVOI_DIAG_DIR
if(-not $folder){Add-Result 'Файлы zapret' 'warning' 'zapret ещё не установлен'}else{
 if($folder -match '[\u0400-\u04ff]'){Add-Result 'Кириллица в пути' 'warning' 'Есть кириллица; при ошибках запуска используйте путь латиницей'}else{Add-Result 'Кириллица в пути' 'ok' 'Не обнаружена'}
 if($env:OneDrive -and $folder.StartsWith($env:OneDrive.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){Add-Result 'OneDrive' 'warning' 'zapret расположен в синхронизируемой папке'}else{Add-Result 'OneDrive' 'ok' 'Папка zapret вне OneDrive'}
 foreach($name in @('bin\winws.exe','bin\WinDivert.dll','bin\WinDivert64.sys')){if(Test-Path -LiteralPath (Join-Path $folder $name)){Add-Result $name 'ok' 'Файл существует'}else{Add-Result $name 'error' 'Файл отсутствует'}}
}
try {$doh=@(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\InterfaceSpecificParameters' -Recurse -ErrorAction Stop|Get-ItemProperty|Where-Object {$_.DohFlags -gt 0});if($doh.Count){Add-Result 'Защищённый DNS Windows' 'ok' 'Найдены параметры DoH'}else{Add-Result 'Защищённый DNS Windows' 'warning' 'DoH не обнаружен. DNS браузера отдельно не проверяется'}}catch{Add-Result 'Защищённый DNS Windows' 'unknown' 'Параметры DoH недоступны; DNS браузера отдельно не проверяется'}
try {$hosts=Get-Content -LiteralPath (Join-Path $env:SystemRoot 'System32\drivers\etc\hosts');$yt=@($hosts|Where-Object {$_ -notmatch '^\s*#' -and $_ -match 'youtube\.com|youtu\.be'});if($yt.Count){Add-Result 'Hosts YouTube' 'warning' 'Найдены записи YouTube в hosts'}else{Add-Result 'Hosts YouTube' 'ok' 'Записи YouTube не найдены'}}catch{Add-Result 'Hosts YouTube' 'unknown' 'Не удалось прочитать hosts'}
if(-not $winws.Count -and @($drivers|Where-Object {$_.Name -match '^WinDivert' -and $_.State -match 'Running|Stop Pending'}).Count){Add-Result 'WinDivert без winws' 'warning' 'Драйвер активен без winws; возможен другой клиент'}else{Add-Result 'WinDivert без winws' 'ok' 'Явный конфликт не обнаружен'}
Add-Result 'Кэш Discord' 'info' 'Очистка кэша не является проверкой и автоматически не выполняется'
ConvertTo-Json -InputObject @($rows.ToArray()) -Depth 4 -Compress
`
