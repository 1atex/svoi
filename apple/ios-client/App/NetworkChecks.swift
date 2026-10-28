import Foundation
import Network
import Combine

struct DNSProvider: Decodable, Identifiable, Sendable {
  let name: String
  let address: String
  var id: String { address }
  static func load() -> [DNSProvider] {
    guard let url = Bundle.main.url(forResource: "dns-providers", withExtension: "json"),
          let data = try? Data(contentsOf: url), let providers = try? JSONDecoder().decode([DNSProvider].self, from: data) else { return [] }
    return providers
  }
}

struct DNSMeasurement: Identifiable, Sendable {
  let provider: DNSProvider
  let samples: [Double]
  var id: String { provider.id }
  var reliable: Bool { samples.count == 6 }
  var median: Double? {
    let sorted = samples.sorted()
    guard !sorted.isEmpty else { return nil }
    let middle = sorted.count / 2
    return sorted.count % 2 == 0 ? (sorted[middle-1] + sorted[middle]) / 2 : sorted[middle]
  }
}

enum DNSWire {
  static func query(_ name: String, id: UInt16) -> Data {
    var bytes: [UInt8] = [UInt8(id >> 8), UInt8(id & 255), 1, 0, 0, 1, 0, 0, 0, 0, 0, 0]
    for label in name.split(separator: ".") { bytes.append(UInt8(label.utf8.count)); bytes.append(contentsOf: label.utf8) }
    bytes.append(contentsOf: [0, 0, 1, 0, 1])
    return Data(bytes)
  }

  static func valid(_ data: Data, id: UInt16) -> Bool {
    let bytes = [UInt8](data)
    guard bytes.count >= 12 && bytes[0] == UInt8(id >> 8) && bytes[1] == UInt8(id & 255)
      && bytes[2] & 0x80 != 0 && bytes[2] & 0x02 == 0 && bytes[3] & 0x0f == 0 else { return false }
    func number(_ offset: Int) -> Int { Int(bytes[offset]) * 256 + Int(bytes[offset + 1]) }
    var offset = 12
    func skipName() -> Bool {
      var labels = 0
      while offset < bytes.count && labels < 128 {
        let length = Int(bytes[offset]); offset += 1; labels += 1
        if length == 0 { return true }
        if length & 0xc0 == 0xc0 {
          guard offset < bytes.count, (length & 63) * 256 + Int(bytes[offset]) < bytes.count else { return false }
          offset += 1
          return true
        }
        guard length <= 63 && offset + length < bytes.count else { return false }
        offset += length
      }
      return false
    }
    for _ in 0..<number(4) {
      guard skipName(), offset + 4 <= bytes.count else { return false }
      offset += 4
    }
    var hasAddress = false
    for _ in 0..<number(6) {
      guard skipName(), offset + 10 <= bytes.count else { return false }
      let type = number(offset), dnsClass = number(offset + 2), count = number(offset + 8)
      offset += 10
      guard offset + count <= bytes.count else { return false }
      if type == 1 && dnsClass == 1 && count == 4 { hasAddress = true }
      offset += count
    }
    return hasAddress
  }
}

final class DNSExchange: @unchecked Sendable {
  private let lock = NSLock()
  private let connection: NWConnection
  private let id = UInt16.random(in: 0...65535)
  private let name: String
  private var continuation: CheckedContinuation<Double, Error>?
  private var result: Result<Double, Error>?
  private var timer: DispatchWorkItem?
  private var sent = false
  private var started = 0.0
  private static let queue = DispatchQueue(label: "dev.svoi.dns", qos: .utility)

  init(server: String, name: String) {
    connection = NWConnection(host: NWEndpoint.Host(server), port: 53, using: .udp)
    self.name = name
  }

