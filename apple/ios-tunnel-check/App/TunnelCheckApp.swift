import SwiftUI
import NetworkExtension

final class TunnelModel: ObservableObject {
  @Published var status = "Не запущено"
  @Published var logs: [String] = []
  @Published var busy = false
  @Published var running = false
  private var manager: NETunnelProviderManager?
  private var observer: NSObjectProtocol?
  private var attempt = 0
  private var preparing = false

  var providerID: String? {
    guard let directory = Bundle.main.builtInPlugInsURL,
          let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil),
          let url = urls.first(where: { $0.pathExtension == "appex" }) else { return nil }
    return Bundle(url: url)?.bundleIdentifier
  }

  init() {
    observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] event in
      guard let self = self, let connection = event.object as? NEVPNConnection,
            connection === self.manager?.connection else { return }
      self.changed()
    }
    note("iOS \(UIDevice.current.systemVersion)")
    note("Приложение: \(Bundle.main.bundleIdentifier ?? "не определено")")
    note("Расширение: \(providerID ?? "отсутствует — установщик мог удалить PlugIns")")
    NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
      DispatchQueue.main.async {
        guard let self = self else { return }
        if let error = error { self.note("Чтение VPN: \(self.errorText(error))") }
        self.manager = managers?.first(where: { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self.providerID })
        self.changed()
      }
    }
  }

  deinit { if let observer = observer { NotificationCenter.default.removeObserver(observer) } }

  func note(_ text: String) { logs = Array((logs + [text]).suffix(24)) }
  func errorText(_ error: Error) -> String { let e = error as NSError; return "\(e.domain) [\(e.code)]: \(e.localizedDescription)" }

  func changed() {
    let state = manager?.connection.status ?? .invalid
    running = [.connecting, .connected, .reasserting, .disconnecting].contains(state)
    switch state {
    case .connected:
      status = "Расширение запущено, проверяем ответ…"
      busy = false
      guard let session = manager?.connection as? NETunnelProviderSession else { return }
      do {
        try session.sendProviderMessage(Data("status".utf8)) { [weak self] response in
          DispatchQueue.main.async {
            guard let self = self, self.manager?.connection.status == .connected else { return }
            if response == Data("SVOI-TUNNEL-CHECK-1".utf8) {
              self.status = "Туннель доступен"
              self.note("Получен ответ нашего Packet Tunnel Provider. Это не тест подключения к VPN-серверу.")
            } else { self.status = "Ответ расширения не подтверждён"; self.note("Расширение не вернуло ожидаемый ответ.") }
          }
        }
      } catch { note(errorText(error)) }
    case .connecting, .reasserting: status = "iOS запускает расширение…"
    case .disconnecting: status = "Отключаем тестовый туннель…"
    default:
      if preparing { return }
      if running == false && status != "Не запущено" { status = "Туннель отключён" }
      busy = false
    }
  }

  func toggle() {
    if running { attempt += 1; manager?.connection.stopVPNTunnel(); return }
    guard let providerID = providerID else { status = "Нет VPN-расширения"; return }
    busy = true
    preparing = true
    attempt += 1
    let currentAttempt = attempt
    let manager = self.manager ?? NETunnelProviderManager()
    self.manager = manager
    let configuration = NETunnelProviderProtocol()
    configuration.providerBundleIdentifier = providerID
    configuration.serverAddress = "SVOI capability check"
    configuration.disconnectOnSleep = false
    manager.protocolConfiguration = configuration
    manager.localizedDescription = "SVOI Tunnel Check — тест разрешения"
    manager.isEnabled = true
    manager.isOnDemandEnabled = false
    status = "Запрашиваем разрешение iOS…"
    manager.saveToPreferences { [weak self] error in
      DispatchQueue.main.async {
        guard let self = self, self.attempt == currentAttempt else { return }
        if let error = error { self.failed(error); return }
        manager.loadFromPreferences { error in
          DispatchQueue.main.async {
            guard self.attempt == currentAttempt else { return }
            if let error = error { self.failed(error); return }
            self.preparing = false
            do { try manager.connection.startVPNTunnel(); self.changed() }
            catch { self.failed(error) }
          }
        }
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
      guard let self = self, self.attempt == currentAttempt,
            self.manager?.connection.status != .connected else { return }
      self.busy = false
      self.preparing = false
      self.attempt += 1
      self.manager?.connection.stopVPNTunnel()
      self.status = "Запуск не подтверждён"
      self.note("За 20 секунд расширение не запустилось. Проверьте подпись приложения и .appex, затем повторите тест.")
    }
  }

  func failed(_ error: Error) {
    busy = false
    preparing = false
    attempt += 1
    status = "iOS не разрешила запуск"
    note(errorText(error))
    note("Проверьте Network Extension entitlement и provisioning для приложения и расширения. Установленная IPA сама по себе не подтверждает доступность туннеля.")
  }

  func remove() {
    guard let manager = manager else { return }
    attempt += 1
    manager.connection.stopVPNTunnel()
    manager.removeFromPreferences { [weak self] error in
      DispatchQueue.main.async {
        guard let self = self else { return }
        if let error = error { self.note(self.errorText(error)) }
        else { self.manager = nil; self.running = false; self.busy = false; self.status = "Тестовая VPN-конфигурация удалена" }
      }
    }
  }
}

@main
struct TunnelCheckApp: App {
  @StateObject private var model = TunnelModel()
  var body: some Scene {
    WindowGroup {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          Text("SVOI · проверка туннеля").font(.title2.bold())
          Text("Это диагностическая сборка, не VPN-клиент. Она проверяет запуск расширения после подписи через Bullfrog, Sideloadly или другой установщик.")
          Text("Интернет не перенаправляется. Только тестовая сеть 192.0.2.0/24 назначается расширению; DNS не меняется.").font(.callout).foregroundStyle(.secondary)
          Text("Перед проверкой отключите другие VPN, включая VPN установщика.").font(.callout).foregroundStyle(.secondary)
          Text(model.status).font(.headline)
          Button(model.running ? "Отключить тест" : "Проверить туннель") { model.toggle() }
            .buttonStyle(.borderedProminent).disabled(model.busy && !model.running)
          Button("Скопировать диагностику") { UIPasteboard.general.string = ([model.status] + model.logs).joined(separator: "\n") }
          Button("Удалить тестовую VPN-конфигурацию", role: .destructive) { model.remove() }.disabled(model.busy)
          Text(model.logs.joined(separator: "\n\n")).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
        }.padding(24)
      }.preferredColorScheme(.dark).tint(Color(red: 0.91, green: 0.73, blue: 0.42))
    }
  }
}
