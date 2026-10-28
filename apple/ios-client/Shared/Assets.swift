import Foundation

enum CoreAssets {
  static func prepare() throws -> URL {
    let manager = FileManager.default
    let root = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      .appendingPathComponent("SVOI", isDirectory: true)
    let core = root.appendingPathComponent("core", isDirectory: true)
    try manager.createDirectory(at: core, withIntermediateDirectories: true,
                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    for name in ["geoip.dat", "geosite.dat"] {
      guard let bundled = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "core") else {
        throw NSError(domain: "SVOI", code: 1, userInfo: [NSLocalizedDescriptionKey: "В сборке отсутствует \(name). Пересоберите приложение целиком."])
      }
      let target = core.appendingPathComponent(name)
      if !manager.contentsEqual(atPath: bundled.path, andPath: target.path) {
        let data = try Data(contentsOf: bundled, options: .mappedIfSafe)
        try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      }
    }
    return root
  }
}
