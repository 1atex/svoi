//go:build !windows

package backend

func externalZapretRunning() bool { return false }
