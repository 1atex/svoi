import SwiftUI
import Charts

struct ToolsScreen: View {
  @ObservedObject var model: SvoiModel
  @ObservedObject var vpn: VPNController
  @Environment(\.svoiColors) private var colors
  @Environment(\.svoiAccent) private var accent

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("Понятные проверки вашей сети.").foregroundStyle(SvoiPalette.muted).padding(.bottom, 8)
        NavigationLink { SpeedToolScreen(model: model, vpn: vpn) } label: {
          tool("Интернетометр", detail: "Без VPN и через выбранные серверы", symbol: "speedometer")
        }.accessibilityIdentifier("tool-speed")
        NavigationLink { SiteToolScreen(vpn: vpn) } label: {
          tool("Проверить сайт", detail: "Ответ сайта в текущем подключении", symbol: "globe")
        }.accessibilityIdentifier("tool-site")
        NavigationLink { DNSToolScreen(vpn: vpn) } label: {
          tool("Сравнить DNS", detail: "12 адресов · отклик и стабильность", symbol: "point.3.connected.trianglepath.dotted")
        }.accessibilityIdentifier("tool-dns")
        SvoiNotice(text: "Проверки выполняются по запросу. Скорость измеряется до узла svoi.space; DNS-тест не меняет настройки устройства.", warning: false)
      }.padding(20).frame(maxWidth: 560).frame(maxWidth: .infinity)
    }.background(colors.canvas)
  }

  private func tool(_ title: String, detail: String, symbol: String) -> some View {
    SvoiCard {
      HStack(spacing: 14) {
        SvoiGlyph(symbol, size: 22).foregroundStyle(accent)
          .frame(width: 48, height: 48).background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
        VStack(alignment: .leading, spacing: 7) {
          Text(title).font(.headline).foregroundStyle(SvoiPalette.text)
          Text(detail).multilineTextAlignment(.leading).font(.footnote).foregroundStyle(SvoiPalette.muted)
        }
        Spacer(minLength: 0)
        SvoiGlyph("chevron.right", size: 12).foregroundStyle(SvoiPalette.muted)
      }
    }
  }
}

struct SpeedSample: Decodable { let seconds: Double; let mbps: Double }
struct SpeedRoute: Decodable, Identifiable {
  let serverId: String
  let name: String
  let `protocol`: String
  var state: String
  let phase: String?
  let error: String?
  let warning: String?
  let downloadMbps: Double?
  let uploadMbps: Double?
  let latencyMs: Double?
  let downloadSamples: [SpeedSample]?
  let uploadSamples: [SpeedSample]?
  var id: String { serverId.isEmpty ? "direct" : serverId }
  var title: String {
    if state == "done" { return "Готово" }
    if state == "error" { return "Не удалось измерить" }
    if state == "cancelled" { return "Остановлено" }
    if state == "queued" { return "В очереди" }
    switch phase {
    case "download": return "Измеряем загрузку…"
    case "upload": return "Измеряем отдачу…"
    case "latency": return "Проверяем отклик…"
    default: return "Готовим маршрут…"
    }
  }
}

@MainActor
final class SpeedToolState: ObservableObject {
  @Published var results: [SpeedRoute] = []
  @Published var working = false
  @Published var error = ""
  private var task: Task<Void, Never>?
  private var generation = 0
  private let model: SvoiModel
  init(model: SvoiModel) { self.model = model; results = model.lastSpeedResults }

  func start(_ ids: [String]) {
    guard !working, !model.vpn.active, !model.vpn.busy, !model.preparingVPN, ids.count <= 3 else { return }
    model.cancelProbes()
    error = ""
    working = true
    results = []
    generation += 1
    let own = generation
    let profile = model.profileID
    task = Task {
      do {
        #if SVOI_UI_PREVIEW
        let values: [[String: Any]] = [["serverId":"","name":"Без VPN","protocol":"Напрямую","state":"done","downloadMbps":80.2,"uploadMbps":42.1,"latencyMs":35.0]]
        results = try JSONDecoder().decode([SpeedRoute].self, from: JSONSerialization.data(withJSONObject: values))
        working = false
        return
        #else
        let started = try await model.toolsRequest("tools/speed/start", method: "POST", body: ["serverIds": ids])
        guard let id = started["id"] as? String else { throw SvoiError("Не удалось начать замер. Попробуйте ещё раз.") }
        guard own == generation, profile == model.profileID, !Task.isCancelled else {
          _ = try? await model.toolsRequest("tools/speed/cancel?id=\(id)", method: "POST")
          return
        }
        while !Task.isCancelled && own == generation {
          let data = try await model.toolsRequest("tools/speed/status?id=\(id)")
          guard own == generation, profile == model.profileID else { return }
          results = try JSONDecoder().decode([SpeedRoute].self, from: JSONSerialization.data(withJSONObject: data["results"] ?? []))
          model.lastSpeedResults = results
          if data["state"] as? String != "running" { working = false; return }
          try await Task.sleep(nanoseconds: 700_000_000)
        }
        #endif
      } catch is CancellationError {} catch {
        if own == generation { self.error = error.localizedDescription; working = false; SvoiCoreCancelSpeed() }
      }
    }
  }

  func stop(clear: Bool = false) {
    generation += 1
    task?.cancel()
    task = nil
    if working { SvoiCoreCancelSpeed() }
    working = false
    for index in results.indices where ["queued", "running"].contains(results[index].state) { results[index].state = "cancelled" }
    model.lastSpeedResults = results
    if clear { results = []; model.lastSpeedResults = [] }
  }
}

