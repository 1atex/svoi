$ErrorActionPreference = 'Stop'
$taskRoot = $PSScriptRoot
Push-Location -LiteralPath $taskRoot
try {
    & .\build-resources.ps1
    & go build -trimpath -ldflags '-H windowsgui' -o svoi.exe .
    if ($LASTEXITCODE -ne 0) { throw 'SVOI build failed' }
    Write-Host 'Opening the SVOI desktop window.'
    & .\svoi.exe
} finally {
    Pop-Location
}
