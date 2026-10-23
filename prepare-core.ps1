$ErrorActionPreference = 'Stop'
$coreRoot = Join-Path $PSScriptRoot 'core'
$url = 'https://github.com/XTLS/Xray-core/releases/download/v26.10.21/Xray-windows-64.zip'
$sha = 'fc58c39ee2f2717b4c54d28d374362389e5319b20ae44aea76ea45a5243ec827'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('svoi-core-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
    $archive = Join-Path $tempRoot 'xray.zip'
    Invoke-WebRequest -Uri $url -OutFile $archive
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sha) { throw 'Xray archive checksum mismatch' }
    $unpacked = Join-Path $tempRoot 'unpacked'
    Expand-Archive -LiteralPath $archive -DestinationPath $unpacked
    New-Item -ItemType Directory -Path $coreRoot -Force | Out-Null
    foreach ($name in @('xray.exe','wintun.dll','geoip.dat','geosite.dat','LICENSE','LICENSE-Wintun')) {
        Copy-Item -LiteralPath (Join-Path $unpacked $name) -Destination (Join-Path $coreRoot $name)
    }
} finally {
    $resolved = [IO.Path]::GetFullPath($tempRoot)
    $expectedRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($expectedRoot, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf).StartsWith('svoi-core-')) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
