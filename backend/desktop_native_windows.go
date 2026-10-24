//go:build windows && native_core

package backend

import (
	"errors"
	"log"
)

const desktopSupported = true

func showDesktop(string) error {
	return errors.New("this binary is the Flutter backend; launch svoi_flutter.exe")
}
func closeDesktop()                   {}
func showStartupError(message string) { log.Print(message) }
