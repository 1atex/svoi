//go:build !windows

package backend

import "fmt"

func launchUpdateInstaller(string, string) error {
	return fmt.Errorf("Установщик поддерживается только на Windows")
}
func installUpdateAfterExit(string, string, int) error {
	return fmt.Errorf("Обновление поддерживается только на Windows")
}
func closeDesktop() {}
