import Foundation
import CoreGraphics
import CryptoKit
import PaperDeviceKit
import Testing
@testable import paperGIF

private final class DeviceFixtureBundleToken: NSObject {}

@MainActor
struct PaperGIFDeviceSupportTests {
    @Test(arguments: ["paperremote.esp32-screenless-reference", "paperremote.supermini-s3-mt6701"])
    func wifiSetupEnrollsBothReferenceBoardsWithoutReplacingSavedCredentials(boardID: String) throws {
        var descriptor = screenless()
        descriptor.boardID = boardID
        #expect(descriptor.requiresProfileEnrollmentToken)
        var profile = PaperGIFRemoteProfile(version: 7, pages: [])
        profile.wifiSSID = " Test Wi-Fi "
        profile.wifiPassword = "test-password"
        try profile.prepareWiFiConfiguration(for: descriptor)
        #expect(profile.wifiSSID == "Test Wi-Fi")
        #expect(profile.deviceEnrollmentToken.count == 32)
        let firstToken = profile.macToken
        try profile.prepareWiFiConfiguration(for: descriptor)
        #expect(profile.macToken == firstToken)
        profile.macToken = ""
        profile.computers = [PaperGIFRemoteComputer(name: "Desk", host: "desk.local", token: "existing-paired-token")]
        try profile.prepareWiFiConfiguration(for: descriptor)
        #expect(profile.macToken.isEmpty)
        #expect(profile.deviceEnrollmentToken == "existing-paired-token")
        let payload = try profile.negotiatedPayload(for: descriptor)
        let object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect(object["wifiSSID"] as? String == "Test Wi-Fi")
        #expect(object["wifiPassword"] as? String == "test-password")
        #expect(object["version"] as? Int == 7)
    }

    @Test func invalidWiFiSettingsAreRejectedBeforeSending() {
        var profile = PaperGIFRemoteProfile(version: 7, pages: [])
        #expect(throws: (any Error).self) { try profile.prepareWiFiConfiguration(for: screenless()) }
        profile.wifiSSID = String(repeating: "x", count: 33)
        #expect(throws: (any Error).self) { try profile.prepareWiFiConfiguration(for: screenless()) }
        profile.wifiSSID = "Test Wi-Fi"
        profile.wifiPassword = "short"
        #expect(throws: (any Error).self) { try profile.prepareWiFiConfiguration(for: screenless()) }
        #expect(profile.macToken.isEmpty)
    }

    @Test func sharedContractFixturesDecodeAndNegotiateOnIOS() throws {
        let bundle = Bundle(for: DeviceFixtureBundleToken.self)
        func fixture(_ name: String) throws -> Data {
            let url = try #require(bundle.url(forResource: name, withExtension: "json", subdirectory: "fixtures"))
            return try Data(contentsOf: url)
        }
        let descriptor = try DeviceDescriptor.decode(fixture("device-descriptor-v1-screenless"))
        let profile = try JSONDecoder().decode(PaperGIFRemoteProfile.self, from: fixture("remote-profile-v7-screenless"))
        _ = try profile.negotiatedPayload(for: descriptor)
        #expect(profile.hardwareBindings.count == 3)
        let directional = try JSONDecoder().decode(PaperGIFRemoteProfile.self, from: fixture("remote-profile-v7-directional"))
        _ = try directional.negotiatedPayload(for: descriptor)
        #expect(Set(directional.hardwareBindings.compactMap(\.direction)) == Set(["negative", "positive"]))
        let landscape = try DeviceDescriptor.decode(fixture("device-descriptor-v1-landscape"))
        #expect(landscape.display?.width == 320 && landscape.display?.height == 240)
        #expect(!landscape.canUseLegacyMedia)
        #expect(landscape.inputs.contains { $0.kind == "dial" })
        for name in ["remote-profile-v6-all-actions", "remote-profile-v6-text-sources"] {
            let legacy = try JSONDecoder().decode(PaperGIFRemoteProfile.self, from: fixture(name))
            #expect(legacy.hardwareBindings.isEmpty)
            #expect(legacy.devicePayload != nil)
        }
    }

