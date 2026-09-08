import Foundation

enum PaperGIFTemperatureUnit: String, Codable, CaseIterable, Identifiable, Sendable {
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

enum PaperGIFRemoteControlKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case button
    case slider
    case textBox

    var id: Self { self }
}

enum PaperGIFRemoteTextSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case staticText
    case dateTime
    case macScript
    case macShortcut
    case controlValue
    case nowPlaying

    var id: Self { self }
}

enum PaperGIFRemoteTextSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case small
    case medium
    case large
    case extraLarge
    case autoFit

    var id: Self { self }
}

enum PaperGIFRemoteTextHorizontalAlignment: String, Codable, CaseIterable, Identifiable, Sendable {
    case leading
    case center
    case trailing

    var id: Self { self }
}

enum PaperGIFRemoteTextVerticalAlignment: String, Codable, CaseIterable, Identifiable, Sendable {
    case top
    case center
    case bottom

    var id: Self { self }
}

enum PaperGIFRemoteTextTapBehavior: String, Codable, CaseIterable, Identifiable, Sendable {
    case displayOnly
    case refresh
    case action

    var id: Self { self }
}

struct PaperGIFRemoteIcon: Identifiable, Sendable {
    let id: String
    let title: String

    static let all: [Self] = [
        .init(id: "circle.fill", title: "Circle"),
        .init(id: "play.fill", title: "Play"),
        .init(id: "pause.fill", title: "Pause"),
        .init(id: "playpause.fill", title: "Play/Pause"),
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

enum PaperGIFRemoteActionType: String, Codable, CaseIterable, Identifiable, Sendable {
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
        case .macKey: "Mac keyboard shortcut"
        case .macOpen: "Open app or URL"
        case .macShortcut: "Run Apple Shortcut"
        case .macScript: "Run script"
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
        case .page: "Open remote page"
        }
    }
}

struct PaperGIFRemoteAction: Codable, Equatable, Sendable {
    var type: PaperGIFRemoteActionType
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
    var schedules: [PaperGIFRemoteScheduleEntry]?

    static let playPause = PaperGIFRemoteAction(type: .macMedia, text: "playPause")
}

struct PaperGIFRemoteScheduleEntry: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var weekdays = Array(1...7)
    var hour = 8
    var minute = 0
    var text: String?
    var value: Int?
    var valueTenths: Int?
}

struct PaperGIFRemoteComputer: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var host: String
    var port = 43_821
    var token: String
}

struct PaperGIFRemoteTextBox: Codable, Equatable, Sendable {
    var source: PaperGIFRemoteTextSource = .staticText
    var sourceText = "Text"
    var referencedControlID: UUID?
    var computerID: UUID?
    var dateFormat = "%b %e, %H:%M"
    var placeholder = "Unavailable"
    var gridWidth = 2
    var gridHeight = 1
    var textSize: PaperGIFRemoteTextSize = .autoFit
    var horizontalAlignment: PaperGIFRemoteTextHorizontalAlignment = .leading
    var verticalAlignment: PaperGIFRemoteTextVerticalAlignment = .top
    var tapBehavior: PaperGIFRemoteTextTapBehavior = .displayOnly
    var tapAction: PaperGIFRemoteAction?
    var refreshIntervalSeconds: Int?
}

extension PaperGIFRemoteTextBox {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decodeIfPresent(PaperGIFRemoteTextSource.self, forKey: .source) ?? .staticText
        sourceText = try container.decodeIfPresent(String.self, forKey: .sourceText) ?? "Text"
        referencedControlID = try container.decodeIfPresent(UUID.self, forKey: .referencedControlID)
        computerID = try container.decodeIfPresent(UUID.self, forKey: .computerID)
        dateFormat = try container.decodeIfPresent(String.self, forKey: .dateFormat) ?? "%b %e, %H:%M"
        placeholder = try container.decodeIfPresent(String.self, forKey: .placeholder) ?? "Unavailable"
        gridWidth = try container.decodeIfPresent(Int.self, forKey: .gridWidth) ?? 2
        gridHeight = try container.decodeIfPresent(Int.self, forKey: .gridHeight) ?? 1
        textSize = try container.decodeIfPresent(PaperGIFRemoteTextSize.self, forKey: .textSize) ?? .autoFit
        horizontalAlignment = try container.decodeIfPresent(
            PaperGIFRemoteTextHorizontalAlignment.self,
            forKey: .horizontalAlignment
        ) ?? .leading
        verticalAlignment = try container.decodeIfPresent(
            PaperGIFRemoteTextVerticalAlignment.self,
            forKey: .verticalAlignment
        ) ?? .top
        tapBehavior = try container.decodeIfPresent(PaperGIFRemoteTextTapBehavior.self, forKey: .tapBehavior) ?? .displayOnly
        tapAction = try container.decodeIfPresent(PaperGIFRemoteAction.self, forKey: .tapAction)
        refreshIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .refreshIntervalSeconds)
    }
}

