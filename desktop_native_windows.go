//go:build windows && native_core

package main

import (
	"errors"
	"log"
)

const desktopSupported = true

func showDesktop(string) error {
	return errors.New("this binary is the Flutter backend; launch SVOI Flutter.exe")
}
func closeDesktop()                   {}
func showStartupError(message string) { log.Print(message) }