    @Test func adaptiveGridUsesMatchingInsetsFramesAndDragCells() {
        for size in [CGSize(width: 320, height: 240), CGSize(width: 120, height: 480),
                     CGSize(width: 128, height: 128), CGSize(width: 32, height: 16)] {
            let placement = PaperGIFRemoteGridPlacement(slot: 1, span: .init(width: 1, height: 2))
            let cell = PaperGIFAdaptiveGridGeometry.cellSize(in: size, columns: 2, rows: 4)
            let frame = PaperGIFAdaptiveGridGeometry.frame(placement, in: size, columns: 2, rows: 4)
            #expect(abs(frame.minX - (size.width * 0.04 + cell.width)) < 0.001)
            #expect(abs(frame.minY - size.height * 0.04) < 0.001)
            #expect(abs(frame.width - (cell.width - 2)) < 0.001)
            #expect(abs(frame.height - (cell.height * 2 - 2)) < 0.001)
            #expect(frame.maxX <= size.width * 0.96)
            #expect(frame.maxY <= size.height * 0.96)
        }
    }

    @Test func bluetoothDescriptorPagingUsesBoundedRawSlices() throws {
        #expect(PaperGIFDescriptorReader.offsetRequest(0) == Data([0, 0, 0, 0]))
        #expect(PaperGIFDescriptorReader.offsetRequest(0x01020304) == Data([4, 3, 2, 1]))
        let descriptor = screenless()
        let data = try JSONEncoder().encode(descriptor)
        #expect(data.count > 512)
        var reader = PaperGIFDescriptorReader()
        var received: DeviceDescriptor?
        var offset = 0
        while offset < data.count {
            let upper = min(offset + 512, data.count)
            received = try reader.append(data.subdata(in: offset..<upper))
            #expect(reader.nextOffset == UInt32(upper))
            if upper - offset == 512 { #expect(received == nil) }
            offset = upper
        }
        // A short nonempty last slice must not publish a descriptor before explicit lease EOF.
        #expect(received == nil)
        #expect(reader.nextOffset == UInt32(data.count))
        received = try reader.append(Data())
        #expect(received == descriptor)
        #expect(throws: (any Error).self) { try reader.append(Data()) }
        var oversized = PaperGIFDescriptorReader()
        #expect(throws: (any Error).self) { try oversized.append(Data(repeating: 0, count: 513)) }
        var malformed = PaperGIFDescriptorReader()
        #expect(throws: (any Error).self) { try malformed.append(Data("{}".utf8)) }
        var exact = data
        exact.append(Data(repeating: 0x20, count: (512 - data.count % 512) % 512))
        var exactReader = PaperGIFDescriptorReader()
        for offset in stride(from: 0, to: exact.count, by: 512) {
            #expect(try exactReader.append(exact.subdata(in: offset..<offset + 512)) == nil)
        }
        #expect(try exactReader.append(Data()) == descriptor)
        var shortData = data
        if shortData.count.isMultiple(of: 512) { shortData.append(0x20) }
        var missingEOF = PaperGIFDescriptorReader()
        for offset in stride(from: 0, to: shortData.count, by: 512) {
            #expect(try missingEOF.append(shortData.subdata(in: offset..<min(offset + 512, shortData.count))) == nil)
        }
        #expect(throws: (any Error).self) { try missingEOF.append(Data([0x20])) }
    }

    @Test func firmwareUpdateRequiresExactBoardRevisionAndCapability() {
        var descriptor = DeviceDescriptor.legacyM5Paper(deviceID: "m5")
        #expect(PaperGIFFirmwareUpdater.supportsFirmware(for: descriptor))
        descriptor.hardwareRevision = "1.1"
        #expect(!PaperGIFFirmwareUpdater.supportsFirmware(for: descriptor))
        descriptor.hardwareRevision = "1.0"
        descriptor.capabilities.firmwareUpdate = false
        #expect(!PaperGIFFirmwareUpdater.supportsFirmware(for: descriptor))
        #expect(!PaperGIFFirmwareUpdater.supportsFirmware(for: screenless()))
        #expect(!PaperGIFFirmwareUpdater.supportsFirmware(for: nil))
    }

    private func screenless() -> DeviceDescriptor {
        let inputs = [
            DeviceInput(id: "button-1", name: "Button", kind: "button", events: ["press", "hold", "release"]),
            DeviceInput(id: "encoder-1", name: "Encoder", kind: "encoder", events: ["rotate", "press"]),
            DeviceInput(id: "slider-1", name: "Slider", kind: "slider", events: ["change"], minimum: 0, maximum: 4095)
        ]
        return DeviceDescriptor(
            deviceID: "test-native", name: "Reference", manufacturer: "PaperRemote",
            boardID: "paperremote.esp32-screenless-reference", hardwareRevision: "1",
            firmwareVersion: "1.0", display: nil, inputs: inputs,
            layout: .generated(display: nil, inputs: inputs),
            capabilities: DeviceCapabilities(profileVersions: [7], media: false, firmwareUpdate: false,
                maxProfileBytes: 262_144, maxControls: 24, maxPages: 8)
        )
    }

    @Test func legacyPayloadRemainsV6WithoutHardwareKeys() throws {
        let profile = PaperGIFRemoteProfile.starter
        let payload = try profile.negotiatedPayload(for: .legacyM5Paper(deviceID: "legacy"))
        let object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect(object["version"] as? Int == 6)
        #expect(object["hardwareBindings"] == nil)
        #expect(object["deviceClock"] != nil)
        #expect(try JSONDecoder().decode(PaperGIFRemoteProfile.self, from: payload).pages == profile.pages)
    }

    @Test func nativeBindingsRoundTripAndCannotLeakToLegacy() throws {
        var profile = PaperGIFRemoteProfile(version: 7, pages: [])
        profile.hardwareBindings = [
            PaperGIFHardwareBinding(inputID: "button-1", event: "press", action: .init(type: .computerMedia, text: "playPause")),
            PaperGIFHardwareBinding(inputID: "encoder-1", event: "rotate", mode: "relative",
                action: .init(type: .computerMedia, text: "volume"), minimum: 0, maximum: 100, step: 5)
        ]
        let payload = try profile.negotiatedPayload(for: screenless())
        let object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect(object["version"] as? Int == 7)
        #expect((object["hardwareBindings"] as? [[String: Any]])?.count == 2)
        #expect(try JSONDecoder().decode(PaperGIFRemoteProfile.self, from: payload) == profile)
        #expect(profile.devicePayload == nil)
        #expect(throws: (any Error).self) {
            try profile.negotiatedPayload(for: .legacyM5Paper(deviceID: "legacy"))
        }
    }

