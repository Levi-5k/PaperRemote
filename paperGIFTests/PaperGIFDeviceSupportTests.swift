import Foundation
import Combine
import CoreGraphics
import ImageIO
import CryptoKit
import PaperDeviceKit
import Testing
@testable import paperGIF

private final class DeviceFixtureBundleToken: NSObject {}

private final class MatterCatalogTestProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestCount = 0
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "matter-catalog.test"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requestCount += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"succeeded\":true,\"devices\":[{\"id\":30,\"name\":\"Heater\",\"number\":3}]}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
struct PaperGIFDeviceSupportTests {
    @Test func matterDeviceUsesCompanionWithoutPhoneIdentifiers() throws {
        let computerID = UUID().uuidString
        for power in ["toggle", "on", "off"] {
            let action = try #require(PaperGIFRemoteAction.matterDevice(number: 3, computerID: computerID, power: power))
            #expect(action.isMatterDevice)
            #expect(action.type == .module)
            #expect(action.host == "matter-switch")
            #expect(action.value == 3 && action.text == power)
            #expect(action.computerID == computerID && action.deviceID == nil)
            let decoded = try JSONDecoder().decode(PaperGIFRemoteAction.self, from: JSONEncoder().encode(action))
            #expect(decoded == action)
        }
        #expect(PaperGIFRemoteAction.matterDevice(number: 0, computerID: computerID) == nil)
        #expect(PaperGIFRemoteAction.matterDevice(number: 3, computerID: "") == nil)
        #expect(PaperGIFRemoteAction.matterDevice(number: 3, computerID: computerID, power: "invalid") == nil)
        #expect(PaperGIFRemoteActionType.iPhoneHomePower.title == "Matter Device")
        let legacy = try JSONDecoder().decode(PaperGIFRemoteAction.self,
            from: Data("{\"type\":\"iPhoneHomePower\",\"host\":\"old-service\",\"text\":\"toggle\",\"value\":0,\"modifiers\":[]}".utf8))
        #expect(!legacy.isMatterDevice)
    }

    @Test func matterCatalogDoesNotRefreshOrRepublishWhileSelecting() async throws {
        MatterCatalogTestProtocol.requestCount = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MatterCatalogTestProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let catalog = PaperGIFMatterDeviceCatalog(session: session)
        let computer = PaperGIFRemoteComputer(name: "Mac", host: "matter-catalog.test", token: "test-token")
        var updates = 0
        let subscription = catalog.$devices.dropFirst().sink { _ in updates += 1 }
        defer { subscription.cancel() }
        await catalog.load(computer: computer)
        #expect(catalog.devices.map(\.number) == [3])
        #expect(catalog.devices.map(\.name) == ["Heater"])
        await catalog.load(computer: computer)
        #expect(MatterCatalogTestProtocol.requestCount == 1)
        #expect(updates == 1)
        await catalog.load(computer: computer, force: true)
        #expect(MatterCatalogTestProtocol.requestCount == 2)
        #expect(updates == 1)
    }

