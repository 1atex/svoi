# Xray early shutdown handler for macOS preview

Source: `github.com/xtls/xray-core`, commit `1b1647cd9ddf`, module version pinned in `config/macos-release.json`. The original `main/run.go` SHA-256 is checked before patching. Source is downloaded with Go module checksum verification and copied into `.tools/macos-xray-source`; the global module cache is never edited.

The official run loop registers SIGINT/SIGTERM after `server.Start()`, `runtime.GC()` and `debug.FreeOSMemory()`. A client can already accept traffic and log that it started while the stop handler is not registered yet. An immediate disconnect can therefore terminate the process with the default signal disposition instead of closing the core normally. This was observed by the real macOS VLESS reconnect test.

The patch moves the existing signal registration directly before `server.Start()` and stops the notification when returning. There is no added sleep, signal retry, or altered networking behavior. The build marker is `1b1647c-svoi-macos.1`. Windows and Linux packages continue to use their existing core.

`scripts/prepare-macos-xray.py` contains the complete, exact source transformation. Original Xray copyright and MPL-2.0 licensing are preserved. Modified source is available in this repository via that script and the pinned upstream source; the app includes the license and this notice.

Regression: `TestMacImmediateReconnectUsesGracefulShutdown` starts and immediately stops the real core twenty times and requires a clean exit every time. Existing real VLESS, Hysteria2, cancellation and profile tests remain enabled.
