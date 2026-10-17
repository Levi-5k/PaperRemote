import Foundation
import PaperDeviceKit
import XCTest
@testable import PaperGIFMac

@MainActor
final class DeviceBluetoothLinkTests: XCTestCase {
    private final class Writes {
        var frames: [Data] = []
    }

    private func snapshotFrames(_ json: String, split: Int = 8) -> [Data] {
        let bytes = Array(json.utf8)
        return stride(from: 0, to: bytes.count, by: split).map { start in
            let end = min(start + split, bytes.count)
            return Data([0x51, end == bytes.count ? 1 : 0]) + Data(bytes[start..<end])
        }
    }

    private func waitForWrite(_ writes: Writes, count: Int) async {
        for _ in 0..<200 where writes.frames.count < count { await Task.yield() }
    }

    func testSnapshotRequestAssemblesFragments() async throws {
        let writes = Writes()
        let channel = DeviceBLEChannel { _ in true }
        channel.open { writes.frames.append($0) }
        async let snapshot = channel.requestSnapshot()
        await waitForWrite(writes, count: 1)
        XCTAssertEqual(writes.frames.first, Data([0x50]))
        snapshotFrames(#"{"values":{"slideshow":true,"sleepDelay":900}}"#).forEach(channel.receive)
        let values = try await snapshot.values
        XCTAssertEqual(values["slideshow"], .bool(true))
        XCTAssertEqual(values["sleepDelay"], .number(900))
    }

    func testSetWaitsForStatusThenSnapshot() async throws {
        let writes = Writes()
        let channel = DeviceBLEChannel { _ in true }
        var unsolicited: [DeviceControlSnapshot] = []
        channel.onSnapshot = { unsolicited.append($0) }
        channel.open { writes.frames.append($0) }
        async let result = channel.set(DeviceControlSetRequest(id: "sleepDelay", value: .number(600)))
        await waitForWrite(writes, count: 1)
        XCTAssertEqual(writes.frames.first, Data([0x52]) + Data(#"{"id":"sleepDelay","value":600}"#.utf8))
        // A snapshot pushed before the status belongs to an earlier change.
        snapshotFrames(#"{"values":{"sleepDelay":900}}"#).forEach(channel.receive)
        channel.receive(Data([0x53, 0]))
        snapshotFrames(#"{"values":{"sleepDelay":600}}"#).forEach(channel.receive)
        let values = try await result.values
        XCTAssertEqual(values["sleepDelay"], .number(600))
        XCTAssertEqual(unsolicited.first?.values["sleepDelay"], .number(900))
    }

    func testRejectedSetSurfacesDeviceError() async {
        let writes = Writes()
        let channel = DeviceBLEChannel { _ in true }
        channel.open { writes.frames.append($0) }
        async let result = channel.set(DeviceControlSetRequest(id: "battery", value: .number(1)))
        await waitForWrite(writes, count: 1)
        channel.receive(Data([0x53, 3]))
        do {
            _ = try await result
            XCTFail("expected read-only rejection")
        } catch {
            XCTAssertEqual(error as? DeviceControlError, .readOnly)
            XCTAssertFalse((error as? DeviceControlError)?.isTransportFailure ?? true)
        }
    }

    func testTimeoutAndDisconnectAreTransportFailures() async {
        let channel = DeviceBLEChannel(timeout: .milliseconds(50)) { _ in true }
        channel.open { _ in }
        do {
            _ = try await channel.requestSnapshot()
            XCTFail("expected timeout")
        } catch {
            XCTAssertTrue((error as? DeviceControlError)?.isTransportFailure == true)
        }

        let closed = DeviceBLEChannel { _ in true }
        do {
            _ = try await closed.requestSnapshot()
            XCTFail("expected disconnected failure")
        } catch {
            XCTAssertTrue((error as? DeviceControlError)?.isTransportFailure == true)
        }
    }

    func testRequestsAreSerialized() async throws {
        let writes = Writes()
        let channel = DeviceBLEChannel { _ in true }
        channel.open { writes.frames.append($0) }
        let first = Task { try await channel.requestSnapshot() }
        await waitForWrite(writes, count: 1)
        XCTAssertEqual(writes.frames.first, Data([0x50]))
        let second = Task { try await channel.set(DeviceControlSetRequest(id: "slideshow", value: .bool(false))) }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(writes.frames.count, 1, "second request must wait for the first reply")
        snapshotFrames(#"{"values":{"slideshow":true}}"#).forEach(channel.receive)
        await waitForWrite(writes, count: 2)
        XCTAssertEqual(writes.frames.count, 2)
        channel.receive(Data([0x53, 0]))
        snapshotFrames(#"{"values":{"slideshow":false}}"#).forEach(channel.receive)
        let a = try await first.value
        let b = try await second.value
        XCTAssertEqual(a.values["slideshow"], .bool(true))
        XCTAssertEqual(b.values["slideshow"], .bool(false))
    }

    func testRelayRegistrationAndActionAck() async throws {
        let writes = Writes()
        var delivered: [Data] = []
        let channel = DeviceBLEChannel { body in
            delivered.append(body)
            return true
        }
        var registration: Bool?
        channel.onRegistration = { registration = $0 }
        channel.open { writes.frames.append($0) }
        try channel.register(token: "mac-token")
        XCTAssertEqual(writes.frames.last, Data([0x70, 0]) + Data("mac-token".utf8))
        channel.receive(Data([0x71, 0]) + Data("computer-1".utf8))
        XCTAssertEqual(registration, true)

        let message = Array(#"{"computerId":"computer-1","body":{"type":"macMedia","text":"playPause"}}"#.utf8)
        channel.receive(Data([0x72, 9, 0]) + Data(message[..<20]))
        channel.receive(Data([0x72, 9, 1]) + Data(message[20...]))
        await waitForWrite(writes, count: 2)
        XCTAssertEqual(writes.frames.last, Data([0x73, 9, 0]))
        let body = try XCTUnwrap(delivered.first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(object, ["type": "macMedia", "text": "playPause"])

        channel.receive(Data([0x71, 1]))
        XCTAssertEqual(registration, false)
    }

    func testFailedRelayActionIsAcknowledgedAsFailed() async {
        let writes = Writes()
        let channel = DeviceBLEChannel { _ in false }
        channel.open { writes.frames.append($0) }
        channel.receive(Data([0x72, 4, 1]) + Data(#"{"computerId":"x","body":{"type":"macKey"}}"#.utf8))
        await waitForWrite(writes, count: 1)
        XCTAssertEqual(writes.frames.last, Data([0x73, 4, 1]))
    }

    func testRelayOnlySearchesAfterRepeatedLANFailures() {
        let relay = DeviceBluetoothRelay(actionHandler: { _ in true }, probe: { _ in true })
        relay.updateReachability(false)
        XCTAssertTrue(relay.lanReachable, "a single missed probe must not start Bluetooth")
        XCTAssertEqual(relay.state, .idle)
        relay.updateReachability(true)
        relay.updateReachability(false)
        XCTAssertTrue(relay.lanReachable)
    }
}
