import SwiftUI
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
          #if !SVOI_UI_PREVIEW
          if phase == .active && model.ready { Task { await model.vpn.initialize() } }
          #endif
        }
    }
  }
}

struct SvoiRoot: View {
  @ObservedObject var model: SvoiModel
  @ObservedObject var vpn: VPNController
  @AppStorage("appearance") private var appearance = "amber"
  @State private var tab = 0
  @State private var importing = false
  @State private var importProfile = false
  private var accent: Color { SvoiPalette.accent(appearance) }

  var body: some View {
    Group {
      if model.ready {
        TabView(selection: $tab) {
          NavigationStack {
            ConnectionScreen(model: model, vpn: vpn, openServers: { tab = 1 }, add: openImport)
              .toolbar { brandToolbar }
          }.tabItem { Label("Подключение", systemImage: "power") }.tag(0)
          NavigationStack {
            ServerList(model: model, vpn: vpn, onSelect: { tab = 0 }, onImport: { openImport(false) })
              .navigationTitle("Серверы")
              .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                  SvoiIconButton(symbol: "plus", label: "Добавить подписку") { openImport(false) }.disabled(model.working)
                }
              }
          }.tabItem { Label("Серверы", systemImage: "globe.europe.africa") }.tag(1)
          NavigationStack {
            ProfileScreen(model: model, vpn: vpn, onImport: { openImport(true) }).navigationTitle("Общий профиль")
          }.tabItem { Label("Профиль", systemImage: "person.2") }.tag(2)
          NavigationStack {
            SettingsScreen(model: model).navigationTitle("Настройки")
          }.tabItem { Label("Настройки", systemImage: "slider.horizontal.3") }.tag(3)
        }
        .toolbarBackground(SvoiPalette.canvas, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .sheet(isPresented: $importing) { ImportSheet(model: model, profile: importProfile) }
      } else {
        VStack(spacing: 24) {
          SvoiBrandMark(size: 64)
          Text("svoi·").font(.system(size: 36, weight: .bold, design: .rounded))
          if model.working { ProgressView("Открываем вашу сеть…").tint(accent) }
          if !model.error.isEmpty {
            SvoiNotice(text: model.error, symbol: "exclamationmark.circle")
            Button("Повторить") { Task { await model.initialize() } }.buttonStyle(SvoiPrimaryButton())
          }
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity).background(SvoiPalette.canvas)
      }
    }
    .tint(accent).environment(\.svoiAccent, accent).background(SvoiPalette.canvas)
    #if SVOI_UI_PREVIEW
    .environment(\.sizeCategory, ProcessInfo.processInfo.arguments.contains("--large-type") ? .accessibilityExtraExtraExtraLarge : .large)
    #endif
  }

  private func openImport(_ profile: Bool) {
    importProfile = profile
    model.error = ""
    importing = true
  }

  @ToolbarContentBuilder private var brandToolbar: some ToolbarContent {
    ToolbarItem(placement: .navigationBarLeading) {
      HStack(spacing: 9) {
        SvoiBrandMark(size: 34)
        (Text("svoi").foregroundColor(SvoiPalette.text) + Text("·").foregroundColor(accent))
          .font(.system(size: 25, weight: .bold, design: .rounded))
      }.accessibilityElement(children: .ignore).accessibilityLabel("SVOI")
    }
    ToolbarItem(placement: .navigationBarTrailing) {
      SvoiIconButton(symbol: "plus", label: "Добавить подписку") { openImport(false) }.disabled(model.working)
    }
  }
}
