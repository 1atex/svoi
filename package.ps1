param([switch]$SkipInstaller, [string]$IsccPath)
$ErrorActionPreference = 'Stop'
Push-Location -LiteralPath $PSScriptRoot
try {
    $versionMatch = [regex]::Match((Get-Content -LiteralPath 'main.go' -Raw), '(?:const|var) appVersion = "([^"]+)"')
    if (-not $versionMatch.Success) { throw 'Version missing in main.go' }
    $version = $versionMatch.Groups[1].Value
    if (-not (Get-Content -LiteralPath 'web/index.html' -Raw).Contains($version)) { throw 'UI version does not match backend' }
    if (-not $SkipInstaller) {
        if (-not $IsccPath) {
            $candidates = @(
                (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6/ISCC.exe'),
                (Join-Path $env:LOCALAPPDATA 'Programs/Inno Setup 6/ISCC.exe'),
                (Join-Path $env:ProgramFiles 'Inno Setup 6/ISCC.exe')
            )
            $IsccPath = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        }
        if (-not $IsccPath -or -not (Test-Path -LiteralPath $IsccPath)) { throw 'Install Inno Setup 6.4+ or pass -IsccPath. Use -SkipInstaller for ZIP only.' }
        & .\installer\prepare-redist.ps1
    }
    & .\build-resources.ps1
    $coreFiles = @('xray.exe','wintun.dll','geoip.dat','geosite.dat','LICENSE','LICENSE-Wintun','SOURCE.txt')
    foreach ($name in $coreFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path 'core' $name))) { throw "Missing core/$name" }
    }
    & go test ./... -count=1
    if ($LASTEXITCODE -ne 0) { throw 'Tests failed' }
    & go vet ./...
    if ($LASTEXITCODE -ne 0) { throw 'Go vet failed' }
    $distRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'dist'))
    $stage = Join-Path $distRoot ('package-' + [guid]::NewGuid().ToString('N'))
    $binaryStage = Join-Path $stage 'binary'
    $sourceStage = Join-Path $stage 'source'
    $releaseDir = Join-Path $PSScriptRoot ('releases/v' + $version)
    New-Item -ItemType Directory -Path (Join-Path $binaryStage 'core'),(Join-Path $binaryStage 'licenses'),(Join-Path $sourceStage 'core'),$releaseDir -Force | Out-Null
    & go build -trimpath -ldflags '-H windowsgui -s -w' -o (Join-Path $binaryStage 'svoi.exe') .
    if ($LASTEXITCODE -ne 0) { throw 'Build failed' }
    Copy-Item -LiteralPath 'START.cmd','README.md','RELEASE-NOTES.md','LICENSE','assets/svoi.ico' -Destination $binaryStage
    foreach ($name in $coreFiles) { Copy-Item -LiteralPath (Join-Path 'core' $name) -Destination (Join-Path $binaryStage 'core') }
    Get-ChildItem -LiteralPath 'licenses' -File | Copy-Item -Destination (Join-Path $binaryStage 'licenses')
    # Explicit source allowlist: never package local state, diagnostics, previews or INCY files.
    Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.go' -File | Copy-Item -Destination $sourceStage
    Copy-Item -LiteralPath 'go.mod','go.sum','.gitignore','START.cmd','run.ps1','package.ps1','build-resources.ps1','prepare-core.ps1','README.md','RELEASE-NOTES.md','ANNOUNCEMENT.txt','LICENSE','ROADMAP.md','ANDROID.md' -Destination $sourceStage
    Copy-Item -LiteralPath 'web','licenses','assets' -Destination $sourceStage -Recurse
    Copy-Item -LiteralPath 'package.json','package-lock.json','PERFORMANCE.md' -Destination $sourceStage
    Copy-Item -LiteralPath 'tests' -Destination $sourceStage -Recurse
    Copy-Item -LiteralPath '.github' -Destination $sourceStage -Recurse
    New-Item -ItemType Directory -Path (Join-Path $sourceStage 'installer/redist') -Force | Out-Null
    Copy-Item -LiteralPath 'installer/svoi.iss','installer/install-info.txt','installer/prepare-redist.ps1','installer/test-setup.ps1' -Destination (Join-Path $sourceStage 'installer')
    Copy-Item -LiteralPath 'installer/redist/SOURCE.txt' -Destination (Join-Path $sourceStage 'installer/redist')
    Copy-Item -LiteralPath 'core/SOURCE.txt','core/LICENSE','core/LICENSE-Wintun' -Destination (Join-Path $sourceStage 'core')
    $artifacts = @()
    if (-not $SkipInstaller) {
        & $IsccPath '/Q' "/DAppVersion=$version" "/DPayloadDir=$binaryStage" "/DReleaseDir=$releaseDir" 'installer/svoi.iss'
        if ($LASTEXITCODE -ne 0) { throw 'Installer compilation failed' }
        $artifacts += Join-Path $releaseDir "SVOI-$version-windows-x64-setup.exe"
    }
    $binaryArchive = Join-Path $releaseDir "SVOI-$version-windows-x64.zip"
    $sourceArchive = Join-Path $releaseDir "SVOI-$version-source.zip"
    Compress-Archive -Path (Join-Path $binaryStage '*') -DestinationPath $binaryArchive -Force
    # .NET includes .gitignore, which Compress-Archive can omit as a hidden file.
    if (Test-Path -LiteralPath $sourceArchive) { Remove-Item -LiteralPath $sourceArchive -Force }
    [IO.Compression.ZipFile]::CreateFromDirectory($sourceStage, $sourceArchive)
    Copy-Item -LiteralPath 'RELEASE-NOTES.md' -Destination $releaseDir
    Copy-Item -LiteralPath 'ANNOUNCEMENT.txt' -Destination $releaseDir
    Copy-Item -LiteralPath 'assets/svoi.ico' -Destination $releaseDir
    $artifacts += $binaryArchive,$sourceArchive,(Join-Path $releaseDir 'svoi.ico'),(Join-Path $releaseDir 'ANNOUNCEMENT.txt')
    $sums = foreach ($file in $artifacts) {
        $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $([IO.Path]::GetFileName($file))"
    }
    Set-Content -LiteralPath (Join-Path $releaseDir 'SHA256SUMS.txt') -Value $sums -Encoding ascii
    Write-Host "Release: $releaseDir"
    $sums | Write-Output
} finally {
    if ($stage -and (Test-Path -LiteralPath $stage)) {
        $resolvedStage = (Resolve-Path -LiteralPath $stage).Path
        if ($resolvedStage.StartsWith($distRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolvedStage -Leaf) -match '^package-[a-f0-9]{32}$') {
            Remove-Item -LiteralPath $resolvedStage -Recurse -Force
        }
    }
    Pop-Location
}
