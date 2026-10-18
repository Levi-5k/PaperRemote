import Foundation
import Network
import XCTest
@testable import PaperGIFMac

final class DialStreamReceiverTests: XCTestCase {
    private func datagram(token: String = "secret", boot: Int = 7, seq: Int = 1, type: String = "paperGIF.dialStream") -> Data {
        Data("""
        {"type":"\(type)","version":1,"boot":\(boot),"seq":\(seq),"token":"\(token)",\
        "action":{"type":"macMedia","host":"","text":"volume","value":128,"modifiers":[]}}
        """.utf8)
    }

    func testParsesAuthorizedDatagramAndDecodesAction() throws {
        let parsed = try XCTUnwrap(DialStreamDatagram.parse(datagram(), token: "secret"))
        XCTAssertEqual(parsed.boot, 7)
        XCTAssertEqual(parsed.seq, 1)
        let request = try JSONDecoder().decode(RemoteRequest.self, from: parsed.action)
        XCTAssertEqual(request.type, "macMedia")
        XCTAssertEqual(request.text, "volume")
        XCTAssertEqual(request.value, 128)
    }

    func testRejectsWrongTokenTypeOrOversizedDatagrams() {
        XCTAssertNil(DialStreamDatagram.parse(datagram(token: "nope"), token: "secret"))
        XCTAssertNil(DialStreamDatagram.parse(datagram(), token: ""))
        XCTAssertNil(DialStreamDatagram.parse(datagram(type: "other"), token: "secret"))
        XCTAssertNil(DialStreamDatagram.parse(Data(repeating: 32, count: 4_096), token: "secret"))
        XCTAssertNil(DialStreamDatagram.parse(datagram(seq: -1), token: "secret"))
    }

    func testOrderingDropsStaleAndDuplicateValuesAndResetsOnReboot() {
        var ordering = DialStreamOrdering()
        XCTAssertTrue(ordering.accept(sender: "a", boot: 1, seq: 10))
        XCTAssertFalse(ordering.accept(sender: "a", boot: 1, seq: 10))
        XCTAssertFalse(ordering.accept(sender: "a", boot: 1, seq: 9))
        XCTAssertTrue(ordering.accept(sender: "a", boot: 1, seq: 12))
        XCTAssertTrue(ordering.accept(sender: "b", boot: 1, seq: 1))
        XCTAssertTrue(ordering.accept(sender: "a", boot: 2, seq: 1))
        XCTAssertTrue(ordering.accept(sender: "a", boot: 2, seq: 2))
        var wrap = DialStreamOrdering()
        XCTAssertTrue(wrap.accept(sender: "a", boot: 1, seq: UInt32.max))
        XCTAssertTrue(wrap.accept(sender: "a", boot: 1, seq: 0))
    }

    func testReceiverAppliesDatagramSentOverUDP() throws {
        let port = UInt16.random(in: 50_000...59_000)
        let applied = expectation(description: "applied")
        applied.assertForOverFulfill = false
        let receiver = DialStreamReceiver(port: port, token: "secret") { request in
            if request.value == 128 { applied.fulfill() }
        }
        try receiver.start()
        defer { receiver.stop() }
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .udp)
        connection.start(queue: .global())
        defer { connection.cancel() }
        // The listener may still be binding; resend until it is applied.
        for attempt in 0..<10 {
            connection.send(content: datagram(seq: attempt + 1), completion: .idempotent)
            if XCTWaiter.wait(for: [applied], timeout: 0.3) == .completed { return }
        }
        XCTFail("datagram was not applied")
    }
}
