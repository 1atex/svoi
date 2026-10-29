import SwiftUI
import UIKit

struct ConnectionScreen: View {
  @Environment(\.svoiColors) private var colors
  @Environment(\.svoiAccent) private var accent
  @Environment(\.sizeCategory) private var sizeCategory
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ObservedObject var model: SvoiModel
  @ObservedObject var vpn: VPNController
  let add: (Bool) -> Void
  @State private var details = false
  @State private var focusServers = false
  @State private var focusConnection = false
  private var switching: Bool { vpn.connected && model.selected != nil && vpn.serverID != model.selectedID }
  private var busy: Bool { model.preparingVPN || vpn.busy }
  private var title: String { model.preparingVPN ? "Готовим подключение…" : vpn.title }

  var body: some View {
    ScrollViewReader { proxy in
      ServerList(model: model, vpn: vpn, onSelect: { focusConnection.toggle() }, onImport: { add(false) }, header: AnyView(introduction.id("connection")))
        .onChange(of: focusServers) { _ in
          withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            proxy.scrollTo("subscription-list", anchor: .top)
          }
        }
        .onChange(of: focusConnection) { _ in
          withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            proxy.scrollTo("connection", anchor: .top)
          }
        }
    }
    .background(colors.canvas).toolbar(.hidden, for: .navigationBar)
    .safeAreaInset(edge: .top, spacing: 0) {
      HStack(spacing: 9) {
        SvoiBrandMark(size: 32)
        (Text("svoi").foregroundColor(SvoiPalette.text) + Text("·").foregroundColor(accent))
          .font(.system(size: 25, weight: .bold, design: .rounded)).accessibilityLabel("SVOI")
        Spacer()
        SvoiIconButton(symbol: "plus", label: "Добавить подписку") { add(false) }
          .accessibilityIdentifier("add-subscription").disabled(model.working)
      }.padding(.horizontal, 20).padding(.vertical, 4).background(colors.canvas)
    }
    .sheet(isPresented: $details) {
      NavigationStack {
        ScrollView {
          VStack(spacing: 16) {
            SvoiNotice(text: "Все приложения используют VPN. Маршруты из конфигурации подписки сохраняются.", symbol: "shield.lefthalf.filled", warning: false)
            ConnectionTools(vpn: vpn)
          }.padding(20)
        }.background(colors.canvas).navigationTitle("Соединение").navigationBarTitleDisplayMode(.inline)
          .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { details = false } } }
      }
    }
  }

  @ViewBuilder private var introduction: some View {
    if model.servers.isEmpty && !vpn.active { welcome }
    else { connection }
  }

  private var connection: some View {
    VStack(spacing: 12) {
      HStack(alignment: .center, spacing: 20) {
        if !sizeCategory.isAccessibilityCategory {
          VStack(alignment: .leading, spacing: 8) {
            SvoiSectionTitle(title: "Ваша сеть")
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(SvoiPalette.text)
              .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("vpn-status")
            Text(switching ? "Выбран новый сервер" : busy ? "Нажмите, чтобы отменить" : vpn.connected ? "Все приложения · VPN" : "Нажмите, чтобы подключиться")
              .font(.footnote).foregroundStyle(SvoiPalette.muted).fixedSize(horizontal: false, vertical: true)
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
        power
      }
      if sizeCategory.isAccessibilityCategory {
        Text(title).font(.title2.bold()).foregroundStyle(SvoiPalette.text)
          .multilineTextAlignment(.center).accessibilityIdentifier("vpn-status")
      }
      Button { focusServers.toggle() } label: {
        HStack(spacing: 12) {
          ServerFlag(name: model.selected?.name ?? "", size: 40)
          VStack(alignment: .leading, spacing: 4) {
            Text(displayServerName(model.selected?.name ?? "Текущее соединение"))
              .font(.headline).foregroundStyle(SvoiPalette.text).lineLimit(2)
            Text(switching ? "Нажмите «Переключить»" : "\(model.selected?.kind ?? "VPN") · Выбранный сервер")
              .font(.caption).foregroundStyle(switching ? accent : SvoiPalette.muted)
          }.frame(maxWidth: .infinity, alignment: .leading)
          SvoiGlyph("chevron.down", size: 14).foregroundStyle(SvoiPalette.muted)
        }.padding(12).background(colors.surface, in: RoundedRectangle(cornerRadius: 16))
      }.buttonStyle(SvoiPressStyle()).accessibilityIdentifier("selected-server")
      HStack {
        if switching {
          Button("Отключить текущий VPN") {
            Task { do { try await vpn.disconnect() } catch { model.error = error.localizedDescription } }
          }.font(.footnote).frame(minHeight: 44).disabled(busy)
        } else {
          SvoiLabel("Все приложения", systemImage: "shield.lefthalf.filled")
            .font(.caption).foregroundStyle(SvoiPalette.muted)
        }
        Spacer(minLength: 8)
        Button { details = true } label: {
          SvoiLabel("Подробнее", systemImage: "info.circle").font(.footnote.weight(.medium)).frame(minHeight: 44)
        }.accessibilityIdentifier("connection-details")
      }
      if !vpn.error.isEmpty { SvoiNotice(text: vpn.error, symbol: "exclamationmark.circle") }
    }.padding(.top, 4).padding(.bottom, 8)
  }

  private var power: some View {
    Button {
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
      Task { await model.toggleVPN() }
    } label: {
      ZStack {
        Circle().stroke(accent.opacity(vpn.connected ? 0.5 : 0.16), lineWidth: 1)
        Circle().fill(vpn.connected ? accent : accent.opacity(0.12)).padding(10)
        Circle().stroke(accent.opacity(0.8), lineWidth: 1).padding(10)
        VStack(spacing: 8) {
          if busy { ProgressView().tint(vpn.connected ? colors.canvas : accent) }
          else { SvoiGlyph(switching ? "arrow.triangle.2.circlepath" : "power", size: 31) }
          Text(busy ? "Отменить" : switching ? "Переключить" : vpn.active ? "Отключить" : "Подключить")
            .font(.caption2.weight(.semibold)).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .lineLimit(1).minimumScaleFactor(0.75)
        }.foregroundStyle(vpn.connected ? colors.canvas : accent).frame(width: 106)
      }.frame(width: 140, height: 140).contentShape(Circle())
    }.buttonStyle(SvoiPressStyle()).accessibilityIdentifier("vpn-toggle")
      .accessibilityLabel(busy ? "Отменить подключение" : switching ? "Переключить VPN на выбранный сервер" : vpn.active ? "Отключить VPN" : "Подключить VPN")
      .disabled(model.selected == nil && !vpn.active)
  }

  private var welcome: some View {
    SvoiCard {
      VStack(alignment: .leading, spacing: 20) {
        Text("Ваша сеть.\nВ одном месте.").font(.system(.largeTitle, design: .rounded).weight(.bold)).foregroundStyle(SvoiPalette.text)
        Text("Вставьте ссылку на подписку или перенесите профиль с другого устройства.")
          .font(.body).foregroundStyle(SvoiPalette.muted).fixedSize(horizontal: false, vertical: true)
        Button { add(false) } label: { SvoiLabel("Добавить подписку", systemImage: "plus") }
          .buttonStyle(SvoiPrimaryButton()).accessibilityIdentifier("welcome-import")
        Button { add(true) } label: { SvoiLabel("Вставить код SVOI", systemImage: "doc.on.clipboard") }
          .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, minHeight: 48)
      }
    }.padding(.vertical, 20)
  }
}
