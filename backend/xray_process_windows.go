//go:build windows

package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"syscall"
	"time"

	"golang.org/x/sys/windows"
)

func init() {
	if len(os.Args) != 3 || os.Args[1] != "--svoi-stop-xray" {
		return
	}
	pid, err := strconv.ParseUint(os.Args[2], 10, 32)
	if err != nil || pid == 0 {
		os.Exit(2)
	}
	if err := sendXrayInterrupt(uint32(pid)); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	os.Exit(0)
}

func prepareXrayCommand(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: windows.CREATE_NEW_CONSOLE}
}

func interruptXray(cmd *exec.Cmd) error {
	executable, err := os.Executable()
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	helper := exec.CommandContext(ctx, executable, "--svoi-stop-xray", strconv.Itoa(cmd.Process.Pid))
	hideCommand(helper)
	output, err := helper.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%w: %s", err, output)
	}
	return nil
}

func sendXrayInterrupt(pid uint32) error {
	kernel := windows.NewLazySystemDLL("kernel32.dll")
	attach := kernel.NewProc("AttachConsole")
	free := kernel.NewProc("FreeConsole")
	handler := kernel.NewProc("SetConsoleCtrlHandler")
	generate := kernel.NewProc("GenerateConsoleCtrlEvent")
	free.Call()
	if ok, _, err := attach.Call(uintptr(pid)); ok == 0 {
		return fmt.Errorf("AttachConsole: %w", err)
	}
	defer free.Call()
	callback := syscall.NewCallback(func(uint32) uintptr { return 1 })
	if ok, _, err := handler.Call(callback, 1); ok == 0 {
		return fmt.Errorf("SetConsoleCtrlHandler: %w", err)
	}
	if ok, _, err := generate.Call(windows.CTRL_BREAK_EVENT, 0); ok == 0 {
		return fmt.Errorf("GenerateConsoleCtrlEvent: %w", err)
	}
	return nil
}
