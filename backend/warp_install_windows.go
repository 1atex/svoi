//go:build windows

package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

const warpInstallScript = `
$ErrorActionPreference='Stop'
$signature=Get-AuthenticodeSignature -LiteralPath $env:SVOI_WARP_INSTALLER
if ($signature.Status -ne 'Valid' -or !$signature.SignerCertificate -or $signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName,$false) -notin @('Cloudflare, Inc.','Cloudflare, Inc','Cloudflare Inc.','Cloudflare Inc')) {throw 'Подпись Cloudflare не подтверждена'}
$args='/i "' + $env:SVOI_WARP_INSTALLER + '" /passive /norestart'
Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -Verb RunAs -ArgumentList $args -WindowStyle Normal | Out-Null
`

func launchWarpComponent(ctx context.Context, path string) error {
	cmd := exec.CommandContext(ctx, filepath.Join(os.Getenv("SystemRoot"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe"), "-NoLogo", "-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-Command", warpInstallScript)
	hideCommand(cmd)
	cmd.Env = append(os.Environ(), "SVOI_WARP_INSTALLER="+path)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("Не удалось открыть установщик WARP: %.700s", strings.TrimSpace(string(out)))
	}
	return nil
}
