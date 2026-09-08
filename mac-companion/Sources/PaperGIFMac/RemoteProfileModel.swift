import Foundation

enum RemoteTemperatureUnit: String, Codable, CaseIterable, Identifiable, Sendable {
    case celsius
    case fahrenheit

    var id: Self { self }
    var symbol: String { self == .celsius ? "°C" : "°F" }

    func displayValue(celsius: Int) -> Int {
        self == .celsius ? celsius : Int((Double(celsius) * 9 / 5 + 32).rounded())
    }

    func celsiusValue(displayValue: Int) -> Int {
        self == .celsius ? displayValue : Int((Double(displayValue - 32) * 5 / 9).rounded())
    }

    func displayValue(celsiusTenths: Int) -> Int {
        self == .celsius
            ? Int((Double(celsiusTenths) / 10).rounded())
            : Int((Double(celsiusTenths) * 9 / 50 + 32).rounded())
    }

    func celsiusTenthsValue(displayValue: Int) -> Int {
        self == .celsius
            ? displayValue * 10
            : Int((Double(displayValue - 32) * 10 / 9).rounded()) * 5
    }
}

enum RemoteControlKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case button
    case slider
    case textBox

    var id: Self { self }
}

enum RemotePageLayout: String, Codable, Sendable {
    case openBuildsController
}

enum RemoteJogMode: String, Codable, Sendable {
    case incremental
    case continuous
}

struct RemoteOpenBuildsController: Codable, Equatable, Sendable {
    var host = "127.0.0.1"
    var jogSpeed = 1_000
    var jogMode: RemoteJogMode = .incremental
    var jogDistanceTenths = 10
}

enum RemoteTextSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case staticText
    case dateTime
    case macScript
    case macShortcut
    case controlValue
    case nowPlaying
    case openBuildsPosition

    var id: Self { self }
}

enum RemoteTextSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case small
    case medium
    case large
    case extraLarge
    case autoFit

    var id: Self { self }
}

enum RemoteTextHorizontalAlignment: String, Codable, CaseIterable, Identifiable, Sendable {
    case leading
    case center
    case trailing

    var id: Self { self }
}

enum RemoteTextVerticalAlignment: String, Codable, CaseIterable, Identifiable, Sendable {
    case top
    case center
    case bottom

    var id: Self { self }
}

enum RemoteTextTapBehavior: String, Codable, CaseIterable, Identifiable, Sendable {
    case displayOnly
    case refresh
    case action

    var id: Self { self }
}

enum RemoteActionType: String, Codable, CaseIterable, Identifiable, Sendable {
    case macMedia
    case macKey
    case macOpen
    case macShortcut
    case macScript
    case openBuilds
    case wledPower
    case wledPreset
    case wledBrightness
    case netHomePower
    case netHomeTemperature
    case netHomeTemperatureStep
    case netHomeMode
    case netHomeFan
    case netHomeAuto
    case page

    var id: Self { self }

    var title: String {
        switch self {
        case .macMedia: "Media"
        case .macKey: "Keyboard shortcut"
        case .macOpen: "Open app or URL"
        case .macShortcut: "Apple Shortcut"
        case .macScript: "Approved script"
        case .openBuilds: "OpenBuilds CONTROL"
        case .wledPower: "WLED power"
        case .wledPreset: "WLED preset"
        case .wledBrightness: "WLED brightness"
        case .netHomePower: "NetHome power"
        case .netHomeTemperature: "NetHome temperature"
        case .netHomeTemperatureStep: "NetHome temperature step"
        case .netHomeMode: "NetHome mode"
        case .netHomeFan: "NetHome fan"
        case .netHomeAuto: "Sensor auto mode"
        case .page: "Open page"
        }
    }