    @Test func separateRotationDirectionsAreDistinctButWildcardOverlapIsRejected() throws {
        var profile = PaperGIFRemoteProfile(version: 7, pages: [])
        var left = PaperGIFHardwareBinding(inputID: "encoder-1", event: "rotate", action: .init(type: .computerMedia, text: "previous"))
        left.direction = "negative"
        var right = left
        right.direction = "positive"
        right.action.text = "next"
        profile.hardwareBindings = [left, right]
        _ = try profile.negotiatedPayload(for: screenless())
        #expect(left.id != right.id)
        profile.hardwareBindings[1].direction = nil
        #expect(throws: (any Error).self) { try profile.negotiatedPayload(for: screenless()) }
    }

    @Test func unsupportedInputsEventsModesAndActionsAreRejected() throws {
        let descriptor = screenless()
        let valid = PaperGIFHardwareBinding(inputID: "encoder-1", event: "rotate", mode: "relative",
            action: .init(type: .wledBrightness), minimum: 0, maximum: 255, step: 5)
        try valid.validate(for: descriptor)
        var invalid = valid
        invalid.inputID = "not-reported"
        #expect(throws: (any Error).self) { try invalid.validate(for: descriptor) }
        invalid = valid
        invalid.event = "hold"
        #expect(throws: (any Error).self) { try invalid.validate(for: descriptor) }
        invalid = valid
        invalid.action = .init(type: .computerOpen)
        #expect(throws: (any Error).self) { try invalid.validate(for: descriptor) }
        invalid = valid
        invalid.step = .infinity
        #expect(throws: (any Error).self) { try invalid.validate(for: descriptor) }
        invalid = valid
        invalid.maximum = 256
        #expect(throws: (any Error).self) { try invalid.validate(for: descriptor) }
        invalid = valid
        invalid.mode = "absolute"
        #expect(throws: (any Error).self) { try invalid.validate(for: descriptor) }
        invalid = valid
        invalid.action = .init(type: .iPhoneMedia, text: "volume")
        #expect(throws: (any Error).self) { try invalid.validate(for: descriptor) }
    }

