import SwiftUI
import UIKit

struct DNSToolScreen: View {
  @ObservedObject var vpn: VPNController
  @StateObject private var state = DNSCheckState()
  @State private var providers = DNSProvider.load()
  @State private var copied = ""
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.svoiColors) private var colors
  @Environment(\.svoiAccent) private var accent
  private var sorted: [DNSMeasurement] {
    state.results.sorted { a, b in
      if a.reliable != b.reliable { return a.reliable }
      return (a.median ?? .infinity) < (b.median ?? .infinity)
    }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Text("Сравниваем время ответа DNS по UDP: шесть запросов к каждому адресу, до трёх адресов одновременно.").foregroundStyle(SvoiPalette.muted)
        SvoiNotice(text: "DNS переводит имена сайтов в IP-адреса. Быстрый отклик не означает более высокую скорость скачивания. Настройки устройства не меняются.", warning: false)
        if vpn.active || vpn.busy { SvoiNotice(text: "Отключите VPN для сравнения DNS вашей сети. Туннель может перенаправлять DNS-запросы и искажать результат.") }
        Text("Проверено: \(state.results.count) из \(providers.count)").font(.footnote).foregroundStyle(SvoiPalette.muted)
        if state.working { ProgressView(value: Double(state.results.count), total: Double(max(1, providers.count))).tint(accent) }
        ForEach(sorted) { value in
          SvoiCard {
            VStack(alignment: .leading, spacing: 12) {
              Text(value.provider.name).font(.headline)
              Text(value.provider.address).font(.subheadline).foregroundStyle(SvoiPalette.muted).textSelection(.enabled)
              if let median = value.median {
                Text(String(format: "%.1f мс", median)).font(.title2.weight(.semibold)).monospacedDigit()
                Text("Медиана · ответов \(value.samples.count)/6").font(.caption).foregroundStyle(SvoiPalette.muted)
              } else { Text("Нет ответа").foregroundStyle(SvoiPalette.warning) }
              if value.id == sorted.first(where: \.reliable)?.id { SvoiLabel("Лучший полный результат этого теста", systemImage: "checkmark.circle").font(.footnote).foregroundStyle(SvoiPalette.success) }
              Button {
                UIPasteboard.general.string = value.provider.address
                copied = value.id
              } label: { SvoiLabel(copied == value.id ? "Адрес скопирован" : "Скопировать адрес", systemImage: copied == value.id ? "checkmark" : "doc.on.doc") }.frame(minHeight: 44)
            }
          }
        }
        if providers.isEmpty { SvoiNotice(text: "Не удалось загрузить список DNS. Переустановите приложение целиком.") }
      }.padding(20).frame(maxWidth: 600).frame(maxWidth: .infinity)
    }.background(colors.canvas).navigationTitle("Сравнить DNS").navigationBarTitleDisplayMode(.inline)
      .safeAreaInset(edge: .bottom) {
        Button { state.working ? state.stop() : state.start(providers) } label: { SvoiLabel(state.working ? "Остановить проверку" : "Сравнить DNS", systemImage: state.working ? "stop.circle" : "waveform.path.ecg") }
          .buttonStyle(SvoiPrimaryButton()).disabled(!state.working && (vpn.active || vpn.busy || providers.isEmpty))
          .padding(20).background(colors.canvas).accessibilityIdentifier("dns-start")
      }
      .onDisappear { state.stop() }
      .onChange(of: scenePhase) { if $0 != .active { state.stop() } }
      .onChange(of: vpn.status) { _ in state.stop(clear: true) }
  }
}

struct SiteToolScreen: View {
  @ObservedObject var vpn: VPNController
  @StateObject private var state = SiteCheckState()
  @State private var input = ""
  @FocusState private var editing: Bool
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.svoiColors) private var colors

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Text("Проверка сайта по текущему подключению.").foregroundStyle(SvoiPalette.muted)
        SvoiLabel(vpn.connected ? "VPN включён · маршрутизация профиля" : "SVOI отключён · текущая сеть iPhone", systemImage: vpn.connected ? "shield.lefthalf.filled" : "wifi")
          .font(.footnote).foregroundStyle(SvoiPalette.muted)
        SvoiCard {
          VStack(alignment: .leading, spacing: 14) {
            Text("Адрес сайта").font(.subheadline.weight(.semibold))
            TextField("https://example.com", text: $input).keyboardType(.URL).textContentType(.URL)
              .textInputAutocapitalization(.never).autocorrectionDisabled().focused($editing)
              .padding(14).background(colors.inset, in: RoundedRectangle(cornerRadius: 14)).accessibilityIdentifier("site-url")
            Button {
              editing = false
              if state.working { state.stop() } else { state.start(input) }
            } label: { SvoiLabel(state.working ? "Остановить" : "Проверить сайт", systemImage: state.working ? "stop.circle" : "arrow.up.right") }
              .buttonStyle(SvoiPrimaryButton()).disabled(!state.working && (input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vpn.busy))
          }
        }
        if state.working { ProgressView("Ждём ответ сайта…") }
        if !state.result.isEmpty { SvoiNotice(text: state.result, symbol: "checkmark.circle", warning: false) }
        if !state.error.isEmpty { SvoiNotice(text: state.error, symbol: "exclamationmark.circle") }
        Text("Проверяются заголовки HTTPS, без скачивания страницы. Ответ сайта приложению может отличаться от ответа браузеру. Чтобы сравнить режимы, повторите проверку с VPN и без него.")
          .font(.footnote).foregroundStyle(SvoiPalette.muted)
      }.padding(20).frame(maxWidth: 560).frame(maxWidth: .infinity)
    }.background(colors.canvas).navigationTitle("Проверить сайт").navigationBarTitleDisplayMode(.inline)
      .scrollDismissesKeyboard(.interactively)
      .onDisappear { state.stop() }
      .onChange(of: scenePhase) { if $0 != .active { state.stop() } }
      .onChange(of: vpn.status) { _ in state.stop(clear: true) }
  }
}
