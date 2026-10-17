import Foundation
import XCTest
@testable import PaperDeviceKit

#if os(macOS)
final class NativeTransportTests: XCTestCase {
    @MainActor
    func testRealHTTPDescriptorAndAuthenticatedProfileRoundTrip() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try XCTUnwrap(Bundle.module.url(forResource: "device_server", withExtension: "py", subdirectory: "Fixtures"))
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, root.path]
        process.standardOutput = output
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let portData = output.fileHandleForReading.availableData
        let port = try XCTUnwrap(Int(String(decoding: portData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = DeviceSession(storageURL: directory.appendingPathComponent("devices.json"),
            catalog: DeviceCatalog(indexURL: URL(string: "https://example.invalid/index.json")!))
        try await session.connect(address: "127.0.0.1:\(port)")
        XCTAssertTrue(session.isVerified)
        XCTAssertEqual(session.descriptor?.boardID, "paperremote.esp32-screenless-reference")
        let loaded = try await session.loadProfile(token: "fixture-token")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: loaded) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 7)
        object["updatedAtMilliseconds"] = 1234
        let updated = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        try await session.sendProfile(updated, token: "fixture-token")
        XCTAssertEqual(session.profileData, updated)
        let reloaded = try await session.loadProfile(token: "fixture-token")
        XCTAssertEqual(reloaded, updated)
        do {
            try await session.sendProfile(updated, token: "incorrect")
            XCTFail("Unauthorized write was accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("401"))
        }
        object["updatedAtMilliseconds"] = 666
        let rejected = try JSONSerialization.data(withJSONObject: object)
        do {
            try await session.sendProfile(rejected, token: "fixture-token")
            XCTFail("A failed installation was reported as success")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("did not install"))
        }
        XCTAssertEqual(session.profileData, updated)
        object["version"] = 8
        let downgraded = try JSONSerialization.data(withJSONObject: object)
        do {
            try await session.sendProfile(downgraded, token: "fixture-token")
            XCTFail("Unsupported version was uploaded")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("negotiated version"))
        }
    }
}
#endif
