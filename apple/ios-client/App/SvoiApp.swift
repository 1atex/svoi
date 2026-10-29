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
          if phase != .active { model.cancelProbes(); SvoiCoreCancelSpeed() }
          if phase == .background { model.suspendForegroundWork() }
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
  @AppStorage("colorScheme") private var colorScheme = "dark"
  @AppStorage("uiIconStyle") private var iconStyleName = "outline"
  private var iconStyle: SvoiIconStyle { SvoiIconStyle(rawValue: iconStyleName) ?? .outline }
  @State private var tab = 0
  @State private var importing = false
  @State private var importProfile = false
  private var accent: Color { SvoiPalette.accent(appearance) }
  private var colors: SvoiThemeColors { colorScheme == "amoled" ? .amoled : .dark }

  var body: some View {
    Group {
      if model.ready {
        TabView(selection: $tab) {
          NavigationStack {
            ConnectionScreen(model: model, vpn: vpn, add: openImport)
          }.tabItem { Label("Подключение", image: SvoiIconAssets.name("power", style: iconStyle)) }.tag(0)
          NavigationStack {
            ToolsScreen(model: model, vpn: vpn).navigationTitle("Инструменты")
          }.tabItem { Label("Инструменты", image: SvoiIconAssets.name("wrench.and.screwdriver", style: iconStyle)) }.tag(4)
          NavigationStack {
            SettingsScreen(model: model, vpn: vpn, onImport: { openImport(true) }).navigationTitle("Настройки")
          }.tabItem { Label("Настройки", image: SvoiIconAssets.name("slider.horizontal.3", style: iconStyle)) }.tag(3)
        }
        .toolbarBackground(colors.canvas, for: .tabBar, .navigationBar)
        .toolbarBackground(.visible, for: .tabBar, .navigationBar)
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
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity).background(colors.canvas)
      }
    }
    .environment(\.svoiIconStyle, iconStyle).tint(accent).environment(\.svoiAccent, accent).environment(\.svoiColors, colors).background(colors.canvas)
    #if SVOI_UI_PREVIEW
    .environment(\.sizeCategory, ProcessInfo.processInfo.arguments.contains("--large-type") ? .accessibilityExtraExtraExtraLarge : .large)
    #endif
  }

  private func openImport(_ profile: Bool) {
    importProfile = profile
    model.error = ""
    importing = true
  }

}
