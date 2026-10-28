package main

import (
	"fmt"
	"log"
)

const desktopSupported = true

func showDesktop(string) error        { return fmt.Errorf("откройте SVOI.app") }
func showStartupError(message string) { log.Print(message) }
