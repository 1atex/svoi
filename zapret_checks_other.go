//go:build !windows

package main

import (
	"context"
	"fmt"
)

func pingHost(ctx context.Context, ip string) (string, error) {
	return "Доступно в Windows", fmt.Errorf("Windows only")
}
func systemZapretDiagnostics(ctx context.Context, folder string) ([]CheckResult, error) {
	return nil, fmt.Errorf("Диагностика zapret доступна в Windows")
}
