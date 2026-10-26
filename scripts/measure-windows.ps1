param(
    [ValidateRange(5, 120)][int]$Seconds = 20,
    [string]$Label = 'idle',
    [string]$Output = ''
)
$ErrorActionPreference = 'Stop'
$names = @('svoi', 'svoi-backend', 'xray', 'winws', 'winws2')
$before = @{}
foreach ($p in Get-Process -Name $names -ErrorAction SilentlyContinue) {
    $before[$p.Id] = [pscustomobject]@{Cpu = $p.TotalProcessorTime.TotalSeconds; Start = $p.StartTime}
}
$watch = [Diagnostics.Stopwatch]::StartNew()
$samples = [Collections.Generic.List[object]]::new()
while ($watch.Elapsed.TotalSeconds -lt $Seconds) {
    Start-Sleep -Milliseconds 1000
    foreach ($p in Get-Process -Name $names -ErrorAction SilentlyContinue) {
        $samples.Add([pscustomobject]@{Id = $p.Id; Name = $p.ProcessName; WorkingSetMB = $p.WorkingSet64 / 1MB; PrivateMB = $p.PrivateMemorySize64 / 1MB})
    }
}
$elapsed = $watch.Elapsed.TotalSeconds
$result = @(
    foreach ($p in Get-Process -Name $names -ErrorAction SilentlyContinue) {
        $saved = $before[$p.Id]
        $rows = @($samples | Where-Object Id -eq $p.Id)
        $cpu = $null
        if ($saved -and $saved.Start -eq $p.StartTime) {
            $cpu = [Math]::Round(100 * ($p.TotalProcessorTime.TotalSeconds - $saved.Cpu) / $elapsed / [Environment]::ProcessorCount, 3)
        }
        [pscustomobject]@{
            Process = $p.ProcessName
            Id = $p.Id
            CpuPercentWholeMachine = $cpu
            AverageWorkingSetMB = [Math]::Round(($rows | Measure-Object WorkingSetMB -Average).Average, 1)
            PeakPrivateMB = [Math]::Round(($rows | Measure-Object PrivateMB -Maximum).Maximum, 1)
        }
    }
)
$report = [pscustomobject]@{Label = $Label; At = (Get-Date).ToString('o'); Seconds = [Math]::Round($elapsed, 2); LogicalProcessors = [Environment]::ProcessorCount; Processes = $result}
$json = $report | ConvertTo-Json -Depth 4
if ($Output) { $json | Set-Content -LiteralPath $Output -Encoding utf8 }
$json
