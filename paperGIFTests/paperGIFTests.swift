//
//  paperGIFTests.swift
//  paperGIFTests
//
//  Created by Levi Richards on 8/29/26.
//

import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import paperGIF

struct paperGIFTests {
    @Test func remoteButtonTextSizeDefaultsClampsAndRoundTrips() throws {
        let legacy = try JSONDecoder().decode(PaperGIFRemoteProfile.self, from: Data(#"{"version":6,"pages":[]}"#.utf8))
        #expect(legacy.maxButtonTextSize == 24)
        #expect(PaperGIFRemoteProfile(pages: []).maxButtonTextSize == 24)
        for (input, expected) in [(Int.min, 9), (8, 9), (9, 9), (17, 17), (24, 24), (25, 24), (Int.max, 24)] {
            var profile = PaperGIFRemoteProfile(maxButtonTextSize: input, pages: [])
            #expect(profile.maxButtonTextSize == expected)
            profile.maxButtonTextSize = input
            #expect(profile.maxButtonTextSize == expected)
            let data = try JSONEncoder().encode(profile)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["maxButtonTextSize"] as? Int == expected)
            #expect(!String(decoding: data, as: UTF8.self).contains("\"maxButtonTextSize\":\(expected)."))
            #expect(try JSONDecoder().decode(PaperGIFRemoteProfile.self, from: data) == profile)
            let decoded = try JSONDecoder().decode(PaperGIFRemoteProfile.self, from: Data("{\"pages\":[],\"maxButtonTextSize\":\(input)}".utf8))
            #expect(decoded.maxButtonTextSize == expected)
            let payload = try #require(profile.devicePayload)
            let device = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            #expect(device["maxButtonTextSize"] as? Int == expected)
        }
    }

    @Test func remotePreviewTextCapRecomputesForScaleAndResize() {
        for scale in [CGFloat(0.25), 0.5, 1, 2] {
            for compact in [false, true] {
                for cap in [9, 17, 24] {
                    let layout = PaperGIFRemotePreviewLabelFitting.layout(
                        size: CGSize(width: 300 * scale, height: 150 * scale), scale: scale,
                        compact: compact, maxButtonTextSize: cap
                    )
                    #expect(layout.maximumFontSize == CGFloat(cap) * scale)
                    #expect(PaperGIFRemotePreviewLabelFitting.fontSize(for: "Go", in: layout.labelSize,
                                                                     maximum: layout.maximumFontSize) == layout.maximumFontSize)
                }
            }
        }
        var previous: CGFloat = 0
        for width in [CGFloat(30), 60, 120, 240, 480] {
            let layout = PaperGIFRemotePreviewLabelFitting.layout(size: CGSize(width: width, height: width / 3),
                                                                  scale: 1, compact: true, maxButtonTextSize: 17)
            let font = PaperGIFRemotePreviewLabelFitting.fontSize(for: "Jog X Negative Y Positive", in: layout.labelSize,
                                                                 maximum: layout.maximumFontSize)
            #expect(font >= previous && font <= 17)
            previous = font
        }
        #expect(previous > 9)
    }

    @Test func remotePreviewCentersTitleAndMeasuredVerticalGroupInsideSafeEdges() {
        for size in [CGSize(width: 38, height: 12), CGSize(width: 300, height: 80), CGSize(width: 100, height: 240)] {
            for title in ["Go", "A longer label that may use multiple lines", ""] {
                let layout = PaperGIFRemotePreviewLabelFitting.layout(size: size, scale: 0.5, compact: false,
                                                                     hasTitle: !title.isEmpty)
                let font = PaperGIFRemotePreviewLabelFitting.fontSize(for: title, in: layout.labelSize, maximum: layout.maximumFontSize)
                let measured = PaperGIFRemotePreviewLabelFitting.measuredSize(title, fontSize: font, width: layout.labelSize.width)
                let frames = layout.frames(in: size, measuredLabelHeight: measured.height)
                if layout.horizontal {
                    let extent = layout.iconSize + 2 * layout.iconHalo
                    #expect(abs(layout.labelSize.width - (size.width - 2 * layout.padding - extent - layout.spacing)) < 0.0001)
                    #expect(abs(frames.label.midX - (layout.padding + extent + layout.spacing + size.width - layout.padding) / 2) < 0.0001)
                    #expect(abs(frames.label.maxX - (size.width - layout.padding)) < 0.0001)
                    #expect(abs(frames.label.midY - size.height / 2) < 0.0001)
                    if !title.isEmpty {
                        #expect(frames.label.minX >= frames.icon.maxX + layout.iconHalo + layout.spacing - 0.0001)
                    }
                } else {
                    #expect(abs(frames.label.midX - size.width / 2) < 0.0001)
                    let top = frames.icon.minY - layout.iconHalo
                    let bottom = title.isEmpty ? frames.icon.maxY + layout.iconHalo : frames.label.maxY
                    #expect(abs((top + bottom) / 2 - size.height / 2) < 0.0001)
                    #expect(abs(frames.label.height - measured.height) < 0.0001)
                    #expect(frames.label.height < layout.labelSize.height)
                }
                for frame in [frames.icon.insetBy(dx: -layout.iconHalo, dy: -layout.iconHalo), frames.label] {
                    #expect(frame.minX >= layout.padding - 0.0001 && frame.minY >= layout.padding - 0.0001)
                    #expect(frame.maxX <= size.width - layout.padding + 0.0001)
                    #expect(frame.maxY <= size.height - layout.padding + 0.0001)
                }
            }
        }
        let size = CGSize(width: 100, height: 240)
        let noIcon = PaperGIFRemotePreviewLabelFitting.layout(size: size, scale: 1, compact: false, hasIcon: false)
        #expect(noIcon.frames(in: size, measuredLabelHeight: 20).label.midY == size.height / 2)
        #expect(noIcon.iconSize == 0 && noIcon.spacing == 0)
    }

        @Test func remotePreviewWordWrappedMeasurementAndWholeWordShrink() {
        #expect(PaperGIFRemotePreviewLabelFitting.normalizedTitle("Line one\r\nLine two\rLine three\u{2028}Line four") ==
            "Line one\nLine two\nLine three\nLine four")
        let bounds = CGSize(width: 80, height: 200)
        let title = "Up Left Down Right"
        #expect(PaperGIFRemotePreviewLabelFitting.fontSize(for: title, in: bounds, maximum: 24) == 24)
        #expect(PaperGIFRemotePreviewLabelFitting.measuredSize(title, fontSize: 24, width: 80).height >
            PaperGIFRemotePreviewLabelFitting.measuredSize("Go", fontSize: 24, width: 80).height)
        #expect(PaperGIFRemotePreviewLabelFitting.measuredSize("Go\n\nGo", fontSize: 24, width: 80).height >
            PaperGIFRemotePreviewLabelFitting.measuredSize("Go\nGo", fontSize: 24, width: 80).height)
        for word in ["Supercalifragilisticexpialidocious", "第一行很长的按钮标题第二行", "word-with/slashes"] {
            let rejected = PaperGIFRemotePreviewLabelFitting.measuredSize(word, fontSize: 24, width: 80)
            #expect(rejected.width > 80 && rejected.height.isInfinite)
            let fitted = PaperGIFRemotePreviewLabelFitting.fontSize(for: word, in: bounds, maximum: 24)
            #expect(fitted > 0 && fitted < 24)
            #expect(PaperGIFRemotePreviewLabelFitting.widestWordWidth(word, fontSize: fitted) <= 80)
            #expect(PaperGIFRemotePreviewLabelFitting.measuredSize(word, fontSize: fitted, width: 80).height ==
                PaperGIFRemotePreviewLabelFitting.measuredSize("Go", fontSize: fitted, width: 80).height)
        }
        for title in ["Jog X Negative Y Positive", "Supercalifragilisticexpialidocious",
                      "第一行很长的按钮标题第二行", "Line one\nLine two\nLine three"] {
            let measured = PaperGIFRemotePreviewLabelFitting.measuredSize(title, fontSize: 24, width: 20)
            #expect(measured.width > 20)
            #expect(measured.height.isInfinite)
            for bounds in [CGSize(width: 20, height: 100), CGSize(width: 100, height: 5)] {
                let fitted = PaperGIFRemotePreviewLabelFitting.fontSize(for: title, in: bounds, maximum: 24)
                #expect(fitted > 0 && fitted < 24)
                #expect(PaperGIFRemotePreviewLabelFitting.widestWordWidth(title, fontSize: fitted) <= bounds.width)
                let actual = PaperGIFRemotePreviewLabelFitting.measuredSize(title, fontSize: fitted, width: bounds.width)
                #expect(actual.width <= bounds.width && actual.height <= bounds.height)
                let larger = PaperGIFRemotePreviewLabelFitting.measuredSize(title, fontSize: fitted + 0.001, width: bounds.width)
                #expect(larger.width > bounds.width || larger.height > bounds.height)
            }
        }
        for hasIcon in [false, true] {
            let size = CGSize(width: 300, height: 80)
            let layout = PaperGIFRemotePreviewLabelFitting.layout(size: size, scale: 1, compact: true, hasIcon: hasIcon)
            for title in ["Go", "Up Left", "Play"] {
                #expect(PaperGIFRemotePreviewLabelFitting.fontSize(for: title, in: layout.labelSize, maximum: layout.maximumFontSize) == 24)
            }
            if !hasIcon {
                #expect(layout.labelSize.width == size.width - 2 * layout.padding)
                #expect(layout.frames(in: size, measuredLabelHeight: 20).label.midX == size.width / 2)
            }
        }
    }

    @Test @MainActor func mediaSourceSelectionPreservesSeekSliderAndOutline() throws {
        var control = PaperGIFRemoteControl(
            title: "Music", symbol: "music.note", tintHex: "202020", kind: .slider,
            gridWidth: 2, gridHeight: 1, sliderOutlineInsetPixels: 7,
            action: .init(type: .computerMedia, text: "seek", value: 123),
            layoutSlot: 4,
            textBox: .init(source: .nowPlaying, textSize: .large,
                           horizontalAlignment: .center, verticalAlignment: .bottom)
        )
        for source in [PaperGIFRemoteActionType.iPhoneMedia, .computerMedia] {
            let previousType = control.action.type
            control.action.type = source
            control.applyEditorActionDefaults(previousType: previousType)
            #expect(control.kind == .slider)
            #expect(control.action.text == "seek")
            #expect(control.sliderOutlineInsetPixels == 7)
            #expect(control.title == "Music")
            #expect(control.layoutSlot == 4)
            #expect(control.gridWidth == 2 && control.gridHeight == 1)
            #expect(control.textBox?.textSize == .large)
            #expect(control.textBox?.verticalAlignment == .bottom)
            #expect(control.action.value == 123)
        }
        let data = try JSONEncoder().encode(control)
        #expect(try JSONDecoder().decode(PaperGIFRemoteControl.self, from: data) == control)
    }

    @Test @MainActor func newSliderKeepsOutlineWhenMediaSourceIsSelected() {
        for source in [PaperGIFRemoteActionType.computerMedia, .iPhoneMedia] {
            var control = PaperGIFRemoteControl(
                title: "Slider", symbol: "", tintHex: "202020", kind: .slider,
                sliderOutlineInsetPixels: 3,
                action: .init(type: .wledBrightness, value: 128)
            )
            control.action.type = source
            control.applyEditorActionDefaults(previousType: .wledBrightness)
            #expect(control.kind == .slider)
            #expect(control.action.text == "volume")
            #expect(control.sliderOutlineInsetPixels == 3)
            control.setEditorMediaCommand("seek")
            #expect(control.kind == .slider)
            #expect(control.sliderOutlineInsetPixels == 3)
            #expect(control.textBox?.source == .nowPlaying)
        }
        // Changing a transport button's appearance to Slider before its source
        // must not silently undo the user's chosen layout either.
        var control = PaperGIFRemoteControl.button(title: "Music", symbol: "", action: .playPause)
        control.kind = .slider
        control.sliderOutlineInsetPixels = 5
        let previousType = control.action.type
        control.action.type = .computerMedia
        control.applyEditorActionDefaults(previousType: previousType)
        #expect(control.kind == .slider)
        #expect(control.action.text == "volume")
        #expect(control.sliderOutlineInsetPixels == 5)
    }

    @Test @MainActor func selectingSeekRepairsButtonLayoutAndUsesSelectedComputer() {
        let computerID = UUID()
        var control = PaperGIFRemoteControl.button(
            title: "Music", symbol: "music.note",
            action: .init(type: .computerMedia, text: "playPause", computerID: computerID.uuidString)
        )
        control.setEditorMediaCommand("seek")
        #expect(control.kind == .slider)
        #expect(control.textBox?.source == .nowPlaying)
        #expect(control.textBox?.computerID == computerID)
        control.sliderOutlineInsetPixels = 9
        control.setEditorMediaCommand("volume")
        #expect(control.kind == .slider && control.sliderOutlineInsetPixels == 9)
        control.setEditorMediaCommand("playPause")
        #expect(control.kind == .button)
        #expect(control.isToggle == nil)
        control.setEditorMediaCommand("seek")
        #expect(control.kind == .slider && control.sliderOutlineInsetPixels == 9)
    }

    @Test @MainActor func mediaTapActionDoesNotConvertTextBoxToSlider() {
        var control = PaperGIFRemoteControl(
            title: "Text", symbol: "", tintHex: "202020", kind: .textBox,
            action: .init(type: .computerMedia, text: "seek"),
            textBox: .init(source: .staticText, sourceText: "Keep this text")
        )
        control.action.type = .iPhoneMedia
        control.applyEditorActionDefaults(previousType: .computerMedia)
        control.setEditorMediaCommand("volume")
        #expect(control.kind == .textBox)
        #expect(control.textBox?.source == .staticText)
        #expect(control.textBox?.sourceText == "Keep this text")
    }

    @Test @MainActor func nonMediaActionDefaultsStillNormalizeLayout() {
        var control = PaperGIFRemoteControl.button(
            title: "Control", symbol: "", action: .init(type: .netHomeTemperature)
        )
        control.applyEditorActionDefaults(previousType: .computerMedia)
        #expect(control.kind == .slider)
        #expect(control.action.value == 22 && control.action.valueTenths == 220)
        control.action.type = .computerKey
        control.applyEditorActionDefaults(previousType: .netHomeTemperature)
        #expect(control.kind == .button)
    }

    @Test func canonicalV6FixtureCoversEveryActionType() throws {
        let profile = try JSONDecoder().decode(
            PaperGIFRemoteProfile.self,
            from: Data(contentsOf: protocolFixture("remote-profile-v6-all-actions.json"))
        )
        let actionTypes = Set(profile.pages.flatMap(\.controls).map(\.action.type))

        #expect(actionTypes == Set(PaperGIFRemoteActionType.allCases))
        #expect(profile.computers.count == 2)
        #expect(profile.pages.count == 2)
        #expect(profile.pages[0].controls[5].textBox?.source == .nowPlaying)
        #expect(profile.pages[1].controls[4].action.schedules?.first?.valueTenths == 225)
        let localHTTP = try #require(profile.pages[1].controls.first { $0.action.type == .localHTTP })
        #expect(localHTTP.action.httpMethod == "GET")
        #expect(localHTTP.action.httpBody == nil)
    }

    @Test func canonicalV6FixtureCoversEveryTextSource() throws {
        let profile = try JSONDecoder().decode(
            PaperGIFRemoteProfile.self,
            from: Data(contentsOf: protocolFixture("remote-profile-v6-text-sources.json"))
        )
        let sources = Set(profile.pages.flatMap(\.controls).compactMap(\.textBox?.source))

        #expect(sources == Set(PaperGIFRemoteTextSource.allCases))
    }

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
                tapAction: .init(type: .computerMedia, text: "playPause"),
                refreshIntervalSeconds: 5
            )
        )
        let profile = PaperGIFRemoteProfile(
            buttonQualityRefreshInterval: 17,
            elementRefreshDelayMilliseconds: 35,
            timeZoneOffsetMinutes: -240,
            pages: [.init(name: "Main", controls: [control])]
        )

        let encoded = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(PaperGIFRemoteProfile.self, from: encoded)

        #expect(decoded == profile)
        #expect(decoded.buttonQualityRefreshInterval == 17)
        #expect(decoded.elementRefreshDelayMilliseconds == 35)
    }

    @Test func remoteProfileTimestampDefaultsToZeroAndAdvancesMonotonically() throws {
        let legacy = try JSONDecoder().decode(
            PaperGIFRemoteProfile.self,
            from: Data(#"{"version":6,"pages":[]}"#.utf8)
        )
        #expect(legacy.updatedAtMilliseconds == 0)

        var profile = legacy
        profile.markUpdated(now: Date(timeIntervalSince1970: 100))
        #expect(profile.updatedAtMilliseconds == 100_000)
        profile.markUpdated(now: Date(timeIntervalSince1970: 99))
        #expect(profile.updatedAtMilliseconds == 100_001)
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

    @Test func remoteGridTranslationPreservesControlOrigin() {
        #expect(PaperGIFRemoteGrid.translatedSlot(
            from: 0,
            columnOffset: 0,
            rowOffset: 0,
            columns: 9,
            rows: 14
        ) == 0)
        #expect(PaperGIFRemoteGrid.translatedSlot(
            from: 117,
            columnOffset: 1,
            rowOffset: 0,
            columns: 9,
            rows: 14
        ) == 118)
        #expect(PaperGIFRemoteGrid.translatedSlot(
            from: 118,
            columnOffset: -1,
            rowOffset: 0,
            columns: 9,
            rows: 14
        ) == 117)
    }

    @Test func deviceProfilePreservesKnownNumericComputerHosts() {
        let computerID = UUID()
        let localComputer = PaperGIFRemoteComputer(
            id: computerID,
            name: "Mac",
            host: "192.168.50.20",
            token: "token"
        )
        var deviceProfile = PaperGIFRemoteProfile(
            macHost: "levis-mac-mini.local",
            macToken: "token",
            computers: [PaperGIFRemoteComputer(
                id: computerID,
                name: "Mac",
                host: "levis-mac-mini.local",
                token: "token"
            )],
            pages: []
        )
        let localProfile = PaperGIFRemoteProfile(
            macHost: "192.168.50.20",
            macToken: "token",
            computers: [localComputer],
            pages: []
        )

        let changed = deviceProfile.preserveNumericComputerHosts(from: localProfile)
        #expect(changed)
        #expect(deviceProfile.macHost == "192.168.50.20")
        #expect(deviceProfile.computers.first?.host == "192.168.50.20")
    }

    @Test func starterLayoutDetectionIgnoresGeneratedIdentifiers() {
        #expect(PaperGIFRemoteProfile.starter.usesStarterLayout)

        var configured = PaperGIFRemoteProfile.starter
        configured.pages.append(.init(name: "Media", controls: []))

        #expect(!configured.usesStarterLayout)
    }

    @Test func openBuildsSettingsRailRejectsOverlappingControls() throws {
        var control = PaperGIFRemoteControl.button(
            title: "Move",
            symbol: "arrow.right",
            action: .playPause
        )
        control.gridWidth = 2
        control.gridHeight = 2

        let openPlacement = try #require(PaperGIFRemoteGrid.placement(
            for: control, at: 27, columns: 9, rows: 14
        ))
        let railPlacement = try #require(PaperGIFRemoteGrid.placement(
            for: control, at: 33, columns: 9, rows: 14
        ))

        let rail = PaperGIFRemoteGrid.cells(
            for: PaperGIFRemoteGrid.openBuildsSettingsPlacement(slot: nil, columns: 9, rows: 14),
            columns: 9
        )
        #expect(PaperGIFRemoteGrid.cells(for: openPlacement, columns: 9).isDisjoint(with: rail))
        #expect(!PaperGIFRemoteGrid.cells(for: railPlacement, columns: 9).isDisjoint(with: rail))
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
            hasHomeWiFiEndpoint: true,
            isDeviceWiFiConnected: false
        )

        #expect(transport == .wifi)
    }

    @Test @MainActor func prefersBluetoothWhenHomeWiFiEndpointIsUnavailable() {
        let transport = PaperGIFBluetoothManager.preferredTransferTransport(
            homeWiFiState: .connected,
            hasHomeWiFiEndpoint: false,
            isDeviceWiFiConnected: false
        )

        #expect(transport == .bluetooth)
    }

    @Test @MainActor func prefersDeviceWiFiWhenAccessPointIsConnected() {
        let transport = PaperGIFBluetoothManager.preferredTransferTransport(
            homeWiFiState: .notConfigured,
            hasHomeWiFiEndpoint: false,
            isDeviceWiFiConnected: true
        )

        #expect(transport == .wifi)
    }

    @Test @MainActor func treatsValidPaperGIFStatusResponseAsReachableEvenWhenNotReady() {
        #expect(PaperGIFBluetoothManager.isDeviceWiFiReachable(device: "paperGIF", ready: false))
    }

    @Test func decodesOpenBuildsMotionControllerModulePage() throws {
        let page = try PaperGIFModuleCatalog.decodeMotionControllerPage(
            from: Data(contentsOf: moduleFixture("openbuilds-control.json"))
        )

        #expect(page.name == "Motion Control")
        #expect(page.layout == .openBuildsController)
        #expect(page.controls.count == 22)
        #expect(page.moduleID == PaperGIFModuleCatalog.openBuildsModuleID)
        #expect(page.modulePageID == PaperGIFModuleCatalog.motionControllerPageID)
        #expect(Set(page.controls.map(\.id)).count == page.controls.count)
    }

    @Test func decodesPublishedModulePagesWithTheirGridGeometry() throws {
        let fixtures = [
            (module: "media-controls", page: "media", name: "Media"),
            (module: "presentation-controls", page: "presentation", name: "Presentation"),
            (module: "wled-scenes", page: "wled-scenes", name: "WLED Scenes"),
        ]

        for fixture in fixtures {
            let page = try PaperGIFModuleCatalog.decodePage(
                from: Data(contentsOf: moduleFixture("\(fixture.module).json")),
                expectedModuleID: fixture.module,
                pageID: fixture.page
            )

            #expect(page.name == fixture.name)
            #expect(page.gridColumns == 3)
            #expect(page.gridRows == 8)
            #expect(page.moduleID == fixture.module)
            #expect(page.modulePageID == fixture.page)
            #expect(page.controls.allSatisfy { $0.layoutSlot != nil })
            #expect(Set(page.controls.map(\.id)).count == page.controls.count)
        }
    }

    @Test func loadsBundledModulePages() throws {
        let modules = try PaperGIFModuleCatalog.bundledModules()

        #expect(Set(modules.map(\.id)) == Set([
            "media-controls",
            "openbuilds-control",
            "presentation-controls",
            "wled-scenes",
        ]))
        #expect(modules.flatMap { $0.pages ?? [] }.count == 4)
    }

    @Test func modulePageComputerConfigurationRoutesCommandsAndLiveDataTogether() throws {
        let computerID = UUID()
        let mediaPage = try PaperGIFModuleCatalog.decodePage(
            from: Data(contentsOf: moduleFixture("media-controls.json")),
            expectedModuleID: "media-controls",
            pageID: "media"
        )
        let configuredMedia = PaperGIFModuleCatalog.configure(mediaPage, for: computerID)
        let seek = try #require(configuredMedia.controls.first { $0.action.text == "seek" })

        #expect(seek.action.computerID == computerID.uuidString)
        #expect(seek.textBox?.computerID == computerID)

        let motionPage = try PaperGIFModuleCatalog.decodeMotionControllerPage(
            from: Data(contentsOf: moduleFixture("openbuilds-control.json"))
        )
        let configuredMotion = PaperGIFModuleCatalog.configure(motionPage, for: computerID)

        #expect(configuredMotion.controls.allSatisfy {
            $0.action.computerID == computerID.uuidString
        })
        #expect(configuredMotion.controls.filter {
            $0.textBox?.source == .openBuildsPosition
        }.allSatisfy { $0.textBox?.computerID == computerID })
    }

    @Test func remoteTabLayoutMatchesFirmwareGeometry() throws {
        let frames = PaperGIFRemoteTabLayout.frames(pageCount: 8, selectedIndex: 3)

        #expect(frames.count == 8)
        #expect(frames[0] == PaperGIFRemoteTabFrame(x: 24, y: 858, width: 61, height: 60))
        #expect(frames[3] == PaperGIFRemoteTabFrame(x: 208, y: 850, width: 62, height: 68))
        #expect(frames[7] == PaperGIFRemoteTabFrame(x: 454, y: 858, width: 62, height: 60))
        #expect(frames.reduce(0) { $0 + $1.width } == 492)
    }

}

private func protocolFixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("protocol/fixtures")
        .appendingPathComponent(name)
}

    private func moduleFixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("modules")
        .appendingPathComponent(name)
    }
