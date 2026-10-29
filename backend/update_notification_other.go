//go:build !windows

package main

import "fmt"

func showUpdateNotification(string, string) error {
	return fmt.Errorf("уведомления обновлений доступны только в Windows")
}
