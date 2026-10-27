package main

import (
	"fmt"
	"log"
)

const desktopSupported = true

func showDesktop(string) error {
	return fmt.Errorf("запустите графическое приложение svoi")
}
func showStartupError(message string) { log.Print(message) }