    var systemImage: String {
        switch self {
        case .macMedia: "playpause.fill"
        case .macKey: "keyboard"
        case .macOpen: "arrow.up.forward.app"
        case .macShortcut: "command"
        case .macScript: "terminal"
        case .openBuilds: "move.3d"
        case .wledPower: "power"
        case .wledPreset: "sparkles"
        case .wledBrightness: "sun.max.fill"
        case .netHomePower: "power"
        case .netHomeTemperature: "thermometer.medium"
        case .netHomeTemperatureStep: "plusminus"
        case .netHomeMode: "arrow.triangle.2.circlepath"
        case .netHomeFan: "fan.fill"
        case .netHomeAuto: "humidity.fill"
        case .page: "rectangle.on.rectangle"
        }
    }
}

struct RemoteAction: Codable, Equatable, Sendable {
    var type: RemoteActionType
    var host = ""
    var text = ""
    var value = 0
    var valueTenths: Int?
    var modifiers: [String] = []
    var computerID: String?
    var deadbandTenths: Int?
    var humidityThreshold: Int?
    var minimumCycleMinutes: Int?
    var scheduleEnabled: Bool?
    var scheduleHour: Int?
    var scheduleMinute: Int?
    var schedules: [RemoteScheduleEntry]?
}

struct RemoteScheduleEntry: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var weekdays = Array(1...7)
    var hour = 8
    var minute = 0
    var text: String?
    var value: Int?
    var valueTenths: Int?
}

struct RemoteComputer: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var host: String
    var port = 43_821
    var token: String
}

struct RemoteTextBox: Codable, Equatable, Sendable {
    var source: RemoteTextSource = .staticText
    var sourceText = "Text"
    var referencedControlID: UUID?
    var computerID: UUID?
    var dateFormat = "%b %e, %H:%M"
    var placeholder = "Unavailable"
    var gridWidth = 2
    var gridHeight = 1
    var textSize: RemoteTextSize = .autoFit
    var horizontalAlignment: RemoteTextHorizontalAlignment = .leading
    var verticalAlignment: RemoteTextVerticalAlignment = .top
    var tapBehavior: RemoteTextTapBehavior = .displayOnly
    var tapAction: RemoteAction?
    var refreshIntervalSeconds: Int?
}

extension RemoteTextBox {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decodeIfPresent(RemoteTextSource.self, forKey: .source) ?? .staticText
        sourceText = try container.decodeIfPresent(String.self, forKey: .sourceText) ?? "Text"
        referencedControlID = try container.decodeIfPresent(UUID.self, forKey: .referencedControlID)
        computerID = try container.decodeIfPresent(UUID.self, forKey: .computerID)
        dateFormat = try container.decodeIfPresent(String.self, forKey: .dateFormat) ?? "%b %e, %H:%M"
        placeholder = try container.decodeIfPresent(String.self, forKey: .placeholder) ?? "Unavailable"
        gridWidth = try container.decodeIfPresent(Int.self, forKey: .gridWidth) ?? 2
        gridHeight = try container.decodeIfPresent(Int.self, forKey: .gridHeight) ?? 1
        textSize = try container.decodeIfPresent(RemoteTextSize.self, forKey: .textSize) ?? .autoFit
        horizontalAlignment = try container.decodeIfPresent(
            RemoteTextHorizontalAlignment.self,
            forKey: .horizontalAlignment
        ) ?? .leading
        verticalAlignment = try container.decodeIfPresent(
            RemoteTextVerticalAlignment.self,
            forKey: .verticalAlignment
        ) ?? .top
        tapBehavior = try container.decodeIfPresent(RemoteTextTapBehavior.self, forKey: .tapBehavior) ?? .displayOnly
        tapAction = try container.decodeIfPresent(RemoteAction.self, forKey: .tapAction)
        refreshIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .refreshIntervalSeconds)
    }
}

