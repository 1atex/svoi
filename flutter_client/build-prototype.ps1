param(
    [string]$Version = '0.5.0-beta.11',
    [string]$FlutterSdk = '',
    [string]$CrtDirectory = '',
    [switch]$SkipChecks
)
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^\d+\.\d+\.\d+(?:-(?:prebeta|beta|rc)\.\d+)?$') { throw 'Invalid version' }
$root = Split-Path $PSScriptRoot -Parent
$dartVersion = [regex]::Match((Get-Content -LiteralPath "$PSScriptRoot/lib/features.dart" -Raw), "const clientVersion = '([^']+)'").Groups[1].Value
$packageVersion = [regex]::Match((Get-Content -LiteralPath "$PSScriptRoot/pubspec.yaml" -Raw), '(?m)^version: ([^+\s]+)').Groups[1].Value
if ($Version -ne $dartVersion -or $Version -ne $packageVersion) { throw 'Go, Dart and pubspec release versions must match -Version' }
if (!$FlutterSdk) { $FlutterSdk = Join-Path $root '.tools/sdk/flutter' }
$flutter = Join-Path $FlutterSdk 'bin/flutter.bat'
$dart = Join-Path $FlutterSdk 'bin/dart.bat'
if (!(Test-Path -LiteralPath $flutter)) { throw 'Pass -FlutterSdk pointing to a Flutter SDK with Windows support.' }
$go = (Get-Command go -ErrorAction SilentlyContinue).Source
if (!$go) { $go = 'C:/Program Files/Go/bin/go.exe' }
if (!$CrtDirectory) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    $vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    $CrtDirectory = (Get-ChildItem "$vs/VC/Redist/MSVC/*/x64/Microsoft.VC143.CRT" -Directory | Sort-Object FullName -Descending | Select-Object -First 1).FullName
}
if (!(Test-Path -LiteralPath "$CrtDirectory/msvcp140.dll")) { throw 'Pass -CrtDirectory containing the Visual C++ x64 redistributable DLLs.' }
$env:CI = 'true'
Push-Location $root
try {
    New-Item -ItemType Directory -Force dist | Out-Null
    & $go build -tags native_core -trimpath -ldflags "-H windowsgui -s -w -X main.nativeVersion=$Version" -o dist/svoi-backend.exe ./backend
    if ($LASTEXITCODE) { throw 'Go backend build failed' }

    New-Item -ItemType Directory -Force dist/core | Out-Null
    foreach ($name in @('xray.exe','wintun.dll','geoip.dat','geosite.dat','LICENSE','LICENSE-Wintun','SOURCE.txt')) {
        Copy-Item -LiteralPath "core/$name" -Destination dist/core
    }
    Push-Location $PSScriptRoot
    try {
        if (!$SkipChecks) {
            & $dart format --output=none --set-exit-if-changed lib test
            if ($LASTEXITCODE) { throw 'Run dart format lib test first' }
            & $flutter --no-version-check analyze
            if ($LASTEXITCODE) { throw 'Flutter analysis failed' }
            $env:SVOI_BACKEND = Join-Path $root 'dist/svoi-backend.exe'
            & $flutter --no-version-check test
            if ($LASTEXITCODE) { throw 'Flutter tests failed' }
        }
        (Get-Item windows/runner/Runner.rc).LastWriteTime = Get-Date
        & $flutter --no-version-check build windows --release
        if ($LASTEXITCODE) { throw 'Flutter release build failed' }
        & "$PSScriptRoot/verify-windows-branding.ps1" -Executable "$PSScriptRoot/build/windows/x64/runner/Release/svoi.exe"
    } finally { Pop-Location; Remove-Item Env:SVOI_BACKEND -ErrorAction SilentlyContinue }
    $release = Join-Path $root "releases/v$Version"
    $stage = Join-Path $release ('SVOI-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path "$stage/backend/core" -Force | Out-Null
    Copy-Item -Path "$PSScriptRoot/build/windows/x64/runner/Release/*" -Destination $stage -Recurse
    if (Test-Path -LiteralPath "$stage/svoi_flutter.exe") { Remove-Item -LiteralPath "$stage/svoi_flutter.exe" }
    Copy-Item -LiteralPath dist/svoi-backend.exe -Destination "$stage/backend"
    foreach ($name in @('xray.exe','wintun.dll','geoip.dat','geosite.dat','LICENSE','LICENSE-Wintun','SOURCE.txt')) {
        Copy-Item -LiteralPath "dist/core/$name" -Destination "$stage/backend/core"
    }
    Copy-Item -Path "$CrtDirectory/*.dll" -Destination $stage
    Copy-Item -LiteralPath LICENSE -Destination $stage
    Copy-Item -LiteralPath assets/svoi.ico -Destination $stage
    Copy-Item -LiteralPath "$FlutterSdk/LICENSE" -Destination "$stage/LICENSE-Flutter.txt"
    Copy-Item -LiteralPath "$PSScriptRoot/WINDOWS-README.md" -Destination "$stage/README.md"
    $zip = Join-Path $release "SVOI-$Version-windows-x64.zip"
    Compress-Archive -Path "$stage/*" -DestinationPath $zip -Force
    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower()
    "$hash  $([IO.Path]::GetFileName($zip))" | Set-Content -LiteralPath "$zip.sha256" -Encoding ascii
    Write-Output "APP=$stage/svoi.exe"
    Write-Output "ZIP=$zip"
    Write-Output "SHA256=$hash"
    $iscc = 'C:/Program Files (x86)/Inno Setup 6/ISCC.exe'
    if (!(Test-Path -LiteralPath $iscc)) { throw 'Install Inno Setup 6 to build the Windows installer. ZIP is already built.' }
    & $iscc /Qp "/DAppVersion=$Version" "/DPayloadDir=$stage" "/DReleaseDir=$release" "$PSScriptRoot/installer.iss"
    if ($LASTEXITCODE) { throw 'Flutter installer build failed' }
    $setup = Join-Path $release "SVOI-$Version-windows-x64-setup.exe"
    $setupHash = (Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash.ToLower()
    "$setupHash  $([IO.Path]::GetFileName($setup))" | Set-Content -LiteralPath "$setup.sha256" -Encoding ascii
    Write-Output "SETUP=$setup"
    $legacySetup = Join-Path $release "SVOI-Flutter-$Version-windows-x64-setup.exe"
    Copy-Item -LiteralPath $setup -Destination $legacySetup
    "$setupHash  $([IO.Path]::GetFileName($legacySetup))" | Set-Content -LiteralPath "$legacySetup.sha256" -Encoding ascii
} finally { Pop-Location }
