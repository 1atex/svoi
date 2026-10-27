//go:build !windows && !linux

package main

import (
	"errors"
	"os"
	"os/exec"
)

func hideCommand(*exec.Cmd)                  {}
func protectChild(*exec.Cmd) (func(), error) { return func() {}, nil }
func isElevated() bool                       { return os.Geteuid() == 0 }
func enableSystemProxy(string, int) (func() error, error) {
	return nil, errors.New("системный прокси поддерживается только в Windows")
}
func recoverSystemProxy(string) error { return nil }
func watchProxy(int, string) error    { return nil }
