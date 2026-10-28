import Darwin
import SwiftUI
import UIKit

struct ConnectionTools: View {
  @Environment(\.svoiColors) private var colors
  @ObservedObject var vpn: VPNController
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.svoiAccent) private var accent
  @Environment(\.sizeCategory) private var sizeCategory
  @State private var ip = ""
  @State private var baseline = ""
  @State private var ipError = ""
  @State private var refreshing = false
  @State private var checking = false
  @State private var checkResult = ""
  @State private var checkTask: Task<Void, Never>?
  @State private var ipRevision = UUID()
  @State private var copied = false
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Group {
        if sizeCategory.isAccessibilityCategory {
          VStack(alignment: .leading, spacing: 12) { ipSummary; HStack { Spacer(); ipActions } }
        } else { HStack { ipSummary; Spacer(minLength: 0); ipActions } }
      }
      if !baseline.isEmpty && vpn.connected && !ip.isEmpty { Text(ip == baseline ? "IP совпадает с адресом до подключения" : "IP изменился после подключения").font(.caption).foregroundStyle(.secondary) }
      if !ipError.isEmpty { Text(ipError).font(.caption).foregroundStyle(.orange) }
      Divider().overlay(colors.line)
      Button {
        checkTask?.cancel()
        checkTask = Task { await checkInternet() }
      } label: {
        HStack {
          Label(checking ? "Проверяем интернет…" : "Проверить интернет", systemImage: "waveform.path.ecg")
          Spacer(minLength: 8)
          if checking { ProgressView() } else { Image(systemName: "arrow.up.right").font(.caption) }
        }.frame(minHeight: 44)
      }.font(.footnote.weight(.medium)).disabled(checking || vpn.busy)
      if !checkResult.isEmpty { Text(checkResult).font(.caption).foregroundStyle(.secondary) }
      if !vpn.error.isEmpty { Text(vpn.error).font(.footnote).foregroundStyle(.orange).textSelection(.enabled) }
    }.padding(20).background(colors.surface, in: RoundedRectangle(cornerRadius: 24))
      .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(colors.line))
      .task(id: "\(vpn.status.rawValue):\(vpn.serverID):\(scenePhase)") {
        checkTask?.cancel()
        checkResult = ""
        ip = ""
        ipError = ""
        copied = false
        if scenePhase == .active && (!vpn.active || vpn.connected) { await refreshIP() }
      }
      .onDisappear { checkTask?.cancel() }
  }

  private var ipSummary: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "globe").font(.title3).foregroundStyle(accent).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text(ip.isEmpty ? refreshing ? "Определяем IP…" : "IP не определён" : ip).font(.headline).textSelection(.enabled)
        Text(vpn.busy ? "Соединение меняется" : vpn.connected ? "IP с подключением SVOI" : "IP без подключения SVOI").font(.caption).foregroundStyle(SvoiPalette.muted)
      }
    }
  }

  private var ipActions: some View {
    HStack(spacing: 0) {
      if !ip.isEmpty {
        SvoiIconButton(symbol: copied ? "checkmark" : "doc.on.doc", label: "Скопировать IP") { UIPasteboard.general.string = ip; copied = true }
      }
      SvoiIconButton(symbol: "arrow.clockwise", label: "Обновить IP") { Task { await refreshIP() } }.disabled(refreshing || vpn.busy)
    }
  }

  private func refreshIP() async {
    #if SVOI_UI_PREVIEW
    ip = vpn.connected ? "203.0.113.24" : "198.51.100.10"
    if !vpn.active { baseline = ip }
    #else
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
    #endif
  }

  private func checkInternet() async {
    #if SVOI_UI_PREVIEW
    checkResult = "Демонстрация интерфейса · сеть не проверяется"
    #else
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
    #endif
  }
}
