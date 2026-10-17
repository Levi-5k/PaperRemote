import Foundation
import PaperDeviceKit
import XCTest
@testable import PaperGIFMac

final class CustomDeviceProfileTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func descriptor() throws -> DeviceDescriptor {
        try DeviceDescriptor.decode(Data(contentsOf: root.appendingPathComponent(
            "protocol/fixtures/device-descriptor-v1-screenless.json")))
    }

    func testV7SharedFixtureRoundTripsBindings() throws {
        let profile = try JSONDecoder().decode(RemoteProfile.self, from: Data(contentsOf:
            root.appendingPathComponent("protocol/fixtures/remote-profile-v7-screenless.json")))
        XCTAssertEqual(profile.version, 7)
        XCTAssertEqual(profile.hardwareBindings?.count, 3)
        let payload = try profile.devicePayload(for: descriptor())
        let decoded = try JSONDecoder().decode(RemoteProfile.self, from: payload)
        XCTAssertEqual(decoded.hardwareBindings, profile.hardwareBindings)
        XCTAssertEqual(decoded.pages, profile.pages)
    }

    func testLegacyPayloadHasNoHardwareFields() throws {
        let payload = try RemoteProfile.starter.devicePayload(for: .legacyM5Paper(deviceID: "legacy:test"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 6)
        XCTAssertNil(json["hardwareBindings"])
    }

    func testBindingsCannotBeDowngradedToLegacyDevice() throws {
        var profile = RemoteProfile(pages: [RemotePage(name: "Main", controls: [])])
        profile.hardwareBindings = [.init(inputID: "button-1", event: "press",
            action: RemoteAction(type: .computerMedia, text: "playPause"))]
        XCTAssertThrowsError(try profile.devicePayload(for: .legacyM5Paper(deviceID: "legacy:test")))
    }

    func testDirectionPairsAreDistinctAndWildcardCannotOverlap() throws {
        var profile = RemoteProfile(pages: [RemotePage(name: "Main", controls: [])])
        profile.hardwareBindings = [
            .init(inputID: "encoder-1", event: "rotate",
                  action: RemoteAction(type: .computerMedia, text: "previous"), direction: "negative"),
            .init(inputID: "encoder-1", event: "rotate",
                  action: RemoteAction(type: .computerMedia, text: "next"), direction: "positive"),
        ]
        XCTAssertNoThrow(try profile.devicePayload(for: descriptor()))
        profile.hardwareBindings?.append(.init(inputID: "encoder-1", event: "rotate",
            action: RemoteAction(type: .computerMedia, text: "next")))
        XCTAssertThrowsError(try profile.devicePayload(for: descriptor()))
    }

    func testValueModesRejectNonValueActionsAndLimits() throws {
        var profile = RemoteProfile(pages: [RemotePage(name: "Main", controls: [])])
        profile.hardwareBindings = [.init(inputID: "encoder-1", event: "rotate", mode: "relative",
            action: RemoteAction(type: .computerMedia, text: "next"))]
        XCTAssertThrowsError(try profile.devicePayload(for: descriptor()))
        profile.hardwareBindings?[0].action.text = "volume"
        XCTAssertNoThrow(try profile.devicePayload(for: descriptor()))
        profile.hardwareBindings?[0].maximum = 101
        XCTAssertThrowsError(try profile.devicePayload(for: descriptor()))
        profile.hardwareBindings?[0].maximum = 100
        var limited = try descriptor()
        limited.capabilities.maxProfileBytes = 8
        XCTAssertThrowsError(try profile.devicePayload(for: limited))
    }
}
