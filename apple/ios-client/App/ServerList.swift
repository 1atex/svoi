import SwiftUI

struct ServerList: View {
  @ObservedObject var model: SvoiModel
  @ObservedObject var vpn: VPNController
  let onSelect: () -> Void
  let onImport: () -> Void
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.svoiAccent) private var accent
  @Environment(\.sizeCategory) private var sizeCategory
  @State private var search = ""
  @State private var byLatency = false
  @State private var config: String?
  @State private var showingConfig = false
  @State private var batch: Task<Void, Never>?
  @State private var checkingAll = false
  @State private var checked = 0
  @State private var batchCount = 0

  private var filtered: [SvoiServer] {
    let result = model.servers.filter { search.isEmpty || "\($0.name) \($0.kind) \($0.detail)".localizedCaseInsensitiveContains(search) }
    return byLatency ? result.sorted { latency($0) < latency($1) } : result
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass").foregroundStyle(SvoiPalette.muted)
        TextField("Найти сервер", text: $search).textInputAutocapitalization(.never).autocorrectionDisabled()
          .accessibilityIdentifier("server-search")
        if !search.isEmpty { SvoiIconButton(symbol: "xmark.circle.fill", label: "Очистить поиск") { search = "" } }
      }.padding(.horizontal, 14).frame(minHeight: 50)
        .background(SvoiPalette.surface, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 20).padding(.bottom, 12)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          if !model.error.isEmpty { SvoiNotice(text: model.error, symbol: "exclamationmark.circle") }
          if model.servers.isEmpty {
            SvoiCard {
              VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "square.stack.3d.up").font(.largeTitle).foregroundStyle(accent)
                Text("Здесь будут ваши серверы").font(.title2.bold())
                Text("Добавьте подписку или импортируйте профиль SVOI.").foregroundStyle(SvoiPalette.muted)
                Button("Добавить подписку", action: onImport).buttonStyle(SvoiPrimaryButton())
              }
            }
          } else if filtered.isEmpty {
            VStack(spacing: 12) {
              Image(systemName: "magnifyingglass").font(.title).foregroundStyle(SvoiPalette.muted)
              Text("Ничего не найдено").font(.headline)
              Button("Очистить поиск") { search = "" }.frame(minHeight: 44)
            }.frame(maxWidth: .infinity).padding(.vertical, 36)
          } else {
            HStack {
              Text("Серверов: \(filtered.count)").font(.footnote).foregroundStyle(SvoiPalette.muted)
              Spacer()
              Button { byLatency.toggle() } label: {
                Label(byLatency ? "По задержке" : "По подпискам", systemImage: "arrow.up.arrow.down")
                  .font(.footnote.weight(.medium)).frame(minHeight: 44)
              }.accessibilityLabel("Сортировка: \(byLatency ? "по задержке" : "по подпискам")")
            }
            if byLatency { ForEach(filtered) { row($0) } }
            else {
              let groups = Dictionary(grouping: filtered, by: \.subscriptionID)
              ForEach(model.sources) { source in
                if let servers = groups[source.id], !servers.isEmpty {
                  sourceHeader(source).padding(.top, 6)
                  ForEach(servers) { row($0) }
                }
              }
              let ungrouped = filtered.filter { server in !model.sources.contains { $0.id == server.subscriptionID } }
              if !ungrouped.isEmpty {
                SvoiSectionTitle(title: "Конфигурации").padding(.top, 12)
                ForEach(ungrouped) { row($0) }
              }
            }
          }
        }.padding(.horizontal, 20).padding(.bottom, 16).frame(maxWidth: 600).frame(maxWidth: .infinity)
      }.scrollDismissesKeyboard(.interactively)
        .refreshable { await model.refreshSubscriptions() }
    }.background(SvoiPalette.canvas)
      .safeAreaInset(edge: .bottom, spacing: 0) { probeBar }
      .sheet(isPresented: $showingConfig) {
        NavigationStack {
          ScrollView { Text(config ?? "Готовим конфигурацию…").font(.system(.footnote, design: .monospaced)).textSelection(.enabled).padding(20) }
            .background(SvoiPalette.canvas).navigationTitle("Конфигурация").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { showingConfig = false } } }
        }
      }
      .onDisappear { cancelBatch() }
      .onChange(of: scenePhase) { if $0 != .active { cancelBatch() } }
  }

  private var probeBar: some View {
    VStack(alignment: .leading, spacing: 10) {
      if vpn.active { Text("Для сравнения серверов сначала отключите VPN.").font(.footnote).foregroundStyle(SvoiPalette.muted) }
      if checkingAll { ProgressView(value: Double(checked), total: Double(max(1, batchCount))).tint(accent) }
      HStack {
        Text(checkingAll ? "\(checked) из \(batchCount)" : "Через профиль · GET").font(.caption).foregroundStyle(SvoiPalette.muted)
        Spacer(minLength: 8)
        Button { checkingAll ? cancelBatch() : startBatch() } label: {
          Label(checkingAll ? "Остановить" : "Проверить задержку", systemImage: checkingAll ? "stop.circle" : "waveform.path.ecg")
            .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
        }.disabled(vpn.busy || vpn.active || filtered.isEmpty)
      }
    }.padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 4).background(SvoiPalette.canvas)
      .overlay(alignment: .top) { Rectangle().fill(SvoiPalette.line).frame(height: 1) }
  }

  private func row(_ server: SvoiServer) -> some View {
    let selected = server.id == model.selectedID
    return VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .center, spacing: 8) {
        Button {
          model.selectedID = server.id
          onSelect()
        } label: {
          HStack(spacing: 12) {
            ServerFlag(name: server.name)
            VStack(alignment: .leading, spacing: 5) {
              Text(displayServerName(server.name)).font(.headline).foregroundStyle(SvoiPalette.text).fixedSize(horizontal: false, vertical: true)
              Text(server.kind + (selected ? " · Выбран" : ""))
                .font(.caption).foregroundStyle(selected ? accent : SvoiPalette.muted)
            }
            Spacer(minLength: 0)
            if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(accent) }
          }.frame(minHeight: 52).contentShape(Rectangle())
        }.buttonStyle(SvoiPressStyle()).accessibilityIdentifier("server-\(server.id)")
        Menu {
          Button { showConfig(server) } label: { Label("Конфигурация", systemImage: "curlybraces") }
          Button { Task { await model.probe(server) } } label: { Label("Проверить задержку", systemImage: "waveform.path.ecg") }
            .disabled(vpn.active || vpn.busy || model.checking.count >= 2)
        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle()).foregroundStyle(SvoiPalette.muted) }
          .accessibilityLabel("Действия: \(displayServerName(server.name))")
      }
      HStack {
        Text(server.detail).font(.caption).foregroundStyle(SvoiPalette.muted).lineLimit(sizeCategory.isAccessibilityCategory ? nil : 2)
        Spacer(minLength: 4)
        Button { Task { await model.probe(server) } } label: {
          if model.checking.contains(server.id) { ProgressView().frame(minWidth: 76, minHeight: 44) }
          else { Text(model.latencies[server.id] ?? "Проверить").font(.caption.weight(.medium)).monospacedDigit().frame(minWidth: 76, minHeight: 44) }
        }.disabled(model.checking.contains(server.id) || model.checking.count >= 2 || vpn.busy || vpn.active)
          .accessibilityLabel("Задержка \(server.name): \(model.latencies[server.id] ?? "не проверена")")
      }
    }.padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
      .background(selected ? accent.opacity(0.09) : SvoiPalette.surface, in: RoundedRectangle(cornerRadius: 20))
      .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(selected ? accent.opacity(0.55) : .clear))
  }

  private func sourceHeader(_ source: SvoiSource) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(source.name).font(.headline)
        Spacer(minLength: 4)
        if source.remote {
          Button { Task { await model.refreshSubscriptions() } } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }
            .disabled(model.working).accessibilityLabel("Обновить подписки")
        }
      }
      if let download = source.metadata["download"] as? NSNumber {
        let used = download.int64Value + ((source.metadata["upload"] as? NSNumber)?.int64Value ?? 0)
        let total = (source.metadata["total"] as? NSNumber)?.int64Value ?? 0
        let amount = ByteCountFormatter.string(fromByteCount: used, countStyle: .binary)
        Text(total > 0 ? "\(amount) из \(ByteCountFormatter.string(fromByteCount: total, countStyle: .binary))" : "Использовано \(amount) · без лимита")
          .font(.caption).foregroundStyle(SvoiPalette.muted)
        if total > 0 { ProgressView(value: min(1, max(0, Double(used) / Double(total)))).tint(accent) }
      }
      if let expire = source.metadata["expire"] as? NSNumber, expire.doubleValue > 0 {
        Text("До \(Date(timeIntervalSince1970: expire.doubleValue).formatted(date: .numeric, time: .omitted))").font(.caption).foregroundStyle(SvoiPalette.muted)
      }
      if let message = source.metadata["announcement"] as? String, !message.isEmpty { Text(message).font(.caption).foregroundStyle(SvoiPalette.muted) }
    }.padding(.horizontal, 6).padding(.bottom, 4)
  }

  private func latency(_ server: SvoiServer) -> Int {
    Int((model.latencies[server.id] ?? "").split(separator: " ").first ?? "") ?? Int.max
  }

  private func showConfig(_ server: SvoiServer) {
    config = nil
    showingConfig = true
    Task {
      do { config = try await model.configuration(server) }
      catch { config = error.localizedDescription }
    }
  }

  private func startBatch() {
    let servers = filtered
    checked = 0
    batchCount = servers.count
    checkingAll = true
    batch = Task {
      defer { checkingAll = false; batch = nil }
      for index in stride(from: 0, to: servers.count, by: 2) {
        if Task.isCancelled { break }
        async let first: Void = model.probe(servers[index])
        async let second: Void = index + 1 < servers.count ? model.probe(servers[index + 1]) : ()
        _ = await (first, second)
        if !Task.isCancelled { checked = min(index + 2, servers.count) }
      }
    }
  }

  private func cancelBatch() { batch?.cancel(); model.cancelProbes() }
}
