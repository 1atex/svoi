import Combine
import Foundation
import UIKit

struct SvoiError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

struct SvoiServer: Identifiable {
  let id: String
  let name: String
  let kind: String
  let detail: String
  let subscriptionID: String
  init(_ value: [String: Any]) {
    id = value["id"] as? String ?? ""
    name = value["name"] as? String ?? "Сервер"
    kind = (value["protocol"] as? String ?? "Xray").uppercased()
    detail = value["fullProfile"] as? Bool == true ? "Профиль Xray · маршрутизация из подписки" : [value["network"] as? String, value["security"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    subscriptionID = value["subscriptionId"] as? String ?? ""
  }
}

struct SvoiSource: Identifiable {
  let id: String
  let name: String
  let count: Int
  let remote: Bool
  let metadata: [String: Any]
  init(_ value: [String: Any]) {
    id = value["id"] as? String ?? ""
    metadata = value["metadata"] as? [String: Any] ?? [:]
    name = metadata["title"] as? String ?? value["name"] as? String ?? "Подписка"
    count = value["count"] as? Int ?? 0
    remote = value["remote"] as? Bool ?? false
  }
}

struct SavedProfile: Codable, Identifiable {
  var id: String
  var name: String
  var token: String
}

final class CoreBridge {
  private let queue = DispatchQueue(label: "dev.svoi.api", qos: .userInitiated, attributes: .concurrent)

  func run<T>(_ work: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        do { continuation.resume(returning: try work()) }
        catch { continuation.resume(throwing: error) }
      }
    }
  }

  static func decode(_ raw: String) throws -> [String: Any] {
    guard let data = raw.data(using: .utf8), let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let status = envelope["status"] as? Int, let body = envelope["body"] as? [String: Any] else {
      throw SvoiError("Ядро вернуло некорректный ответ")
    }
    guard status < 400 else { throw SvoiError(body["error"] as? String ?? "Ошибка ядра") }
    return body
  }

  func request(_ path: String, method: String = "GET", token: String, body: [String: Any] = [:]) async throws -> [String: Any] {
    let raw = String(data: try JSONSerialization.data(withJSONObject: body), encoding: .utf8)!
    return try await run { try Self.decode(SvoiCoreRequest(method, path, token, raw)) }
  }
}

@MainActor
final class SvoiModel: ObservableObject {
  @Published var ready = false
  @Published var working = false
  @Published var error = ""
  @Published var group: [String: Any] = [:]
  @Published var servers: [SvoiServer] = []
  @Published var sources: [SvoiSource] = []
  @Published var selectedID = "" { didSet { UserDefaults.standard.set(selectedID, forKey: "selectedServer") } }
  @Published var profiles: [SavedProfile] = []
  @Published var latencies: [String: String] = [:]
  @Published var checking = Set<String>()
  @Published var autoRefresh = true
  @Published private(set) var preparingVPN = false
  let vpn = VPNController()
  let api = CoreBridge()
  private var token = ""
  private var root: URL?
  private var probeIDs: [String: String] = [:]
  private var connectionAttempt = 0
  var selected: SvoiServer? { servers.first { $0.id == selectedID } }
  var profileID: String { group["id"] as? String ?? "" }

  func initialize() async {
    guard !ready && !working else { return }
    working = true
    error = ""
    defer { working = false }
    do {
      let directory = try await api.run { () throws -> URL in
        let root = try CoreAssets.prepare()
        let message = SvoiCoreOpen(root.path)
        guard message.isEmpty else { throw SvoiError(message) }
        return root
      }
      root = directory
      if let data = try? Data(contentsOf: directory.appendingPathComponent("session.json")) {
        let saved = try JSONDecoder().decode(SessionState.self, from: data)
        profiles = saved.profiles
        token = saved.token
      }
      if token.isEmpty {
        let result = try await api.request("groups", method: "POST", token: "", body: ["name": "Моя сеть", "deviceName": "iPhone", "platform": "iOS"])
        token = result["token"] as? String ?? ""
      }
      let savedSelection = UserDefaults.standard.string(forKey: "selectedServer")
      try await reload()
      selectedID = savedSelection ?? servers.first?.id ?? ""
      if selected == nil { selectedID = servers.first?.id ?? "" }
      let settings = try await api.request("settings", token: token)
      autoRefresh = settings["autoRefresh"] as? Bool ?? true
      try saveSession()
      ready = true
      await vpn.initialize()
      if autoRefresh { Task { await refreshSubscriptions() } }
    } catch { self.error = error.localizedDescription }
  }

  private struct SessionState: Codable { let token: String; let profiles: [SavedProfile] }

