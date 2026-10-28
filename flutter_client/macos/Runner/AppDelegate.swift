import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  var quitRequested = false
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let window = mainFlutterWindow as? MainFlutterWindow, !window.closing else { return .terminateNow }
    if !quitRequested { quitRequested = true; window.requestQuit() }
    return .terminateLater
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    (mainFlutterWindow as? MainFlutterWindow)?.show()
    return true
  }
}