struct RemoteControl: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var title: String
    var symbol: String
    var iconBitmap: String? = nil
    var tintHex = "202020"
    var kind: RemoteControlKind
    var isToggle: Bool? = nil
    var buttonHeight: Int? = nil
    var gridWidth: Int? = nil
    var gridHeight: Int? = nil
    var action: RemoteAction
    var layoutSlot: Int?
    var textBox: RemoteTextBox? = nil

    var gridSpan: RemoteGridSpan {
        gridSpan(columns: 2, rows: 8)
    }

    func gridSpan(columns: Int, rows: Int) -> RemoteGridSpan {
        let legacySpan: RemoteGridSpan
        switch kind {
        case .button: legacySpan = RemoteGridSpan(width: 1, height: buttonGridHeight)
        case .slider: legacySpan = RemoteGridSpan(width: 1, height: 1)
        case .textBox:
            legacySpan = RemoteGridSpan(
                width: min(max(textBox?.gridWidth ?? 2, 1), 2),
                height: min(max(textBox?.gridHeight ?? 1, 1), 8)
            )
        }
        return RemoteGridSpan(
            width: min(max(gridWidth ?? legacySpan.width, 1), columns),
            height: min(max(gridHeight ?? legacySpan.height, 1), rows)
        )
    }

    var buttonGridHeight: Int {
        min(max(buttonHeight ?? 2, 1), 2)
    }
}

struct RemoteGridSpan: Equatable, Sendable {
    let width: Int
    let height: Int
}

struct RemoteGridPlacement: Equatable, Sendable {
    let slot: Int
    let span: RemoteGridSpan
}

enum RemoteGrid {
    static let columns = 2
    static let rows = 8

    static func placement(
        for control: RemoteControl,
        at requestedSlot: Int,
        columns: Int = RemoteGrid.columns,
        rows: Int = RemoteGrid.rows
    ) -> RemoteGridPlacement? {
        guard (0..<(columns * rows)).contains(requestedSlot) else { return nil }
        let span = control.gridSpan(columns: columns, rows: rows)
        let row = requestedSlot / columns
        var column = requestedSlot % columns
        if span.width == columns { column = 0 }
        guard column + span.width <= columns, row + span.height <= rows else { return nil }
        return RemoteGridPlacement(slot: row * columns + column, span: span)
    }

    static func cells(
        for placement: RemoteGridPlacement,
        columns: Int = RemoteGrid.columns
    ) -> Set<Int> {
        let row = placement.slot / columns
        let column = placement.slot % columns
        return Set((0..<placement.span.height).flatMap { rowOffset in
            (0..<placement.span.width).map { columnOffset in
                (row + rowOffset) * columns + column + columnOffset
            }
        })
    }
}

struct RemotePage: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var controls: [RemoteControl]
    var gridColumns = 2
    var gridRows = 8
    var layout: RemotePageLayout? = nil
    var openBuildsController: RemoteOpenBuildsController? = nil
    var moduleID: String? = nil
    var modulePageID: String? = nil
}

extension RemotePage {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        controls = try container.decode([RemoteControl].self, forKey: .controls)
        gridColumns = try container.decodeIfPresent(Int.self, forKey: .gridColumns) ?? 2
        gridRows = try container.decodeIfPresent(Int.self, forKey: .gridRows) ?? 8
        layout = try container.decodeIfPresent(RemotePageLayout.self, forKey: .layout)
        openBuildsController = try container.decodeIfPresent(
            RemoteOpenBuildsController.self, forKey: .openBuildsController
        )
        moduleID = try container.decodeIfPresent(String.self, forKey: .moduleID)
        modulePageID = try container.decodeIfPresent(String.self, forKey: .modulePageID)
        if layout == .openBuildsController && !container.contains(.gridColumns) {
            upgradeLegacyOpenBuildsGrid()
        }
    }

    private mutating func upgradeLegacyOpenBuildsGrid() {
        gridColumns = 9
        gridRows = 14
        let slots = [
            "XNegativeYPositive": 18, "YPositive": 20, "XPositiveYPositive": 22,
            "XNegative": 36, "XPositive": 40,
            "XNegativeYNegative": 54, "YNegative": 56, "XPositiveYNegative": 58,
        ]
        for index in controls.indices {
            if controls[index].textBox?.source == .openBuildsPosition {
                let axis = controls[index].textBox?.sourceText.split(separator: "|").last?.lowercased()
                controls[index].layoutSlot = ["x": 0, "y": 3, "z": 6][axis ?? "x"] ?? 0
                controls[index].gridWidth = 3
                controls[index].gridHeight = 2
            } else {
                let direction = controls[index].action.text
                    .replacingOccurrences(of: "continuousJog", with: "")
                    .replacingOccurrences(of: "jog", with: "")
                guard let slot = slots[direction] else { continue }
                controls[index].layoutSlot = slot
                controls[index].gridWidth = 2
                controls[index].gridHeight = 2
            }
        }
    }
}

