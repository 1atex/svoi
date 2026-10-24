//go:build !windows

package backend

import "log"

const desktopSupported = false

func showDesktop(string) error        { return nil }
func showStartupError(message string) { log.Print(message) }
