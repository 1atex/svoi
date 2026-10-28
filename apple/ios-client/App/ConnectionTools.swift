import Darwin
import SwiftUI

struct ConnectionTools: View {
  @ObservedObject var vpn: VPNController
  @State private var ip = ""
  @State private var baseline = ""
  @State private var ipError = ""
  @State private var refreshing = false
  @State private var checking = false
  @State private var checkResult = ""
  @State private var checkTask: Task<Void, Never>?
  @State private var ipRevision = UUID()
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Image(systemName: "globe")
        VStack(alignment: .leading, spacing: 4) {
          Text(ip.isEmpty ? refreshing ? "Определяем IP…" : "IP не определён" : ip).font(.headline).textSelection(.enabled)
          Text(vpn.connected ? "Текущая сеть с SVOI" : "Текущая сеть без SVOI").font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button { Task { await refreshIP() } } label: { Image(systemName: "arrow.clockwise") }
          .disabled(refreshing || vpn.busy).accessibilityLabel("Обновить IP")
      }
      if !baseline.isEmpty && vpn.connected && !ip.isEmpty { Text(ip == baseline ? "IP совпадает с адресом до подключения" : "IP изменился после подключения").font(.caption).foregroundStyle(.secondary) }
      if !ipError.isEmpty { Text(ipError).font(.caption).foregroundStyle(.orange) }
      Button(checking ? "Проверяем интернет…" : "Проверить интернет") {
        checkTask?.cancel()
        checkTask = Task { await checkInternet() }
      }.font(.footnote).disabled(checking || vpn.busy)
      if !checkResult.isEmpty { Text(checkResult).font(.caption).foregroundStyle(.secondary) }
      if !vpn.error.isEmpty { Text(vpn.error).font(.footnote).foregroundStyle(.orange).textSelection(.enabled) }
    }.padding(18).background(Color(red: 0.10, green: 0.10, blue: 0.12), in: RoundedRectangle(cornerRadius: 20))
      .task(id: "\(vpn.status.rawValue):\(vpn.serverID)") {
        checkTask?.cancel()
        checkResult = ""
        if !vpn.active || vpn.connected { await refreshIP() }
      }
      .onDisappear { checkTask?.cancel() }
  }

  private func refreshIP() async {
    let revision = UUID()
    ipRevision = revision
    refreshing = true
    defer { if ipRevision == revision { refreshing = false } }
    let status = vpn.status
    let server = vpn.serverID
    do {
      var request = URLRequest(url: URL(string: "https://api64.ipify.org")!, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 5)
      request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
      let session = URLSession(configuration: .ephemeral)
      defer { session.invalidateAndCancel() }
      let (data, response) = try await session.data(for: request)
      try Task.checkCancellation()
      guard status == vpn.status, server == vpn.serverID, ipRevision == revision else { return }
      let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      var address4 = in_addr()
      var address6 = in6_addr()
      guard data.count <= 64, (response as? HTTPURLResponse)?.statusCode == 200,
            inet_pton(AF_INET, value, &address4) == 1 || inet_pton(AF_INET6, value, &address6) == 1 else {
        throw SvoiError("Сервис не вернул IP-адрес")
      }
      ip = value
      if !vpn.active { baseline = value }
      ipError = ""
    } catch is CancellationError {}
    catch {
      if !Task.isCancelled && ipRevision == revision { ip = ""; ipError = "Не удалось определить IP. Повторите проверку." }
    }
  }

  private func checkInternet() async {
    checking = true
    defer { checking = false }
    let status = vpn.status
    let server = vpn.serverID
    let start = Date()
    do {
      let request = URLRequest(url: URL(string: "https://www.gstatic.com/generate_204")!, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 8)
      let session = URLSession(configuration: .ephemeral)
      defer { session.invalidateAndCancel() }
      let (_, response) = try await session.data(for: request)
      try Task.checkCancellation()
      guard status == vpn.status, server == vpn.serverID else { return }
      guard (response as? HTTPURLResponse)?.statusCode == 204 else { throw SvoiError("Неожиданный ответ") }
      checkResult = "Контрольный запрос прошёл · \(Int(Date().timeIntervalSince(start) * 1000)) мс"
    } catch {
      if !Task.isCancelled { checkResult = "Контрольный запрос не прошёл. Попробуйте другой сервер или повторите проверку." }
    }
  }
}
