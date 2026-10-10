import Foundation
import XCTest
@testable import PaperGIFMac

final class RemoteProfileModelTests: XCTestCase {
    func testButtonTextSizeDefaultClampAndIntegerRoundTrip() throws {
        let legacy = try JSONDecoder().decode(RemoteProfile.self, from: Data(#"{"version":6,"pages":[]}"#.utf8))
        XCTAssertEqual(legacy.maxButtonTextSize, 24)
        XCTAssertEqual(RemoteProfile(pages: []).maxButtonTextSize, 24)
        for (input, expected) in [(Int.min, 9), (8, 9), (9, 9), (17, 17), (24, 24), (25, 24), (Int.max, 24)] {
            var profile = RemoteProfile(maxButtonTextSize: input, pages: [])
            XCTAssertEqual(profile.maxButtonTextSize, expected)
            profile.maxButtonTextSize = input
            XCTAssertEqual(profile.maxButtonTextSize, expected)
            let data = try JSONEncoder().encode(profile)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let value = try XCTUnwrap(object["maxButtonTextSize"] as? NSNumber)
            XCTAssertEqual(value.intValue, expected)
            XCTAssertFalse(String(data: data, encoding: .utf8)!.contains("\"maxButtonTextSize\":\(expected)."))
            XCTAssertEqual(try JSONDecoder().decode(RemoteProfile.self, from: data), profile)
            let decoded = try JSONDecoder().decode(RemoteProfile.self, from: Data("{\"pages\":[],\"maxButtonTextSize\":\(input)}".utf8))
            XCTAssertEqual(decoded.maxButtonTextSize, expected)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: profile.devicePayload) as? [String: Any])
            XCTAssertEqual(payload["maxButtonTextSize"] as? Int, expected)
        }
    }

    func testCanonicalV6FixtureCoversEveryActionType() throws {
        let profile = try JSONDecoder().decode(
            RemoteProfile.self,
            from: Data(contentsOf: protocolFixture("remote-profile-v6-all-actions.json"))
        )
        let actionTypes = Set(profile.pages.flatMap(\.controls).map(\.action.type))

        XCTAssertEqual(actionTypes, Set(RemoteActionType.allCases))
        XCTAssertEqual(profile.computers.count, 2)
        XCTAssertEqual(profile.pages.count, 2)
        XCTAssertEqual(profile.pages[0].controls[5].textBox?.source, .nowPlaying)
        XCTAssertEqual(profile.pages[1].controls[4].action.schedules?.first?.valueTenths, 225)
        let localHTTP = try XCTUnwrap(profile.pages[1].controls.first { $0.action.type == .localHTTP })
        XCTAssertEqual(localHTTP.action.httpMethod, "GET")
        XCTAssertNil(localHTTP.action.httpBody)
    }

    func testCanonicalV6FixtureCoversEveryTextSource() throws {
        let profile = try JSONDecoder().decode(
            RemoteProfile.self,
            from: Data(contentsOf: protocolFixture("remote-profile-v6-text-sources.json"))
        )
        let sources = Set(profile.pages.flatMap(\.controls).compactMap(\.textBox?.source))

        XCTAssertEqual(sources, Set(RemoteTextSource.allCases))
    }

    @MainActor
    func testNetHomeRenameReconciliationUsesStableUnitID() {
        let localComputer = RemoteComputer(name: "This Mac", host: "mac.local", token: "token")
        let otherComputer = RemoteComputer(name: "Other Mac", host: "other.local", token: "token")
        var profile = RemoteProfile(pages: [
            .netHomeThermostat(unit: "Bedroom", computerID: localComputer.id.uuidString),
            .netHomeThermostat(unit: "Office", computerID: otherComputer.id.uuidString),
        ])
        profile.computers = [localComputer, otherComputer]

        let result = RemoteEditorStore.reconcileNetHomeProfile(
            profile,
            previousUnits: [.init(id: "101", name: "Bedroom")],
            currentUnits: [.init(id: "101", name: "Primary Bedroom")],
            localComputerID: localComputer.id.uuidString
        )

        XCTAssertEqual(result.profile.pages[0].name, "Primary Bedroom")
        XCTAssertTrue(result.profile.pages[0].controls.allSatisfy {
            $0.action.host == "Primary Bedroom"
        })
        XCTAssertEqual(result.profile.pages[1], profile.pages[1])
        XCTAssertEqual(result.aliases["bedroom"], "Primary Bedroom")
    }

