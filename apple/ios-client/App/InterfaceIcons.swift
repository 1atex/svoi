import SwiftUI

enum SvoiIconStyle: String { case outline, duotone }

private struct SvoiIconStyleKey: EnvironmentKey { static let defaultValue = SvoiIconStyle.outline }
extension EnvironmentValues {
  var svoiIconStyle: SvoiIconStyle {
    get { self[SvoiIconStyleKey.self] }
    set { self[SvoiIconStyleKey.self] = newValue }
  }
}

enum SvoiIconAssets {
  static func name(_ symbol: String, style: SvoiIconStyle) -> String {
    "UiIcon-\(style.rawValue)-\(names[symbol] ?? "info")"
  }
}

struct SvoiGlyph: View {
  let symbol: String
  @ScaledMetric private var size: CGFloat
  @Environment(\.svoiIconStyle) private var style
  init(_ symbol: String, size: CGFloat = 18) {
    self.symbol = symbol
    _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
  }
  var body: some View {
    Image(SvoiIconAssets.name(symbol, style: style)).renderingMode(.template)
      .resizable().scaledToFit().frame(width: size, height: size).accessibilityHidden(true)
  }
}

struct SvoiLabel: View {
  let title: String
  let symbol: String
  init(_ title: String, systemImage: String) { self.title = title; self.symbol = systemImage }
  var body: some View { Label { Text(title) } icon: { SvoiGlyph(symbol) } }
}
