import SwiftUI
import UniformTypeIdentifiers
import UIKit

@main
struct SvoiApp: App {
  @StateObject private var model = SvoiModel()
  @Environment(\.scenePhase) private var scenePhase
  var body: some Scene {
    WindowGroup {
      SvoiRoot(model: model, vpn: model.vpn)
        .preferredColorScheme(.dark)
        .task { await model.initialize() }
        .onChange(of: scenePhase) { phase in
          if phase != .active { model.cancelProbes() }
          else if model.ready { Task { await model.vpn.initialize() } }
        }
    }
  }
}

private let svoiSurface = Color(red: 0.10, green: 0.10, blue: 0.12)
private let svoiMuted = Color(red: 0.67, green: 0.67, blue: 0.69)

struct SvoiRoot: View {
  @ObservedObject var model: SvoiModel
  @ObservedObject var vpn: VPNController
  @AppStorage("appearance") private var appearance = "amber"
  @State private var tab = 0
  @State private var importing = false
  var accent: Color { appearance == "blue" ? .cyan : appearance == "green" ? .mint : Color(red: 0.91, green: 0.73, blue: 0.42) }

  var body: some View {
    Group {
      if model.ready {
        TabView(selection: $tab) {
          NavigationStack {
            ScrollView {
              VStack(spacing: 24) {
                if model.servers.isEmpty {
                  VStack(alignment: .leading, spacing: 16) {
                    Text("Начнём с подписки").font(.largeTitle.bold())
                    Text("Вставьте ссылку провайдера, конфигурацию или код профиля SVOI с другого устройства.").foregroundStyle(svoiMuted)
                    Button { importing = true } label: { Label("Добавить подписку или профиль", systemImage: "plus").frame(maxWidth: .infinity).padding(.vertical, 8) }
                      .buttonStyle(.borderedProminent)
                  }.padding(22).background(svoiSurface, in: RoundedRectangle(cornerRadius: 24))
                } else {
                  Button { tab = 1 } label: {
                    HStack(spacing: 14) {
                      Text(flag(model.selected?.name ?? "")).font(.largeTitle)
                      VStack(alignment: .leading, spacing: 5) {
                        Text(model.selected?.name ?? "Выбрать сервер").font(.headline).foregroundStyle(.white)
                        Text(model.selected?.kind ?? "").font(.caption).foregroundStyle(svoiMuted)
                      }
                      Spacer()
                      Image(systemName: "chevron.right").foregroundStyle(svoiMuted)
                    }.padding(18).background(svoiSurface, in: RoundedRectangle(cornerRadius: 20))
                  }.buttonStyle(.plain)
                }
                VStack(spacing: 20) {
                  Button { Task { await model.toggleVPN() } } label: {
                    ZStack {
                      Circle().stroke(accent.opacity(0.12), lineWidth: 1).frame(width: 190, height: 190)
                      Circle().stroke(accent.opacity(0.22), lineWidth: 1).frame(width: 158, height: 158)
                      Circle().fill(vpn.connected ? accent : accent.opacity(0.15)).overlay(Circle().stroke(accent, lineWidth: 1)).frame(width: 122, height: 122)
                      Image(systemName: vpn.busy || model.preparingVPN ? "xmark" : "power")
                        .font(.system(size: 42, weight: .regular)).foregroundStyle(vpn.connected ? .black : accent)
                    }.frame(maxWidth: .infinity).contentShape(Rectangle())
                  }.buttonStyle(.plain)
                    .disabled(model.selected == nil && !vpn.active)
                    .accessibilityLabel(vpn.busy || model.preparingVPN ? "Отменить подключение" : vpn.active ? "Отключить VPN" : "Подключить VPN")
                  Text(model.preparingVPN ? "Готовим подключение…" : vpn.title).font(.title2.bold())
                  Text(vpn.connected ? "Туннель запущен. Доступность интернета проверяется отдельно." : vpn.busy ? "Повторное нажатие отменит подключение." : "Нажмите на кнопку включения, чтобы подключиться.")
                    .font(.footnote).foregroundStyle(svoiMuted).multilineTextAlignment(.center)
                  if vpn.connected && vpn.serverID != model.selectedID {
                    Text("Выбран другой сервер. Нажмите кнопку, чтобы переключиться.").font(.footnote).foregroundStyle(accent)
                  }
                }.padding(.vertical, 12)
                ConnectionTools(vpn: vpn)
                if !model.sources.isEmpty { sources }
              }.padding(20)
            }
            .background(Color.black)
            .navigationTitle("svoi·")
            .toolbar { topToolbar }
          }.tabItem { Label("VPN", systemImage: "power") }.tag(0)
          NavigationStack {
            ServerList(model: model, vpn: vpn, onSelect: { tab = 0 })
              .navigationTitle("Серверы")
              .toolbar { topToolbar }
          }.tabItem { Label("Серверы", systemImage: "globe") }.tag(1)
          NavigationStack {
            settings.navigationTitle("Настройки")
          }.tabItem { Label("Настройки", systemImage: "gearshape") }.tag(2)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
          if !model.error.isEmpty {
            HStack(alignment: .top) {
              Text(model.error).font(.footnote).textSelection(.enabled)
              Spacer(minLength: 8)
              Button { model.error = "" } label: { Image(systemName: "xmark") }.accessibilityLabel("Закрыть сообщение")
            }.padding(14).foregroundStyle(.orange).background(svoiSurface)
          }
        }
        .sheet(isPresented: $importing) { ImportSheet(model: model) }
      } else {
        VStack(spacing: 20) {
          Text("svoi·").font(.system(size: 42, weight: .bold))
          if model.working { ProgressView("Открываем профили…") }
          if !model.error.isEmpty {
            Text(model.error).font(.callout).textSelection(.enabled)
            Button("Повторить") { Task { await model.initialize() } }.buttonStyle(.borderedProminent)
          }
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black)
      }
    }.tint(accent)
  }

