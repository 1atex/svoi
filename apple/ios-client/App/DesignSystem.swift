import SwiftUI

struct SvoiThemeColors {
  let canvas: Color
  let surface: Color
  let inset: Color
  let line: Color
  static let dark = SvoiThemeColors(canvas: SvoiPalette.canvas, surface: SvoiPalette.surface, inset: SvoiPalette.inset, line: SvoiPalette.line)
  static let amoled = SvoiThemeColors(canvas: .black, surface: Color(red: 8/255, green: 8/255, blue: 10/255), inset: .black, line: .white.opacity(0.15))
}

private struct SvoiColorsKey: EnvironmentKey { static let defaultValue = SvoiThemeColors.dark }
extension EnvironmentValues {
  var svoiColors: SvoiThemeColors {
    get { self[SvoiColorsKey.self] }
    set { self[SvoiColorsKey.self] = newValue }
  }
}

enum SvoiPalette {
  static let canvas = Color(red: 0.055, green: 0.055, blue: 0.063)
  static let surface = Color(red: 0.102, green: 0.102, blue: 0.114)
  static let inset = Color(red: 0.075, green: 0.075, blue: 0.086)
  static let text = Color(red: 0.96, green: 0.95, blue: 0.93)
  static let muted = Color(red: 0.69, green: 0.69, blue: 0.72)
  static let line = Color.white.opacity(0.09)
  static let gold = Color(red: 0.91, green: 0.73, blue: 0.42)
  static let success = Color(red: 0.59, green: 0.82, blue: 0.69)
  static let warning = Color(red: 1, green: 0.66, blue: 0.57)
  static func accent(_ name: String) -> Color {
    switch name {
    case "blue": return Color(red: 0.63, green: 0.77, blue: 0.96)
    case "green": return Color(red: 0.64, green: 0.82, blue: 0.72)
    default: return gold
    }
  }
}

private struct SvoiAccentKey: EnvironmentKey { static let defaultValue = SvoiPalette.gold }
extension EnvironmentValues {
  var svoiAccent: Color {
    get { self[SvoiAccentKey.self] }
    set { self[SvoiAccentKey.self] = newValue }
  }
}

struct SvoiCard<Content: View>: View {
  @Environment(\.svoiColors) private var colors
  private let content: Content
  init(@ViewBuilder content: () -> Content) { self.content = content() }
  var body: some View {
    content.padding(20).frame(maxWidth: .infinity, alignment: .leading)
      .background(colors.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(colors.line))
  }
}

struct SvoiPrimaryButton: ButtonStyle {
  @Environment(\.svoiColors) private var colors
  @Environment(\.svoiAccent) private var accent
  @Environment(\.isEnabled) private var enabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.headline).multilineTextAlignment(.center)
      .frame(maxWidth: .infinity).padding(.horizontal, 18).padding(.vertical, 16)
      .foregroundStyle(colors.canvas)
      .background(accent.opacity(enabled ? configuration.isPressed ? 0.75 : 1 : 0.38), in: RoundedRectangle(cornerRadius: 16))
      .contentShape(RoundedRectangle(cornerRadius: 16))
  }
}

struct SvoiPressStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isEnabled) private var enabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.opacity(!enabled ? 0.42 : configuration.isPressed ? 0.68 : 1)
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

struct SvoiIconButton: View {
  let symbol: String
  let label: String
  let action: () -> Void
  @Environment(\.svoiAccent) private var accent
  var body: some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 18, weight: .medium))
        .foregroundStyle(accent)
        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
    }.buttonStyle(SvoiPressStyle()).accessibilityLabel(label)
  }
}

struct SvoiBrandMark: View {
  var size: CGFloat = 42
  var body: some View {
    Image("SvoiMark").resizable().scaledToFit().frame(width: size, height: size)
      .clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)).accessibilityHidden(true)
  }
}

struct SvoiSectionTitle: View {
  let title: String
  var body: some View {
    Text(title).font(.caption.weight(.semibold)).tracking(1.2)
      .dynamicTypeSize(...DynamicTypeSize.accessibility1)
      .foregroundStyle(SvoiPalette.muted).textCase(.uppercase).accessibilityAddTraits(.isHeader)
  }
}

struct SvoiNotice: View {
  let text: String
  var symbol = "info.circle"
  var warning = true
  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: symbol).padding(.top, 2).accessibilityHidden(true)
      Text(text).font(.footnote).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }.foregroundStyle(warning ? SvoiPalette.warning : SvoiPalette.muted)
      .padding(14).frame(maxWidth: .infinity, alignment: .leading)
      .background((warning ? SvoiPalette.warning : SvoiPalette.muted).opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
  }
}

struct ServerFlag: View {
  @Environment(\.svoiColors) private var colors
  let name: String
  var size: CGFloat = 44
  var body: some View {
    Group {
      if let value = countryFlag(name) { Text(value).font(.system(size: size * 0.57)) }
      else { Image(systemName: "globe.europe.africa").font(.system(size: size * 0.48)).foregroundStyle(SvoiPalette.muted) }
    }.frame(width: size, height: size)
      .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
      .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(colors.line)).accessibilityHidden(true)
  }
}

func countryFlag(_ name: String) -> String? {
  let regional = name.unicodeScalars.filter { (0x1F1E6...0x1F1FF).contains($0.value) }
  if regional.count >= 2 { return String(String.UnicodeScalarView(regional.prefix(2))) }
  let lower = name.lowercased()
  let countries: [(String, [String])] = [
    ("NL", ["netherlands", "нидерланды", "nl"]), ("DE", ["germany", "германия", "de"]),
    ("FI", ["finland", "финляндия", "fi"]), ("RU", ["russia", "россия", "ru"]),
    ("FR", ["france", "франция", "fr"]), ("IT", ["italy", "италия", "it"]),
    ("LV", ["latvia", "латвия", "lv"]), ("US", ["united states", "usa", "us"]),
    ("GB", ["united kingdom", "britain", "uk", "gb"]), ("JP", ["japan", "япония", "jp"]),
    ("PL", ["poland", "польша", "pl"]), ("TR", ["turkey", "турция", "tr"]),
    ("SG", ["singapore", "сингапур", "sg"]), ("NO", ["norway", "норвегия", "no"]),
    ("ES", ["spain", "испания", "es"]), ("IE", ["ireland", "ирландия", "ie"]),
    ("CA", ["canada", "канада", "ca"]), ("EU", ["europe", "eu"]), ("AM", ["armenia", "армения", "am"])
  ]
  for (code, names) in countries where names.contains(where: { $0.count > 2 ? lower.contains($0) : lower.hasPrefix($0) }) {
    return String(String.UnicodeScalarView(code.unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }))
  }
  return nil
}

func displayServerName(_ name: String) -> String {
  var value = name
  if let flag = countryFlag(name) { value = value.replacingOccurrences(of: flag, with: "") }
  if let first = value.split(separator: " ").first, first.count == 2,
     countryFlag(String(first)) != nil, value.hasPrefix(String(first) + " ") { value = String(value.dropFirst(3)) }
  return value.trimmingCharacters(in: .whitespacesAndNewlines)
}
