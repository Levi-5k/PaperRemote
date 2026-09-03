//
//  paperGIFTests.swift
//  paperGIFTests
//
//  Created by Levi Richards on 8/29/26.
//

import CoreGraphics
import Foundation
import Testing
@testable import paperGIF

struct paperGIFTests {

    @Test func remoteToggleRemainsBackwardCompatible() throws {
        let legacyData = Data(#"{"version":1,"pages":[{"id":"00000000-0000-0000-0000-000000000001","name":"Main","controls":[{"id":"00000000-0000-0000-0000-000000000002","title":"Power","symbol":"power","tintHex":"202020","kind":"button","action":{"type":"wledPower","host":"lights.local","text":"toggle","value":0,"modifiers":[]}}]}]}"#.utf8)
        var profile = try JSONDecoder().decode(PaperGIFRemoteProfile.self, from: legacyData)

        #expect(profile.version == PaperGIFRemoteProfile.currentVersion)
        #expect(profile.pages[0].controls[0].isToggle == nil)

        profile.pages[0].controls[0].isToggle = true
        let encoded = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(PaperGIFRemoteProfile.self, from: encoded)

        #expect(decoded.pages[0].controls[0].isToggle == true)
    }

    @Test func remoteTextBoxRoundTripsAllConfiguration() throws {
        let referenceID = UUID()
        let computerID = UUID()
        let control = PaperGIFRemoteControl(
            title: "Now Playing",
            symbol: "music.note",
            tintHex: "202020",
            kind: .textBox,
            action: .playPause,
            layoutSlot: 4,
            textBox: PaperGIFRemoteTextBox(
                source: .nowPlaying,
                sourceText: "",
                referencedControlID: referenceID,
                computerID: computerID,
                dateFormat: "%H:%M",
                placeholder: "Nothing playing",
                gridWidth: 2,
                gridHeight: 3,
                textSize: .large,
                horizontalAlignment: .center,
                verticalAlignment: .bottom,
                tapBehavior: .action,
                tapAction: .init(type: .macMedia, text: "playPause"),
                refreshIntervalSeconds: 5
            )
        )
        let profile = PaperGIFRemoteProfile(
            timeZoneOffsetMinutes: -240,
            pages: [.init(name: "Main", controls: [control])]
        )

        let encoded = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(PaperGIFRemoteProfile.self, from: encoded)

        #expect(decoded == profile)
    }

    @Test func remoteTextBoxWithoutAlignmentUsesTopLeadingDefaults() throws {
        let data = Data(#"{"source":"staticText","sourceText":"Legacy"}"#.utf8)

        let textBox = try JSONDecoder().decode(PaperGIFRemoteTextBox.self, from: data)

        #expect(textBox.horizontalAlignment == .leading)
        #expect(textBox.verticalAlignment == .top)
    }

    @Test func remoteTextBoxPlacementUsesEveryCellInItsSpan() throws {
        let control = PaperGIFRemoteControl(
            title: "Status",
            symbol: "",
            tintHex: "202020",
            kind: .textBox,
            action: .playPause,
            layoutSlot: 2,
            textBox: PaperGIFRemoteTextBox(gridWidth: 2, gridHeight: 3)
        )

        let placement = try #require(PaperGIFRemoteGrid.placement(for: control, at: 2))

        #expect(PaperGIFRemoteGrid.cells(for: placement) == Set([2, 3, 4, 5, 6, 7]))
        #expect(PaperGIFRemoteGrid.placement(for: control, at: 13) == nil)
    }

    @Test func remoteButtonCanStartOnAnyRowWhereItFits() throws {
        let control = PaperGIFRemoteControl.button(
            title: "Play",
            symbol: "play.fill",
            action: .playPause
        )

        let placement = try #require(PaperGIFRemoteGrid.placement(for: control, at: 3))

        #expect(placement.slot == 3)
        #expect(PaperGIFRemoteGrid.cells(for: placement) == Set([3, 5]))
        #expect(PaperGIFRemoteGrid.placement(for: control, at: 15) == nil)
    }

    @Test func remoteOneRowButtonUsesOneCellAndRoundTrips() throws {
        var control = PaperGIFRemoteControl.button(
            title: "Mute",
            symbol: "speaker.slash.fill",
            action: .playPause
        )
        control.buttonHeight = 1

        let placement = try #require(PaperGIFRemoteGrid.placement(for: control, at: 15))
        let decoded = try JSONDecoder().decode(
            PaperGIFRemoteControl.self,
            from: JSONEncoder().encode(control)
        )

        #expect(PaperGIFRemoteGrid.cells(for: placement) == Set([15]))
        #expect(decoded.buttonHeight == 1)
        #expect(decoded.gridSpan == PaperGIFRemoteGridSpan(width: 1, height: 1))
    }

    @Test func remoteDevicePayloadIncludesClockWithoutChangingStoredProfile() throws {
        let profile = PaperGIFRemoteProfile(pages: [.init(name: "Main", controls: [])])
        let payload = try #require(profile.devicePayload)
        let object = try #require(
            JSONSerialization.jsonObject(with: payload) as? [String: Any]
        )
        let clock = try #require(object["deviceClock"] as? [String: Int])
        let stored = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any]
        )