    @MainActor
    func testNetHomeRenameReconciliationInfersSingleLegacyRename() {
        let computer = RemoteComputer(name: "This Mac", host: "mac.local", token: "token")
        var profile = RemoteProfile(pages: [
            .netHomeThermostat(unit: "Old Name", computerID: computer.id.uuidString),
        ])
        profile.computers = [computer]

        let result = RemoteEditorStore.reconcileNetHomeProfile(
            profile,
            previousUnits: [],
            currentUnits: [.init(id: "101", name: "New Name")],
            localComputerID: computer.id.uuidString
        )

        XCTAssertEqual(result.profile.pages[0].name, "New Name")
        XCTAssertTrue(result.profile.pages[0].controls.allSatisfy {
            $0.action.host == "New Name"
        })
    }

    func testLegacyProfileMigratesToCurrentVersion() throws {
        let data = Data(#"{"version":1,"pages":[{"id":"00000000-0000-0000-0000-000000000001","name":"Main","controls":[]}]}"#.utf8)

        let profile = try JSONDecoder().decode(RemoteProfile.self, from: data)

        XCTAssertEqual(profile.version, RemoteProfile.currentVersion)
        XCTAssertEqual(profile.updatedAtMilliseconds, 0)
        XCTAssertEqual(profile.buttonQualityRefreshInterval, 10)
        XCTAssertEqual(profile.elementRefreshDelayMilliseconds, 20)
        XCTAssertEqual(profile.temperatureUnit, .celsius)
    }

    func testProfileTimestampAdvancesMonotonically() {
        var profile = RemoteProfile(pages: [])
        profile.updatedAtMilliseconds = 100_000

        profile.markUpdated(now: Date(timeIntervalSince1970: 99))

        XCTAssertEqual(profile.updatedAtMilliseconds, 100_001)
    }

    func testLegacyOpenBuildsPageMigratesToFlexibleGrid() throws {
        let data = Data(#"{"version":6,"pages":[{"id":"00000000-0000-0000-0000-000000000001","name":"Motion","layout":"openBuildsController","controls":[{"id":"00000000-0000-0000-0000-000000000002","title":"Y","symbol":"","tintHex":"202020","kind":"textBox","action":{"type":"openBuilds","host":"127.0.0.1","text":"","value":0,"modifiers":[]},"textBox":{"source":"openBuildsPosition","sourceText":"127.0.0.1|y|mm"}},{"id":"00000000-0000-0000-0000-000000000003","title":"Up Left","symbol":"arrow.up.left","tintHex":"202020","kind":"button","action":{"type":"openBuilds","host":"127.0.0.1","text":"jogXNegativeYPositive","value":1,"modifiers":[]}}]}]}"#.utf8)

        let page = try XCTUnwrap(JSONDecoder().decode(RemoteProfile.self, from: data).pages.first)

        XCTAssertEqual(page.gridColumns, 9)
        XCTAssertEqual(page.gridRows, 14)
        XCTAssertEqual(page.controls[0].layoutSlot, 3)
        XCTAssertEqual(page.controls[0].gridSpan(columns: 9, rows: 14), .init(width: 3, height: 2))
        XCTAssertEqual(page.controls[1].layoutSlot, 18)
        XCTAssertEqual(page.controls[1].gridSpan(columns: 9, rows: 14), .init(width: 2, height: 2))
    }

    func testExplicitOpenBuildsGridIsNotMigrated() throws {
        let data = Data(#"{"version":6,"pages":[{"id":"00000000-0000-0000-0000-000000000001","name":"Motion","gridColumns":4,"gridRows":5,"layout":"openBuildsController","controls":[]}]}"#.utf8)

        let page = try XCTUnwrap(JSONDecoder().decode(RemoteProfile.self, from: data).pages.first)

        XCTAssertEqual(page.gridColumns, 4)
        XCTAssertEqual(page.gridRows, 5)
    }

    func testOpenBuildsUnitsDecodeLegacyDistanceAndRoundTripInches() throws {
        let legacy = Data(#"{"host":"127.0.0.1","jogSpeed":1000,"jogMode":"incremental","jogDistanceTenths":10}"#.utf8)
        let legacySettings = try JSONDecoder().decode(RemoteOpenBuildsController.self, from: legacy)

        XCTAssertEqual(legacySettings.units, .millimeters)
        XCTAssertEqual(legacySettings.jogDistanceThousandths, 1_000)

        let inchSettings = RemoteOpenBuildsController(
            jogSpeed: 40,
            units: .inches,
            jogDistanceThousandths: 1
        )
        let roundTripped = try JSONDecoder().decode(
            RemoteOpenBuildsController.self,
            from: JSONEncoder().encode(inchSettings)
        )

        XCTAssertEqual(roundTripped, inchSettings)
    }

    func testTextBoxPlacementUsesEveryCellInItsSpan() throws {
        let control = RemoteControl(
            title: "Status",
            symbol: "",
            kind: .textBox,
            action: .init(type: .computerMedia),
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
            action: .init(type: .computerMedia, text: "playPause")
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
            action: .init(type: .computerMedia, text: "mute")
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

    func testGridTranslationPreservesControlOrigin() {
        XCTAssertEqual(RemoteGrid.translatedSlot(
            from: 0,
            columnOffset: 0,
            rowOffset: 0,
            columns: 9,
            rows: 14
        ), 0)
        XCTAssertEqual(RemoteGrid.translatedSlot(
            from: 117,
            columnOffset: 1,
            rowOffset: 0,
            columns: 9,
            rows: 14
        ), 118)
        XCTAssertEqual(RemoteGrid.translatedSlot(
            from: 118,
            columnOffset: -1,
            rowOffset: 0,
            columns: 9,
            rows: 14
        ), 117)
    }

    private let rail = RemoteGrid.cells(
        for: RemoteGrid.openBuildsSettingsPlacement(slot: nil, columns: 9, rows: 14), columns: 9
    )

    func testOpenBuildsSettingsOccupyWholeCellsWhereTheFixedRailUsedToBe() {
        let placement = RemoteGrid.openBuildsSettingsPlacement(slot: nil, columns: 9, rows: 14)
        XCTAssertEqual(placement.slot, 33)
        XCTAssertEqual(placement.span, RemoteGridSpan(width: 3, height: 9))
        XCTAssertTrue(rail.contains(33) && rail.contains(107) && !rail.contains(32) && !rail.contains(114))
        // Out-of-bounds saved slots fall back to the default position.
        XCTAssertEqual(RemoteGrid.openBuildsSettingsPlacement(slot: 7, columns: 9, rows: 14).slot, 33)
        XCTAssertEqual(RemoteGrid.openBuildsSettingsPlacement(slot: 45, columns: 9, rows: 14).slot, 45)
    }

    func testOpenBuildsSettingsMoveOnlyIntoFreeCells() {
        var page = RemotePage(name: "Motion", controls: jogButtons([27]))
        page.layout = .openBuildsController
        page.gridColumns = 9
        page.gridRows = 14
        page.openBuildsController = RemoteOpenBuildsController()
        XCTAssertEqual(RemoteGrid.movedOpenBuildsSettings(on: page, controls: page.controls, to: 42), 42)
        XCTAssertNil(RemoteGrid.movedOpenBuildsSettings(on: page, controls: page.controls, to: 28))
        // Drops past the edge clamp onto the page.
        XCTAssertEqual(RemoteGrid.movedOpenBuildsSettings(on: page, controls: page.controls, to: 125), 51)
    }

    private func jogButtons(_ slots: [Int?]) -> [RemoteControl] {
        slots.map { slot in
            var control = RemoteControl(
                title: "Jog", symbol: "arrow.up", kind: .button, action: RemoteAction(type: .page)
            )
            control.gridWidth = 2
            control.gridHeight = 2
            control.layoutSlot = slot
            return control
        }
    }

    func testDroppingOntoOneControlSwapsThem() throws {
        let controls = jogButtons([27, 29, 31])
        let slots = try XCTUnwrap(RemoteGrid.rearranged(
            controls, moving: 0, to: 29, columns: 9, rows: 14, reserved: rail
        ))
        XCTAssertEqual(slots, [29, 27, 31])
    }

    func testDroppingIntoFreeSpaceMovesAndPinsAutoPlacedControls() throws {
        let controls = jogButtons([27, nil])
        let slots = try XCTUnwrap(RemoteGrid.rearranged(
            controls, moving: 0, to: 81, columns: 9, rows: 14, reserved: rail
        ))
        XCTAssertEqual(slots, [81, 0])
    }

    func testDropsRejectedOnSettingsRailOrAcrossSeveralControls() {
        let controls = jogButtons([27, 29, 31])
        XCTAssertNil(RemoteGrid.rearranged(
            controls, moving: 0, to: 33, columns: 9, rows: 14, reserved: rail
        ))
        XCTAssertNil(RemoteGrid.rearranged(
            controls, moving: 2, to: 28, columns: 9, rows: 14, reserved: rail
        ))
    }

    func testSwapRejectedWhenTheOtherControlWouldNotFit() {
        var controls = jogButtons([27, nil])
        controls[1].gridWidth = 3
        controls[1].gridHeight = 1
        controls[1].layoutSlot = 18
        // The 3-wide control can't take slot 27's place without hitting the 2x2 at 29.
        controls.append(contentsOf: jogButtons([29]))
        XCTAssertNil(RemoteGrid.rearranged(
            controls, moving: 0, to: 18, columns: 9, rows: 14, reserved: rail
        ))
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

    func testNetHomeAutoSettingsRoundTripAndRemainOptionalForLegacyActions() throws {
        let configured = RemoteAction(
            type: .netHomeAuto,
            host: "Room",
            text: "cool",
            value: 22,
            deadbandTenths: 15,
            humidityThreshold: 60,
            minimumCycleMinutes: 10
        )
        let decoded = try JSONDecoder().decode(
            RemoteAction.self,
            from: JSONEncoder().encode(configured)
        )
        let legacy = try JSONDecoder().decode(
            RemoteAction.self,
            from: Data(#"{"type":"macMedia","text":"playPause","value":0,"host":"","modifiers":[]}"#.utf8)
        )

        XCTAssertEqual(decoded, configured)
        XCTAssertNil(legacy.deadbandTenths)
        XCTAssertNil(legacy.humidityThreshold)
        XCTAssertNil(legacy.minimumCycleMinutes)
    }

    func testDailyScheduleRoundTripsAndRemainsOptionalForLegacyActions() throws {
        let configured = RemoteAction(
            type: .netHomeTemperature,
            host: "Room",
            value: 22,
            valueTenths: 220,
            scheduleEnabled: true,
            scheduleHour: 7,
            scheduleMinute: 30,
            schedules: [
                RemoteScheduleEntry(
                    weekdays: [2, 3, 4, 5, 6],
                    hour: 7,
                    minute: 30,
                    value: 22,
                    valueTenths: 220
                ),
                RemoteScheduleEntry(
                    weekdays: [1, 7],
                    hour: 9,
                    minute: 15,
                    value: 20,
                    valueTenths: 200
                ),
            ]
        )
        let decoded = try JSONDecoder().decode(
            RemoteAction.self,
            from: JSONEncoder().encode(configured)
        )
        let legacy = try JSONDecoder().decode(
            RemoteAction.self,
            from: Data(#"{"type":"macMedia","text":"playPause","value":0,"host":"","modifiers":[]}"#.utf8)
        )

        XCTAssertEqual(decoded, configured)
        XCTAssertNil(legacy.scheduleEnabled)
        XCTAssertNil(legacy.scheduleHour)
        XCTAssertNil(legacy.scheduleMinute)
        XCTAssertNil(legacy.schedules)
    }

    func testFahrenheitPreferenceRoundTripsWithoutChangingStoredCelsius() throws {
        var profile = RemoteProfile(pages: [])
        profile.buttonQualityRefreshInterval = 17
        profile.elementRefreshDelayMilliseconds = 35
        profile.temperatureUnit = .fahrenheit
        let decoded = try JSONDecoder().decode(
            RemoteProfile.self,
            from: JSONEncoder().encode(profile)
        )

    XCTAssertEqual(decoded.buttonQualityRefreshInterval, 17)
    XCTAssertEqual(decoded.elementRefreshDelayMilliseconds, 35)
        XCTAssertEqual(decoded.temperatureUnit, .fahrenheit)
        XCTAssertEqual(decoded.temperatureUnit.displayValue(celsius: 22), 72)
        XCTAssertEqual(decoded.temperatureUnit.celsiusValue(displayValue: 72), 22)
        XCTAssertEqual(decoded.temperatureUnit.celsiusTenthsValue(displayValue: 72), 220)
        XCTAssertEqual(decoded.temperatureUnit.celsiusTenthsValue(displayValue: 71), 215)
        XCTAssertEqual(decoded.temperatureUnit.displayValue(celsiusTenths: 215), 71)
    }

    func testVersionFourGeneratedThermostatMigratesToResponsiveTemplate() throws {
        var profile = RemoteProfile(pages: [])
        profile.version = 4
        profile.pages = [RemotePage(name: "Room", controls: [
            RemoteControl(title: "Power", symbol: "power", kind: .button, action: .init(type: .netHomePower, host: "Room")),
            RemoteControl(title: "Auto", symbol: "humidity.fill", kind: .button, action: .init(type: .netHomeAuto, host: "Room", value: 23)),
            RemoteControl(title: "Setpoint", symbol: "thermometer.medium", kind: .slider, action: .init(type: .netHomeTemperature, host: "Room", value: 23)),
            RemoteControl(title: "Fan", symbol: "fan.fill", kind: .slider, action: .init(type: .netHomeFan, host: "Room", value: 40)),
            RemoteControl(title: "Cool", symbol: "snowflake", kind: .button, action: .init(type: .netHomeMode, host: "Room", text: "cool")),
            RemoteControl(title: "Heat", symbol: "sun.max.fill", kind: .button, action: .init(type: .netHomeMode, host: "Room", text: "heat")),
            RemoteControl(title: "Dry", symbol: "drop.fill", kind: .button, action: .init(type: .netHomeMode, host: "Room", text: "dry")),
            RemoteControl(title: "Fan Only", symbol: "wind", kind: .button, action: .init(type: .netHomeMode, host: "Room", text: "fan")),
        ])]

        let decoded = try JSONDecoder().decode(RemoteProfile.self, from: JSONEncoder().encode(profile))
        let controls = try XCTUnwrap(decoded.pages.first?.controls)

        XCTAssertEqual(decoded.version, 6)
        let setpoint = controls.first(where: { $0.action.type == .netHomeTemperature })
        XCTAssertEqual(setpoint?.kind, .textBox)
        XCTAssertEqual(setpoint?.textBox?.gridHeight, 1)
        XCTAssertEqual(setpoint?.action.valueTenths, 230)
        XCTAssertEqual(controls.filter { $0.action.type == .netHomeTemperatureStep }.map(\.action.value).sorted(), [-1, 1])
        XCTAssertEqual(setpoint?.action.value, 23)
    }

}

private func protocolFixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("protocol/fixtures")
        .appendingPathComponent(name)
}