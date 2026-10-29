//go:build !windows

package main

import "fmt"

func verifyUpdateInstaller(string) error {
	return fmt.Errorf("Проверка установщика доступна только в Windows")
}

func launchUpdateInstaller(string, string) error {
	return fmt.Errorf("Установщик поддерживается только на Windows")
}
func installUpdateAfterExit(string, string, int) error {
	return fmt.Errorf("Обновление поддерживается только на Windows")
}
func closeDesktop() {}
