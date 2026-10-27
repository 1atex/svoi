package main

import "runtime"

func coreExecutableName() string {
	if runtime.GOOS == "windows" {
		return "xray.exe"
	}
	return "xray"
}

func platformIdentityOS() string {
	if runtime.GOOS == "linux" {
		return "Linux"
	}
	if runtime.GOOS == "darwin" {
		return "macOS"
	}
	return "Windows"
}