  @ToolbarContentBuilder private var topToolbar: some ToolbarContent {
    ToolbarItemGroup(placement: .navigationBarTrailing) {
      if model.working { ProgressView() }
      Button { importing = true } label: { Image(systemName: "plus") }.disabled(model.working).accessibilityLabel("Добавить подписку")
    }
  }

  private var sources: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Подписки").font(.title3.bold())
        Spacer()
        Button { Task { await model.refreshSubscriptions() } } label: { Image(systemName: "arrow.clockwise") }
          .disabled(model.working).accessibilityLabel("Обновить подписки")
      }
      ForEach(model.sources) { source in
        VStack(alignment: .leading, spacing: 7) {
          Text(source.name).font(.headline)
          Text("\(source.count) серверов").font(.caption).foregroundStyle(svoiMuted)
          if let message = source.metadata["announcement"] as? String, !message.isEmpty { Text(message).font(.footnote).foregroundStyle(svoiMuted) }
          if let download = source.metadata["download"] as? Int64 {
            let upload = source.metadata["upload"] as? Int64 ?? 0
            Text("Использовано \(ByteCountFormatter.string(fromByteCount: download + upload, countStyle: .binary))\(trafficLimit(source.metadata))").font(.caption)
          }
          if let expire = source.metadata["expire"] as? Double, expire > 0 {
            Text("До \(Date(timeIntervalSince1970: expire).formatted(date: .numeric, time: .omitted))").font(.caption)
          }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(17).background(svoiSurface, in: RoundedRectangle(cornerRadius: 18))
      }
    }
  }

  private var settings: some View {
    Form {
      Section("Профили") {
        ForEach(model.profiles) { profile in
          Button { Task { await model.switchProfile(profile) } } label: {
            HStack { Text(profile.name); Spacer(); if profile.id == model.profileID { Image(systemName: "checkmark") } }
          }.disabled(model.working || vpn.busy)
        }
        Button("Импортировать профиль") { importing = true }
        ShareProfileButton(model: model)
        NavigationLink("HWID и данные устройства") { IdentitySettings(model: model) }
      }
      Section("Подписки") {
        Toggle("Обновлять при запуске", isOn: Binding(get: { model.autoRefresh }, set: { enabled in Task { await model.setAutoRefresh(enabled) } })).disabled(model.working)
        Button("Обновить сейчас") { Task { await model.refreshSubscriptions() } }.disabled(model.working)
      }
      Section("Оформление") {
        Picker("Акцент", selection: $appearance) { Text("Янтарный").tag("amber"); Text("Голубой").tag("blue"); Text("Мятный").tag("green") }
      }
      Section("SVOI для iOS") {
        Text("Preview 0.1.0 · Xray \(SvoiCoreVersion())").font(.footnote)
        Text("Разделение по отдельным приложениям и автоматические обновления в этой версии не реализованы.").font(.footnote).foregroundStyle(.secondary)
        Button("Новости в Telegram") {
          if let url = URL(string: "tg://resolve?domain=SVOI_client") { UIApplication.shared.open(url) }
        }
        Link("Сайт SVOI", destination: URL(string: "https://svoi.space/")!)
      }
    }
  }
}

private func trafficLimit(_ metadata: [String: Any]) -> String {
  guard let total = metadata["total"] as? Int64, total > 0 else { return " · без лимита трафика" }
  return " из " + ByteCountFormatter.string(fromByteCount: total, countStyle: .binary)
}

func flag(_ name: String) -> String {
  let regional = name.unicodeScalars.filter { (0x1F1E6...0x1F1FF).contains($0.value) }
  if regional.count >= 2 { return String(String.UnicodeScalarView(regional.prefix(2))) }
  let lower = name.lowercased()
  let countries: [(String, [String])] = [("NL", ["netherlands", "нидерланды", "nl"]), ("DE", ["germany", "германия", "de"]), ("FI", ["finland", "финляндия", "fi"]), ("RU", ["russia", "россия", "ru"]), ("FR", ["france", "франция", "fr"]), ("IT", ["italy", "италия", "it"]), ("LV", ["latvia", "латвия", "lv"]), ("US", ["united states", "usa", "us"]), ("GB", ["united kingdom", "britain", "uk", "gb"]), ("JP", ["japan", "япония", "jp"]), ("PL", ["poland", "польша", "pl"]), ("TR", ["turkey", "турция", "tr"]), ("SG", ["singapore", "сингапур", "sg"])]
  for (code, names) in countries where names.contains(where: { $0.count > 2 ? lower.contains($0) : lower.hasPrefix($0) }) {
    return String(String.UnicodeScalarView(code.unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }))
  }
  return "🌐"
}
