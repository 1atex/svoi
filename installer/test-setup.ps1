param([string]$IsccPath = 'C:\Program Files (x86)\Inno Setup 6\ISCC.exe')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$version = [regex]::Match((Get-Content -LiteralPath (Join-Path $root 'main.go') -Raw), 'const appVersion = "([^"]+)"').Groups[1].Value
$release = Join-Path $root ('releases/v' + $version)
$testId = [guid]::NewGuid().ToString('N')
$testRoot = Join-Path $root ('dist/setup-test-' + $testId)
$payload = Join-Path $testRoot 'payload'
$target = Join-Path $testRoot 'installed'
$label = 'SVOI Setup Test ' + $testId
$appId = 'SVOI.Test.' + $testId
$regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\${appId}_is1"
$desktopLink = Join-Path ([Environment]::GetFolderPath('Desktop')) ($label + '.lnk')
$menuDir = Join-Path ([Environment]::GetFolderPath('Programs')) $label
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
Expand-Archive -LiteralPath (Join-Path $release "SVOI-$version-windows-x64.zip") -DestinationPath $payload

& $IsccPath '/Q' '/DTestBuild=1' "/DAppVersion=$version" "/DPayloadDir=$payload" "/DReleaseDir=$testRoot" "/DSetupAppId=$appId" "/DAppLabel=$label" "/DDesktopMutex=Local\$appId" (Join-Path $PSScriptRoot 'svoi.iss')
if ($LASTEXITCODE -ne 0) { throw 'Test installer build failed' }
$setup = Join-Path $testRoot 'TEST-ONLY-NOT-FOR-DISTRIBUTION.exe'
function Run-Setup([string]$LogName) {
    $args = @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',"/DIR=`"$target`"","/LOG=`"$(Join-Path $testRoot $LogName)`"")
    $process = Start-Process -FilePath $setup -ArgumentList $args -WindowStyle Hidden -PassThru
    if (-not $process.WaitForExit(120000)) { throw 'Setup did not finish within two minutes' }
    $process.Refresh()
    if ($process.ExitCode -ne 0) { throw "Setup failed: $($process.ExitCode). See $LogName" }
}
function Assert-Payload {
    foreach ($file in Get-ChildItem -LiteralPath $payload -File -Recurse) {
        $relative = $file.FullName.Substring($payload.Length + 1)
        $installed = Join-Path $target $relative
        if (-not (Test-Path -LiteralPath $installed) -or (Get-FileHash -LiteralPath $file.FullName).Hash -ne (Get-FileHash -LiteralPath $installed).Hash) {
            throw "Payload mismatch: $relative"
        }
    }
}
try {
    Run-Setup 'install.log'
    Assert-Payload
    if (-not (Test-Path -LiteralPath $desktopLink) -or -not (Test-Path -LiteralPath (Join-Path $menuDir ($label + '.lnk')))) { throw 'Shortcuts missing' }
    if (-not (Test-Path -LiteralPath $regPath)) { throw 'Uninstall registration missing' }
    Set-Content -LiteralPath (Join-Path $target 'user-test-data.txt') -Value 'keep this user file'
    Run-Setup 'upgrade.log'
    Assert-Payload
    if (-not (Test-Path -LiteralPath (Join-Path $target 'user-test-data.txt'))) { throw 'Upgrade removed user data' }
    $uninstaller = Join-Path $target 'unins000.exe'
    $process = Start-Process -FilePath $uninstaller -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',"/LOG=`"$(Join-Path $testRoot 'uninstall.log')`"") -WindowStyle Hidden -PassThru
    if (-not $process.WaitForExit(60000)) { throw 'Uninstaller did not finish within one minute' }
    $process.Refresh()
    if ($process.ExitCode -ne 0) { throw "Uninstall failed: $($process.ExitCode)" }
    if ((Test-Path -LiteralPath (Join-Path $target 'svoi.exe')) -or (Test-Path -LiteralPath $desktopLink) -or (Test-Path -LiteralPath $regPath)) { throw 'Uninstall left application files or registration' }
    if (-not (Test-Path -LiteralPath (Join-Path $target 'user-test-data.txt'))) { throw 'Uninstall removed an unowned file' }
    Write-Output 'PASS: install, exact payload, shortcuts, uninstall registration, repeat install, uninstall, unowned-file preservation.'
    Write-Output "Test logs: $testRoot"
} finally {

    if (Test-Path -LiteralPath (Join-Path $target 'svoi.exe')) {
        Write-Warning "Isolated test install remains at $target"
    }
    if (Test-Path -LiteralPath $setup) { Remove-Item -LiteralPath $setup -Force }
}
