import Foundation
import XCTest
@testable import PaperDeviceKit

#if os(macOS)
final class NativeTransportTests: XCTestCase {
    func testPhysicalHTTPImageRoundTrip() async throws {
        guard let address = ProcessInfo.processInfo.environment["PAPERGIF_HTTP_IMAGE_DEVICE"] else {
            throw XCTSkip("Set PAPERGIF_HTTP_IMAGE_DEVICE to validate a physical native image API")
        }
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/paperGIF Mac/config.json")
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any])
        let token = try XCTUnwrap(config["token"] as? String)
        let transport = HTTPDeviceImageTransport(address: address, token: token)
        let screenID = UUID(), buttonID = UUID()
        func checksum(_ data: Data) -> UInt32 {
            var result = UInt32.max
            for byte in data {
                result ^= UInt32(byte)
                for _ in 0..<8 { result = (result >> 1) ^ (0xedb88320 & (0 &- (result & 1))) }
            }
            return ~result
        }
        func count() async throws -> Int {
            var request = URLRequest(url: try DeviceHTTP.endpoint(address, path: "/debug/inputs"))
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, status) = try await DeviceHTTP.request(request, maximumBytes: 16384)
            XCTAssertEqual(status, 200)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            return try XCTUnwrap(object["screensaverImages"] as? Int)
        }
        func remove(_ id: UUID, button: Bool) async throws {
            var request = URLRequest(url: try DeviceHTTP.endpoint(address, path: "/images"))
            request.httpMethod = "DELETE"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(id.uuidString, forHTTPHeaderField: "X-Image-ID")
            request.setValue(button ? "button" : "screen", forHTTPHeaderField: "X-Image-Kind")
            let (_, status) = try await DeviceHTTP.request(request, maximumBytes: 4096)
            XCTAssertTrue(status == 200 || status == 404)
        }
        let before = try await count()
        var image = Data(repeating: 0, count: 10 + 368 * 448 * 2)
        image.replaceSubrange(0..<10, with: [80, 73, 77, 71, 1, 0, 112, 1, 192, 1])
        for offset in stride(from: 10, to: image.count, by: 2) { image[offset + 1] = 248 }
        let crc = checksum(image)
        var stage = "initial full-size upload"
        do {
            let installed = try await transport.upload(image, id: screenID, name: "HTTP API validation", checksum: crc)
            stage = "duplicate upload"
            let repeated = try await transport.upload(image, id: screenID, name: "Retry", checksum: crc)
            XCTAssertEqual(installed.index, repeated.index)
            let after = try await count()
            XCTAssertEqual(after, before + 1)
            stage = "bad CRC rejection"
            do {
                _ = try await transport.upload(image, id: screenID, name: "Bad CRC", checksum: crc &+ 1)
                XCTFail("Corrupt upload accepted")
            } catch let error as DeviceControlError { XCTAssertFalse(error.isTransportFailure) }
            image[10] ^= 1
            stage = "conflicting content rejection"
            do {
                _ = try await transport.upload(image, id: screenID, name: "Conflict", checksum: checksum(image))
                XCTFail("Request ID reused with different pixels")
            } catch let error as DeviceControlError { XCTAssertFalse(error.isTransportFailure) }
            let button = Data([80, 66, 71, 73, 1, 0, 2, 0, 2, 0, 0, 85, 170, 255])
            stage = "button upload and retry"
            _ = try await transport.upload(button, id: buttonID, name: "Button validation", checksum: checksum(button), button: true)
            _ = try await transport.upload(button, id: buttonID, name: "Button retry", checksum: checksum(button), button: true)
            stage = "unauthorized rejection"
            do {
                _ = try await HTTPDeviceImageTransport(address: address, token: "invalid-fixture-token")
                    .upload(button, id: buttonID, name: "Unauthorized", checksum: checksum(button), button: true)
                XCTFail("Unauthorized image accepted")
            } catch let error as DeviceControlError { XCTAssertEqual(error, .unauthorized) }
        } catch {
            print("Physical HTTP image test failed during \(stage)")
            var diagnostic = URLRequest(url: try DeviceHTTP.endpoint(address, path: "/debug/inputs"))
            diagnostic.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let (data, _) = try? await DeviceHTTP.request(diagnostic, maximumBytes: 16384),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let imageHTTP = object["imageHTTP"] {
                print("Image HTTP diagnostic: \(imageHTTP)")
            }
            try? await remove(screenID, button: false)
            try? await remove(buttonID, button: true)
            throw error
        }
        try await remove(screenID, button: false)
        try await remove(buttonID, button: true)
        let final = try await count()
        XCTAssertEqual(final, before)
        print("Verified physical native HTTP: 329738-byte screen image, button image, retry deduplication, CRC/conflict/auth rejection, and fixture cleanup")
    }

    func testImageUploadHeadersAndAcknowledgement() async throws {
        let id = UUID()
        let bytes = Data([80, 73, 77, 71, 1, 0, 1, 0, 1, 0, 0, 248])
        let response = try JSONSerialization.data(withJSONObject: ["ok": true, "id": id.uuidString, "index": 3])
        let transport = HTTPDeviceImageTransport(address: "127.0.0.1:1234", token: "fixture-token") { request, maximum in
            XCTAssertEqual(request.url?.path, "/images")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.httpBody, bytes)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Image-ID"), id.uuidString)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Image-CRC32"), "1234ABCD")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Image-Kind"), "screen")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Image-Name"), "SafeTitle")
            XCTAssertEqual(maximum, 4096)
            return (response, 201)
        }
        let acknowledgement = try await transport.upload(bytes, id: id, name: "Safe\r\nTitle", checksum: 0x1234abcd)
        XCTAssertEqual(acknowledgement.index, 3)
        for status in [200, 201] {
            for object: [String: Any] in [
                ["ok": false, "id": id.uuidString, "index": 0],
                ["ok": true, "id": UUID().uuidString, "index": 0],
                ["ok": true, "id": id.uuidString, "index": 128],
                ["ok": true, "id": id.uuidString],
            ] {
                let invalid = try JSONSerialization.data(withJSONObject: object)
                do {
                    _ = try await HTTPDeviceImageTransport(address: "127.0.0.1", token: "") { _, _ in (invalid, status) }
                        .upload(bytes, id: id, name: "Image", checksum: 0)
                    XCTFail("Invalid image acknowledgement accepted")
                } catch {}
            }
        }
        do {
            _ = try await HTTPDeviceImageTransport(address: "127.0.0.1", token: "") { _, _ in
                (Data("{\"error\":\"unauthorized\"}".utf8), 401)
            }.upload(bytes, id: id, name: "Image", checksum: 0)
            XCTFail("Unauthorized image accepted")
        } catch let error as DeviceControlError {
            XCTAssertEqual(error, .unauthorized)
            XCTAssertFalse(error.isTransportFailure)
        }
    }

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
