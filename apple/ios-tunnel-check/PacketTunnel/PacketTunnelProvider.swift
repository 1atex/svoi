import NetworkExtension

class PacketTunnelProvider: NEPacketTunnelProvider {
  override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "192.0.2.1")
    let ipv4 = NEIPv4Settings(addresses: ["192.0.2.2"], subnetMasks: ["255.255.255.0"])
    ipv4.includedRoutes = [NEIPv4Route(destinationAddress: "192.0.2.0", subnetMask: "255.255.255.0")]
    settings.ipv4Settings = ipv4
    settings.mtu = 1280
    setTunnelNetworkSettings(settings, completionHandler: completionHandler)
  }

  override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
    completionHandler()
  }

  override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
    completionHandler?(messageData == Data("status".utf8) ? Data("SVOI-TUNNEL-CHECK-1".utf8) : nil)
  }
}
