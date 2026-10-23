$ErrorActionPreference = 'Stop'
Push-Location -LiteralPath $PSScriptRoot
try {
    $version = [regex]::Match((Get-Content -LiteralPath 'main.go' -Raw), 'const appVersion = "([^"]+)"').Groups[1].Value
    $parts = [regex]::Match($version, '^(\d+)\.(\d+)\.(\d+)(?:-prebeta\.(\d+))?$')
    if (-not $parts.Success) { throw 'Unsupported resource version' }
    $revision = if ($parts.Groups[4].Success) { $parts.Groups[4].Value } else { '0' }
    $numeric = '{0}.{1}.{2}.{3}' -f $parts.Groups[1].Value,$parts.Groups[2].Value,$parts.Groups[3].Value,$revision
    $resources = @{
        RT_GROUP_ICON = @{ '#1' = @{ '0000' = '../assets/svoi.ico' } }
        RT_MANIFEST = @{ '#1' = @{ '0409' = @{
            description = 'SVOI Xray VPN'; 'minimum-os' = 'win10'
            'execution-level' = 'as invoker'; 'dpi-awareness' = 'per monitor v2'
            'use-common-controls-v6' = $true
        } } }
        RT_VERSION = @{ '#1' = @{ '0000' = @{
            fixed = @{ file_version = $numeric; product_version = $numeric; flags = 'Prerelease' }
            info = @{ '0409' = @{
                CompanyName = 'SVOI'; FileDescription = 'SVOI - Xray VPN'
                FileVersion = $version; ProductVersion = $version; ProductName = 'SVOI'
                OriginalFilename = 'svoi.exe'; InternalName = 'svoi'
            } }
        } } }
    }
    New-Item -ItemType Directory -Path 'dist' -Force | Out-Null
    $resourceJSON = Join-Path $PSScriptRoot ('dist/resources-' + [guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::WriteAllText($resourceJSON, ($resources | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding($false)))
    & go run github.com/tc-hib/go-winres@v0.3.3 make --in $resourceJSON --arch amd64 --out rsrc
    if ($LASTEXITCODE -ne 0) { throw 'Windows resource generation failed' }
} finally {
    if ($resourceJSON -and (Test-Path -LiteralPath $resourceJSON)) { Remove-Item -LiteralPath $resourceJSON }
    Pop-Location
}