extension RemotePage {
    static func netHomeThermostat(
        unit: String,
        computerID: String?,
        setpoint: Int = 22,
        setpointTenths: Int? = nil,
        fanSpeed: Int = 40,
        autoAction: RemoteAction? = nil
    ) -> Self {
        let color = "197278"
        let setpointID = UUID()
        let fanID = UUID()
        let automatic = autoAction ?? RemoteAction(
            type: .netHomeAuto,
            host: unit,
            text: "cool",
            value: setpoint,
            computerID: computerID,
            deadbandTenths: 10,
            humidityThreshold: 65,
            minimumCycleMinutes: 10
        )
        return Self(name: unit, controls: [
            RemoteControl(
                title: "Power",
                symbol: "power",
                tintHex: color,
                kind: .button,
                isToggle: true,
                buttonHeight: 2,
                action: .init(type: .netHomePower, host: unit, text: "toggle", computerID: computerID),
                layoutSlot: 0
            ),
            RemoteControl(
                title: "Auto",
                symbol: "humidity.fill",
                tintHex: "D1495B",
                kind: .button,
                isToggle: true,
                buttonHeight: 2,
                action: automatic,
                layoutSlot: 1
            ),
            RemoteControl(
                id: setpointID,
                title: "Setpoint",
                symbol: "thermometer.medium",
                tintHex: color,
                kind: .textBox,
                action: .init(
                    type: .netHomeTemperature,
                    host: unit,
                    value: setpoint,
                    valueTenths: setpointTenths ?? setpoint * 10,
                    computerID: computerID
                ),
                layoutSlot: 4,
                textBox: RemoteTextBox(
                    source: .controlValue,
                    sourceText: "",
                    referencedControlID: setpointID,
                    placeholder: "--",
                    gridWidth: 2,
                    gridHeight: 1,
                    textSize: .extraLarge,
                    horizontalAlignment: .center,
                    verticalAlignment: .center
                )
            ),
            temperatureStepControl("Down", symbol: "minus", step: -1, unit: unit, computerID: computerID, slot: 6),
            temperatureStepControl("Up", symbol: "plus", step: 1, unit: unit, computerID: computerID, slot: 7),
            RemoteControl(
                id: fanID,
                title: "Fan Speed",
                symbol: "fan.fill",
                tintHex: color,
                kind: .slider,
                action: .init(type: .netHomeFan, host: unit, value: fanSpeed, computerID: computerID),
                layoutSlot: 8
            ),
            RemoteControl(
                title: "Fan",
                symbol: "fan.fill",
                tintHex: color,
                kind: .textBox,
                action: .init(type: .netHomeFan, host: unit, value: fanSpeed, computerID: computerID),
                layoutSlot: 9,
                textBox: RemoteTextBox(
                    source: .controlValue,
                    sourceText: "",
                    referencedControlID: fanID,
                    placeholder: "--",
                    gridWidth: 1,
                    gridHeight: 1,
                    textSize: .large,
                    horizontalAlignment: .center,
                    verticalAlignment: .center
                )
            ),
            modeControl("Cool", symbol: "snowflake", mode: "cool", unit: unit, computerID: computerID, slot: 10),
            modeControl("Heat", symbol: "sun.max.fill", mode: "heat", unit: unit, computerID: computerID, slot: 11),
            modeControl("Dry", symbol: "drop.fill", mode: "dry", unit: unit, computerID: computerID, slot: 12),
            modeControl("Fan Only", symbol: "wind", mode: "fan", unit: unit, computerID: computerID, slot: 13),
        ])
    }

