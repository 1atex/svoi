import Foundation
import Security
import SystemConfiguration
import Darwin

typealias ProxyMap = [String: [String: Any]]

enum ProxyFailure: Error, CustomStringConvertible {
  case message(String)
  var description: String { switch self { case .message(let text): return text } }
}

func require(_ condition: Bool, _ text: String) throws {
  if !condition { throw ProxyFailure.message(text) }
}

func same(_ a: [String: Any], _ b: [String: Any]) -> Bool {
  NSDictionary(dictionary: a).isEqual(to: b)
}

let managedKeys = Set([
  kSCPropNetProxiesHTTPEnable as String, kSCPropNetProxiesHTTPProxy as String,
  kSCPropNetProxiesHTTPPort as String, kSCPropNetProxiesHTTPSEnable as String,
  kSCPropNetProxiesHTTPSProxy as String, kSCPropNetProxiesHTTPSPort as String,
  kSCPropNetProxiesProxyAutoConfigEnable as String,
  kSCPropNetProxiesProxyAutoDiscoveryEnable as String, kSCPropNetProxiesSOCKSEnable as String,
])

func appliedProxy(_ original: [String: Any], port: Int) -> [String: Any] {
  var next = original
  next[kSCPropNetProxiesHTTPEnable as String] = 1
  next[kSCPropNetProxiesHTTPProxy as String] = "127.0.0.1"
  next[kSCPropNetProxiesHTTPPort as String] = port
  next[kSCPropNetProxiesHTTPSEnable as String] = 1
  next[kSCPropNetProxiesHTTPSProxy as String] = "127.0.0.1"
  next[kSCPropNetProxiesHTTPSPort as String] = port
  next[kSCPropNetProxiesProxyAutoConfigEnable as String] = 0
  next[kSCPropNetProxiesProxyAutoDiscoveryEnable as String] = 0
  next[kSCPropNetProxiesSOCKSEnable as String] = 0
  return next
}

func restoreChanges(current: ProxyMap, original: ProxyMap, expected: ProxyMap) -> ProxyMap {
  var changes: ProxyMap = [:]
  for (id, value) in original {
    if let actual = current[id], let wanted = expected[id],
       same(actual.filter { managedKeys.contains($0.key) }, wanted.filter { managedKeys.contains($0.key) }) {
      var restored = actual
      for key in managedKeys { restored[key] = value[key] }
      changes[id] = restored
    }
  }
  return changes
}

final class NetworkPreferences {
  let authorization: AuthorizationRef
  let preferences: SCPreferences

  init() throws {
    var reference: AuthorizationRef?
    let status = AuthorizationCreate(nil, nil, [], &reference)
    try require(status == errAuthorizationSuccess && reference != nil, "Не удалось запросить разрешение macOS.")
    let auth = reference!
    authorization = auth
    let allowed = "system.preferences.network".withCString { name -> OSStatus in
      var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
      return withUnsafeMutablePointer(to: &item) { pointer in
        var rights = AuthorizationRights(count: 1, items: pointer)
        return AuthorizationCopyRights(auth, &rights, nil, [.interactionAllowed, .extendRights, .preAuthorize], nil)
      }
    }
    if allowed != errAuthorizationSuccess {
      AuthorizationFree(auth, [])
      throw ProxyFailure.message("Изменение сети не разрешено. Повторите подключение и подтвердите запрос macOS.")
    }
    guard let prefs = SCPreferencesCreateWithAuthorization(nil, "SVOI" as CFString, nil, auth) else {
      AuthorizationFree(auth, [])
      throw ProxyFailure.message("Не удалось открыть настройки сети macOS.")
    }
    preferences = prefs
  }

  deinit { AuthorizationFree(authorization, []) }

  func transaction(restoring: Bool = false, _ body: (ProxyMap) throws -> ProxyMap) throws {
    SCPreferencesSynchronize(preferences)
    try require(SCPreferencesLock(preferences, false), "Настройки сети заняты. Повторите подключение.")
    defer { SCPreferencesUnlock(preferences) }
    let list: CFArray?
    if restoring { list = SCNetworkServiceCopyAll(preferences) }
    else if let set = SCNetworkSetCopyCurrent(preferences) { list = SCNetworkSetCopyServices(set) }
    else { list = nil }
    guard let services = list as? [SCNetworkService] else {
      throw ProxyFailure.message("В macOS не найдены сетевые подключения.")
    }
    var protocols: [String: SCNetworkProtocol] = [:]
    var current: ProxyMap = [:]
    for service in services where restoring || SCNetworkServiceGetEnabled(service) {
      guard let interface = SCNetworkServiceGetInterface(service),
            let type = SCNetworkInterfaceGetInterfaceType(interface),
            type == kSCNetworkInterfaceTypeEthernet || type == kSCNetworkInterfaceTypeIEEE80211,
            let serviceID = SCNetworkServiceGetServiceID(service),
            let proxy = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { continue }
      let id = serviceID as String
      protocols[id] = proxy
      current[id] = SCNetworkProtocolGetConfiguration(proxy) as? [String: Any] ?? [:]
    }
    let changes = try body(current)
    if changes.isEmpty { return }
    for (id, value) in changes {
      guard let proxy = protocols[id] else { continue }
      try require(SCNetworkProtocolSetConfiguration(proxy, value as CFDictionary), "Не удалось изменить настройки прокси.")
    }
    try require(SCPreferencesCommitChanges(preferences), "macOS не разрешила сохранить прокси. Разрешите изменение настроек сети.")
    try require(SCPreferencesApplyChanges(preferences), "macOS не применила прокси. Повторите подключение.")
  }
}

