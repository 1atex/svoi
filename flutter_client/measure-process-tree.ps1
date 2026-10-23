param([Parameter(Mandatory)][int]$RootProcessId, [Parameter(Mandatory)][string]$OutputFile)
$ErrorActionPreference = 'Stop'
function Snapshot {
    $all = @(Get-CimInstance Win32_Process | Select-Object ProcessId,ParentProcessId,Name)
    $ids = [Collections.Generic.HashSet[int]]::new()
    [void]$ids.Add($RootProcessId)
    do {
        $changed = $false
        foreach ($p in $all) {
            if ($ids.Contains([int]$p.ParentProcessId) -and $ids.Add([int]$p.ProcessId)) { $changed = $true }
        }
    } while ($changed)
    $processes = @($ids | ForEach-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
    if (!$processes.Count) { throw 'Benchmark process has exited' }
    [pscustomobject]@{
        timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        processes = @($processes | ForEach-Object { [pscustomobject]@{
            id = $_.Id; name = $_.ProcessName
            workingSet = $_.WorkingSet64; privateBytes = $_.PrivateMemorySize64
            cpuSeconds = $_.TotalProcessorTime.TotalSeconds
        }})
        workingSetMiB = [math]::Round(($processes | Measure-Object WorkingSet64 -Sum).Sum / 1MB, 2)
        privateCommitMiB = [math]::Round(($processes | Measure-Object PrivateMemorySize64 -Sum).Sum / 1MB, 2)
        cpuSeconds = ($processes | ForEach-Object { $_.TotalProcessorTime.TotalSeconds } | Measure-Object -Sum).Sum
    }
}
$initial = Snapshot
$samples = @()
for ($i=0; $i -lt 3; $i++) {
    Start-Sleep -Seconds 5
    $samples += Snapshot
}
$last = $samples[-1]
$result = [pscustomobject]@{
    rootPid = $RootProcessId
    samples = $samples
    cpuPercentOfOneCore = [math]::Round(100 * ($last.cpuSeconds - $initial.cpuSeconds) / (($last.timestamp - $initial.timestamp)/1000), 3)
    note = 'One warm idle run, 3 samples, complete child process tree. Working sets can double-count shared pages; private bytes are committed memory, not physical RAM. GPU memory excluded.'
}
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputFile -Encoding utf8
$result | Select-Object rootPid,cpuPercentOfOneCore
$samples | Select-Object workingSetMiB,privateCommitMiB,@{Name='processCount';Expression={$_.processes.Count}}
