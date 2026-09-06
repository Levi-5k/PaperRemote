import Foundation
import XCTest
@testable import PaperGIFMac

final class RemoteProfileModelTests: XCTestCase {
    func testLegacyProfileMigratesToCurrentVersion() throws {
        let data = Data(#"{"version":1,"pages":[{"id":"00000000-0000-0000-0000-000000000001","name":"Main","controls":[]}]}"#.utf8)

        let profile = try JSONDecoder().decode(RemoteProfile.self, from: data)

        XCTAssertEqual(profile.version, RemoteProfile.currentVersion)
        XCTAssertEqual(profile.temperatureUnit, .celsius)
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
            scheduleMinute: 30
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
    }

    func testFahrenheitPreferenceRoundTripsWithoutChangingStoredCelsius() throws {
        var profile = RemoteProfile(pages: [])
        profile.temperatureUnit = .fahrenheit
        let decoded = try JSONDecoder().decode(
            RemoteProfile.self,
            from: JSONEncoder().encode(profile)
        )

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