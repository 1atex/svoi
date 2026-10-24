//go:build !windows

package backend

import "fmt"

func startupEnabled(string) (bool, error) {
	return false, fmt.Errorf("Автозапуск доступен в Windows")
}
func setStartup(string, bool) error {
	return fmt.Errorf("Автозапуск доступен в Windows")
}