struct PaperGIFRemoteControl: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var title: String
    var symbol: String
    var iconBitmap: String? = nil
    var tintHex: String
    var kind: PaperGIFRemoteControlKind
    var isToggle: Bool? = nil
    var buttonHeight: Int? = nil
    var action: PaperGIFRemoteAction
    var layoutSlot: Int? = nil
    var textBox: PaperGIFRemoteTextBox? = nil

    static func button(
        title: String,
        symbol: String,
        tintHex: String = "202020",
        action: PaperGIFRemoteAction
    ) -> Self {
        Self(title: title, symbol: symbol, tintHex: tintHex, kind: .button, action: action)
    }

    var gridSpan: PaperGIFRemoteGridSpan {
        switch kind {
        case .button:
            PaperGIFRemoteGridSpan(width: 1, height: buttonGridHeight)
        case .slider:
            PaperGIFRemoteGridSpan(width: 1, height: 1)
        case .textBox:
            PaperGIFRemoteGridSpan(
                width: min(max(textBox?.gridWidth ?? 2, 1), 2),
                height: min(max(textBox?.gridHeight ?? 1, 1), 8)
            )
        }
    }

    var buttonGridHeight: Int {
        min(max(buttonHeight ?? 2, 1), 2)
    }
}

struct PaperGIFRemoteGridSpan: Equatable, Sendable {
    let width: Int
    let height: Int
}

struct PaperGIFRemoteGridPlacement: Equatable, Sendable {
    let slot: Int
    let span: PaperGIFRemoteGridSpan
}

enum PaperGIFRemoteGrid {
    static let columnCount = 2
    static let rowCount = 8

    static func placements(for controls: [PaperGIFRemoteControl]) -> [PaperGIFRemoteGridPlacement?] {
        var occupied: Set<Int> = []
        var result = Array<PaperGIFRemoteGridPlacement?>(repeating: nil, count: controls.count)

        for index in controls.indices {
            guard let slot = controls[index].layoutSlot,
                  let placement = placement(for: controls[index], at: slot),
                  occupied.isDisjoint(with: cells(for: placement)) else { continue }
            result[index] = placement
            occupied.formUnion(cells(for: placement))
        }

        for index in controls.indices where result[index] == nil {
            for slot in 0..<(columnCount * rowCount) {
                guard let placement = placement(for: controls[index], at: slot),
                      occupied.isDisjoint(with: cells(for: placement)) else { continue }
                result[index] = placement
                occupied.formUnion(cells(for: placement))
                break
            }
        }
        return result
    }

    static func placement(
        for control: PaperGIFRemoteControl,
        at requestedSlot: Int
    ) -> PaperGIFRemoteGridPlacement? {
        guard (0..<(columnCount * rowCount)).contains(requestedSlot) else { return nil }
        let span = control.gridSpan
        let row = requestedSlot / columnCount
        var column = requestedSlot % columnCount
        if span.width == columnCount {
            column = 0
        }
        guard column + span.width <= columnCount, row + span.height <= rowCount else { return nil }
        return PaperGIFRemoteGridPlacement(slot: row * columnCount + column, span: span)
    }

    static func cells(for placement: PaperGIFRemoteGridPlacement) -> Set<Int> {
        let row = placement.slot / columnCount
        let column = placement.slot % columnCount
        return Set((0..<placement.span.height).flatMap { rowOffset in
            (0..<placement.span.width).map { columnOffset in
                (row + rowOffset) * columnCount + column + columnOffset
            }
        })
    }
}

struct PaperGIFRemotePage: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var controls: [PaperGIFRemoteControl]
}

