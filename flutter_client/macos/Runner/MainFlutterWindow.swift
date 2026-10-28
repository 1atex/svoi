import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  private var channel: FlutterMethodChannel!
  private var statusItem: NSStatusItem!
  private var visibilityObservers: [NSObjectProtocol] = []
  var closing = false

  override func awakeFromNib() {
    let project = FlutterDartProject()
    project.dartEntrypointArguments = Array(CommandLine.arguments.dropFirst())
    let controller = FlutterViewController(project: project)
    contentViewController = controller
    setContentSize(NSSize(width: 1220, height: 840))
    minSize = NSSize(width: 800, height: 600)
    title = "SVOI"
    appearance = NSAppearance(named: .darkAqua)
    center()
    delegate = self
    isReleasedWhenClosed = false
    RegisterGeneratedPlugins(registry: controller)
    channel = FlutterMethodChannel(name: "dev.svoi/window", binaryMessenger: controller.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result) }
    for event in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
      visibilityObservers.append(NotificationCenter.default.addObserver(forName: event, object: NSApp, queue: .main) { [weak self] _ in
        guard let self = self else { return }
        self.channel.invokeMethod("visibility", arguments: self.isVisible && !self.isMiniaturized && !NSApp.isHidden)
      })
    }
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let image = NSImage(named: NSImage.Name("AppIcon"))?.copy() as? NSImage {
      image.size = NSSize(width: 18, height: 18)
      statusItem.button?.image = image
    } else { statusItem.button?.title = "S" }
    super.awakeFromNib()
  }

  deinit { for observer in visibilityObservers { NotificationCenter.default.removeObserver(observer) } }

  func requestQuit() { channel.invokeMethod("requestClose", arguments: nil) }

  func show() {
    deminiaturize(nil)
    makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    channel.invokeMethod("visibility", arguments: true)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if closing { return true }
    orderOut(nil)
    channel.invokeMethod("visibility", arguments: false)
    return false
  }

  func windowDidMiniaturize(_ notification: Notification) { channel.invokeMethod("visibility", arguments: false) }
  func windowDidDeminiaturize(_ notification: Notification) { channel.invokeMethod("visibility", arguments: true) }

  @objc private func menuAction(_ item: NSMenuItem) {
    guard let id = item.representedObject as? String else { return }
    if id == "open" { show() }
    else { channel.invokeMethod("trayAction", arguments: id) }
  }

  private func menu(_ items: [[String: Any]]) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    for data in items {
      if data["separator"] as? Bool == true { menu.addItem(.separator()); continue }
      let item = NSMenuItem(title: data["label"] as? String ?? "", action: #selector(menuAction(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = data["id"] as? String ?? ""
      item.isEnabled = data["enabled"] as? Bool ?? true
      item.state = data["checked"] as? Bool == true ? .on : .off
      if let children = data["children"] as? [[String: Any]] { item.submenu = self.menu(children) }
      menu.addItem(item)
    }
    return menu
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "ready": result(nil)
    case "show": show(); result(nil)
    case "tray": orderOut(nil); channel.invokeMethod("visibility", arguments: false); result(nil)
    case "minimize": miniaturize(nil); result(nil)
    case "maximize": zoom(nil); result(nil)
    case "requestWindowClose": requestQuit(); result(nil)
    case "close":
      closing = true
      result(nil)
      if let delegate = NSApp.delegate as? AppDelegate, delegate.quitRequested {
        NSApp.reply(toApplicationShouldTerminate: true)
      } else { NSApp.terminate(nil) }
    case "titlebar":
      if let data = call.arguments as? [String: Any], let dark = data["dark"] as? Bool {
        appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      }
      result(nil)
    case "updateTray":
      if let data = call.arguments as? [String: Any] {
        statusItem.menu = menu(data["items"] as? [[String: Any]] ?? [])
        statusItem.button?.toolTip = data["tooltip"] as? String
      }
      result(nil)
    case "openCommunity", "openExternal":
      let text = call.method == "openCommunity" ? "tg://resolve?domain=SVOI_client" : call.arguments as? String ?? ""
      guard let url = URL(string: text), ["http", "https", "tg"].contains(url.scheme?.lowercased() ?? ""),
            url.host?.isEmpty == false, url.user == nil, url.password == nil else {
        result(FlutterError(code: "invalid_uri", message: "Недопустимая ссылка", details: nil)); return
      }
      if NSWorkspace.shared.open(url) { result(nil) }
      else { result(FlutterError(code: "open_failed", message: url.scheme == "tg" ? "Установите Telegram" : "Не удалось открыть ссылку", details: nil)) }
    case "openFile":
      let panel = NSOpenPanel()
      panel.canChooseDirectories = false
      panel.allowsMultipleSelection = false
      panel.beginSheetModal(for: self) { response in result(response == .OK ? panel.url?.path : nil) }
    case "saveFile":
      let panel = NSSavePanel()
      panel.nameFieldStringValue = ((call.arguments as? String ?? "SVOI.json") as NSString).lastPathComponent
      panel.beginSheetModal(for: self) { response in result(response == .OK ? panel.url?.path : nil) }
    default: result(FlutterMethodNotImplemented)
    }
  }
}
