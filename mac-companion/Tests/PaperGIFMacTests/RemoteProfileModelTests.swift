import Foundation
import XCTest
@testable import PaperGIFMac

final class RemoteProfileModelTests: XCTestCase {
    func testLegacyProfileMigratesToCurrentVersion() throws {
        let data = Data(#"{"version":1,"pages":[{"id":"00000000-0000-0000-0000-000000000001","name":"Main","controls":[]}]}"#.utf8)

        let profile = try JSONDecoder().decode(RemoteProfile.self, from: data)

        XCTAssertEqual(profile.version, RemoteProfile.currentVersion)
    }

    func testTextBoxPlacementUsesEveryCellInItsSpan() throws {
        let control = RemoteControl(
            title: "Status",
            symbol: "",
            kind: .textBox,
            action: .init(type: .macMedia),
            layoutSlot: 2,
            textBox: RemoteTextBox(gridWidth: 2, gridHeight: 3)
        )

        let placement = try XCTUnwrap(RemoteGrid.placement(for: control, at: 2))

        XCTAssertEqual(RemoteGrid.cells(for: placement), Set([2, 3, 4, 5, 6, 7]))
        XCTAssertNil(RemoteGrid.placement(for: control, at: 13))
    }

    func testButtonCanStartOnAnyRowWhereItFits() throws {
        let control = RemoteControl(
            title: "Play",
            symbol: "play.fill",
            kind: .button,
            action: .init(type: .macMedia, text: "playPause")
        )

        let placement = try XCTUnwrap(RemoteGrid.placement(for: control, at: 3))

        XCTAssertEqual(placement.slot, 3)
        XCTAssertEqual(RemoteGrid.cells(for: placement), Set([3, 5]))
        XCTAssertNil(RemoteGrid.placement(for: control, at: 15))
    }

    func testOneRowButtonUsesOneCellAndRoundTrips() throws {
        var control = RemoteControl(
            title: "Mute",
            symbol: "speaker.slash.fill",
            kind: .button,
            action: .init(type: .macMedia, text: "mute")
        )
        control.buttonHeight = 1

        let placement = try XCTUnwrap(RemoteGrid.placement(for: control, at: 15))
        let decoded = try JSONDecoder().decode(
            RemoteControl.self,
            from: JSONEncoder().encode(control)
        )

        XCTAssertEqual(RemoteGrid.cells(for: placement), Set([15]))
        XCTAssertEqual(decoded.buttonHeight, 1)
        XCTAssertEqual(decoded.gridSpan, RemoteGridSpan(width: 1, height: 1))
    }

    func testTextBoxAlignmentRoundTripsAndDefaultsLegacyValues() throws {
        let configured = RemoteTextBox(horizontalAlignment: .center, verticalAlignment: .bottom)
        let decoded = try JSONDecoder().decode(
            RemoteTextBox.self,
            from: JSONEncoder().encode(configured)
        )
        let legacy = try JSONDecoder().decode(
            RemoteTextBox.self,
            from: Data(#"{"source":"staticText","sourceText":"Legacy"}"#.utf8)
        )

        XCTAssertEqual(decoded, configured)
        XCTAssertEqual(legacy.horizontalAlignment, .leading)
        XCTAssertEqual(legacy.verticalAlignment, .top)
    }

    func testDevicePayloadIncludesCurrentClockWithoutChangingStoredProfile() throws {
        let profile = RemoteProfile(pages: [.init(name: "Main", controls: [])])

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: profile.devicePayload) as? [String: Any]
        )
        let clock = try XCTUnwrap(object["deviceClock"] as? [String: Int])
        let stored = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any]

        XCTAssertGreaterThanOrEqual(clock["year"] ?? 0, 2020)
        XCTAssertNotNil(clock["weekday"])
        XCTAssertNil(stored?["deviceClock"])
    }

}