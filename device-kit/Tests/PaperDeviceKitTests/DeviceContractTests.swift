import CryptoKit
import XCTest

@testable import PaperDeviceKit

final class DeviceContractTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func reference() throws -> DeviceDescriptor {
        try DeviceDescriptor.decode(
            Data(
                contentsOf: root.appendingPathComponent(
                    "protocol/fixtures/device-descriptor-v1-screenless.json")))
    }

    func testScreenlessDescriptorAndBoardCatalogAgree() throws {
        let descriptor = try reference()
        XCTAssertNil(descriptor.display)
        XCTAssertFalse(descriptor.canUseLegacyMedia)
        XCTAssertEqual(descriptor.inputs.map(\.id), ["button-1", "encoder-1", "slider-1"])
        let index = try JSONDecoder().decode(
            BoardCatalogIndex.self,
            from: Data(contentsOf: root.appendingPathComponent("boards/index.json")))
        let entry = try XCTUnwrap(DeviceCatalog.match(index, descriptor: descriptor))
        let board = try DeviceCatalog.validated(
            Data(contentsOf: root.appendingPathComponent("boards/\(entry.path)")),
            descriptor: descriptor, entry: entry)
        XCTAssertEqual(board.layout, descriptor.layout)
    }

    func testMissingLayoutGeneratesGeometryButMalformedLayoutDoesNotFallback() throws {
        let data = try Data(contentsOf: root.appendingPathComponent(
            "protocol/fixtures/device-descriptor-v1-minimal.json"))
        let descriptor = try DeviceDescriptor.decode(data)
        XCTAssertEqual(descriptor.layout.inputs.map(\.id), ["button-1"])
        XCTAssertNil(descriptor.layout.screen)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["layout"] = NSNull()
        XCTAssertThrowsError(try DeviceDescriptor.decode(JSONSerialization.data(withJSONObject: object)))
        object.removeValue(forKey: "layout")
        object.removeValue(forKey: "display")
        XCTAssertThrowsError(try DeviceDescriptor.decode(JSONSerialization.data(withJSONObject: object)))
    }

    func testM5PaperBaselinePreserved() throws {
        let descriptor = DeviceDescriptor.legacyM5Paper(deviceID: "legacy:test")
        try descriptor.validate()
        XCTAssertTrue(descriptor.canUseLegacyMedia)
        XCTAssertEqual(descriptor.display?.width, 540)
        XCTAssertEqual(descriptor.capabilities.profileVersions, [6])
    }

    func testInvalidDimensionsAndVersionsRejected() throws {
        var descriptor = DeviceDescriptor.legacyM5Paper(deviceID: "test")
        descriptor.display?.width = 0
        XCTAssertThrowsError(try descriptor.validate())
        descriptor.display?.width = 8192
        descriptor.display?.height = 8192
        XCTAssertThrowsError(try descriptor.validate())
        descriptor.display?.width = 540
        descriptor.display?.height = 960
        descriptor.schemaVersion = 2
        XCTAssertThrowsError(try descriptor.validate())
    }

    func testInputIDsAndRangeValidated() throws {
        var descriptor = try reference()
        descriptor.inputs.append(descriptor.inputs[0])
        XCTAssertThrowsError(try descriptor.validate())
        descriptor.inputs.removeLast()
        descriptor.inputs[2].minimum = 4095
        XCTAssertThrowsError(try descriptor.validate())
        descriptor.inputs[2].minimum = 0
        descriptor.inputs[0].events = ["change"]
        XCTAssertThrowsError(try descriptor.validate())
    }

    func testGeometryCannotInventInputsOrScreen() throws {
        var descriptor = try reference()
        descriptor.layout.inputs[0].id = "unknown"
        XCTAssertThrowsError(try descriptor.validate())
        descriptor.layout.inputs[0].id = "button-1"
        descriptor.layout.screen = DeviceRect(x: 0, y: 0, width: 10, height: 10)
        XCTAssertThrowsError(try descriptor.validate())
        descriptor.layout.screen = nil
        descriptor.layout.inputs[0].x = .infinity
        XCTAssertThrowsError(try descriptor.validate())
    }

    func testGeneratedLayoutFitsAllInputs() throws {
        let inputs = (0..<128).map {
            DeviceInput(id: "button-\($0)", name: "Button", kind: "button", events: ["press"])
        }
        for display in [
            nil, DeviceDisplay(width: 1, height: 8192, touch: true, pixelFormat: "mono1"),
            DeviceDisplay(width: 8192, height: 1, touch: false, pixelFormat: "rgb565"),
        ] {
            let layout = DeviceLayout.generated(display: display, inputs: inputs)
            try layout.validate(inputIDs: Set(inputs.map(\.id)), hasDisplay: display != nil)
            XCTAssertEqual(layout.inputs.count, 128)
        }
    }

    func testRelativeAndAbsoluteClamping() throws {
        let descriptor = try reference()
        var binding = DeviceHardwareBinding(
            inputID: "encoder-1", event: "rotate",
            mode: "relative", action: "volume", minimum: 0, maximum: 100, step: 2)
        try binding.validate(for: descriptor)
        XCTAssertEqual(try binding.adjustedValue(current: 50, value: -3), 44)
        XCTAssertEqual(try binding.adjustedValue(current: 50, value: 1000), 100)
        XCTAssertEqual(try binding.adjustedValue(current: 50, value: -1000), 0)
        binding.inputID = "slider-1"
        binding.event = "change"
        binding.mode = "absolute"
        try binding.validate(for: descriptor)
        XCTAssertEqual(try binding.adjustedValue(current: 0, value: 2048, sourceMaximum: 4095), 50)
        XCTAssertEqual(try binding.adjustedValue(current: 0, value: 4095, sourceMaximum: 4095), 100)
        XCTAssertThrowsError(try binding.adjustedValue(current: 0, value: .nan))
        binding.step = 0
        XCTAssertThrowsError(try binding.validate(for: descriptor))
    }

    func testLegacyBindingRejected() {
        let binding = DeviceHardwareBinding(inputID: "encoder-1", event: "rotate", action: "volume")
        XCTAssertThrowsError(try binding.validate(for: .legacyM5Paper(deviceID: "test")))
    }

    func testRevisionMatchingAndDigests() throws {
        var descriptor = try reference()
        let data = try Data(contentsOf: root.appendingPathComponent("boards/index.json"))
        var index = try JSONDecoder().decode(BoardCatalogIndex.self, from: data)
        let entry = try XCTUnwrap(DeviceCatalog.match(index, descriptor: descriptor))
        descriptor.hardwareRevision = "unknown"
        XCTAssertNil(try DeviceCatalog.match(index, descriptor: descriptor))
        descriptor.hardwareRevision = "1"
        index.boards.append(entry)
        XCTAssertThrowsError(try DeviceCatalog.match(index, descriptor: descriptor))
        var package = try Data(contentsOf: root.appendingPathComponent("boards/\(entry.path)"))
        package.append(32)
        XCTAssertThrowsError(try DeviceCatalog.validated(package, descriptor: descriptor, entry: entry))
    }

    func testAddressValidation() throws {
        XCTAssertEqual(
            try DeviceHTTP.endpoint("192.168.1.2:8080", path: "/device").absoluteString,
            "http://192.168.1.2:8080/device")
        for address in [
            "file:///tmp/device", "http://user:password@localhost", "host/path",
            "host?target=other", "host#fragment",
        ] {
            XCTAssertThrowsError(try DeviceHTTP.endpoint(address, path: "/device"))
        }
    }

    func testLandscapeAndTurnOnlyEncoder() throws {
        let descriptor = try DeviceDescriptor.decode(
            Data(
                contentsOf: root.appendingPathComponent(
                    "protocol/fixtures/device-descriptor-v1-landscape.json")))
        XCTAssertEqual(descriptor.display?.width, 320)
        XCTAssertEqual(descriptor.inputs.first?.events, ["rotate"])
        XCTAssertFalse(descriptor.canUseLegacyMedia)
        let binding = DeviceHardwareBinding(inputID: "encoder-1", event: "press", action: "play")
        XCTAssertThrowsError(try binding.validate(for: descriptor))
    }

    func testOfflineResolutionUsesBundledBoardAndReportsFailure() async throws {
        let catalog = DeviceCatalog(indexURL: URL(string: "https://example.invalid/index.json")!)
        let descriptor = try reference()
        let result = await catalog.resolve(descriptor: descriptor)
        XCTAssertEqual(result.layout, descriptor.layout)
        XCTAssertTrue(result.message.contains("bundled board layout"))
        XCTAssertTrue(result.message.contains("GitHub unavailable"))
    }

    func testOfflineResolutionRetainsCacheAndInvalidCacheReportsError() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = try reference()
        let identity = Data("\(descriptor.boardID)\n\(descriptor.hardwareRevision)".utf8)
        let digest = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent("\(digest).json")
        let package = try Data(
            contentsOf: root.appendingPathComponent("boards/esp32-screenless-reference.json"))
        try package.write(to: file)
        let catalog = DeviceCatalog(
            cacheDirectory: directory, indexURL: URL(string: "https://example.invalid/index.json")!)
        let cached = await catalog.resolve(descriptor: descriptor)
        XCTAssertTrue(cached.message.contains("cached board layout"))
        XCTAssertEqual(try Data(contentsOf: file), package)
        try Data("bad json".utf8).write(to: file)
        let invalid = await catalog.resolve(descriptor: descriptor)
        XCTAssertTrue(invalid.message.contains("Cached layout rejected"))
        XCTAssertEqual(invalid.layout, descriptor.layout)
    }

    func testNativeAdapterDoesNotFallbackOnMalformedOrUnauthorizedDescriptor() async throws {
        for status in [200, 401, 500] {
            let adapter = NativeDeviceAdapter { request, _ in
                XCTAssertEqual(request.url?.path, "/device")
                return (Data("invalid".utf8), status)
            }
            do {
                _ = try await adapter.identify(address: "device.local")
                XCTFail("Invalid descriptor was accepted")
            } catch {
                XCTAssertFalse(error is CancellationError)
            }
        }
    }

    func testNativeAdapterOnlyRecognizesVerifiedLegacyAfter404() async throws {
        let adapter = NativeDeviceAdapter { request, _ in
            if request.url?.path == "/device" { return (Data(), 404) }
            XCTAssertEqual(request.url?.path, "/status")
            return (Data(#"{"device":"paperGIF","firmware":"1.0.7"}"#.utf8), 200)
        }
        let (descriptor, kind) = try await adapter.identify(address: "device.local:8080")
        XCTAssertEqual(kind, .legacyM5Paper)
        XCTAssertEqual(descriptor.capabilities.profileVersions, [6])
        XCTAssertTrue(descriptor.deviceID.contains("8080"))
        let unknown = NativeDeviceAdapter { request, _ in
            (Data(#"{"device":"unknown"}"#.utf8), request.url?.path == "/device" ? 404 : 200)
        }
        do {
            _ = try await unknown.identify(address: "device.local")
            XCTFail("Unknown protocol was accepted")
        } catch {}
    }

    @MainActor
    func testNativeSessionConnectsOfflineAndIgnoresStaleIdentification() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = DeviceSession(
            storageURL: directory.appendingPathComponent("devices.json"),
            catalog: DeviceCatalog(indexURL: URL(string: "https://example.invalid/index.json")!))
        let descriptor = try reference()
        let data = try JSONEncoder().encode(descriptor)
        let adapter = NativeDeviceAdapter { _, _ in (data, 200) }
        try await session.connect(address: "first.local", adapter: adapter)
        XCTAssertTrue(session.isVerified)
        try session.saveProfile(Data("first".utf8))
        var other = descriptor
        other.deviceID = "other"
        let otherData = try JSONEncoder().encode(other)
        let started = expectation(description: "identification started")
        let slow = NativeDeviceAdapter { _, _ in
            started.fulfill()
            try await Task.sleep(for: .milliseconds(50))
            return (otherData, 200)
        }
        let pending = Task { try await session.connect(address: "other.local", adapter: slow) }
        await fulfillment(of: [started], timeout: 2)
        session.select(id: descriptor.deviceID)
        do {
            try await pending.value
            XCTFail("Stale identification completed")
        } catch is CancellationError {}
        XCTAssertEqual(session.selectedID, descriptor.deviceID)
        XCTAssertEqual(session.profileData, Data("first".utf8))
        XCTAssertFalse(session.isVerified)
        try await session.connect(address: "first.local", adapter: adapter)
        XCTAssertTrue(session.isVerified)
        session.address = "different.local"
        XCTAssertFalse(session.isVerified)
        XCTAssertFalse(session.isLoading)
    }

    @MainActor
    func testSavedProfilesAreIsolatedAndOverridesValidated() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("devices.json")
        let first = try reference()
        var second = first
        second.deviceID = "fixture:other"
        let records = [
            SavedDevice(
                descriptor: first, address: "first.local", adapter: .native, profile: Data("first".utf8)),
            SavedDevice(
                descriptor: second, address: "second.local", adapter: .native, profile: Data("second".utf8)),
        ]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: file)
        let session = DeviceSession(storageURL: file)
        session.select(id: first.id)
        XCTAssertFalse(session.isVerified)
        XCTAssertEqual(session.profileData, Data("first".utf8))
        try session.saveProfile(Data("changed".utf8))
        session.select(id: second.id)
        XCTAssertEqual(session.profileData, Data("second".utf8))
        XCTAssertThrowsError(try session.setLayoutOverride(DeviceLayout(width: -1, height: 100)))
        let reloaded = DeviceSession(storageURL: file)
        reloaded.select(id: first.id)
        XCTAssertEqual(reloaded.profileData, Data("changed".utf8))
    }
}