func readSnapshot(_ file: URL) throws -> (ProxyMap, ProxyMap, Int32)? {
  if !FileManager.default.fileExists(atPath: file.path) { return nil }
  let bytes = try Data(contentsOf: file)
  try require(bytes.count < 1024 * 1024, "Повреждён файл восстановления прокси.")
  guard let data = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
        data["version"] as? Int == 1,
        let before = data["original"] as? ProxyMap,
        let after = data["expected"] as? ProxyMap,
        let pid = data["pid"] as? Int, pid > 1, pid <= Int(Int32.max) else { throw ProxyFailure.message("Повреждён файл восстановления прокси.") }
  return (before, after, Int32(pid))
}

func recover(_ file: URL, store: NetworkPreferences? = nil) throws {
  guard let (before, after, pid) = try readSnapshot(file) else { return }
  if store == nil && pid > 1 && (kill(pid, 0) == 0 || errno == EPERM) {
    throw ProxyFailure.message("Другое подключение SVOI ещё управляет прокси. Сначала отключите его.")
  }
  let network = try store ?? NetworkPreferences()
  try network.transaction(restoring: true) { restoreChanges(current: $0, original: before, expected: after) }
  try FileManager.default.removeItem(at: file)
}

func selfTest() throws {
  let old: [String: Any] = ["HTTPEnable": 0, "ExceptionsList": ["localhost", "*.local"], "ProxyAutoConfigURLString": "https://example.com/pac"]
  let next = appliedProxy(old, port: 12345)
  try require(next["HTTPPort"] as? Int == 12345 && next["HTTPEnable"] as? Int == 1, "proxy setup")
  try require(next["ExceptionsList"] as? [String] == old["ExceptionsList"] as? [String], "preserve exclusions")
  try require(restoreChanges(current: ["wifi": next], original: ["wifi": old], expected: ["wifi": next]).count == 1, "restore owned values")
  var userChanged = next
  userChanged["HTTPPort"] = 54321
  try require(restoreChanges(current: ["wifi": userChanged], original: ["wifi": old], expected: ["wifi": next]).isEmpty, "preserve user changes")
  var changedExclusions = next
  changedExclusions["ExceptionsList"] = ["new.example"]
  changedExclusions["FutureSystemKey"] = true
  let restored = restoreChanges(current: ["wifi": changedExclusions], original: ["wifi": old], expected: ["wifi": next])["wifi"]!
  try require(restored["HTTPEnable"] as? Int == 0 && restored["HTTPPort"] == nil, "restore only managed keys")
  try require(restored["ExceptionsList"] as? [String] == ["new.example"] && restored["FutureSystemKey"] as? Bool == true, "preserve unrelated keys")
  try require(restoreChanges(current: [:], original: ["wifi": old], expected: ["wifi": next]).isEmpty, "removed service")
  let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: file) }
  let data: [String: Any] = ["version": 1, "pid": 123, "original": ["wifi": old], "expected": ["wifi": next]]
  try PropertyListSerialization.data(fromPropertyList: data, format: .binary, options: 0).write(to: file)
  let saved = try readSnapshot(file)
  try require(saved != nil && same(saved!.0["wifi"]!, old), "snapshot roundtrip")
  print("Proxy state tests passed")
}

func run() throws {
  let args = CommandLine.arguments
  if args.count == 2 && args[1] == "--self-test" { try selfTest(); return }
  if args.count == 3 && args[1] == "watch", let child = Int32(args[2]), child > 1 {
    if readLine() != "release" { kill(-child, SIGTERM) }
    return
  }
  try require(args.count >= 3 && ["session", "recover"].contains(args[1]), "Неверный запуск помощника SVOI.")
  let directory = URL(fileURLWithPath: args[2], isDirectory: true)
  let file = directory.appendingPathComponent("macos-proxy.plist")
  if args[1] == "recover" { try recover(file); return }
  try require(args.count == 4, "Не указан порт прокси.")
  guard let port = Int(args[3]), (1024...65535).contains(port) else { throw ProxyFailure.message("Недопустимый порт прокси.") }
  try recover(file)
  let network = try NetworkPreferences()
  var snapshotWritten = false
  do {
    try network.transaction { before in
      try require(!FileManager.default.fileExists(atPath: file.path), "Другое подключение SVOI уже управляет прокси.")
      try require(!before.isEmpty, "Не найдено подключений Wi-Fi или Ethernet. Выберите ручной прокси.")
      let after = before.mapValues { appliedProxy($0, port: port) }
      let snapshot: [String: Any] = ["version": 1, "pid": Int(getpid()), "original": before, "expected": after]
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let bytes = try PropertyListSerialization.data(fromPropertyList: snapshot, format: .binary, options: 0)
      try require(bytes.count < 1024 * 1024, "Настройки прокси слишком большие для безопасного восстановления. Выберите ручной прокси.")
      try bytes.write(to: file, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      snapshotWritten = true
      return after
    }
  } catch {
    if snapshotWritten { try? recover(file, store: network) }
    throw error
  }
  print("{\"ready\":true}")
  fflush(stdout)
  while readLine() != nil {}
  try recover(file, store: network)
}

do { try run() } catch {
  let data = try! JSONSerialization.data(withJSONObject: ["error": String(describing: error)])
  print(String(data: data, encoding: .utf8)!)
  fflush(stdout)
  exit(1)
}