    @Test func screenlessAndCustomPanelsCannotReceiveM5MediaOrTouchContent() throws {
        let descriptor = screenless()
        #expect(!descriptor.canUseLegacyMedia)
        #expect(descriptor.layout.screen == nil)
        #expect(throws: (any Error).self) {
            try PaperGIFRemoteProfile.starter.negotiatedPayload(for: descriptor)
        }
        var panel = descriptor
        panel.display = DeviceDisplay(width: 320, height: 240, touch: true, pixelFormat: "rgb565", rotation: 90)
        panel.layout = .generated(display: panel.display, inputs: panel.inputs)
        try panel.validate()
        #expect(!panel.canUseLegacyMedia)
        var profile = PaperGIFRemoteProfile(version: 7, pages: [])
        profile.buttonTexture.kind = .image
        profile.buttonTexture.imageID = UUID()
        #expect(throws: (any Error).self) { try profile.negotiatedPayload(for: panel) }
    }

    @Test func negotiatedLimitsAndFutureVersionsAreRejected() throws {
        var descriptor = screenless()
        descriptor.capabilities.maxProfileBytes = 64
        #expect(throws: (any Error).self) {
            try PaperGIFRemoteProfile(version: 7, pages: []).negotiatedPayload(for: descriptor)
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PaperGIFRemoteProfile.self, from: Data(#"{"version":8,"pages":[]}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PaperGIFRemoteProfile.self, from: Data(#"{"version":6,"pages":[],"hardwareBindings":[{"inputID":"button-1","event":"press","mode":"action","action":{"type":"macMedia"},"minimum":0,"maximum":100,"step":1}]}"#.utf8))
        }
    }

    @Test func profilesAreIsolatedByStableIDIncludingPathCharacters() throws {
        let firstID = "test/\(UUID().uuidString)"
        let secondID = "test:\(UUID().uuidString)".padding(toLength: 128, withPad: "x", startingAt: 0)
        var first = PaperGIFRemoteProfile(version: 7, pages: [])
        first.wifiSSID = "first-network"
        var second = first
        second.wifiSSID = "second-network"
        try PaperGIFStorage.saveRemoteProfile(first, deviceID: firstID)
        try PaperGIFStorage.saveRemoteProfile(second, deviceID: secondID)
        defer {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("paperGIF-v2/Remote")
            for id in [firstID, secondID] {
                let name = "device-" + SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
                try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
            }
        }
        #expect(PaperGIFStorage.loadRemoteProfile(deviceID: firstID) == first)
        #expect(PaperGIFStorage.loadRemoteProfile(deviceID: secondID) == second)
    }

    @Test func enrollmentTokensAndSelectedProfilesSurviveSessionReinitializationInIsolation() async throws {
        let namespace = UUID().uuidString
        let firstID = "test-keychain-first-\(namespace)"
        let secondID = "test-keychain-second-\(namespace)"
        let firstToken = "synthetic-first-\(UUID().uuidString)"
        let secondToken = "synthetic-second-\(UUID().uuidString)"
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("PaperGIFDeviceSupportTests/\(namespace)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("devices.json")
        defer {
            for id in [firstID, secondID] {
                try? PaperGIFDeviceCredentials.save("", for: id)
                let filename = "device-" + SHA256.hash(data: Data(id.utf8))
                    .map { String(format: "%02x", $0) }.joined() + ".json"
                try? FileManager.default.removeItem(
                    at: support.appendingPathComponent("paperGIF-v2/Remote").appendingPathComponent(filename)
                )
            }
            try? FileManager.default.removeItem(at: directory)
        }
        #expect(PaperGIFDeviceCredentials.token(for: firstID).isEmpty)
        #expect(PaperGIFDeviceCredentials.token(for: secondID).isEmpty)
        try PaperGIFDeviceCredentials.save(firstToken, for: firstID)
        try PaperGIFDeviceCredentials.save(secondToken, for: secondID)

        let catalog = DeviceCatalog(
            cacheDirectory: directory.appendingPathComponent("boards"),
            indexURL: URL(string: "http://127.0.0.1/disabled-catalog")!
        )
        var session: DeviceSession? = DeviceSession(storageURL: storageURL, catalog: catalog)
        var firstDescriptor = screenless()
        firstDescriptor.deviceID = firstID
        var secondDescriptor = firstDescriptor
        secondDescriptor.deviceID = secondID
        var firstProfile = PaperGIFRemoteProfile(version: 7, pages: [])
        firstProfile.macToken = firstToken
        firstProfile.wifiSSID = "synthetic-first-network"
        var secondProfile = firstProfile
        secondProfile.macToken = secondToken
        secondProfile.wifiSSID = "synthetic-second-network"
        let firstData = try JSONEncoder().encode(firstProfile)
        let secondData = try JSONEncoder().encode(secondProfile)
        do {
            let active = try #require(session)
            try await active.applyDescriptor(firstDescriptor, address: "")
            try active.saveProfile(firstData)
            try PaperGIFStorage.saveRemoteProfile(firstProfile, deviceID: firstID)
            try await active.applyDescriptor(secondDescriptor, address: "")
            try active.saveProfile(secondData)
            try PaperGIFStorage.saveRemoteProfile(secondProfile, deviceID: secondID)

            active.select(id: firstID)
            #expect(active.profileData == firstData)
            #expect(PaperGIFDeviceCredentials.token(for: try #require(active.selectedID)) == firstToken)
            active.select(id: secondID)
            #expect(active.profileData == secondData)
            #expect(PaperGIFDeviceCredentials.token(for: try #require(active.selectedID)) == secondToken)
        }
        session = nil

        let restored = DeviceSession(storageURL: storageURL, catalog: catalog)
        #expect(restored.records.count == 2)
        #expect(restored.selectedID == nil)
        restored.select(id: firstID)
        #expect(!restored.isVerified)
        #expect(restored.profileData == firstData)
        #expect(PaperGIFStorage.loadRemoteProfile(deviceID: firstID) == firstProfile)
        #expect(PaperGIFDeviceCredentials.token(for: try #require(restored.selectedID)) == firstToken)
        restored.select(id: secondID)
        #expect(restored.profileData == secondData)
        #expect(PaperGIFStorage.loadRemoteProfile(deviceID: secondID) == secondProfile)
        #expect(PaperGIFDeviceCredentials.token(for: try #require(restored.selectedID)) == secondToken)

        try PaperGIFDeviceCredentials.save("synthetic-replacement-\(namespace)", for: firstID)
        #expect(PaperGIFDeviceCredentials.token(for: firstID) != firstToken)
        #expect(PaperGIFDeviceCredentials.token(for: secondID) == secondToken)
        try PaperGIFDeviceCredentials.save("", for: firstID)
        #expect(PaperGIFDeviceCredentials.token(for: firstID).isEmpty)
        #expect(PaperGIFDeviceCredentials.token(for: secondID) == secondToken)
        try PaperGIFDeviceCredentials.save("", for: secondID)
        #expect(PaperGIFDeviceCredentials.token(for: secondID).isEmpty)
    }
}
