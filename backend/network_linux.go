package main

import (
	"encoding/binary"
	"errors"
	"os"
	"os/exec"
	"syscall"
)

func hideCommand(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGTERM, Setpgid: true}
}
func protectChild(*exec.Cmd) (func(), error) { return func() {}, nil }
func isElevated() bool                       { return os.Geteuid() == 0 }
func enableSystemProxy(string, int) (func() error, error) {
	return nil, errors.New("выберите TUN или настройте ручной SOCKS5/HTTP-прокси в приложении")
}
func recoverSystemProxy(string) error { return nil }
func watchProxy(int, string) error    { return nil }

func effectiveNetworkCapabilities(data []byte) bool {
	if len(data) < 20 {
		return false
	}
	magic := binary.LittleEndian.Uint32(data)
	revision := magic & 0xff000000
	if (revision != 0x02000000 && revision != 0x03000000) || magic&1 == 0 {
		return false
	}
	if revision == 0x03000000 && (len(data) < 24 || binary.LittleEndian.Uint32(data[20:]) != 0) {
		return false
	}
	const required = 1<<12 | 1<<13
	return binary.LittleEndian.Uint32(data[4:])&required == required
}

func canCreateTun(binary string) bool {
	if isElevated() {
		return true
	}
	var data [24]byte
	n, err := syscall.Getxattr(binary, "security.capability", data[:])
	return err == nil && effectiveNetworkCapabilities(data[:n])
}
