//go:build !windows && !linux && !darwin

package main

import "log"

const desktopSupported = false

func showDesktop(string) error        { return nil }
func showStartupError(message string) { log.Print(message) }
