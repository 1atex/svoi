//go:build windows

package backend

import (
	"golang.org/x/sys/windows"
	"strings"
	"unsafe"
)

func externalZapretRunning() bool {
	handle, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return false
	}
	defer windows.CloseHandle(handle)
	entry := windows.ProcessEntry32{Size: uint32(unsafe.Sizeof(windows.ProcessEntry32{}))}
	for err = windows.Process32First(handle, &entry); err == nil; err = windows.Process32Next(handle, &entry) {
		name := windows.UTF16ToString(entry.ExeFile[:])
		if strings.EqualFold(name, "winws.exe") || strings.EqualFold(name, "winws2.exe") {
			return true
		}
	}
	return false
}
