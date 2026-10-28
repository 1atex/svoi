import Darwin
import Foundation
import NetworkExtension

final class PacketPump {
  private let flow: NEPacketTunnelFlow
  private let descriptor: Int32
  private let queue = DispatchQueue(label: "dev.svoi.packets", qos: .userInitiated)
  private var source: DispatchSourceRead?
  private var active = false
  private let failed: () -> Void

  init(flow: NEPacketTunnelFlow, descriptor: Int32, failed: @escaping () -> Void) {
    self.flow = flow
    self.descriptor = descriptor
    self.failed = failed
  }

  func start() {
    queue.sync {
      active = true
      let reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
      reader.setEventHandler { [weak self] in self?.receive() }
      let descriptor = self.descriptor
      reader.setCancelHandler { Darwin.close(descriptor) }
      source = reader
      reader.resume()
      read()
    }
  }

  func stop() {
    queue.sync {
      active = false
      source?.cancel()
      source = nil
    }
  }

  private func read() {
    guard active else { return }
    flow.readPackets { [weak self] packets, families in
      guard let self = self else { return }
      self.queue.async {
        guard self.active else { return }
        for (packet, family) in zip(packets, families) {
          guard !packet.isEmpty, packet.count <= 65535,
                family.int32Value == AF_INET || family.int32Value == AF_INET6 else { continue }
          var framed = Data([0, 0, 0, UInt8(family.int32Value)])
          framed.append(packet)
          let result = framed.withUnsafeBytes { bytes in
            Darwin.send(self.descriptor, bytes.baseAddress, bytes.count, 0)
          }
          if result < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
            self.fail()
            return
          }
        }
        self.read()
      }
    }
  }

  private func receive() {
    guard active else { return }
    var buffer = [UInt8](repeating: 0, count: 65540)
    var packets: [Data] = []
    var protocols: [NSNumber] = []
    for _ in 0..<64 {
      let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
      if count < 0 {
        if errno == EAGAIN || errno == EWOULDBLOCK { break }
        if errno == EINTR { continue }
        fail()
        return
      }
      if count == 0 { fail(); return }
      guard count > 4 else { continue }
      let family = Int32(buffer[3])
      guard family == AF_INET || family == AF_INET6 else { continue }
      packets.append(Data(buffer[4..<count]))
      protocols.append(NSNumber(value: family))
    }
    if !packets.isEmpty { _ = flow.writePackets(packets, withProtocols: protocols) }
  }

  private func fail() {
    guard active else { return }
    active = false
    failed()
  }
}
