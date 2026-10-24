//go:build windows && !native_core

package backend

import (
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"runtime"
	"sync/atomic"
	"unsafe"

	webview2 "github.com/jchv/go-webview2"
	"github.com/jchv/go-webview2/webviewloader"
	"golang.org/x/sys/windows"
)

const desktopSupported = true

var windowTitle = "SVOI — Xray VPN"

var desktopDataName = "SVOI"

var user32 = windows.NewLazySystemDLL("user32.dll")
var desktopHandle atomic.Uintptr

func closeDesktop() {
	if hwnd := desktopHandle.Load(); hwnd != 0 {
		user32.NewProc("PostMessageW").Call(hwnd, 0x10, 0, 0)
	}
}

func showDesktop(address string) error {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	mutexName, _ := windows.UTF16PtrFromString(`Local\` + desktopDataName + `.Desktop`)

	rawHandle, _, err := windows.NewLazySystemDLL("kernel32.dll").NewProc("CreateMutexW").Call(0, 0, uintptr(unsafe.Pointer(mutexName)))
	handle := windows.Handle(rawHandle)
	if handle != 0 {
		defer windows.CloseHandle(handle)
	}
	if errors.Is(err, windows.ERROR_ALREADY_EXISTS) {
		title, _ := windows.UTF16PtrFromString(windowTitle)
		hwnd, _, _ := user32.NewProc("FindWindowW").Call(0, uintptr(unsafe.Pointer(title)))
		if hwnd != 0 {
			user32.NewProc("ShowWindow").Call(hwnd, 9)
			user32.NewProc("SetForegroundWindow").Call(hwnd)
		}
		return nil
	}
	if handle == 0 {
		return err
	}
	if _, err := webviewloader.GetInstalledVersion(); err != nil {
		return fmt.Errorf("для окна SVOI нужен Microsoft Edge WebView2 Runtime. Установите его с сайта Microsoft и повторите запуск: %w", err)
	}
	dir, err := os.UserConfigDir()
	if err != nil {
		return err
	}
	w := webview2.NewWithOptions(webview2.WebViewOptions{
		DataPath:      filepath.Join(dir, desktopDataName, "WebView2"),
		AutoFocus:     true,
		WindowOptions: webview2.WindowOptions{Title: windowTitle, Width: 1240, Height: 900, Center: true, IconId: 1},
	})
	if w == nil {
		return errors.New("не удалось создать окно SVOI")
	}
	defer w.Destroy()
	desktopHandle.Store(uintptr(w.Window()))
	defer desktopHandle.Store(0)
	w.SetSize(720, 600, webview2.HintMin)
	setWindowIcon(uintptr(w.Window()))
	darkWindowFrame(uintptr(w.Window()))
	w.Navigate(address)
	w.Run()
	return nil
}

func setWindowIcon(hwnd uintptr) {
	module, _, _ := windows.NewLazySystemDLL("kernel32.dll").NewProc("GetModuleHandleW").Call(0)

	for _, size := range []struct{ kind, pixels uintptr }{{0, 16}, {1, 32}} {
		icon, _, _ := user32.NewProc("LoadImageW").Call(module, 1, 1, size.pixels, size.pixels, 0x8000)
		if icon != 0 {
			user32.NewProc("SendMessageW").Call(hwnd, 0x80, size.kind, icon)
		}
	}
}

func darkWindowFrame(hwnd uintptr) {
	set := windows.NewLazySystemDLL("dwmapi.dll").NewProc("DwmSetWindowAttribute")
	if set.Find() != nil {
		return
	}
	dark := uint32(1)
	result, _, _ := set.Call(hwnd, 20, uintptr(unsafe.Pointer(&dark)), 4)
	if int32(result) < 0 {
		set.Call(hwnd, 19, uintptr(unsafe.Pointer(&dark)), 4)
	}

	background, foreground := uint32(0x00111410), uint32(0x00e8f3ec)
	set.Call(hwnd, 35, uintptr(unsafe.Pointer(&background)), 4)
	set.Call(hwnd, 36, uintptr(unsafe.Pointer(&foreground)), 4)
}

func showStartupError(message string) {
	log.Print(message)
	text, _ := windows.UTF16PtrFromString(message)
	title, _ := windows.UTF16PtrFromString("SVOI — ошибка запуска")
	user32.NewProc("MessageBoxW").Call(0, uintptr(unsafe.Pointer(text)), uintptr(unsafe.Pointer(title)), 0x10)
}
