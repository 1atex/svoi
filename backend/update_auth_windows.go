//go:build windows

package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Matching a trusted certificate pins the publisher to the installed app. A
// GitHub asset digest alone cannot authenticate the publisher. Certificate
// rotation requires a separately reviewed/manual update of the trusted app.
const updateAuthenticodeScript = `
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
try {
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1') -ErrorAction Stop
$current = Get-AuthenticodeSignature -LiteralPath $env:SVOI_TRUSTED_EXE
if ($current.Status -ne 'Valid' -or !$current.SignerCertificate) { throw 'Установленная версия не имеет доверенной подписи издателя. Используйте ручную установку с официальной страницы релиза.' }
$candidate = Get-AuthenticodeSignature -LiteralPath $env:SVOI_CANDIDATE_EXE
if ($candidate.Status -ne 'Valid' -or !$candidate.SignerCertificate) { throw 'Обновление не имеет действительной доверенной подписи издателя. Автоматическая установка заблокирована.' }
if ($current.SignerCertificate.Thumbprint -ne $candidate.SignerCertificate.Thumbprint) { throw 'Сертификат издателя обновления отличается от установленного приложения. Требуется ручная проверка релиза.' }
Write-Output 'SVOI_AUTHENTICODE_VERIFIED'
} catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
`

func trustedUpdateExecutable() (string, error) {
	if desktopExecutable != "" {
		return filepath.Abs(desktopExecutable)
	}
	return os.Executable()
}

func verifyUpdateInstaller(installer string) error {
	trusted, err := trustedUpdateExecutable()
	if err != nil {
		return err
	}
	if !filepath.IsAbs(installer) {
		return fmt.Errorf("Неверный путь обновления")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := windowsPowerShell(ctx, updateAuthenticodeScript)
	cmd.Env = append(os.Environ(), "SVOI_TRUSTED_EXE="+trusted, "SVOI_CANDIDATE_EXE="+installer)
	output, err := cmd.CombinedOutput()
	if err != nil {
		if ctx.Err() != nil {
			return fmt.Errorf("Проверка подписи не завершилась за 30 секунд; установка отменена")
		}
		return fmt.Errorf("Проверка подписи издателя: %.1200s", strings.TrimSpace(string(output)))
	}
	if !strings.Contains(string(output), "SVOI_AUTHENTICODE_VERIFIED") {
		return fmt.Errorf("Windows не подтвердила подпись обновления")
	}
	return nil
}
