//go:build !windows && !linux && !darwin

package main

import (
	"context"
	"fmt"
)

func launchWarpComponent(context.Context, string) error {
	return fmt.Errorf("WARP не поддерживается этой сборкой")
}
