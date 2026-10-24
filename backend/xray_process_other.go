//go:build !windows

package backend

import (
	"os"
	"os/exec"
)

func prepareXrayCommand(cmd *exec.Cmd)  { hideCommand(cmd) }
func interruptXray(cmd *exec.Cmd) error { return cmd.Process.Signal(os.Interrupt) }
