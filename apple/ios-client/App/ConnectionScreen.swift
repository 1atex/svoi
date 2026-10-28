import SwiftUI
import UIKit

struct ConnectionScreen: View {
  @ObservedObject var model: SvoiModel
  @ObservedObject var vpn: VPNController
  let openServers: () -> Void
  let add: (Bool) -> Void
  @Environment(\.svoiAccent) private var accent
  @Environment(\.sizeCategory) private var sizeCategory
  private var switching: Bool { vpn.connected && model.selected != nil && vpn.serverID != model.selectedID }
  private var busy: Bool { model.preparingVPN || vpn.busy }
  private var title: String { model.preparingVPN ? "Готовим подключение…" : vpn.title }

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        if !model.error.isEmpty {
          HStack(alignment: .top) {
            SvoiNotice(text: model.error, symbol: "exclamationmark.circle")
            SvoiIconButton(symbol: "xmark", label: "Закрыть ошибку") { model.error = "" }
          }
        }
        if model.servers.isEmpty && !vpn.active { welcome }
        else {
          connection
          ConnectionTools(vpn: vpn)
          Button(action: openServers) {
            SvoiCard {
              HStack(spacing: 14) {
                Image(systemName: "square.stack.3d.up").font(.title3).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 5) {
                  Text("Ваши подписки").font(.headline).foregroundStyle(SvoiPalette.text)
                  Text("Подписок: \(model.sources.count) · серверов: \(model.servers.count)").font(.footnote).foregroundStyle(SvoiPalette.muted)
                }
                Spacer(minLength: 4)
                if model.working { ProgressView().tint(accent) }
                else { Image(systemName: "chevron.right").font(.footnote).foregroundStyle(SvoiPalette.muted) }
              }
            }
          }.buttonStyle(SvoiPressStyle())
        }
      }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 24).frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }.background(SvoiPalette.canvas).toolbar(.hidden, for: .navigationBar)
      .safeAreaInset(edge: .top, spacing: 0) {
        HStack(spacing: 10) {
          SvoiBrandMark(size: 36)
          (Text("svoi").foregroundColor(SvoiPalette.text) + Text("·").foregroundColor(accent))
            .font(.system(size: 27, weight: .bold, design: .rounded))
            .accessibilityLabel("SVOI")
          Spacer()
          SvoiIconButton(symbol: "plus", label: "Добавить подписку") { add(false) }
            .background(SvoiPalette.surface, in: Circle()).disabled(model.working)
        }.padding(.horizontal, 20).padding(.vertical, 8).background(SvoiPalette.canvas)
      }
  }

  private var connection: some View {
    SvoiCard {
      VStack(spacing: 18) {
        Group {
          if sizeCategory.isAccessibilityCategory {
            VStack(alignment: .leading, spacing: 8) { cardTitle; coverage }
              .frame(maxWidth: .infinity, alignment: .leading)
          } else { HStack { cardTitle; Spacer(); coverage } }
        }
        Button(action: openServers) {
          Group {
            if sizeCategory.isAccessibilityCategory {
              VStack(alignment: .leading, spacing: 12) {
                HStack { ServerFlag(name: model.selected?.name ?? ""); Spacer(); serverChevron }
                selectedServerText
              }
            } else {
              HStack(spacing: 12) {
                ServerFlag(name: model.selected?.name ?? "")
                selectedServerText
                Spacer(minLength: 2)
                serverChevron
              }
            }
          }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(SvoiPalette.inset, in: RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(SvoiPressStyle()).accessibilityIdentifier("selected-server")

        Button {
          UIImpactFeedbackGenerator(style: .light).impactOccurred()
          Task { await model.toggleVPN() }
        } label: {
          ZStack {
            Circle().fill(RadialGradient(colors: [accent.opacity(vpn.connected ? 0.18 : 0.07), .clear], center: .center, startRadius: 35, endRadius: 90))
            Circle().stroke(accent.opacity(0.10), lineWidth: 1).padding(1)
            Circle().stroke(accent.opacity(0.22), lineWidth: 1).padding(16)
            Circle().fill(vpn.connected ? accent : accent.opacity(0.14)).padding(26)
            Circle().stroke(accent.opacity(0.9), lineWidth: 1.5).padding(26)
            VStack(spacing: 9) {
              if busy { ProgressView().tint(vpn.connected ? SvoiPalette.canvas : accent).scaleEffect(1.35) }
              else { Image(systemName: switching ? "arrow.triangle.2.circlepath" : "power").font(.system(size: 35, weight: .light)) }
              Text(busy ? "Отменить" : switching ? "Переключить" : vpn.active ? "Отключить" : "Подключить")
                .font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75)
            }.foregroundStyle(vpn.connected ? SvoiPalette.canvas : accent).frame(width: 126)
          }.frame(width: 180, height: 180).contentShape(Circle())
        }.buttonStyle(SvoiPressStyle()).accessibilityIdentifier("vpn-toggle")
          .accessibilityLabel(busy ? "Отменить подключение" : switching ? "Переключить VPN на выбранный сервер" : vpn.active ? "Отключить VPN" : "Подключить VPN")
          .disabled(model.selected == nil && !vpn.active)

        VStack(spacing: 8) {
          Text(title).font(.title2.weight(.bold)).foregroundStyle(SvoiPalette.text)
            .multilineTextAlignment(.center).accessibilityIdentifier("vpn-status")
          Text(busy ? "Можно отменить повторным нажатием." : switching ? "Выбран новый сервер. Нажмите «Переключить», чтобы подключиться к нему." : vpn.connected ? "Трафик направлен через VPN. IP и интернет можно проверить ниже." : "Один тап — и вы на связи.")
            .font(.footnote).foregroundStyle(SvoiPalette.muted).multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
          if switching {
            Button("Отключить текущий VPN") {
              Task { do { try await vpn.disconnect() } catch { model.error = error.localizedDescription } }
            }.font(.footnote.weight(.semibold)).frame(minHeight: 44).disabled(busy)
          }
        }
      }
    }
  }

  private var cardTitle: some View { SvoiSectionTitle(title: "Подключение") }
  private var coverage: some View {
    Label("Все приложения", systemImage: "shield.lefthalf.filled").font(.caption.weight(.medium)).foregroundStyle(SvoiPalette.muted)
  }
  private var serverChevron: some View {
    Image(systemName: "chevron.down").font(.subheadline.weight(.medium)).foregroundStyle(SvoiPalette.muted)
  }
  private var selectedServerText: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(displayServerName(model.selected?.name ?? (vpn.active ? "Текущее соединение" : "Выбрать сервер")))
        .font(.headline).foregroundStyle(SvoiPalette.text).fixedSize(horizontal: false, vertical: true)
      Text("\(model.selected?.kind ?? "") · Сменить сервер").font(.caption).foregroundStyle(SvoiPalette.muted)
    }
  }

  private var welcome: some View {
    SvoiCard {
      VStack(alignment: .leading, spacing: 24) {
        HStack { SvoiBrandMark(size: 56); Spacer(); Image(systemName: "sparkle").font(.title2).foregroundStyle(accent) }
        VStack(alignment: .leading, spacing: 12) {
          Text("Начнём с\nвашей подписки").font(.system(.largeTitle, design: .rounded).weight(.bold)).foregroundStyle(SvoiPalette.text)
          Text("Добавьте ссылку от VPN-провайдера или перенесите общий профиль с другого устройства.")
            .font(.body).foregroundStyle(SvoiPalette.muted).fixedSize(horizontal: false, vertical: true)
        }
        VStack(spacing: 12) {
          Button { add(false) } label: { Label("Добавить подписку", systemImage: "plus") }
            .buttonStyle(SvoiPrimaryButton()).accessibilityIdentifier("welcome-import")
          Button { add(true) } label: { Label("У меня есть код SVOI", systemImage: "person.2") }
            .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, minHeight: 48)
        }
        Label("Подписки хранятся на вашем устройстве", systemImage: "iphone")
          .font(.footnote).foregroundStyle(SvoiPalette.muted)
      }
    }
  }
}