    @Test func deviceRefreshKeepsWindowsMediaPageEvenWhenPhoneTimestampIsNewer() throws {
        var descriptor = screenless()
        descriptor.boardID = "paperremote.waveshare-amoled-18-v2"
        descriptor.display = DeviceDisplay(width: 368, height: 448, touch: true, pixelFormat: "rgb565")
        descriptor.layout = .generated(display: descriptor.display, inputs: descriptor.inputs)
        let main = PaperGIFRemotePage(name: "Main", controls: [])
        let media = PaperGIFRemotePage(name: "Windows Media", controls: [])
        let device = PaperGIFRemoteProfile(version: 7, updatedAtMilliseconds: 100, pages: [main, media])
        let phone = PaperGIFRemoteProfile(version: 7, updatedAtMilliseconds: 200, pages: [main])
        let loaded = try PaperGIFRemoteProfile.profileFromDeviceRefresh(JSONEncoder().encode(device), descriptor: descriptor,
            previousLocalProfile: phone, currentLocalProfile: phone)
        #expect(loaded.pages.map(\.id) == [main.id, media.id])
        #expect(loaded.updatedAtMilliseconds == 100)
        var edited = phone
        edited.pages.append(PaperGIFRemotePage(name: "Local draft", controls: []))
        let data = try JSONEncoder().encode(device)
        #expect(throws: DeviceContractError.self) {
            try PaperGIFRemoteProfile.profileFromDeviceRefresh(data, descriptor: descriptor,
                previousLocalProfile: phone, currentLocalProfile: edited)
        }
    }

    @Test func buttonColorProfileRoundTrip() throws {
        var texture = PaperGIFRemoteButtonTexture()
        texture.kind = .image
        texture.preserveColor = true
        let decoded = try JSONDecoder().decode(PaperGIFRemoteButtonTexture.self, from: JSONEncoder().encode(texture))
        #expect(decoded.preserveColor)
        #expect(try JSONDecoder().decode(PaperGIFRemoteButtonTexture.self, from: Data("{}".utf8)).preserveColor == false)
        var control = PaperGIFRemoteControl(title: "Color", symbol: "", tintHex: "FF0000", kind: .button, action: .init(type: .computerMedia))
        control.tintHex = "FF0000"
        control.backgroundTintHex = "0000FF"
        control.imageTintHex = "00FF00"
        let roundTrip = try JSONDecoder().decode(PaperGIFRemoteControl.self, from: JSONEncoder().encode(control))
        #expect(roundTrip.tintHex == "FF0000")
        #expect(roundTrip.backgroundTintHex == "0000FF")
        #expect(roundTrip.imageTintHex == "00FF00")
    }

    @Test func buttonColorPixelsAndLegacyConversion() throws {
        let samples = Data(Array(repeating: [UInt8(255), 0, 0], count: 4).flatMap { $0 })
        let provider = try #require(CGDataProvider(data: samples as CFData))
        let source = try #require(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 24,
            bytesPerRow: 6, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let bytes = try PaperGIFButtonImageStore.makeImageFile(from: source, color: true)
        #expect(bytes.count == 18 && bytes[4] == 2)
        let image = try #require(PaperGIFButtonImageStore.decode(bytes))
        #expect(image.colorPixels?.prefix(3) == [255, 0, 0])
        let grayscale = try #require(PaperGIFButtonImageStore.grayscaleFile(bytes))
        #expect(grayscale[4] == 1 && grayscale.count == 14)
        #expect(PaperGIFButtonImageStore.decode(grayscale)?.pixels == image.pixels)
        #expect(PaperGIFButtonImageStore.decode(bytes.dropLast()) == nil)
        var texture = PaperGIFRemoteButtonTexture()
        texture.kind = .pattern
        texture.pattern = .rings
        texture.fade = 0
        let rendered = try #require(PaperGIFButtonTextureRenderer.image(texture: texture, background: .outline,
            width: 20, height: 20, radius: 0, backgroundHex: "FF0000", foregroundHex: "0000FF", imageTintHex: "00FF00"))
        let pixels = Array((try #require(rendered.dataProvider?.data)) as Data)
        #expect(Array(pixels[(10 * 20 + 10) * 3..<(10 * 20 + 10) * 3 + 3]) == [0, 255, 0])
    }

    @Test func phoneButtonImageKeepsColorAndResolution() throws {
        let samples = Data([UInt8(10), 20, 30])
        let provider = try #require(CGDataProvider(data: samples as CFData))
        let source = try #require(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 24,
            bytesPerRow: 3, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        var wide = [UInt8](repeating: 0, count: 600 * 4)
        let drawn = wide.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let context = CGContext(data: buffer.baseAddress, width: 600, height: 1,
                bitsPerComponent: 8, bytesPerRow: 600 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.interpolationQuality = .none
            context.draw(source, in: CGRect(x: 0, y: 0, width: 600, height: 1))
            return context.makeImage()
        }
        let phone = try PaperGIFButtonImageStore.makePhoneImageFile(from: try #require(drawn))
        #expect(phone[4] == 3)
        let decoded = try #require(PaperGIFButtonImageStore.decode(phone))
        #expect(decoded.width == 600)
        #expect(decoded.colorPixels?.prefix(3) == [10, 20, 30])
        let panel = try #require(PaperGIFButtonImageStore.panelFile(phone))
        #expect(panel[4] == 1)
        #expect((Int(panel[6]) | Int(panel[7]) << 8) <= 540)
        var texture = PaperGIFRemoteButtonTexture()
        texture.kind = .image
        texture.preserveColor = true
        texture.fade = 0
        let rendered = try #require(PaperGIFButtonTextureRenderer.render(
            texture: texture, source: decoded, fill: 255, foreground: 0, width: 8, height: 8, radius: 0))
        let pixels = Array((try #require(rendered.dataProvider?.data)) as Data)
        #expect(Array(pixels.prefix(3)) == [10, 20, 30])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PAPERGIF_AMOLED_WIFI"] == "1"))
    func physicalAMOLEDAutomaticallyUsesWiFi() async throws {
        let manager = try #require(PaperGIFBluetoothManager.liveInstance)
        let session = try #require(manager.deviceSession)
        manager.startBrowsingNearby()
        defer { manager.stopBrowsingNearby() }
        let discoveryDeadline = Date().addingTimeInterval(20)
        while Date() < discoveryDeadline,
              !manager.nearbyDevices.contains(where: { $0.name.localizedCaseInsensitiveContains("AMOLED") }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        let nearby = try #require(manager.nearbyDevices.first {
            $0.name.localizedCaseInsensitiveContains("AMOLED")
        })
        manager.connectNearby(nearby.id)
        let connectionDeadline = Date().addingTimeInterval(40)
        while Date() < connectionDeadline,
              manager.connectionState != .connected || manager.bluetoothDescriptor?.boardID != "paperremote.waveshare-amoled-18-v2" {
            try await Task.sleep(for: .milliseconds(100))
        }
        let descriptor = try #require(manager.bluetoothDescriptor)
        try #require(descriptor.boardID == "paperremote.waveshare-amoled-18-v2")
        try #require(manager.connectionState == .connected)
        manager.requestDeviceWiFiStatus()
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, !session.isVerified || manager.wifiConnectionState != .connected {
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(session.isVerified, "\(manager.wifiConnectionError ?? "Native Wi-Fi was not verified")")
        #expect(session.selectedID == descriptor.deviceID)
        let status = try #require(manager.deviceWiFiStatus)
        guard case .connected(let address) = status.state else {
            Issue.record("No native Wi-Fi address was reported")
            return
        }
        #expect(session.address == address)
        #expect(session.records.first(where: { $0.id == descriptor.deviceID })?.address == address)
        let routes = manager.deviceControlRoutes(for: descriptor)
        #expect(routes.httpCredential == .stored(deviceID: descriptor.deviceID))
        let transports = manager.deviceControlTransports(for: routes)
        #expect(transports.map(\.name) == ["Wi-Fi", "Bluetooth"])
        let wifi = try #require(transports.first)
        let snapshot = try await wifi.snapshot()
        #expect(snapshot.values["dialPresent"] == .bool(true))
        let step = try #require(snapshot.values["dialStep"])
        let acknowledgement = try await wifi.set(.init(id: "dialStep", value: step))
        #expect(acknowledgement.values["dialStep"] == step)
        session.invalidateNetwork()
        let fallback = manager.deviceControlTransports(for: manager.deviceControlRoutes(for: descriptor))
        #expect(fallback.map(\.name) == ["Bluetooth"])
        let bluetooth = try #require(fallback.first)
        #expect(try await bluetooth.snapshot().values["dialStep"] == step)
        manager.refreshNativeNetworkConnection()
        let recoveryDeadline = Date().addingTimeInterval(20)
        while Date() < recoveryDeadline, !session.isVerified {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(session.isVerified)
        print("Verified automatic native Wi-Fi at \(address), authenticated HTTP read/write, Bluetooth route fallback, and Wi-Fi recovery")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PAPERGIF_AMOLED_DISCOVERY"] == "1"))
    func physicalAMOLEDIsDetectedAndConnectedByTheApp() async throws {
        let manager = try #require(PaperGIFBluetoothManager.liveInstance)
        let session = try #require(manager.deviceSession)
        manager.startBrowsingNearby()
        defer { manager.stopBrowsingNearby() }
        let discoveryDeadline = Date().addingTimeInterval(20)
        while Date() < discoveryDeadline,
              !manager.nearbyDevices.contains(where: { $0.name.localizedCaseInsensitiveContains("AMOLED") }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        let nearby = try #require(manager.nearbyDevices.first {
            $0.name.localizedCaseInsensitiveContains("AMOLED")
        }, "AMOLED was not found. Nearby devices: \(manager.nearbyDevices.map(\.name)); connection: \(manager.connectionState); status: \(manager.descriptorStatus ?? "none")")
        manager.connectNearby(nearby.id)
        let connectionDeadline = Date().addingTimeInterval(35)
        while Date() < connectionDeadline,
              manager.connectionState != .connected || manager.bluetoothDescriptor?.boardID != "paperremote.waveshare-amoled-18-v2" {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(manager.connectionState == .connected, "\(manager.descriptorStatus ?? "No Bluetooth status")")
        let descriptor = try #require(manager.bluetoothDescriptor)
        #expect(descriptor.boardID == "paperremote.waveshare-amoled-18-v2")
        #expect(descriptor.display?.width == 368 && descriptor.display?.height == 448)
        #expect(descriptor.capabilities.profileVersions.contains(7))
        #expect(manager.connectedPeripheralID == nearby.id)
        print("Verified app Bluetooth discovery and descriptor: \(descriptor.name), \(descriptor.boardID)")
        let pendingDeadline = Date().addingTimeInterval(45)
        while manager.isTransferring, Date() < pendingDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        var profile = session.profileData.flatMap { try? JSONDecoder().decode(PaperGIFRemoteProfile.self, from: $0) }
            ?? PaperGIFStorage.loadRemoteProfile(deviceID: descriptor.deviceID)
        profile.version = 7
        _ = profile.prepareBluetoothEnrollment(for: descriptor,
            savedToken: PaperGIFDeviceCredentials.token(for: descriptor.deviceID))
        try PaperGIFStorage.saveRemoteProfile(profile, deviceID: descriptor.deviceID)
        manager.syncRemoteProfile(profile)
        let syncDeadline = Date().addingTimeInterval(50)
        while Date() < syncDeadline, !manager.isRemoteProfileConfirmed(profile), manager.remoteSyncError == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(manager.remoteSyncError == nil, "\(manager.remoteSyncError ?? "")")
        let confirmed = manager.isRemoteProfileConfirmed(profile)
        try #require(confirmed, "\(manager.remoteSyncStatus ?? "No profile acknowledgement")")
        print("Verified saved AMOLED profile acknowledgement: \(profile.pages.count) pages")
        if ProcessInfo.processInfo.environment["PAPERGIF_AMOLED_IMAGES"] == "1" {
            try #require(descriptor.canUseColorImages)
            func waitForLibrary() async throws {
                let deadline = Date().addingTimeInterval(15)
                while (manager.isLoadingDeviceLibrary || manager.isTransferring), Date() < deadline {
                    try await Task.sleep(for: .milliseconds(100))
                }
                try #require(!manager.isLoadingDeviceLibrary && !manager.isTransferring)
                try #require(manager.deviceLibraryError == nil, "\(manager.deviceLibraryError ?? "")")
            }
            try await waitForLibrary()
            manager.refreshDeviceLibrary()
            try await waitForLibrary()
            let routes = manager.deviceControlRoutes(for: descriptor)
            let controls = try #require(manager.deviceControlTransports(for: routes).first { $0.name == "Bluetooth" })
            let storage = try await controls.snapshot()
            print("AMOLED storage: SD mounted=\(String(describing: storage.values["sdCardMounted"])); capacity=\(String(describing: storage.values["sdCardCapacity"]))")
            if ProcessInfo.processInfo.environment["PAPERGIF_AMOLED_SD"] == "1" {
                try #require(storage.values["sdCardMounted"] == .bool(true))
            }
            try #require(manager.deviceMedia.isEmpty,
                "Image validation requires an empty library; existing images are left untouched")
            let display = try #require(descriptor.display)
            let context = try #require(CGContext(data: nil, width: display.width, height: display.height,
                bitsPerComponent: 8, bytesPerRow: display.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(red: 0.1, green: 0.7, blue: 0.3, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: display.width, height: display.height))
            let image = try #require(context.makeImage())
            let encoded = try DeviceImageEncoder.encode(image, for: display)
            try #require(manager.canSendColorImage)
            let fixtureName = "Image validation"
            manager.sendColorImage(encoded.data, to: descriptor.deviceID, name: fixtureName)
            let imageDeadline = Date().addingTimeInterval(60)
            while manager.isTransferring, Date() < imageDeadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            try await waitForLibrary()
            let fixture = try #require(manager.deviceMedia.first { $0.name == fixtureName })
            #expect(fixture.frameCount == 1)
            manager.selectDeviceMedia(fixture)
            manager.deleteDeviceMedia(fixture)
            let deleteDeadline = Date().addingTimeInterval(10)
            while manager.deletingDeviceMediaIndex != nil, Date() < deleteDeadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            try await waitForLibrary()
            #expect(manager.deviceMedia.isEmpty)
            print("Verified real app image upload: \(encoded.data.count) bytes; screensaver fixture shown and removed")
            return
        }
        let routes = manager.deviceControlRoutes(for: descriptor)
        let controls = try #require(manager.deviceControlTransports(for: routes).first { $0.name == "Bluetooth" })
        let snapshot = try await controls.snapshot()
        #expect(snapshot.values["dialPresent"] == .bool(true))
        let resolution = try #require(snapshot.values["dialStep"])
        let updated = try await controls.set(.init(id: "dialStep", value: resolution))
        #expect(updated.values["dialStep"] == resolution)
        print("Verified AMOLED sensor snapshot and persisted dial setting acknowledgement")
    }

    @Test
    func sharedMediaLibraryPreservesSourceAcrossDisplayFormats() throws {
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let source = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(source, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        try #require(CGImageDestinationFinalize(destination))
        let recipe = PaperGIFConversionRecipe(cropRect: nil, rotationQuarterTurns: 0,
            monochromeMode: .threshold, threshold: 128, monochromeLevels: 16,
            halftoneDotSpacing: 8, halftoneAngle: 45, halftoneDotGain: 0, maximumFramesPerSecond: 10,
            scanRateHz: 60, transitionScans: 1, cleanRefreshInterval: 120, adaptiveCleaning: true)
        let display = DeviceDisplay(width: 368, height: 448, touch: true, pixelFormat: "rgb565")
        let media = PaperGIFStorage.LoadedMedia(data: Data(), sourceData: source as Data, recipe: recipe)
        let color = try media.convertedData(for: display)
        var saved = try PaperGIFStorage.save(name: "Shared media regression", data: color, sourceData: source as Data, recipe: recipe)
        defer { try? PaperGIFStorage.delete(saved) }
        #expect(saved.isColorImage)
        #expect(try PaperGIFStorage.loadAll().contains { $0.id == saved.id && $0.isColorImage })
        let loaded = try PaperGIFStorage.load(saved)
        #expect(loaded.sourceData == source as Data)
        #expect(try DeviceImageEncoder.decode(loaded.data).width == 368)
        let legacy = try loaded.convertedData(for: nil)
        #expect(try PaperGIFAnimation(encoded: legacy).frames.count == 1)
        saved = try PaperGIFStorage.save(id: saved.id, name: saved.name, data: legacy, sourceData: source as Data, recipe: recipe)
        #expect(!saved.isColorImage)
        let records = try PaperGIFStorage.loadAll().filter { $0.id == saved.id }
        #expect(records.count == 1)
        #expect(try PaperGIFStorage.load(saved).convertedData(for: display) == color)
    }

    @Test(arguments: ["paperremote.esp32-screenless-reference", "paperremote.supermini-s3-mt6701", "paperremote.waveshare-amoled-18-v2"])
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

    @Test func pageTileBindingsResolveLatestActionsAndRejectDanglingTargets() throws {
        var descriptor = screenless()
        descriptor.display = DeviceDisplay(width: 368, height: 448, touch: true, pixelFormat: "rgb565")
        descriptor.layout = .generated(display: descriptor.display, inputs: descriptor.inputs)
        let slider = PaperGIFRemoteControl(title: "Volume", symbol: "speaker.wave.2", tintHex: "202020",
            kind: .slider, action: .init(type: .computerMedia, text: "volume", value: 128))
        let first = PaperGIFRemotePage(name: "Music", controls: [slider])
        let second = PaperGIFRemotePage(name: "Lights", controls: [slider])
        var profile = PaperGIFRemoteProfile(version: 7, pages: [first, second])
        profile.hardwareBindings = [first, second].map { page in
            PaperGIFPageInputsSection.tileBinding(pageID: page.id, control: slider,
                input: descriptor.inputs[2], event: "change")
        }
        #expect(profile.hardwareBindings[0].id != profile.hardwareBindings[1].id)
        profile.pages[1].controls[0].action.text = "seek"
        let data = try profile.negotiatedPayload(for: descriptor)
        let loaded = try JSONDecoder().decode(PaperGIFRemoteProfile.self, from: data)
        #expect(loaded.hardwareBindings[0].action.text == "volume")
        #expect(loaded.hardwareBindings[1].action.text == "seek")
        #expect(loaded.hardwareBindings[0].controlID == slider.id)
        profile.pages[0].controls.removeAll()
        #expect(throws: (any Error).self) { try profile.negotiatedPayload(for: descriptor) }
        profile.reconcileTileBindings()
        #expect(profile.hardwareBindings.count == 1)
        profile.pages.removeAll()
        profile.reconcileTileBindings()
        #expect(profile.hardwareBindings.isEmpty)
    }

    @Test func existingAMOLEDActionsBecomePageTilesOnceWithoutChangingTheirUnits() throws {
        var descriptor = screenless()
        descriptor.boardID = "paperremote.waveshare-amoled-18-v2"
        descriptor.display = DeviceDisplay(width: 368, height: 448, touch: true, pixelFormat: "rgb565")
        descriptor.layout = .generated(display: descriptor.display, inputs: descriptor.inputs)
        var profile = PaperGIFRemoteProfile(version: 7, pages: [])
        profile.hardwareBindings = [
            .init(inputID: "button-1", event: "press", action: .init(type: .computerMedia, text: "playPause")),
            .init(inputID: "slider-1", event: "change", mode: "absolute",
                  action: .init(type: .computerMedia, text: "volume", value: 50))
        ]
        let prepared = profile.prepareAMOLEDPageTiles(for: descriptor)
        #expect(prepared)
        #expect(profile.pages.count == 1 && profile.pages[0].controls.count == 2)
        #expect(profile.pages[0].controls[1].action.value == 128)
        #expect(profile.hardwareBindings.allSatisfy { $0.pageID == profile.pages[0].id && $0.controlID != nil })
        let previous = profile
        let repeated = profile.prepareAMOLEDPageTiles(for: descriptor)
        #expect(!repeated && profile == previous)
        _ = try profile.negotiatedPayload(for: descriptor)
    }

    @Test func bluetoothEnrollmentDoesNotRequireWiFiOrReplaceExistingCredentials() {
        var descriptor = screenless()
        descriptor.boardID = "paperremote.waveshare-amoled-18-v2"
        var profile = PaperGIFRemoteProfile(version: 7, pages: [])
        let enrolled = profile.prepareBluetoothEnrollment(for: descriptor, savedToken: "saved-device-token")
        #expect(enrolled && profile.macToken == "saved-device-token" && profile.wifiSSID.isEmpty)
        let repeated = profile.prepareBluetoothEnrollment(for: descriptor, savedToken: "different-token")
        #expect(!repeated && profile.macToken == "saved-device-token")
        profile.macToken = ""
        let generated = profile.prepareBluetoothEnrollment(for: descriptor, savedToken: "")
        #expect(generated && profile.macToken.count == 32)
        profile.macToken = ""
        profile.computers = [.init(name: "Desk", host: "desk.local", token: "computer-token")]
        let paired = profile.prepareBluetoothEnrollment(for: descriptor, savedToken: "")
        #expect(!paired && profile.macToken.isEmpty && profile.deviceEnrollmentToken == "computer-token")
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
