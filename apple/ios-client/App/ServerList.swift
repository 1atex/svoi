import SwiftUI

struct ServerList: View {
  @ObservedObject var model: SvoiModel
  @ObservedObject var vpn: VPNController
  let onSelect: () -> Void
  @Environment(\.scenePhase) private var scenePhase
  @State private var search = ""
  @State private var config: String?
  @State private var showingConfig = false
  @State private var batch: Task<Void, Never>?
  @State private var checkingAll = false
  var filtered: [SvoiServer] { model.servers.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.kind.localizedCaseInsensitiveContains(search) } }

  var body: some View {
    List {
      if model.servers.isEmpty { Text("Добавьте подписку кнопкой +").foregroundStyle(.secondary) }
      ForEach(model.sources) { source in
        Section(source.name) {
          ForEach(filtered.filter { $0.subscriptionID == source.id }) { server in row(server) }
        }
      }
      let ungrouped = filtered.filter { server in !model.sources.contains { $0.id == server.subscriptionID } }
      if !ungrouped.isEmpty { Section("Конфигурации") { ForEach(ungrouped) { server in row(server) } } }
    }
    .listStyle(.insetGrouped)
    .searchable(text: $search, prompt: "Название или протокол")
    .safeAreaInset(edge: .bottom) {
      HStack {
        Text("\(filtered.count) серверов").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button(checkingAll ? "Остановить проверку" : "Проверить задержку") {
          if checkingAll { cancelBatch() }
          else {
            let servers = filtered
            checkingAll = true
            batch = Task {
              defer { checkingAll = false; batch = nil }
              for index in stride(from: 0, to: servers.count, by: 2) {
                if Task.isCancelled { break }
                async let first: Void = model.probe(servers[index])
                async let second: Void = index + 1 < servers.count ? model.probe(servers[index + 1]) : ()
                _ = await (first, second)
              }
            }
          }
        }.font(.footnote).disabled(vpn.busy || filtered.isEmpty)
      }.padding(16).background(.bar)
    }
    .sheet(isPresented: $showingConfig) {
      NavigationStack {
        ScrollView { Text(config ?? "Готовим конфигурацию…").font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding() }
          .navigationTitle("Конфигурация")
          .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Закрыть") { showingConfig = false } } }
      }
    }
    .onDisappear { cancelBatch() }
    .onChange(of: scenePhase) { if $0 != .active { cancelBatch() } }
  }

  private func row(_ server: SvoiServer) -> some View {
    HStack(spacing: 12) {
      Button {
        model.selectedID = server.id
        onSelect()
      } label: {
        HStack(spacing: 12) {
          Text(flag(server.name)).font(.title2)
          VStack(alignment: .leading, spacing: 5) {
            Text(server.name).foregroundStyle(.primary).font(.headline)
            Text("\(server.kind) · \(server.detail)").foregroundStyle(.secondary).font(.caption)
          }
          Spacer(minLength: 0)
          if server.id == model.selectedID { Image(systemName: "checkmark.circle.fill") }
        }.contentShape(Rectangle())
      }.buttonStyle(.plain)
      Button { Task { await model.probe(server) } } label: {
        if model.checking.contains(server.id) { ProgressView() }
        else { Text(model.latencies[server.id] ?? "Пинг").font(.caption).frame(minWidth: 44) }
      }.buttonStyle(.borderless).disabled(model.checking.contains(server.id) || model.checking.count >= 2 || vpn.busy)
    }
    .padding(.vertical, 5)
    .contextMenu {
      Button {
        showingConfig = true
        config = nil
        Task {
          do { config = try await model.configuration(server) }
          catch { config = error.localizedDescription }
        }
      } label: { Label("Посмотреть конфигурацию", systemImage: "curlybraces") }
    }
  }

  private func cancelBatch() {
    batch?.cancel()
    model.cancelProbes()
  }
}
