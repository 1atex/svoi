import Darwin
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
  private let lifecycle = DispatchQueue(label: "dev.svoi.tunnel.lifecycle", qos: .userInitiated)
  private var pump: PacketPump?
  private var generation = 0
  private var started = false

  override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
    lifecycle.async {
      self.generation += 1
      let attempt = self.generation
      guard let config = (self.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["config"] as? String,
            !config.isEmpty, config.utf8.count <= 4 * 1024 * 1024 else {
        completionHandler(self.error("Не найдена конфигурация сервера. Откройте SVOI и подключитесь заново."))
        return
      }
      self.cleanup()
      let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "198.18.0.1")
      let ipv4 = NEIPv4Settings(addresses: ["172.31.255.1"], subnetMasks: ["255.255.255.252"])
      ipv4.includedRoutes = [NEIPv4Route.default()]
      settings.ipv4Settings = ipv4
      let ipv6 = NEIPv6Settings(addresses: ["fd42:7376:6f69::1"], networkPrefixLengths: [126])
      ipv6.includedRoutes = [NEIPv6Route.default()]
      settings.ipv6Settings = ipv6
      settings.dnsSettings = NEDNSSettings(servers: ["1.1.1.1"])
      settings.dnsSettings?.matchDomains = [""]
      settings.mtu = 1500
      self.setTunnelNetworkSettings(settings) { error in
        self.lifecycle.async {
          guard attempt == self.generation else {
            completionHandler(self.error("Подключение отменено"))
            return
          }
          if let error = error { completionHandler(error); return }
          var descriptors: [Int32] = [-1, -1]
          do {
            let directory = try CoreAssets.prepare()
            guard Darwin.socketpair(AF_UNIX, SOCK_DGRAM, 0, &descriptors) == 0 else {
              throw self.error("Не удалось создать канал пакетов: \(errno)")
            }
            var bufferSize: Int32 = 256 * 1024
            for descriptor in descriptors {
              _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))
              _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))
            }
            guard fcntl(descriptors[1], F_SETFL, O_NONBLOCK) != -1 else {
              throw self.error("Не удалось настроить канал пакетов: \(errno)")
            }
            var enabled: Int32 = 1
            _ = setsockopt(descriptors[1], SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
            let failure = SvoiCoreStart(config, descriptors[0], directory.appendingPathComponent("core").path)
            guard failure.isEmpty else { throw self.error(failure) }
            self.started = true
            Darwin.close(descriptors[0])
            descriptors[0] = -1
            let pump = PacketPump(flow: self.packetFlow, descriptor: descriptors[1]) { [weak self] in
              guard let self = self else { return }
              self.lifecycle.async {
                guard self.generation == attempt else { return }
                self.cleanup()
                self.cancelTunnelWithError(self.error("Канал VPN остановился. Откройте SVOI и подключитесь заново."))
              }
            }
            self.pump = pump
            descriptors[1] = -1
            pump.start()
            completionHandler(nil)
          } catch {
            for fd in descriptors where fd >= 0 { Darwin.close(fd) }
            self.cleanup()
            completionHandler(error)
          }
        }
      }
    }
  }

  override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
    lifecycle.async {
      self.generation += 1
      self.cleanup()
      completionHandler()
    }
  }

  override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
    lifecycle.async {
      let response = try? JSONSerialization.data(withJSONObject: ["running": self.started, "core": SvoiCoreVersion()])
      completionHandler?(response)
    }
  }

  private func cleanup() {
    pump?.stop()
    pump = nil
    if started { _ = SvoiCoreStop(); started = false }
  }

  private func error(_ message: String) -> NSError {
    NSError(domain: "dev.svoi.tunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
