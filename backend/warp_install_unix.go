//go:build linux || darwin

package main

import (
	"context"
	"fmt"
	"os/exec"
	"runtime"
)

func launchWarpComponent(ctx context.Context, path string) error {
	binary := "/usr/bin/xdg-open"
	if runtime.GOOS == "darwin" {
		binary = "/usr/bin/open"
	}
	if err := exec.CommandContext(ctx, binary, path).Run(); err != nil {
		return fmt.Errorf("Откройте компонент WARP через системный установщик: %w", err)
	}
	return nil
}
