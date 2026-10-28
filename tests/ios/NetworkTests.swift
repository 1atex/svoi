import XCTest

struct SvoiError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

final class NetworkTests: XCTestCase {
  private func response() -> Data {
    var bytes = [UInt8](DNSWire.query("example.com", id: 0x1234))
    bytes[2] = 0x81; bytes[3] = 0x80; bytes[7] = 1
    bytes += [0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 93, 184, 215, 14]
    return Data(bytes)
  }

  func testDNSRejectsErrorsWrongTransactionAndTruncatedAnswers() {
    let good = response()
    XCTAssertTrue(DNSWire.valid(good, id: 0x1234))
    XCTAssertFalse(DNSWire.valid(good, id: 0x4321))
    for count in 0..<good.count {
      XCTAssertFalse(DNSWire.valid(good.prefix(count), id: 0x1234))
    }
    var bad = good; bad[3] = 0x83
    XCTAssertFalse(DNSWire.valid(bad, id: 0x1234))
    bad = good; bad[2] |= 0x02
    XCTAssertFalse(DNSWire.valid(bad, id: 0x1234))
    bad = good; bad[good.count - 6] = 0xff
    XCTAssertFalse(DNSWire.valid(bad, id: 0x1234))
  }

  func testDNSCancellationBeforeStartResumesPromptly() async {
    let exchange = DNSExchange(server: "127.0.0.1", name: "example.com")
    let task = Task { try await exchange.run() }
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Cancelled exchange returned a measurement")
    } catch is CancellationError {} catch {
      XCTFail("Cancellation returned \(error)")
    }
  }

  func testPartialResultsDoNotAppearReliable() {
    let provider = DNSProvider(name: "Fixture", address: "127.0.0.1")
    XCTAssertNil(DNSMeasurement(provider: provider, samples: []).median)
    let partial = DNSMeasurement(provider: provider, samples: [8, 2, 4, 6])
    XCTAssertEqual(partial.median, 5)
    XCTAssertFalse(partial.reliable)
    XCTAssertTrue(DNSMeasurement(provider: provider, samples: [1, 2, 3, 4, 5, 6]).reliable)
  }
}
