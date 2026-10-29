import Darwin
import Foundation

enum PacketSocket {
  static func send(_ packet: Data, family: Int32, descriptor: Int32) -> Int {
    var header = UInt32(family).bigEndian
    return withUnsafePointer(to: &header) { prefix in
      packet.withUnsafeBytes { payload in
        var vectors = [
          iovec(iov_base: UnsafeMutableRawPointer(mutating: prefix), iov_len: 4),
          iovec(iov_base: UnsafeMutableRawPointer(mutating: payload.baseAddress), iov_len: payload.count)
        ]
        return vectors.withUnsafeMutableBufferPointer { vector in
          var message = msghdr()
          message.msg_iov = vector.baseAddress
          message.msg_iovlen = 2
          var result: Int
          repeat { result = Darwin.sendmsg(descriptor, &message, 0) } while result < 0 && errno == EINTR
          return result
        }
      }
    }
  }
}