struct SpeedToolScreen: View {
  @ObservedObject var model: SvoiModel
  @ObservedObject var vpn: VPNController
  @StateObject private var state: SpeedToolState
  @State private var selected = Set<String>()
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.svoiColors) private var colors
  @Environment(\.svoiAccent) private var accent
  @Environment(\.sizeCategory) private var sizeCategory

  init(model: SvoiModel, vpn: VPNController) {
    self.model = model
    self.vpn = vpn
    _state = StateObject(wrappedValue: SpeedToolState(model: model))
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Text("Сравните прямое соединение и до трёх серверов. Все маршруты проверяются до одного узла: svoi.space.")
          .font(.subheadline).foregroundStyle(SvoiPalette.muted)
        if vpn.active || vpn.busy || model.preparingVPN {
          SvoiNotice(text: "Отключите VPN перед сравнением. SVOI проверит выбранные профили самостоятельно, без включения системного туннеля.")
        }
        SvoiSectionTitle(title: "Серверы для сравнения")
        SvoiCard {
          LazyVStack(spacing: 0) {
            SvoiLabel("Без VPN · включён в каждый тест", systemImage: "iphone").font(.footnote).foregroundStyle(SvoiPalette.muted).padding(.bottom, 16)
            ForEach(model.servers) { server in
              Button {
                if selected.contains(server.id) { selected.remove(server.id) }
                else if selected.count < 3 { selected.insert(server.id) }
              } label: {
                HStack(spacing: 12) {
                  ServerFlag(name: server.name, size: 36)
                  Text(displayServerName(server.name)).font(.subheadline).foregroundStyle(SvoiPalette.text)
                  Spacer(minLength: 4)
                  SvoiGlyph( selected.contains(server.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(selected.contains(server.id) ? accent : SvoiPalette.muted)
                }.frame(minHeight: 58).contentShape(Rectangle())
              }.buttonStyle(SvoiPressStyle()).disabled(state.working || (!selected.contains(server.id) && selected.count >= 3))
                .accessibilityAddTraits(selected.contains(server.id) ? .isSelected : [])
            }
          }
        }
        Text("До \((selected.count + 1) * 48) МиБ за сравнение · обычно 10–25 секунд на маршрут. Перед тестом отключите другие VPN-приложения.")
          .font(.footnote).foregroundStyle(SvoiPalette.muted)
        if !state.error.isEmpty { SvoiNotice(text: state.error, symbol: "exclamationmark.circle") }
        ForEach(state.results) { result in speedCard(result) }
      }.padding(20).frame(maxWidth: 600).frame(maxWidth: .infinity)
    }.background(colors.canvas).navigationTitle("Интернетометр").navigationBarTitleDisplayMode(.inline)
      .safeAreaInset(edge: .bottom) {
        Button {
          if state.working { state.stop() } else { state.start(Array(selected)) }
        } label: { SvoiLabel(state.working ? "Остановить замер" : "Сравнить скорость", systemImage: state.working ? "stop.circle" : "speedometer") }
          .buttonStyle(SvoiPrimaryButton()).disabled(!state.working && (vpn.active || vpn.busy || model.preparingVPN))
          .padding(.horizontal, 20).padding(.vertical, 12).background(colors.canvas).accessibilityIdentifier("speed-start")
      }
      .onAppear { if selected.isEmpty && model.selected != nil { selected.insert(model.selectedID) } }
      .onDisappear { state.stop() }
      .onChange(of: scenePhase) { if $0 != .active { state.stop() } }
      .onChange(of: vpn.status) { _ in state.stop() }
      .onChange(of: model.profileID) { _ in state.stop(clear: true); selected = [] }
      .onChange(of: model.servers.map(\.id)) { ids in selected.formIntersection(ids) }
  }

  private func speedCard(_ result: SpeedRoute) -> some View {
    SvoiCard {
      VStack(alignment: .leading, spacing: 16) {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 5) { Text(displayServerName(result.name)).font(.headline); Text(result.protocol).font(.caption).foregroundStyle(SvoiPalette.muted) }
          Spacer(minLength: 4)
          Text(result.title).font(.caption).foregroundStyle(result.state == "error" ? SvoiPalette.warning : SvoiPalette.muted)
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: sizeCategory.isAccessibilityCategory ? 220 : 120))], alignment: .leading, spacing: 16) {
          metric("Загрузка", value: result.downloadMbps, unit: "Мбит/с")
          metric("Отдача", value: result.uploadMbps, unit: "Мбит/с")
          metric("Отклик", value: result.latencyMs, unit: "мс")
        }
        if let samples = result.downloadSamples, samples.count > 1 {
          Chart {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
              LineMark(x: .value("Секунды", sample.seconds), y: .value("Мбит/с", sample.mbps)).foregroundStyle(accent)
            }
          }.chartYScale(domain: .automatic(includesZero: true)).frame(height: 110)
            .accessibilityLabel("График скорости загрузки, мегабит в секунду")
        }
        if let message = result.error, !message.isEmpty { SvoiNotice(text: message) }
        if let message = result.warning, !message.isEmpty { SvoiNotice(text: message, warning: false) }
      }
    }
  }

  private func metric(_ title: String, value: Double?, unit: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.caption).foregroundStyle(SvoiPalette.muted)
      Text(value.map { String(format: "%.1f", $0) } ?? "—").font(.title2.weight(.semibold)).monospacedDigit()
      Text(unit).font(.caption).foregroundStyle(SvoiPalette.muted)
    }
  }
}
