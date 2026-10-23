$ErrorActionPreference = 'Stop'
$redistDir = Join-Path $PSScriptRoot 'redist'
$bootstrapper = Join-Path $redistDir 'MicrosoftEdgeWebview2Setup.exe'
New-Item -ItemType Directory -Path $redistDir -Force | Out-Null
if (-not (Test-Path -LiteralPath $bootstrapper)) {
    Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/p/?LinkId=2124703' -OutFile $bootstrapper
}
$signature = Get-AuthenticodeSignature -LiteralPath $bootstrapper
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(^|, )O=Microsoft Corporation(,|$)') {
    throw 'WebView2 bootstrapper must have a valid Microsoft Authenticode signature'
}
Write-Host 'Verified Microsoft WebView2 bootstrapper.'