        #expect((clock["year"] ?? 0) >= 2020)
        #expect(clock["weekday"] != nil)
        #expect(stored["deviceClock"] == nil)
    }

    @Test @MainActor func decodesNamedWLEDPresetsInNumericOrder() throws {
        let data = Data(#"{"0":{},"12":{"n":"Movie Night"},"2":{"n":"Reading"}}"#.utf8)

        let presets = try PaperGIFWLEDDiscovery.decodePresets(from: data)

        #expect(presets == [
            .init(id: 2, name: "Reading"),
            .init(id: 12, name: "Movie Night"),
        ])
    }

    @Test func packsBlackPixelsMostSignificantBitFirst() {
        let pixels: [UInt8] = [0, 255, 0, 255, 255, 255, 255, 0]
        let data = PaperGIFEncoder.packLuminance(pixels, threshold: 128)

        #expect(Array(data) == [0b1010_0001])
    }

    @Test func padsEachPackedRowToAWholeByte() {
        let pixels: [UInt8] = [0, 255, 255, 255, 0, 255, 0, 255, 0, 255]
        let data = PaperGIFEncoder.packLuminance(pixels, threshold: 128, width: 5)

        #expect(Array(data) == [0b1000_1000, 0b0101_0000])
    }

    @Test func halftonePreservesSolidTonesAndDotsMidtones() {
        let white = PaperGIFEncoder.packHalftoneLuminance(
            [UInt8](repeating: 255, count: 256),
            dotSpacing: 8,
            angleDegrees: 45,
            dotGain: 0,
            width: 16
        )
        let black = PaperGIFEncoder.packHalftoneLuminance(
            [UInt8](repeating: 0, count: 256),
            dotSpacing: 8,
            angleDegrees: 45,
            dotGain: 0,
            width: 16
        )
        let gray = PaperGIFEncoder.packHalftoneLuminance(
            [UInt8](repeating: 128, count: 256),
            dotSpacing: 8,
            angleDegrees: 45,
            dotGain: 0,
            width: 16
        )

        #expect(white.allSatisfy { $0 == 0 })
        #expect(black.allSatisfy { $0 == 0xFF })
        #expect(gray.contains { $0 != 0 })
        #expect(gray.contains { $0 != 0xFF })
    }

    @Test func packsSixteenGrayscaleLevelsHighNibbleFirst() {
        let pixels = (0..<16).map { UInt8($0 * 17) }

        let data = PaperGIFEncoder.packGrayscaleLuminance(
            pixels,
            levels: 16,
            threshold: 128,
            width: 16
        )

        #expect(Array(data) == [0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF])
    }

    @Test func combinedModeScreensBetweenGrayscaleLevels() {
        let data = PaperGIFEncoder.packGrayscaleLuminance(
            [UInt8](repeating: 128, count: 256),
            levels: 4,
            threshold: 128,
            halftoneDotSpacing: 8,
            halftoneAngle: 45,
            width: 16
        )

        #expect(data.contains { $0 != data.first })
        #expect(data.allSatisfy { byte in
            [UInt8(0x5), UInt8(0xA)].contains(byte >> 4) &&
                [UInt8(0x5), UInt8(0xA)].contains(byte & 0x0F)
        })
    }

    @Test func zeroMonochromeLevelsDisableFourBitFrames() throws {
        let provider = try #require(CGDataProvider(data: Data([0, 255, 0, 255]) as CFData))
        let image = try #require(CGImage(
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: 2,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))

        let frame = try PaperGIFEncoder.packedFrame(
            image: image,
            monochromeMode: .monochrome,
            threshold: 128,
            monochromeLevels: 0
        )

        #expect(frame.count == PaperGIFAnimation.bytesPerFrame)
    }

    @Test func createsPreviewFromOneBitFrame() throws {
        var frame = Data(repeating: 0, count: PaperGIFAnimation.bytesPerFrame)
        frame[0] = 0x80

        let preview = try PaperGIFEncoder.previewImage(fromPackedFrame: frame)

        #expect(preview.width == PaperGIFAnimation.width)
        #expect(preview.height == PaperGIFAnimation.height)
    }

    @Test func frameSamplingPreservesOriginalGifDuration() {
        let sourceDurations = [TimeInterval](repeating: 0.01, count: 100)

        let samples = PaperGIFEncoder.frameSamples(
            sourceDurations: sourceDurations,
            maximumFramesPerSecond: 6
        )

        #expect(samples.reduce(0) { $0 + Int($1.durationMilliseconds) } == 1_000)
        #expect(samples.count <= 6)
        #expect(samples.last?.sourceIndex == 99)
    }

    @Test func encodesVersionedHeaderAndDurations() {
        let frame = Data(repeating: 0xA5, count: PaperGIFAnimation.bytesPerFrame)
        let animation = PaperGIFAnimation(
            frames: [frame],
            durations: [125],
            playbackConfiguration: .balanced
        )
        let bytes = Array(animation.encoded.prefix(24))

        #expect(bytes == [
            0x50, 0x47, 0x49, 0x46,
            0x03, 0x00,
            0x1C, 0x02,
            0xC0, 0x03,
            0x01, 0x00,
            0x00, 0xFF, 0x00, 0x00,
            0x3C, 0x00,
            0x01,
            0x01,
            0x78, 0x00,
            0x7D, 0x00,
        ])
    }

    @Test func restoresAnEncodedAnimation() throws {
        let original = PaperGIFAnimation(
            frames: [Data(repeating: 0xA5, count: PaperGIFAnimation.bytesPerFrame)],
            durations: [125],
            playbackConfiguration: .balanced
        )

        let restored = try PaperGIFAnimation(encoded: original.encoded)

        #expect(restored.encoded == original.encoded)
    }

    @Test func encodesAndRestoresVersionFourGrayscaleFrames() throws {
        let original = PaperGIFAnimation(
            frames: [Data(repeating: 0xA5, count: PaperGIFAnimation.grayscaleBytesPerFrame)],
            durations: [125],
            playbackConfiguration: .balanced
        )

        let encoded = original.encoded
        let restored = try PaperGIFAnimation(encoded: encoded)

        #expect(Array(encoded[4..<16]) == [
            0x04, 0x00,
            0x1C, 0x02,
            0xC0, 0x03,
            0x01, 0x00,
            0x80, 0xF4, 0x03, 0x00,
        ])
        #expect(restored.encoded == encoded)
    }

    @Test func cropsAFrameBeforePackingIt() throws {
        let width = 32
        let height = 18
        var pixels = [UInt8](repeating: 255, count: width * height)
        for row in 0..<height {
            for column in 0..<(width / 2) {
                pixels[row * width + column] = 0
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))

        let rightHalf = CGRect(x: 0.5, y: 0.25, width: 0.5, height: 0.5)
        let frame = try PaperGIFEncoder.packedFrame(image: image, threshold: 128, cropRect: rightHalf)

        #expect(frame.allSatisfy { $0 == 0 })
    }

    @Test func cropCoordinatesUseThePreviewTopEdgeAsZero() throws {
        let width = 9
        let height = 32
        var pixels = [UInt8](repeating: 255, count: width * height)
        for row in 0..<(height / 2) {
            for column in 0..<width {
                pixels[row * width + column] = 0
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))

        let frame = try PaperGIFEncoder.packedFrame(
            image: image,
            threshold: 128,
            cropRect: CGRect(x: 0, y: 0, width: 1, height: 0.5)
        )
        let centerPixel = PaperGIFAnimation.height / 2 * PaperGIFAnimation.bytesPerRow +
            PaperGIFAnimation.width / 2 / 8
        let centerMask = UInt8(0x80 >> (PaperGIFAnimation.width / 2 % 8))

        #expect(frame[centerPixel] & centerMask != 0)
    }

    @Test @MainActor func updatesOnlyTheSelectedDeviceLibraryItemAsActive() {
        let media = [
            PaperGIFBluetoothManager.DeviceMedia(index: 0, packageID: "A", name: "Alpha", frameCount: 1, isActive: true),
            PaperGIFBluetoothManager.DeviceMedia(index: 1, packageID: "B", name: "Bravo", frameCount: 2, isActive: false),
            PaperGIFBluetoothManager.DeviceMedia(index: 2, packageID: "C", name: "Charlie", frameCount: 3, isActive: false),
        ]

        let updated = PaperGIFBluetoothManager.deviceMediaWithActiveSelection(media, activeIndex: 1)

        #expect(updated[0].isActive == false)
        #expect(updated[1].isActive == true)
        #expect(updated[2].isActive == false)
    }

    @Test @MainActor func prefersHomeWiFiWhenEndpointIsAvailable() {
        let transport = PaperGIFBluetoothManager.preferredTransferTransport(
            homeWiFiState: .connected,
            hasHomeWiFiEndpoint: true
        )

        #expect(transport == .wifi)
    }

    @Test @MainActor func prefersBluetoothWhenHomeWiFiEndpointIsUnavailable() {
        let transport = PaperGIFBluetoothManager.preferredTransferTransport(
            homeWiFiState: .connected,
            hasHomeWiFiEndpoint: false
        )

        #expect(transport == .bluetooth)
    }

    @Test @MainActor func treatsValidPaperGIFStatusResponseAsReachableEvenWhenNotReady() {
        #expect(PaperGIFBluetoothManager.isDeviceWiFiReachable(device: "paperGIF", ready: false))
    }

}
