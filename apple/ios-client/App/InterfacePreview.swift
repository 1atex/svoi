#if SVOI_UI_PREVIEW
import Foundation

extension SvoiModel {
  func prepareInterfacePreview() {
    guard !ready else { return }
    group = ["id": "preview", "name": "Моя сеть"]
    if ProcessInfo.processInfo.arguments.contains("--reset-collapse") {
      UserDefaults.standard.removeObject(forKey: "collapsedSubscriptions:preview")
    }
    profiles = [SavedProfile(id: "preview", name: "Моя сеть", token: "interface-preview")]
    guard !ProcessInfo.processInfo.arguments.contains("--empty") else {
      if ProcessInfo.processInfo.arguments.contains("--connected") { vpn.setInterfacePreview(connected: true, serverID: "previous-server") }
      ready = true
      return
    }
    servers = [
      SvoiServer(["id": "fi", "name": "Finland", "protocol": "vless", "network": "tcp", "security": "reality", "subscriptionId": "demo"]),
      SvoiServer(["id": "nl", "name": "NL Автоматический", "protocol": "vless", "fullProfile": true, "subscriptionId": "demo"]),
      SvoiServer(["id": "de", "name": "Germany", "protocol": "hysteria2", "network": "udp", "security": "tls", "subscriptionId": "demo"]),
      SvoiServer(["id": "fr", "name": "France", "protocol": "vless", "network": "grpc", "security": "reality", "subscriptionId": "demo"])
    ]
    sources = [SvoiSource(["id": "demo", "name": "Моя подписка", "count": 4, "remote": true,
      "metadata": ["download": 1610612736, "upload": 0, "total": 53687091200,
        "announcement": "Демонстрационные данные для проверки интерфейса"]])]
    selectedID = "fi"
    latencies = ["fi": "42 мс", "nl": "57 мс", "de": "61 мс"]
    if ProcessInfo.processInfo.arguments.contains("--connected") { vpn.setInterfacePreview(connected: true, serverID: "fi") }
    ready = true
  }
}
#endif