    func upgradingGeneratedThermostat() -> Self {
          guard (controls.count == 8 || controls.count == 11),
              let setpoint = controls.first(where: { $0.action.type == .netHomeTemperature }),
              let automatic = controls.first(where: { $0.action.type == .netHomeAuto }),
              let fan = controls.first(where: { $0.action.type == .netHomeFan && $0.kind == .slider }),
              controls.contains(where: { $0.action.type == .netHomePower }),
              controls.filter({ $0.action.type == .netHomeMode }).count == 4 else { return self }
        var upgraded = Self.netHomeThermostat(
            unit: setpoint.action.host,
            computerID: setpoint.action.computerID,
            setpoint: setpoint.action.value,
            setpointTenths: setpoint.action.valueTenths,
            fanSpeed: fan.action.value,
            autoAction: automatic.action
        )
        upgraded.id = id
        upgraded.name = name
        return upgraded
    }

    private static func temperatureStepControl(
        _ title: String,
        symbol: String,
        step: Int,
        unit: String,
        computerID: String?,
        slot: Int
    ) -> RemoteControl {
        RemoteControl(
            title: title,
            symbol: symbol,
            tintHex: "197278",
            kind: .button,
            buttonHeight: 1,
            action: .init(type: .netHomeTemperatureStep, host: unit, value: step, computerID: computerID),
            layoutSlot: slot
        )
    }

    private static func modeControl(
        _ title: String,
        symbol: String,
        mode: String,
        unit: String,
        computerID: String?,
        slot: Int
    ) -> RemoteControl {
        RemoteControl(
            title: title,
            symbol: symbol,
            tintHex: "197278",
            kind: .button,
            buttonHeight: 1,
            action: .init(type: .netHomeMode, host: unit, text: mode, computerID: computerID),
            layoutSlot: slot
        )
    }
}

struct RemoteProfile: Codable, Equatable, Sendable {
    static let currentVersion = 6

    var version = currentVersion
    var wifiSSID = ""
    var wifiPassword = ""
    var macHost = ""
    var macPort = 43_821
    var macToken = ""
    var computers: [RemoteComputer] = []
    var screensaverDelaySeconds = 30
    var temperatureUnit: RemoteTemperatureUnit = .celsius
    var timeZoneOffsetMinutes = TimeZone.current.secondsFromGMT() / 60
    var pages: [RemotePage]