extension PaperGIFRemotePage {
    static func netHomeThermostat(
        unit: String,
        computerID: String?,
        setpoint: Int = 22,
        setpointTenths: Int? = nil,
        fanSpeed: Int = 40,
        autoAction: PaperGIFRemoteAction? = nil
    ) -> Self {
        let color = "197278"
        let setpointID = UUID()
        let fanID = UUID()
        let automatic = autoAction ?? PaperGIFRemoteAction(
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
            PaperGIFRemoteControl(
                title: "Power", symbol: "power", tintHex: color, kind: .button,
                isToggle: true, buttonHeight: 2,
                action: .init(type: .netHomePower, host: unit, text: "toggle", computerID: computerID),
                layoutSlot: 0
            ),
            PaperGIFRemoteControl(
                title: "Auto", symbol: "humidity.fill", tintHex: "D1495B", kind: .button,
                isToggle: true, buttonHeight: 2, action: automatic, layoutSlot: 1
            ),
            PaperGIFRemoteControl(
                id: setpointID,
                title: "Setpoint", symbol: "thermometer.medium", tintHex: color, kind: .textBox,
                action: .init(
                    type: .netHomeTemperature,
                    host: unit,
                    value: setpoint,
                    valueTenths: setpointTenths ?? setpoint * 10,
                    computerID: computerID
                ),
                layoutSlot: 4,
                textBox: PaperGIFRemoteTextBox(
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
            PaperGIFRemoteControl(
                id: fanID,
                title: "Fan Speed", symbol: "fan.fill", tintHex: color, kind: .slider,
                action: .init(type: .netHomeFan, host: unit, value: fanSpeed, computerID: computerID),
                layoutSlot: 8
            ),
            PaperGIFRemoteControl(
                title: "Fan", symbol: "fan.fill", tintHex: color, kind: .textBox,
                action: .init(type: .netHomeFan, host: unit, value: fanSpeed, computerID: computerID),
                layoutSlot: 9,
                textBox: PaperGIFRemoteTextBox(
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
    ) -> PaperGIFRemoteControl {
        PaperGIFRemoteControl(
            title: title, symbol: symbol, tintHex: "197278", kind: .button, buttonHeight: 1,
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
    ) -> PaperGIFRemoteControl {
        PaperGIFRemoteControl(
            title: title, symbol: symbol, tintHex: "197278", kind: .button, buttonHeight: 1,
            action: .init(type: .netHomeMode, host: unit, text: mode, computerID: computerID),
            layoutSlot: slot
        )
    }
}

struct PaperGIFRemoteProfile: Codable, Equatable, Sendable {
    static let currentVersion = 6

    var version = currentVersion
    var wifiSSID = ""
    var wifiPassword = ""
    var macHost = ""
    var macPort = 43821
    var macToken = ""
    var computers: [PaperGIFRemoteComputer]
    var screensaverDelaySeconds = 30
    var temperatureUnit: PaperGIFTemperatureUnit = .celsius
    var timeZoneOffsetMinutes = TimeZone.current.secondsFromGMT() / 60
    var pages: [PaperGIFRemotePage]

    init(
        version: Int = currentVersion,
        wifiSSID: String = "",
        wifiPassword: String = "",
        macHost: String = "",
        macPort: Int = 43_821,
        macToken: String = "",
        computers: [PaperGIFRemoteComputer] = [],
        screensaverDelaySeconds: Int = 30,
        timeZoneOffsetMinutes: Int = TimeZone.current.secondsFromGMT() / 60,
        pages: [PaperGIFRemotePage]
    ) {
        self.version = version
        self.wifiSSID = wifiSSID
        self.wifiPassword = wifiPassword
        self.macHost = macHost
        self.macPort = macPort
        self.macToken = macToken
        self.computers = computers
        self.screensaverDelaySeconds = screensaverDelaySeconds
        self.timeZoneOffsetMinutes = timeZoneOffsetMinutes
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
        computers = try container.decodeIfPresent([PaperGIFRemoteComputer].self, forKey: .computers) ?? []
        screensaverDelaySeconds = try container.decodeIfPresent(Int.self, forKey: .screensaverDelaySeconds) ?? 30
        temperatureUnit = try container.decodeIfPresent(PaperGIFTemperatureUnit.self, forKey: .temperatureUnit) ?? .celsius
        timeZoneOffsetMinutes = try container.decodeIfPresent(Int.self, forKey: .timeZoneOffsetMinutes)
            ?? TimeZone.current.secondsFromGMT() / 60
        pages = try container.decode([PaperGIFRemotePage].self, forKey: .pages)
        if decodedVersion < 6 {
            pages = pages.map { $0.upgradingGeneratedThermostat() }
        }

        if computers.isEmpty, !macHost.isEmpty {
            computers = [PaperGIFRemoteComputer(
                name: "Default Computer",
                host: macHost,
                port: macPort,
                token: macToken
            )]
        }
    }

    static let starter = PaperGIFRemoteProfile(pages: [
        PaperGIFRemotePage(name: "Main", controls: [
            .button(title: "Previous", symbol: "backward.fill", action: .init(type: .macMedia, text: "previous")),
            .button(title: "Play", symbol: "playpause.fill", action: .playPause),
            .button(title: "Next", symbol: "forward.fill", action: .init(type: .macMedia, text: "next")),
            .button(title: "WLED", symbol: "lightbulb.fill", tintHex: "F2C14E", action: .init(type: .wledPower, text: "toggle")),
        ])
    ])

    var devicePayload: Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let encoded = try? encoder.encode(self),
              var object = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            return nil
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
        return try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }
}