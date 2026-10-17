import Foundation
import XCTest
@testable import PaperDeviceKit

final class DeviceControlsTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Self.root.appendingPathComponent("protocol/fixtures/\(name)"))
    }

    func testDescriptorControlsDecodeValidateAndRoundTrip() throws {
        let descriptor = try DeviceDescriptor.decode(fixture("device-descriptor-v1-controls.json"))
        XCTAssertEqual(descriptor.controls.map(\.id), ["slideshow", "sleepDelay", "screenSaver", "battery", "restart"])
        XCTAssertEqual(descriptor.capabilities.transports, ["http", "ble"])
        XCTAssertTrue(descriptor.capabilities.supports(transport: "ble"))
        let encoded = try JSONEncoder().encode(descriptor)
        XCTAssertEqual(try DeviceDescriptor.decode(encoded), descriptor)

        let legacy = try DeviceDescriptor.decode(fixture("device-descriptor-v1-screenless.json"))
        XCTAssertTrue(legacy.controls.isEmpty)
        XCTAssertNil(legacy.capabilities.transports)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        XCTAssertNil(object["controls"], "Descriptors without controls must not gain an empty array")
    }

    func testInvalidControlsAreRejected() throws {
        var descriptor = try DeviceDescriptor.decode(fixture("device-descriptor-v1-controls.json"))
        let valid = descriptor
        descriptor.controls.append(descriptor.controls[0])
        XCTAssertThrowsError(try descriptor.validate())
        descriptor = valid
        descriptor.controls[1].step = 0
        XCTAssertThrowsError(try descriptor.validate())
        descriptor = valid
        descriptor.controls[1].maximum = descriptor.controls[1].minimum
        XCTAssertThrowsError(try descriptor.validate())
        descriptor = valid
        descriptor.controls[2].options = [.init(value: "a", name: "A"), .init(value: "a", name: "B")]
        XCTAssertThrowsError(try descriptor.validate())
        descriptor = valid
        descriptor.controls[4].readOnly = true
        XCTAssertThrowsError(try descriptor.validate())
        descriptor = valid
        descriptor.controls[0].id = "has space"
        XCTAssertThrowsError(try descriptor.validate())
        descriptor = valid
        descriptor.capabilities.transports = ["http", "usb"]
        XCTAssertThrowsError(try descriptor.validate())
    }

    func testValueNormalization() throws {
        let descriptor = try DeviceDescriptor.decode(fixture("device-descriptor-v1-controls.json"))
        let controls = Dictionary(uniqueKeysWithValues: descriptor.controls.map { ($0.id, $0) })
        let delay = try XCTUnwrap(controls["sleepDelay"])
        XCTAssertEqual(try delay.normalized(.number(44)), .number(30))
        XCTAssertEqual(try delay.normalized(.number(45)), .number(60))
        XCTAssertEqual(try delay.normalized(.number(9999)), .number(3600))
        XCTAssertEqual(try delay.normalized(.number(-5)), .number(30))
        XCTAssertThrowsError(try delay.normalized(.bool(true)))
        XCTAssertThrowsError(try delay.normalized(.number(.nan)))
        XCTAssertEqual(try controls["slideshow"]!.normalized(.bool(false)), .bool(false))
        XCTAssertThrowsError(try controls["slideshow"]!.normalized(.number(1)))
        XCTAssertEqual(try controls["screenSaver"]!.normalized(.string("clock")), .string("clock"))
        XCTAssertThrowsError(try controls["screenSaver"]!.normalized(.string("other")))
        XCTAssertThrowsError(try controls["battery"]!.normalized(.number(50))) { error in
            XCTAssertEqual(error as? DeviceControlError, .readOnly)
        }
        XCTAssertNil(try controls["restart"]!.normalized(nil))
        XCTAssertThrowsError(try controls["restart"]!.normalized(.bool(true)))
    }

    func testSnapshotFilteringDropsUnknownAndMistypedValues() throws {
        let descriptor = try DeviceDescriptor.decode(fixture("device-descriptor-v1-controls.json"))
        let snapshot = try DeviceControlSnapshot.decode(fixture("device-controls-v1-snapshot.json"))
        XCTAssertEqual(snapshot.filtered(for: descriptor.controls).count, 4)
        let noisy = DeviceControlSnapshot(values: [
            "slideshow": .number(1), "unknown": .bool(true), "battery": .number(101), "screenSaver": .string("clock"),
        ])
        XCTAssertEqual(noisy.filtered(for: descriptor.controls), ["screenSaver": .string("clock")])
    }

    func testIntegerValuesEncodeWithoutFraction() throws {
        let data = try DeviceControlSetRequest(id: "sleepDelay", value: .number(600)).encoded()
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"id":"sleepDelay","value":600}"#)
        let action = try DeviceControlSetRequest(id: "restart", value: nil).encoded()
        XCTAssertEqual(String(decoding: action, as: UTF8.self), #"{"id":"restart"}"#)
    }

    func testBLESnapshotFramesReassemble() throws {
        let body = Data(#"{"values":{"slideshow":true,"sleepDelay":900}}"#.utf8)
        var assembler = DeviceBLEFrames.SnapshotAssembler()
        let middle = body.count / 2
        XCTAssertNil(try assembler.receive(Data([0x51, 0]) + body.prefix(middle)))
        XCTAssertNil(try assembler.receive(Data([0x60, 1, 2])), "Unrelated opcodes are ignored")
        let snapshot = try XCTUnwrap(try assembler.receive(Data([0x51, 1]) + body.dropFirst(middle)))
        XCTAssertEqual(snapshot.values["sleepDelay"], .number(900))
        XCTAssertThrowsError(try assembler.receive(Data([0x51, 1]) + Data("not json".utf8)))
        XCTAssertNotNil(try assembler.receive(Data([0x51, 1]) + body), "Assembler recovers after an error")
    }

    func testBLESetAndRelayEncoding() throws {
        let set = try DeviceBLEFrames.setRequest(.init(id: "slideshow", value: .bool(false)))
        XCTAssertEqual(set.first, 0x52)
        XCTAssertEqual(String(decoding: set.dropFirst(), as: UTF8.self), #"{"id":"slideshow","value":false}"#)
        XCTAssertThrowsError(try DeviceBLEFrames.setRequest(.init(id: "x", value: .string(String(repeating: "a", count: 300)))))
        XCTAssertEqual(try DeviceBLEFrames.relayRegistration(role: .computer, token: "abc"), Data([0x70, 0]) + Data("abc".utf8))
        XCTAssertEqual(try DeviceBLEFrames.relayRegistration(role: .forwarder, token: "abc").prefix(2), Data([0x70, 1]))
        XCTAssertThrowsError(try DeviceBLEFrames.relayRegistration(role: .computer, token: ""))
        XCTAssertEqual(DeviceBLEFrames.relayAck(sequence: 7, delivered: false), Data([0x73, 7, 1]))
        XCTAssertNil(DeviceControlError(bleStatus: 0))
        XCTAssertEqual(DeviceControlError(bleStatus: 3), .readOnly)
    }

    func testRelayFramesReassemblePerSequence() throws {
        let message = try fixture("device-controls-v1-relay.json")
        var assembler = DeviceBLEFrames.RelayAssembler()
        let split = message.count / 3
        XCTAssertNil(try assembler.receive(Data([0x72, 1, 0]) + message.prefix(split)))
        XCTAssertNil(try assembler.receive(Data([0x72, 2, 0]) + message.prefix(split)))
        let first = try XCTUnwrap(try assembler.receive(Data([0x72, 1, 1]) + message.dropFirst(split)))
        XCTAssertEqual(first.sequence, 1)
        XCTAssertEqual(first.computerID, "fixture-mac")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: first.body) as? [String: Any])
        XCTAssertEqual(body["type"] as? String, "macMedia")
        XCTAssertEqual(try assembler.receive(Data([0x72, 2, 1]) + message.dropFirst(split))?.sequence, 2)
        XCTAssertThrowsError(try assembler.receive(Data([0x72, 3, 1]) + Data(#"{"body":{}}"#.utf8)))
    }

    private struct FakeTransport: DeviceControlTransport {
        let name: String
        let failure: DeviceControlError?
        let values: [String: DeviceControlValue]
        func snapshot() async throws -> DeviceControlSnapshot {
            if let failure { throw failure }
            return DeviceControlSnapshot(values: values)
        }
        func set(_ request: DeviceControlSetRequest) async throws -> DeviceControlSnapshot {
            if let failure { throw failure }
            var values = values
            values[request.id] = request.value
            return DeviceControlSnapshot(values: values)
        }
    }

    @MainActor
    func testModelFallsBackOnlyOnTransportFailures() async throws {
        let descriptor = try DeviceDescriptor.decode(fixture("device-descriptor-v1-controls.json"))
        let model = DeviceControlsModel()
        model.configure(controls: descriptor.controls, transports: [
            FakeTransport(name: "Wi-Fi", failure: .transport("offline"), values: [:]),
            FakeTransport(name: "Bluetooth", failure: nil, values: ["slideshow": .bool(true)]),
        ])
        await model.refresh()
        XCTAssertEqual(model.activeTransport, "Bluetooth")
        XCTAssertEqual(model.values["slideshow"], .bool(true))
        XCTAssertNil(model.error)
        XCTAssertEqual(model.groups.map(\.name), ["Display", "Power", "Status"])

        model.configure(controls: descriptor.controls, transports: [
            FakeTransport(name: "Wi-Fi", failure: .unauthorized, values: [:]),
            FakeTransport(name: "Bluetooth", failure: nil, values: ["slideshow": .bool(true)]),
        ])
        await model.refresh()
        XCTAssertNil(model.activeTransport, "A device rejection must not be retried over Bluetooth")
        XCTAssertEqual(model.error, DeviceControlError.unauthorized.localizedDescription)
    }

    @MainActor
    func testModelSetIsOptimisticAndRollsBackOnRejection() async throws {
        let descriptor = try DeviceDescriptor.decode(fixture("device-descriptor-v1-controls.json"))
        let model = DeviceControlsModel()
        let delay = descriptor.controls[1]
        model.configure(controls: descriptor.controls, transports: [
            FakeTransport(name: "Wi-Fi", failure: nil, values: ["sleepDelay": .number(900)]),
        ])
        await model.refresh()
        model.set(delay, to: .number(601))
        XCTAssertEqual(model.values["sleepDelay"], .number(600))
        XCTAssertTrue(model.pendingIDs.contains("sleepDelay"))
        for _ in 0..<100 where !model.pendingIDs.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.values["sleepDelay"], .number(600))
        XCTAssertTrue(model.pendingIDs.isEmpty)

        model.configure(controls: descriptor.controls, transports: [
            FakeTransport(name: "Wi-Fi", failure: .invalidValue, values: [:]),
        ])
        model.receive(DeviceControlSnapshot(values: ["sleepDelay": .number(900)]), via: "Wi-Fi")
        model.set(delay, to: .number(120))
        for _ in 0..<100 where !model.pendingIDs.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.values["sleepDelay"], .number(900))
        XCTAssertEqual(model.error, DeviceControlError.invalidValue.localizedDescription)
    }

    #if os(macOS)
    func testRealHTTPControlsRoundTrip() async throws {
        let script = try XCTUnwrap(Bundle.module.url(forResource: "device_server", withExtension: "py", subdirectory: "Fixtures"))
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, Self.root.path]
        process.standardOutput = output
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let port = try XCTUnwrap(Int(String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        let transport = HTTPDeviceControlTransport(address: "127.0.0.1:\(port)", token: "fixture-token")
        let snapshot = try await transport.snapshot()
        XCTAssertEqual(snapshot.values["sleepDelay"], .number(900))
        let updated = try await transport.set(.init(id: "sleepDelay", value: .number(600)))
        XCTAssertEqual(updated.values["sleepDelay"], .number(600))
        _ = try await transport.set(.init(id: "restart", value: nil))
        await XCTAssertThrowsErrorAsync(try await transport.set(.init(id: "battery", value: .number(5))), .readOnly)
        await XCTAssertThrowsErrorAsync(try await transport.set(.init(id: "missing", value: .bool(true))), .unknownControl)
        await XCTAssertThrowsErrorAsync(try await transport.set(.init(id: "sleepDelay", value: .number(1))), .invalidValue)
        let unauthorized = HTTPDeviceControlTransport(address: "127.0.0.1:\(port)", token: "wrong")
        await XCTAssertThrowsErrorAsync(try await unauthorized.snapshot(), .unauthorized)
        let closed = HTTPDeviceControlTransport(address: "127.0.0.1:1", token: "fixture-token")
        do {
            _ = try await closed.snapshot()
            XCTFail("Closed port succeeded")
        } catch let error as DeviceControlError {
            XCTAssertTrue(error.isTransportFailure, "Unreachable devices must be classified as transport failures")
        }
    }

    private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T,
                                              _ expected: DeviceControlError,
                                              line: UInt = #line) async {
        do {
            _ = try await expression()
            XCTFail("Expected \(expected)", line: line)
        } catch {
            XCTAssertEqual(error as? DeviceControlError, expected, line: line)
        }
    }
    #endif
}
