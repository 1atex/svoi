import SwiftUI
import UniformTypeIdentifiers

struct ServerList: View {
  @Environment(\.svoiColors) private var colors
  @ObservedObject var model: SvoiModel
  @ObservedObject var vpn: VPNController
  let onSelect: () -> Void
  let onImport: () -> Void
  var header: AnyView? = nil
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.svoiAccent) private var accent
  @Environment(\.sizeCategory) private var sizeCategory
  @State private var search = ""
  @State private var draggingSource: String?
  @State private var batchSourceID: String?
  @State private var byLatency = false
  @State private var config: String?
  @State private var showingConfig = false
  @State private var batch: Task<Void, Never>?
  @State private var checkingAll = false
  @State private var checked = 0
  @State private var batchCount = 0
  @State private var batchGeneration = UUID()
  @State private var collapsed = Set<String>()
  @State private var removing: SvoiSource?
  @State private var confirmingRemoval = false

  private var filtered: [SvoiServer] {
    let result = model.servers.filter { search.isEmpty || "\($0.name) \($0.kind) \($0.detail)".localizedCaseInsensitiveContains(search) }
    return byLatency ? result.sorted { latency($0) < latency($1) } : result
  }

  var body: some View {
    ScrollView {
        LazyVStack(alignment: .leading, spacing: 6) {
          if let header = header { header.id("connection") }
          if !model.error.isEmpty { SvoiNotice(text: model.error, symbol: "exclamationmark.circle") }
          if !model.sources.isEmpty || !model.servers.isEmpty {
            subscriptionHeading.id("subscription-list")
            HStack(spacing: 10) {
              SvoiGlyph("magnifyingglass", size: 18).foregroundStyle(SvoiPalette.muted)
              TextField("Сервер или протокол", text: $search).textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("server-search")
              if !search.isEmpty { SvoiIconButton(symbol: "xmark.circle.fill", label: "Очистить поиск") { search = "" } }
            }.padding(.horizontal, 12).frame(minHeight: 44)
              .background(colors.surface, in: RoundedRectangle(cornerRadius: 12))
          }
          if model.servers.isEmpty && model.sources.isEmpty && header == nil {
            SvoiCard {
              VStack(alignment: .leading, spacing: 16) {
                SvoiGlyph("square.stack.3d.up", size: 34).foregroundStyle(accent)
                Text("Здесь будут ваши серверы").font(.title2.bold())
                Text("Добавьте подписку или импортируйте профиль SVOI.").foregroundStyle(SvoiPalette.muted)
                Button("Добавить подписку", action: onImport).buttonStyle(SvoiPrimaryButton())
              }
            }
          } else if filtered.isEmpty && !search.isEmpty {
            VStack(spacing: 12) {
              SvoiGlyph("magnifyingglass", size: 28).foregroundStyle(SvoiPalette.muted)
              Text("Ничего не найдено").font(.headline)
              Button("Очистить поиск") { search = "" }.frame(minHeight: 44)
            }.frame(maxWidth: .infinity).padding(.vertical, 36)
          } else {
            if byLatency { ForEach(filtered) { row($0) } }
            else {
              let groups = Dictionary(grouping: filtered, by: \.subscriptionID)
              ForEach(model.sources) { source in
                let servers = groups[source.id] ?? []
                if search.isEmpty || !servers.isEmpty {
                  sourceHeader(source).padding(.top, 6)
                    .onDrop(of: [UTType.text], delegate: SubscriptionOrderDrop(model: model, target: source.id, dragging: $draggingSource))
                  if !collapsed.contains(source.id) || !search.isEmpty {
                    ForEach(servers) { row($0) }
                  }
                }
              }
              let ungrouped = filtered.filter { server in !model.sources.contains { $0.id == server.subscriptionID } }
              if !ungrouped.isEmpty {
                SvoiSectionTitle(title: "Конфигурации").padding(.top, 12)
                ForEach(ungrouped) { row($0) }
              }
            }
          }
        }.padding(.horizontal, 16).padding(.bottom, 16).frame(maxWidth: 600).frame(maxWidth: .infinity)
      }.scrollDismissesKeyboard(.interactively)
        .refreshable { await model.refreshSubscriptions() }
      .background(colors.canvas)
      .safeAreaInset(edge: .bottom, spacing: 0) { if checkingAll { probeBar } }
      .sheet(isPresented: $showingConfig) {
        NavigationStack {
          ScrollView { Text(config ?? "Готовим конфигурацию…").font(.system(.footnote, design: .monospaced)).textSelection(.enabled).padding(20) }
            .background(colors.canvas).navigationTitle("Конфигурация").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { showingConfig = false } } }
        }
      }
      .onDisappear { cancelBatch() }
      .onChange(of: scenePhase) { if $0 != .active { cancelBatch() } }
      .onAppear { restoreCollapsed() }
      .onChange(of: collapsed) { value in
        UserDefaults.standard.set(value.sorted(), forKey: "collapsedSubscriptions:\(model.profileID)")
      }
      .onChange(of: model.profileID) { _ in cancelBatch(); restoreCollapsed(); removing = nil; draggingSource = nil }
      .onChange(of: vpn.active) { if $0 { cancelBatch() } }
      .onChange(of: model.preparingVPN) { if $0 { cancelBatch() } }
      .alert("Удалить подписку?", isPresented: $confirmingRemoval) {
        Button("Удалить подписку", role: .destructive) {
          guard let source = removing else { return }
          cancelBatch()
          Task { await model.removeSubscription(source); removing = nil }
        }
        Button("Отмена", role: .cancel) { removing = nil }
      } message: {
        Text("Подписка «\(removing?.name ?? "")» и её серверы будут удалены из текущего профиля. Если через неё работает VPN, он будет отключён. У провайдера подписка останется.")
      }
  }

  private var subscriptionHeading: some View {
    Group {
      if sizeCategory.isAccessibilityCategory {
        VStack(alignment: .leading, spacing: 4) {
          Text("Подписки").font(.title3.weight(.semibold)).foregroundStyle(SvoiPalette.text)
          HStack { subscriptionControls; Spacer(minLength: 0) }
        }
      } else {
        HStack {
          Text("Подписки").font(.title3.weight(.semibold)).foregroundStyle(SvoiPalette.text)
          Spacer(minLength: 8)
          subscriptionControls
        }
      }
    }
  }

  @ViewBuilder private var subscriptionControls: some View {
              Button { checkingAll ? cancelBatch() : startBatch() } label: {
                SvoiLabel(checkingAll ? "Стоп" : "Пинг", systemImage: checkingAll ? "stop.circle" : "waveform.path.ecg")
                  .font(.footnote.weight(.medium)).frame(minHeight: 44)
              }.disabled(vpn.busy || vpn.active || model.preparingVPN || filtered.isEmpty)
                .accessibilityLabel(checkingAll ? "Остановить проверку задержки" : "Проверить задержку серверов")
                .accessibilityIdentifier("servers-probe")
              Menu {
                Button(byLatency ? "Порядок из подписки" : "Сортировать по задержке") { byLatency.toggle() }
                Button(model.sources.allSatisfy { collapsed.contains($0.id) } ? "Развернуть все подписки" : "Свернуть все подписки") {
                  let ids = Set(model.sources.map(\.id))
                  collapsed = ids.isSubset(of: collapsed) ? [] : ids
                }.accessibilityIdentifier("subscriptions-collapse-all")
              } label: {
                SvoiGlyph("ellipsis", size: 18).frame(width: 44, height: 44).contentShape(Rectangle())
              }.accessibilityLabel("Сортировка и подписки")
  }

  private var probeBar: some View {
    VStack(alignment: .leading, spacing: 10) {
      if vpn.active { Text("Для сравнения серверов сначала отключите VPN.").font(.footnote).foregroundStyle(SvoiPalette.muted) }
      if checkingAll { ProgressView(value: Double(checked), total: Double(max(1, batchCount))).tint(accent) }
      HStack {
        Text(checkingAll ? "\(checked) из \(batchCount)" : "Через профиль · GET").font(.caption).foregroundStyle(SvoiPalette.muted)
        Spacer(minLength: 8)
        Button { checkingAll ? cancelBatch() : startBatch() } label: {
          SvoiLabel(checkingAll ? "Остановить" : "Проверить задержку", systemImage: checkingAll ? "stop.circle" : "waveform.path.ecg")
            .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
        }.disabled(vpn.busy || vpn.active || filtered.isEmpty)
      }
    }.padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 4).background(colors.canvas)
      .overlay(alignment: .top) { Rectangle().fill(colors.line).frame(height: 1) }
  }

  private func row(_ server: SvoiServer) -> some View {
    let selected = server.id == model.selectedID
    return HStack(spacing: 0) {
      Button {
        model.selectedID = server.id
        onSelect()
      } label: {
        HStack(spacing: 10) {
          ServerFlag(name: server.name, size: 36)
          VStack(alignment: .leading, spacing: 4) {
            Text(displayServerName(server.name)).font(.subheadline.weight(.semibold))
              .foregroundStyle(SvoiPalette.text).multilineTextAlignment(.leading)
              .lineLimit(sizeCategory.isAccessibilityCategory ? nil : 2)
            Text(([server.kind, server.detail].filter { !$0.isEmpty }).joined(separator: " · "))
              .font(.caption).foregroundStyle(SvoiPalette.muted)
              .multilineTextAlignment(.leading).lineLimit(sizeCategory.isAccessibilityCategory ? nil : 2)
          }.frame(maxWidth: .infinity, alignment: .leading)
          if selected { SvoiGlyph("checkmark.circle.fill", size: 18).foregroundStyle(accent) }
        }.padding(.leading, 12).padding(.vertical, 12).frame(minHeight: 66).contentShape(Rectangle())
      }.buttonStyle(SvoiPressStyle()).accessibilityIdentifier("server-\(server.id)")
        .accessibilityAddTraits(selected ? .isSelected : [])
      Button { Task { await model.probe(server) } } label: {
        Group {
          if model.checking.contains(server.id) { ProgressView().controlSize(.small) }
          else if let result = model.latencies[server.id] { Text(result).font(.caption).monospacedDigit() }
          else { SvoiGlyph("waveform.path.ecg", size: 18) }
        }.frame(minWidth: 44, minHeight: 44)
      }.buttonStyle(SvoiPressStyle()).foregroundStyle(SvoiPalette.muted)
        .disabled(model.checking.contains(server.id) || checkingAll || vpn.busy || vpn.active || model.preparingVPN)
        .accessibilityLabel("Проверить задержку \(displayServerName(server.name))")
        .accessibilityIdentifier("server-probe-\(server.id)")
      Menu {
        Button { showConfig(server) } label: { SvoiLabel("Конфигурация", systemImage: "curlybraces") }
        Button { Task { await model.probe(server) } } label: { SvoiLabel("Проверить задержку", systemImage: "waveform.path.ecg") }
          .disabled(vpn.active || vpn.busy || model.checking.count >= 2)
      } label: {
        SvoiGlyph("ellipsis", size: 18).frame(width: 44, height: 54).contentShape(Rectangle()).foregroundStyle(SvoiPalette.muted)
      }.accessibilityLabel("Действия: \(displayServerName(server.name))")
    }.background(selected ? accent.opacity(0.09) : colors.surface, in: RoundedRectangle(cornerRadius: 14))
      .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? accent.opacity(0.55) : .clear))
  }

  private func sourceHeader(_ source: SvoiSource) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Group {
        if sizeCategory.isAccessibilityCategory {
          VStack(alignment: .leading, spacing: 4) { HStack { reorderHandle(source); sourceToggle(source) }; sourceActions(source) }
        } else {
          VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) { reorderHandle(source); sourceToggle(source) }
            HStack { Spacer(minLength: 0); sourceActions(source) }
          }
        }
      }
      if !source.statusText.isEmpty { Text(source.statusText).font(.caption2).foregroundStyle(SvoiPalette.muted) }
      if let download = source.metadata["download"] as? NSNumber {
        let used = download.int64Value + ((source.metadata["upload"] as? NSNumber)?.int64Value ?? 0)
        let total = (source.metadata["total"] as? NSNumber)?.int64Value ?? 0
        Text(total > 0 ? "\(ByteCountFormatter.string(fromByteCount: used, countStyle: .binary)) из \(ByteCountFormatter.string(fromByteCount: total, countStyle: .binary))" : "Использовано \(ByteCountFormatter.string(fromByteCount: used, countStyle: .binary)) · без лимита")
          .font(.caption).foregroundStyle(SvoiPalette.muted)
        if total > 0 { ProgressView(value: min(1, max(0, Double(used) / Double(total)))).tint(accent) }
      }
      if let expire = source.metadata["expire"] as? NSNumber, expire.doubleValue > 0 {
        Text("До \(Date(timeIntervalSince1970: expire.doubleValue).formatted(date: .numeric, time: .omitted))").font(.caption).foregroundStyle(SvoiPalette.muted)
      }
      if let message = source.metadata["announcement"] as? String, !message.isEmpty {
        Text(message).font(.caption).foregroundStyle(SvoiPalette.muted).fixedSize(horizontal: false, vertical: true)
      }
    }.padding(12).background(colors.surface, in: RoundedRectangle(cornerRadius: 16))
  }

  private func sourceToggle(_ source: SvoiSource) -> some View {
    Button {
      if collapsed.contains(source.id) { collapsed.remove(source.id) }
      else { collapsed.insert(source.id) }
    } label: {
      HStack(spacing: 8) {
        SvoiGlyph("chevron.down", size: 14).rotationEffect(.degrees(collapsed.contains(source.id) ? -90 : 0))
        Text(source.name).font(.headline).multilineTextAlignment(.leading).foregroundStyle(SvoiPalette.text)
        Text("\(source.count)").font(.caption).foregroundStyle(SvoiPalette.muted)
        Spacer(minLength: 0)
      }.frame(minHeight: 44).contentShape(Rectangle())
    }.buttonStyle(SvoiPressStyle()).accessibilityIdentifier("subscription-toggle-\(source.id)")
      .accessibilityLabel("\(collapsed.contains(source.id) ? "Развернуть" : "Свернуть") подписку \(source.name)")
      .accessibilityValue(collapsed.contains(source.id) ? "Свёрнута" : "Развёрнута")
  }

  private func reorderHandle(_ source: SvoiSource) -> some View {
    SvoiGlyph("line.3.horizontal", size: 18).foregroundStyle(SvoiPalette.muted)
      .frame(width: 44, height: 44).contentShape(Rectangle())
      .onDrag { draggingSource = source.id; return NSItemProvider(object: source.id as NSString) }
      .accessibilityLabel("Перетащить подписку \(source.name)")
  }

  private func sourceActions(_ source: SvoiSource) -> some View {
    HStack(spacing: 0) {
      Button {
        if checkingAll && batchSourceID == source.id { cancelBatch() }
        else { startBatch(sourceID: source.id) }
      } label: {
        SvoiLabel(checkingAll && batchSourceID == source.id ? "Стоп" : "Пинг", systemImage: checkingAll && batchSourceID == source.id ? "stop.circle" : "waveform.path.ecg")
          .font(.footnote).frame(minHeight: 44).padding(.horizontal, 8)
      }.disabled(vpn.busy || vpn.active || model.preparingVPN || (checkingAll && batchSourceID != source.id) || !model.servers.contains(where: { $0.subscriptionID == source.id }))
        .accessibilityLabel("Проверить задержку подписки \(source.name)")
        .accessibilityIdentifier("subscription-probe-\(source.id)")
      if source.remote {
        SvoiIconButton(symbol: "arrow.clockwise", label: "Обновить \(source.name)") {
          Task { await model.refreshSubscription(source) }
        }.disabled(model.working)
      }
      Menu {
        if let i = model.sources.firstIndex(where: { $0.id == source.id }) {
          Button("Выше") { model.moveSubscription(source.id, before: model.sources[i - 1].id) }.disabled(i == 0)
          Button("Ниже") { model.moveSubscription(source.id, before: model.sources[i + 1].id, after: true) }.disabled(i + 1 == model.sources.count)
        }
        if let text = source.metadata["supportUrl"] as? String, let url = URL(string: text), ["https", "tg"].contains(url.scheme?.lowercased() ?? "") {
          Link("Поддержка", destination: url)
        }
        Button("Удалить подписку", role: .destructive) { removing = source; confirmingRemoval = true }
          .disabled(model.working || vpn.busy || model.preparingVPN)
          .accessibilityIdentifier("subscription-delete-\(source.id)")
      } label: { SvoiGlyph("ellipsis", size: 18).frame(width: 44, height: 44) }
        .accessibilityLabel("Действия с подпиской \(source.name)")
        .accessibilityIdentifier("subscription-actions-\(source.id)")
    }
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

  private func startBatch(sourceID: String? = nil) {
    cancelBatch()
    let servers = sourceID.map { id in model.servers.filter { $0.subscriptionID == id } } ?? filtered
    guard !servers.isEmpty, !vpn.busy, !vpn.active, !model.preparingVPN else { return }
    batchSourceID = sourceID
    checked = 0
    batchCount = servers.count
    checkingAll = true
    let generation = UUID()
    batchGeneration = generation
    batch = Task {
      defer { if batchGeneration == generation { checkingAll = false; batch = nil; batchSourceID = nil } }
      for index in stride(from: 0, to: servers.count, by: 2) {
        if Task.isCancelled || batchGeneration != generation { break }
        async let first: Void = model.probe(servers[index])
        async let second: Void = index + 1 < servers.count ? model.probe(servers[index + 1]) : ()
        _ = await (first, second)
        if !Task.isCancelled && batchGeneration == generation { checked = min(index + 2, servers.count) }
      }
    }
  }

  private func restoreCollapsed() {
    collapsed = Set(UserDefaults.standard.stringArray(forKey: "collapsedSubscriptions:\(model.profileID)") ?? [])
  }

  private func cancelBatch() {
    batchGeneration = UUID()
    batch?.cancel()
    batch = nil
    checkingAll = false
    batchSourceID = nil
    model.cancelProbes()
  }
}

private struct SubscriptionOrderDrop: DropDelegate {
  let model: SvoiModel
  let target: String
  @Binding var dragging: String?

  func validateDrop(info: DropInfo) -> Bool { dragging != nil && dragging != target }
  func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
  func performDrop(info: DropInfo) -> Bool {
    guard let id = dragging else { return false }
    Task { @MainActor in
      guard let sourceIndex = model.sources.firstIndex(where: { $0.id == id }),
            let targetIndex = model.sources.firstIndex(where: { $0.id == target }) else { return }
      model.moveSubscription(id, before: target, after: sourceIndex < targetIndex)
    }
    dragging = nil
    return true
  }
}