  func run() async throws -> Double {
    try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation { continuation in begin(continuation) }
    }, onCancel: { self.finish(.failure(CancellationError())) })
  }

  private func begin(_ continuation: CheckedContinuation<Double, Error>) {
    lock.lock()
    if let result = result { lock.unlock(); continuation.resume(with: result); return }
    self.continuation = continuation
    lock.unlock()
    started = ProcessInfo.processInfo.systemUptime
    let timeout = DispatchWorkItem { [weak self] in self?.finish(.failure(SvoiError("DNS не ответил"))) }
    lock.lock()
    timer = timeout
    let cancelled = result != nil
    lock.unlock()
    if cancelled { return }
    Self.queue.asyncAfter(deadline: .now() + 1.5, execute: timeout)
    connection.stateUpdateHandler = { [weak self] state in
      guard let self = self else { return }
      switch state {
      case .ready:
        guard !self.sent else { return }
        self.sent = true
        self.connection.send(content: DNSWire.query(self.name, id: self.id), completion: .contentProcessed { [weak self] error in
          guard let self = self else { return }
          if let error = error { self.finish(.failure(error)); return }
          self.connection.receiveMessage { [weak self] data, _, _, error in
            guard let self = self else { return }
            if let error = error { self.finish(.failure(error)) }
            else if let data = data, DNSWire.valid(data, id: self.id) {
              self.finish(.success((ProcessInfo.processInfo.systemUptime - self.started) * 1000))
            } else { self.finish(.failure(SvoiError("Некорректный ответ DNS"))) }
          }
        })
      case .failed(let error): self.finish(.failure(error))
      default: break
      }
    }
    connection.start(queue: Self.queue)
  }

  private func finish(_ value: Result<Double, Error>) {
    lock.lock()
    guard result == nil else { lock.unlock(); return }
    result = value
    let pending = continuation
    continuation = nil
    let timeout = timer
    timer = nil
    lock.unlock()
    timeout?.cancel()
    connection.stateUpdateHandler = nil
    connection.cancel()
    pending?.resume(with: value)
  }
}

enum DNSCheck {
  static func measure(_ provider: DNSProvider) async -> DNSMeasurement {
    var samples: [Double] = []
    #if SVOI_UI_PREVIEW
    return DNSMeasurement(provider: provider, samples: [12, 13, 11, 14, 12, 15])
    #else
    for name in ["example.com", "www.microsoft.com", "www.wikipedia.org", "example.com", "www.microsoft.com", "www.wikipedia.org"] {
      if Task.isCancelled { break }
      if let time = try? await DNSExchange(server: provider.address, name: name).run() { samples.append(time) }
    }
    return DNSMeasurement(provider: provider, samples: samples)
    #endif
  }
}

@MainActor
final class DNSCheckState: ObservableObject {
  @Published var results: [DNSMeasurement] = []
  @Published var working = false
  private var task: Task<Void, Never>?
  private var generation = 0
  func start(_ providers: [DNSProvider]) {
    guard !working else { return }
    generation += 1
    let own = generation
    results = []
    working = true
    task = Task {
      await withTaskGroup(of: DNSMeasurement.self) { group in
        var index = 0
        for provider in providers.prefix(3) { group.addTask { await DNSCheck.measure(provider) }; index += 1 }
        while let value = await group.next() {
          guard !Task.isCancelled, own == generation else { group.cancelAll(); return }
          results.append(value)
          if index < providers.count { let provider = providers[index]; index += 1; group.addTask { await DNSCheck.measure(provider) } }
        }
      }
      if own == generation { working = false }
    }
  }
  func stop(clear: Bool = false) { generation += 1; task?.cancel(); task = nil; working = false; if clear { results = [] } }
}

final class NoSiteRedirect: NSObject, URLSessionTaskDelegate {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor
final class SiteCheckState: ObservableObject {
  @Published var result = ""
  @Published var working = false
  @Published var error = ""
  private var task: Task<Void, Never>?
  private var generation = 0
  func start(_ input: String) {
    let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: raw.contains("://") ? raw : "https://" + raw), url.scheme?.lowercased() == "https", url.host != nil,
          url.user == nil, url.password == nil else { error = "Введите HTTPS-адрес, например https://example.com"; return }
    stop()
    working = true
    error = ""
    result = ""
    let own = generation
    task = Task {
      do {
        #if SVOI_UI_PREVIEW
        result = "Демонстрация интерфейса · сеть не проверяется"
        working = false
        return
        #else
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: NoSiteRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 7)
        request.httpMethod = "HEAD"
        request.setValue("SVOI-Site-Check/1", forHTTPHeaderField: "User-Agent")
        let started = ProcessInfo.processInfo.systemUptime
        let (_, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard own == generation, let http = response as? HTTPURLResponse else { return }
        let ms = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
        result = "Сайт ответил: HTTP \(http.statusCode) · \(ms) мс"
        if http.statusCode >= 300 && http.statusCode < 400 { result += "\nСайт перенаправляет на другой адрес; переход не выполнялся." }
        if http.statusCode >= 400 { result += "\nСервер доступен, но отклонил запрос приложения. Попробуйте открыть сайт в браузере." }
        working = false
        #endif
      } catch is CancellationError {} catch {
        if own == generation && !Task.isCancelled { self.error = "Ответ не получен. Проверьте адрес, интернет или выберите другой VPN-сервер."; working = false }
      }
    }
  }
  func stop(clear: Bool = false) { generation += 1; task?.cancel(); task = nil; working = false; if clear { result = ""; error = "" } }
}
