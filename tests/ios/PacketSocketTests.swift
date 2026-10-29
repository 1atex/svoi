import Darwin
import Foundation
import XCTest

final class PacketSocketTests: XCTestCase {
  private func withSockets(_ body: (Int32, Int32) throws -> Void) rethrows {
    var pair: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &pair) == 0 else { XCTFail("socketpair failed"); return }
    defer { Darwin.close(pair[0]); Darwin.close(pair[1]) }
    var timeout = timeval(tv_sec: 1, tv_usec: 0)
    _ = setsockopt(pair[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    try body(pair[0], pair[1])
  }

  func testIPv4AndIPv6FramesKeepPayloadAndDatagramBoundaries() {
    withSockets { sender, receiver in
      for family in [AF_INET, AF_INET6] {
        let payload = Data((0..<1500).map { UInt8($0 % 251) })
        XCTAssertEqual(PacketSocket.send(payload, family: family, descriptor: sender), payload.count + 4)
        var bytes = [UInt8](repeating: 0, count: 65540)
        let count = Darwin.recv(receiver, &bytes, bytes.count, 0)
        XCTAssertEqual(count, payload.count + 4)
        XCTAssertEqual(Array(bytes.prefix(4)), [0, 0, 0, UInt8(family)])
        XCTAssertEqual(Data(bytes[4..<count]), payload)
      }
    }
  }

  func testNonblockingBackpressureReturnsWithoutSpinning() {
    withSockets { sender, _ in
      XCTAssertNotEqual(fcntl(sender, F_SETFL, O_NONBLOCK), -1)
      var size: Int32 = 8192
      _ = setsockopt(sender, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
      let payload = Data(repeating: 0x45, count: 1500)
      var blocked = false
      let start = Date()
      for _ in 0..<4096 {
        if PacketSocket.send(payload, family: AF_INET, descriptor: sender) < 0 {
          XCTAssertTrue(errno == EAGAIN || errno == EWOULDBLOCK || errno == ENOBUFS)
          blocked = true
          break
        }
      }
      XCTAssertTrue(blocked)
      XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }
  }

  func testClosedDescriptorIsAnError() {
    XCTAssertEqual(PacketSocket.send(Data([0x45]), family: AF_INET, descriptor: -1), -1)
    XCTAssertEqual(errno, EBADF)
  }
}