    init(pages: [RemotePage]) {
        self.pages = pages
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard (1...Self.currentVersion).contains(decodedVersion) else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported remote profile version \(decodedVersion)."
            )
        }
        version = Self.currentVersion
        wifiSSID = try container.decodeIfPresent(String.self, forKey: .wifiSSID) ?? ""
        wifiPassword = try container.decodeIfPresent(String.self, forKey: .wifiPassword) ?? ""
        macHost = try container.decodeIfPresent(String.self, forKey: .macHost) ?? ""
        macPort = try container.decodeIfPresent(Int.self, forKey: .macPort) ?? 43_821
        macToken = try container.decodeIfPresent(String.self, forKey: .macToken) ?? ""
        computers = try container.decodeIfPresent([RemoteComputer].self, forKey: .computers) ?? []
        screensaverDelaySeconds = try container.decodeIfPresent(Int.self, forKey: .screensaverDelaySeconds) ?? 30
        temperatureUnit = try container.decodeIfPresent(RemoteTemperatureUnit.self, forKey: .temperatureUnit) ?? .celsius
        timeZoneOffsetMinutes = try container.decodeIfPresent(Int.self, forKey: .timeZoneOffsetMinutes)
            ?? TimeZone.current.secondsFromGMT() / 60
        pages = try container.decode([RemotePage].self, forKey: .pages)
        if decodedVersion < 6 {
            pages = pages.map { $0.upgradingGeneratedThermostat() }
        }
    }

    static let starter = RemoteProfile(pages: [
        RemotePage(name: "Main", controls: [
            RemoteControl(title: "Previous", symbol: "backward.fill", kind: .button, action: .init(type: .macMedia, text: "previous")),
            RemoteControl(title: "Play / Pause", symbol: "playpause.fill", kind: .button, action: .init(type: .macMedia, text: "playPause")),
            RemoteControl(title: "Next", symbol: "forward.fill", kind: .button, action: .init(type: .macMedia, text: "next")),
            RemoteControl(title: "Lights", symbol: "lightbulb.fill", kind: .button, action: .init(type: .wledPower, text: "toggle")),
        ]),
    ])

    var devicePayload: Data {
        get throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let encoded = try encoder.encode(self)
            guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
                return encoded
            }
            let components = Calendar.current.dateComponents(in: .current, from: Date())
            object["deviceClock"] = [
                "year": components.year ?? 0,
                "month": components.month ?? 0,
                "day": components.day ?? 0,
                "weekday": max((components.weekday ?? 1) - 1, 0),
                "hour": components.hour ?? 0,
                "minute": components.minute ?? 0,
                "second": components.second ?? 0,
            ]
            return try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        }
    }
}

struct RemoteIcon: Identifiable, Sendable {
    let id: String
    let title: String

    static let all: [Self] = [
        .init(id: "circle.fill", title: "Circle"),
        .init(id: "play.fill", title: "Play"),
        .init(id: "pause.fill", title: "Pause"),
        .init(id: "playpause.fill", title: "Play / Pause"),
        .init(id: "stop.fill", title: "Stop"),
        .init(id: "backward.fill", title: "Previous"),
        .init(id: "forward.fill", title: "Next"),
        .init(id: "speaker.fill", title: "Volume"),
        .init(id: "speaker.wave.2.fill", title: "Volume Up"),
        .init(id: "speaker.slash.fill", title: "Mute"),
        .init(id: "power", title: "Power"),
        .init(id: "lightbulb.fill", title: "Light"),
        .init(id: "sun.max.fill", title: "Brightness"),
        .init(id: "snowflake", title: "Cooling"),
        .init(id: "drop.fill", title: "Dry"),
        .init(id: "humidity.fill", title: "Humidity"),
        .init(id: "thermometer.medium", title: "Temperature"),
        .init(id: "fan.fill", title: "Fan"),
        .init(id: "wind", title: "Wind"),
        .init(id: "moon.fill", title: "Moon"),
        .init(id: "sparkles", title: "Effect"),
        .init(id: "house.fill", title: "Home"),
        .init(id: "gearshape.fill", title: "Settings"),
        .init(id: "arrow.up", title: "Up"),
        .init(id: "arrow.down", title: "Down"),
        .init(id: "arrow.left", title: "Left"),
        .init(id: "arrow.right", title: "Right"),
        .init(id: "arrow.up.left", title: "Up Left"),
        .init(id: "arrow.up.right", title: "Up Right"),
        .init(id: "arrow.down.left", title: "Down Left"),
        .init(id: "arrow.down.right", title: "Down Right"),
        .init(id: "plus", title: "Plus"),
        .init(id: "minus", title: "Minus"),
        .init(id: "checkmark", title: "Confirm"),
        .init(id: "xmark", title: "Close"),
        .init(id: "star.fill", title: "Favorite"),
        .init(id: "heart.fill", title: "Heart"),
        .init(id: "bolt.fill", title: "Energy"),
        .init(id: "lock.fill", title: "Lock"),
        .init(id: "wifi", title: "Wi-Fi"),
        .init(id: "slider.horizontal.3", title: "Sliders"),
        .init(id: "music.note", title: "Music"),
        .init(id: "display", title: "Display"),
    ]
}