  private func saveSession() throws {
    guard let root = root else { return }
    if !profiles.contains(where: { $0.id == profileID }) {
      profiles.append(SavedProfile(id: profileID, name: group["name"] as? String ?? "Моя сеть", token: token))
    }
    let data = try JSONEncoder().encode(SessionState(token: token, profiles: profiles))
    try data.write(to: root.appendingPathComponent("session.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }

  func reload() async throws {
    let current = try await api.request("me", token: token)
    group = current
    servers = (current["servers"] as? [[String: Any]] ?? []).map(SvoiServer.init)
    sources = (current["subscriptions"] as? [[String: Any]] ?? []).map(SvoiSource.init)
    if selected == nil { selectedID = servers.first?.id ?? "" }
  }

  func perform(_ work: () async throws -> Void) async {
    guard !working else { return }
    working = true
    error = ""
    defer { working = false }
    do { try await work() }
    catch is CancellationError {}
    catch { self.error = error.localizedDescription }
  }

  func add(_ value: String) async {
    await perform {
      let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty, text.utf8.count <= 4 * 1024 * 1024 else { throw SvoiError("Вставьте ссылку или профиль размером до 4 МБ") }
      if text.hasPrefix("SVOI1.") {
        guard !vpn.busy else { throw SvoiError("Дождитесь завершения переключения VPN") }
        connectionAttempt += 1
        preparingVPN = false
        if vpn.active { try await vpn.disconnect() }
        cancelProbes()
        let result = try await api.request("transfer/import", method: "POST", token: token,
                                          body: ["code": text, "deviceName": "iPhone", "platform": "iOS", "replace": false])
        guard let importedToken = result["token"] as? String, !importedToken.isEmpty else { throw SvoiError("Не удалось открыть импортированный профиль") }
        token = importedToken
        try await reload()
        try saveSession()
        try await refreshRemoteSources()
      } else if let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
        let result = try await api.request("subscriptions", method: "POST", token: token, body: ["url": text, "name": ""])
        try await reload()
        if let id = result["id"] as? String { _ = try await api.request("subscription/refresh?id=\(id)", method: "POST", token: token) }
        try await reload()
      } else {
        _ = try await api.request("subscription/import", method: "POST", token: token, body: ["content": text])
        try await reload()
      }
    }
  }

  private func refreshRemoteSources() async throws {
    var failures: [String] = []
    for source in sources where source.remote {
      do { _ = try await api.request("subscription/refresh?id=\(source.id)", method: "POST", token: token) }
      catch { failures.append("\(source.name): \(error.localizedDescription)") }
    }
    try await reload()
    if !failures.isEmpty { throw SvoiError(failures.joined(separator: "\n")) }
  }

  func refreshSubscriptions() async { await perform { try await refreshRemoteSources() } }

  func switchProfile(_ profile: SavedProfile) async {
    await perform {
      connectionAttempt += 1
      preparingVPN = false
      if vpn.active { try await vpn.disconnect() }
      cancelProbes()
      let previous = token
      token = profile.token
      do { try await reload() }
      catch { token = previous; throw error }
      try saveSession()
    }
  }

  func toggleVPN() async {
    cancelProbes()
    if preparingVPN { connectionAttempt += 1; preparingVPN = false; return }
    if vpn.busy { vpn.cancelStart(); return }
    error = ""
    do {
      if vpn.active && vpn.serverID == selectedID { try await vpn.disconnect(); return }
      guard let server = selected else { throw SvoiError("Сначала добавьте подписку и выберите сервер") }
      let token = token
      let profile = profileID
      connectionAttempt += 1
      let attempt = connectionAttempt
      preparingVPN = true
      defer { if connectionAttempt == attempt { preparingVPN = false } }
      let result = try await api.run { try CoreBridge.decode(SvoiCoreConfig(token, server.id)) }
      guard attempt == connectionAttempt, profile == profileID else { return }
      guard let config = result["config"] as? String else { throw SvoiError("Не удалось подготовить конфигурацию") }
      preparingVPN = false
      try await vpn.connect(config: config, server: server, profileID: profile)
    } catch is CancellationError {}
    catch { self.error = error.localizedDescription }
  }

  func probe(_ server: SvoiServer) async {
    guard checking.count < 2, !checking.contains(server.id), !vpn.busy, !vpn.active else { return }
    let requestID = UUID().uuidString
    let token = token
    let profile = profileID
    probeIDs[server.id] = requestID
    checking.insert(server.id)
    defer {
      if probeIDs[server.id] == requestID { probeIDs.removeValue(forKey: server.id); checking.remove(server.id) }
    }
    do {
      let result = try await api.run { try CoreBridge.decode(SvoiCoreProbe(token, server.id, requestID)) }
      guard profile == profileID, probeIDs[server.id] == requestID else { return }
      latencies[server.id] = "\(result["latency"] as? Int ?? 0) мс"
    } catch {
      if profile == profileID && probeIDs[server.id] == requestID { latencies[server.id] = "Нет ответа" }
    }
  }

  func cancelProbes() {
    for id in probeIDs.values { SvoiCoreCancelProbe(id) }
    probeIDs.removeAll()
    checking.removeAll()
  }

  func configuration(_ server: SvoiServer) async throws -> String {
    let result = try await api.request("servers/\(server.id)/config?mode=tun", token: token)
    return String(data: try JSONSerialization.data(withJSONObject: result["original"] ?? [:], options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!
  }

  func exportProfile() async throws -> String {
    let value = try await api.request("transfer/export", method: "POST", token: token)
    return value["code"] as? String ?? ""
  }

  func updateIdentity(_ identity: [String: Any]) async throws {
    _ = try await api.request("identity", method: "PUT", token: token, body: ["identity": identity])
    try await reload()
  }

  func setAutoRefresh(_ enabled: Bool) async {
    await perform {
      _ = try await api.request("settings", method: "PUT", token: token, body: ["autoRefresh": enabled])
      autoRefresh = enabled
    }
  }
}
