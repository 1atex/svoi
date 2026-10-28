import Combine
import Foundation
import NetworkExtension

@MainActor
final class VPNController: ObservableObject {
  @Published private(set) var status: NEVPNStatus = .invalid
  @Published private(set) var serverID = ""
  @Published private(set) var busy = false
  @Published var error = ""
  private var manager: NETunnelProviderManager?
  private var observer: NSObjectProtocol?
  private var attempt = 0

  var connected: Bool { status == .connected || status == .reasserting }
  var active: Bool { connected || status == .connecting || status == .disconnecting }
  var title: String {
    switch status {
    case .connected: return "VPN включён"
    case .connecting: return "Подключаемся…"
    case .disconnecting: return "Отключаемся…"
    case .reasserting: return "Восстанавливаем связь…"
    default: return "VPN выключен"
    }
  }

  init() {
    observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
  }

  deinit { if let observer = observer { NotificationCenter.default.removeObserver(observer) } }

  func initialize() async {
    do { try await loadManager() }
    catch { self.error = Self.explain(error) }
  }

  private func providerID() throws -> String {
    guard let directory = Bundle.main.builtInPlugInsURL,
          let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil),
          let url = urls.first(where: { $0.pathExtension == "appex" }),
          let identifier = Bundle(url: url)?.bundleIdentifier else {
      throw SvoiError("В сборке отсутствует VPN-расширение. Установите IPA целиком, сохранив PacketTunnel.")
    }
    return identifier
  }

  private func loadManager() async throws {
    let identifier = try providerID()
    let managers: [NETunnelProviderManager] = try await withCheckedThrowingContinuation { continuation in
      NETunnelProviderManager.loadAllFromPreferences { managers, error in
        if let error = error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: managers ?? []) }
      }
    }
    manager = managers.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == identifier }
    refresh()
  }

  private func refresh() {
    status = manager?.connection.status ?? .invalid
    serverID = (manager?.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["serverID"] as? String ?? ""
  }

  func connect(config: String, server: SvoiServer, profileID: String) async throws {
    guard !busy else { throw SvoiError("Дождитесь завершения переключения") }
    busy = true
    error = ""
    attempt += 1
    let current = attempt
    defer { busy = false; refresh() }
    do {
      try await loadManager()
      if active { try await stopAndWait() }
      try Task.checkCancellation()
      guard current == attempt else { throw CancellationError() }
      let manager = manager ?? NETunnelProviderManager()
      self.manager = manager
      let configuration = NETunnelProviderProtocol()
      configuration.providerBundleIdentifier = try providerID()
      configuration.serverAddress = server.name
      configuration.providerConfiguration = ["config": config, "serverID": server.id, "profileID": profileID]
      configuration.disconnectOnSleep = false
      manager.protocolConfiguration = configuration
      manager.localizedDescription = "SVOI"
      manager.isEnabled = true
      manager.isOnDemandEnabled = false
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        manager.saveToPreferences { error in
          if let error = error { continuation.resume(throwing: error) }
          else { continuation.resume() }
        }
      }
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        manager.loadFromPreferences { error in
          if let error = error { continuation.resume(throwing: error) }
          else { continuation.resume() }
        }
      }
      guard current == attempt else { throw CancellationError() }
      try manager.connection.startVPNTunnel()
      for tick in 0..<200 {
        refresh()
        if connected { return }
        guard current == attempt else { throw CancellationError() }
        if tick > 10 && (status == .disconnected || status == .invalid) {
          throw SvoiError("VPN-расширение остановилось. Проверьте подпись приложения и PacketTunnel; затем попробуйте другой сервер.")
        }
        try await Task.sleep(nanoseconds: 100_000_000)
      }
      manager.connection.stopVPNTunnel()
      throw SvoiError("За 20 секунд подключение не установлено. Попробуйте другой сервер и проверьте разрешение VPN.")
    } catch is CancellationError { throw CancellationError() }
    catch { self.error = Self.explain(error); throw SvoiError(self.error) }
  }

  func cancelStart() {
    attempt += 1
    manager?.connection.stopVPNTunnel()
    refresh()
  }

  func disconnect() async throws {
    guard !busy else { cancelStart(); return }
    busy = true
    defer { busy = false; refresh() }
    attempt += 1
    try await stopAndWait()
  }

  private func stopAndWait() async throws {
    guard let manager = manager else { return }
    manager.connection.stopVPNTunnel()
    for _ in 0..<100 {
      refresh()
      if status == .invalid || status == .disconnected { return }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    throw SvoiError("Предыдущее соединение ещё завершается. Подождите несколько секунд и повторите.")
  }

  static func explain(_ error: Error) -> String {
    let value = error as NSError
    if value.domain == NEVPNErrorDomain && value.code == 5 {
      return "iOS отказала в доступе к VPN. Нужна подпись с Network Extension для приложения и PacketTunnel. Настройки Developer Mode это разрешение не выдают."
    }
    return error.localizedDescription
  }
}
