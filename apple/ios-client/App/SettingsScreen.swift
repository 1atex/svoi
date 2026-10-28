import SwiftUI
import UIKit

struct SettingsScreen: View {
  @ObservedObject var model: SvoiModel
  @AppStorage("appearance") private var appearance = "amber"
  @Environment(\.svoiAccent) private var accent
  @Environment(\.sizeCategory) private var sizeCategory
  private let themes = [("amber", "SVOI"), ("blue", "Лунная"), ("green", "Лесная")]

  var body: some View {
    Form {
      Section {
        VStack(alignment: .leading, spacing: 16) {
          Text("Ваш SVOI").font(.title3.bold())
          Text("Выберите акцент, который нравится вам.").font(.footnote).foregroundStyle(SvoiPalette.muted)
          LazyVGrid(columns: [GridItem(.adaptive(minimum: sizeCategory.isAccessibilityCategory ? 180 : 85))], spacing: 12) {
            ForEach(themes, id: \.0) { key, title in
              Button { appearance = key } label: {
                VStack(spacing: 12) {
                  RoundedRectangle(cornerRadius: 12).fill(SvoiPalette.accent(key)).frame(height: 40)
                    .overlay(Image(systemName: "power").foregroundStyle(SvoiPalette.canvas))
                  HStack(spacing: 4) {
                    Text(title).font(.footnote.weight(.medium))
                    if appearance == key { Image(systemName: "checkmark.circle.fill").font(.caption) }
                  }.foregroundStyle(appearance == key ? accent : SvoiPalette.muted)
                }.padding(10).background(SvoiPalette.inset, in: RoundedRectangle(cornerRadius: 16))
                  .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(appearance == key ? accent : .clear))
              }.buttonStyle(SvoiPressStyle()).accessibilityLabel("Тема \(title)")
                .accessibilityAddTraits(appearance == key ? .isSelected : [])
            }
          }
        }.padding(.vertical, 6)
      } header: { Text("Оформление") }
      .listRowBackground(SvoiPalette.surface)

      Section {
        Toggle(isOn: Binding(get: { model.autoRefresh }, set: { enabled in Task { await model.setAutoRefresh(enabled) } })) {
          Label("Обновлять при запуске", systemImage: "arrow.triangle.2.circlepath")
        }.disabled(model.working)
        Button { Task { await model.refreshSubscriptions() } } label: {
          HStack {
            Label("Обновить подписки", systemImage: "arrow.clockwise")
            Spacer()
            if model.working { ProgressView() }
          }.frame(minHeight: 36)
        }.disabled(model.working)
      } header: { Text("Подписки") } footer: { Text("Обновление выполняется в фоне и не включает VPN.") }
        .listRowBackground(SvoiPalette.surface)

      if !model.error.isEmpty { Section { SvoiNotice(text: model.error) }.listRowBackground(SvoiPalette.surface) }

      Section {
        Button { openTelegram(model) } label: { Label("Новости и обсуждения", systemImage: "paperplane") }.frame(minHeight: 36)
        Link(destination: URL(string: "https://svoi.space/")!) { Label("Сайт SVOI", systemImage: "globe") }.frame(minHeight: 36)
        Link(destination: URL(string: "https://github.com/1atex/svoi")!) { Label("Исходный код", systemImage: "chevron.left.forwardslash.chevron.right") }.frame(minHeight: 36)
      } header: { Text("На связи со своими") }.listRowBackground(SvoiPalette.surface)

      Section {
        HStack(spacing: 14) {
          SvoiBrandMark(size: 48)
          VStack(alignment: .leading, spacing: 5) {
            Text("SVOI для iPhone").font(.headline)
            Text("Версия \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0") · сборка \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "2")")
              .font(.caption).foregroundStyle(SvoiPalette.muted)
          }
        }.padding(.vertical, 6)
        Text("Тестовая версия. Установка обновлений выполняется вручную.").font(.footnote).foregroundStyle(SvoiPalette.muted)
      }.listRowBackground(SvoiPalette.surface)
    }.scrollContentBackground(.hidden).background(SvoiPalette.canvas)
  }
}

struct ProfileScreen: View {
  @ObservedObject var model: SvoiModel
  @ObservedObject var vpn: VPNController
  let onImport: () -> Void
  @Environment(\.svoiAccent) private var accent
  @State private var pending: SavedProfile?
  @State private var confirming = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        SvoiCard {
          VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "person.2.fill").font(.system(size: 30)).foregroundStyle(accent)
              .frame(width: 64, height: 64).background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 20))
            Text("Свои — рядом.").font(.title.bold())
            Text("Передавайте подписки и параметры профиля другим устройствам одним кодом SVOI.")
              .font(.body).foregroundStyle(SvoiPalette.muted)
            ShareProfileButton(model: model).buttonStyle(SvoiPrimaryButton())
            Button(action: onImport) { Label("Импортировать код профиля", systemImage: "square.and.arrow.down") }
              .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
          }
        }
        SvoiSectionTitle(title: "Ваши профили")
        SvoiCard {
          VStack(spacing: 6) {
            ForEach(model.profiles) { profile in
              Button {
                guard profile.id != model.profileID else { return }
                if vpn.active { pending = profile; confirming = true }
                else { Task { await model.switchProfile(profile) } }
              } label: {
                HStack(spacing: 14) {
                  Image(systemName: "person.crop.circle").font(.title2).foregroundStyle(accent)
                  VStack(alignment: .leading, spacing: 5) {
                    Text(profile.name).font(.headline).foregroundStyle(SvoiPalette.text)
                    Text(profile.id == model.profileID ? "Активный профиль" : "Нажмите, чтобы переключиться").font(.caption).foregroundStyle(SvoiPalette.muted)
                  }
                  Spacer(minLength: 4)
                  if profile.id == model.profileID { Image(systemName: "checkmark.circle.fill").foregroundStyle(accent) }
                }.padding(.vertical, 10).contentShape(Rectangle())
              }.buttonStyle(SvoiPressStyle()).disabled(model.working || vpn.busy)
            }
            Divider().overlay(SvoiPalette.line)
            NavigationLink { IdentitySettings(model: model) } label: {
              Label("HWID и данные устройства", systemImage: "fingerprint").font(.subheadline).frame(minHeight: 48)
            }
          }
        }
        if !model.error.isEmpty { SvoiNotice(text: model.error, symbol: "exclamationmark.circle") }
      }.padding(20).frame(maxWidth: 560).frame(maxWidth: .infinity)
    }.background(SvoiPalette.canvas)
      .confirmationDialog("Сменить профиль? Текущее VPN-соединение будет отключено.", isPresented: $confirming, titleVisibility: .visible) {
        Button("Сменить профиль") { if let profile = pending { Task { await model.switchProfile(profile) } } }
        Button("Отмена", role: .cancel) { pending = nil }
      }
  }
}

func openTelegram(_ model: SvoiModel) {
  UIApplication.shared.open(URL(string: "tg://resolve?domain=SVOI_client")!) { opened in
    if !opened { model.error = "Telegram не установлен или не открылся. Наш канал: @SVOI_client" }
  }
}
