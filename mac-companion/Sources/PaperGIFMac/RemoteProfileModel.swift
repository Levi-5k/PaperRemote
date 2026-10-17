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

enum RemoteButtonBackground: String, Codable, CaseIterable, Identifiable, Sendable {
    case outline
    case filled
    case shaded
    case borderless

    var id: Self { self }
}

enum RemoteButtonTextureKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case pattern
    case image

    var id: Self { self }
}

enum RemoteButtonPattern: String, Codable, CaseIterable, Identifiable, Sendable {
    case hexagons, triangles, grid, dots, diagonal, checker, waves, rings, spiral, truchet

    var id: Self { self }
}

enum RemoteButtonImageMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case threshold, monochrome, halftone, combined

    var id: Self { self }
}

/// A pattern or converted image drawn behind idle buttons; images are stored on the device by ID.
struct RemoteButtonTexture: Codable, Equatable, Sendable {
    var kind: RemoteButtonTextureKind = .none
    var pattern: RemoteButtonPattern = .hexagons
    var scale = 16
    var lineWidth = 1
    var imageID: UUID? = nil
    var mode: RemoteButtonImageMode = .monochrome
    var threshold = 128
    var levels = 16
    var dotSpacing = 8
    var angle = 45
    var dotGain = 0
    var fade = 50

    init() {}

    private enum CodingKeys: String, CodingKey {
        case kind, pattern, scale, lineWidth, imageID, mode, threshold, levels, dotSpacing, angle, dotGain, fade
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func integer(_ key: CodingKeys, _ fallback: Int, _ range: ClosedRange<Int>) -> Int {
            min(max((try? container.decodeIfPresent(Int.self, forKey: key)) ?? fallback, range.lowerBound), range.upperBound)
        }
        kind = (try? container.decodeIfPresent(RemoteButtonTextureKind.self, forKey: .kind)) ?? .none
        pattern = (try? container.decodeIfPresent(RemoteButtonPattern.self, forKey: .pattern)) ?? .hexagons
        scale = integer(.scale, 16, 6...64)
        lineWidth = integer(.lineWidth, 1, 1...8)
        imageID = try? container.decodeIfPresent(UUID.self, forKey: .imageID)
        mode = (try? container.decodeIfPresent(RemoteButtonImageMode.self, forKey: .mode)) ?? .monochrome
        threshold = integer(.threshold, 128, 32...224)
        levels = integer(.levels, 16, 0...16)
        dotSpacing = integer(.dotSpacing, 8, 3...24)
        angle = integer(.angle, 45, 0...90)
        dotGain = integer(.dotGain, 0, -50...50)
        fade = integer(.fade, 50, 0...90)
    }
}

enum RemoteJogMode: String, Codable, Sendable {
    case incremental
    case continuous
}

enum RemoteOpenBuildsUnits: String, Codable, Sendable {
    case millimeters = "mm"
    case inches = "in"
}

struct RemoteOpenBuildsController: Codable, Equatable, Sendable {
    var host = "127.0.0.1"
    var jogSpeed = 1_000
    var jogMode: RemoteJogMode = .incremental
    var units: RemoteOpenBuildsUnits = .millimeters
    var jogDistanceThousandths = 1_000
    var settingsSlot: Int?

    var jogDistanceTenths: Int {
        max(1, (jogDistanceThousandths + 50) / 100)
    }

    init(
        host: String = "127.0.0.1",
        jogSpeed: Int = 1_000,
        jogMode: RemoteJogMode = .incremental,
        units: RemoteOpenBuildsUnits = .millimeters,
        jogDistanceThousandths: Int = 1_000
    ) {
        self.host = host
        self.jogSpeed = jogSpeed
        self.jogMode = jogMode
        self.units = units
        self.jogDistanceThousandths = jogDistanceThousandths
    }

    private enum CodingKeys: String, CodingKey {
        case host, jogSpeed, jogMode, units, jogDistanceTenths, jogDistanceThousandths, settingsSlot
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? "127.0.0.1"
        jogSpeed = try container.decodeIfPresent(Int.self, forKey: .jogSpeed) ?? 1_000
        jogMode = try container.decodeIfPresent(RemoteJogMode.self, forKey: .jogMode) ?? .incremental
        units = try container.decodeIfPresent(RemoteOpenBuildsUnits.self, forKey: .units) ?? .millimeters
        jogDistanceThousandths = try container.decodeIfPresent(
            Int.self, forKey: .jogDistanceThousandths
        ) ?? (try container.decodeIfPresent(Int.self, forKey: .jogDistanceTenths) ?? 10) * 100
        settingsSlot = try container.decodeIfPresent(Int.self, forKey: .settingsSlot)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(host, forKey: .host)
        try container.encodeIfPresent(settingsSlot, forKey: .settingsSlot)
        try container.encode(jogSpeed, forKey: .jogSpeed)
        try container.encode(jogMode, forKey: .jogMode)
        try container.encode(units, forKey: .units)
        try container.encode(jogDistanceTenths, forKey: .jogDistanceTenths)
        try container.encode(jogDistanceThousandths, forKey: .jogDistanceThousandths)
    }
}

enum RemoteTextSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case staticText
    case dateTime
    // Raw values are the legacy wire names; see protocol/README.md.
    case computerScript = "macScript"
    case appleShortcut = "macShortcut"
    case controlValue
    case nowPlaying
    case openBuildsPosition

    var id: Self { self }

    var runsOnComputer: Bool {
        [.computerScript, .appleShortcut, .nowPlaying, .openBuildsPosition].contains(self)
    }
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
    case iPhoneMedia
    case iPhoneHomePower
    // Raw values are the legacy wire names; see protocol/README.md.
    case computerMedia = "macMedia"
    case computerKey = "macKey"
    case computerOpen = "macOpen"
    case appleShortcut = "macShortcut"
    case computerScript = "macScript"
    case openBuilds
    case wledPower
    case wledPreset
    case wledBrightness
    case eWeLinkPower
    case localHTTP
    case netHomePower
    case netHomeTemperature
    case netHomeTemperatureStep
    case netHomeMode
    case netHomeFan
    case netHomeAuto
    case module
    case page

    var id: Self { self }

    var title: String {
        switch self {
        case .iPhoneMedia: "iPhone media"
        case .iPhoneHomePower: "Apple Home power"
        case .computerMedia: "Media"
        case .computerKey: "Keyboard shortcut"
        case .computerOpen: "Open app or URL"
        case .appleShortcut: "Apple Shortcut (Mac only)"
        case .computerScript: "Approved script"
        case .openBuilds: "OpenBuilds CONTROL"
        case .wledPower: "WLED power"
        case .wledPreset: "WLED preset"
        case .wledBrightness: "WLED brightness"
        case .eWeLinkPower: "eWeLink power"
        case .localHTTP: "Local HTTP request"
        case .netHomePower: "NetHome power"
        case .netHomeTemperature: "NetHome temperature"
        case .netHomeTemperatureStep: "NetHome temperature step"
        case .netHomeMode: "NetHome mode"
        case .netHomeFan: "NetHome fan"
        case .netHomeAuto: "Sensor auto mode"
        case .module: "Module action"
        case .page: "Open page"
        }
    }

    var systemImage: String {
        switch self {
        case .iPhoneMedia: "iphone"
        case .iPhoneHomePower: "homekit"
        case .computerMedia: "playpause.fill"
        case .computerKey: "keyboard"
        case .computerOpen: "arrow.up.forward.app"
        case .appleShortcut: "command"
        case .computerScript: "terminal"
        case .openBuilds: "move.3d"
        case .wledPower: "power"
        case .wledPreset: "sparkles"
        case .wledBrightness: "sun.max.fill"
        case .eWeLinkPower: "powerplug.fill"
        case .localHTTP: "network"
        case .netHomePower: "power"
        case .netHomeTemperature: "thermometer.medium"
        case .netHomeTemperatureStep: "plusminus"
        case .netHomeMode: "arrow.triangle.2.circlepath"
        case .netHomeFan: "fan.fill"
        case .netHomeAuto: "humidity.fill"
        case .module: "shippingbox.fill"
        case .page: "rectangle.on.rectangle"
        }
    }

    var runsOnComputer: Bool {
        switch self {
        case .computerMedia, .computerKey, .computerOpen, .appleShortcut, .computerScript,
             .openBuilds, .module, .netHomePower, .netHomeTemperature, .netHomeTemperatureStep,
             .netHomeMode, .netHomeFan, .netHomeAuto:
            true
        case .iPhoneMedia, .iPhoneHomePower, .wledPower, .wledPreset, .wledBrightness,
             .eWeLinkPower, .localHTTP, .page:
            false
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
    var httpMethod: String?
    var httpBody: String?
    var deviceID: String?
    var deviceKey: String?
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

extension RemoteControl {
    /// Points every computer-routed part of the control at `computerID`.
    func targetingComputer(_ computerID: String, replacingExisting: Bool = true) -> RemoteControl {
        var targeted = self
        if action.type.runsOnComputer, replacingExisting || action.computerID == nil {
            targeted.action.computerID = computerID
        }
        if textBox?.source.runsOnComputer == true, let textComputerID = UUID(uuidString: computerID),
           replacingExisting || textBox?.computerID == nil {
            targeted.textBox?.computerID = textComputerID
        }
        if textBox?.tapAction?.type.runsOnComputer == true,
           replacingExisting || textBox?.tapAction?.computerID == nil {
            targeted.textBox?.tapAction?.computerID = computerID
        }
        return targeted
    }

    mutating func keepComputerTargets(of previous: RemoteControl) {
        if previous.action.type == action.type, let computerID = previous.action.computerID {
            action.computerID = computerID
        }
        if textBox != nil, let computerID = previous.textBox?.computerID {
            textBox?.computerID = computerID
        }
        if textBox?.tapAction != nil, let computerID = previous.textBox?.tapAction?.computerID {
            textBox?.tapAction?.computerID = computerID
        }
    }

    /// Replaces references to `oldIDs` (in any letter case) in the action, text box and tap action.
    mutating func retargetComputer(from oldIDs: Set<String>, to newID: UUID?) {
        let old = Set(oldIDs.map { $0.uppercased() })
        func matches(_ id: String?) -> Bool { id.map { old.contains($0.uppercased()) } ?? false }
        if matches(action.computerID) {
            action.computerID = newID?.uuidString
        }
        if matches(textBox?.computerID?.uuidString) {
            textBox?.computerID = newID
        }
        if matches(textBox?.tapAction?.computerID) {
            textBox?.tapAction?.computerID = newID?.uuidString
        }
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
    var sliderOutlineInsetPixels: Int? = nil
    /// nil inherits `RemoteProfile.buttonBackground`.
    var buttonBackground: RemoteButtonBackground? = nil
    /// nil inherits `RemoteProfile.buttonTexture`.
    var buttonTexture: RemoteButtonTexture? = nil
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

    static func translatedSlot(
        from sourceSlot: Int,
        columnOffset: Int,
        rowOffset: Int,
        columns: Int,
        rows: Int
    ) -> Int? {
        let column = sourceSlot % columns + columnOffset
        let row = sourceSlot / columns + rowOffset
        guard (0..<columns).contains(column), (0..<rows).contains(row) else { return nil }
        return row * columns + column
    }

    // The settings panel content is 152x430 pt; it occupies whole cells, matching the firmware.
    static func openBuildsSettingsSpan(columns: Int, rows: Int) -> RemoteGridSpan {
        RemoteGridSpan(
            width: min(columns, (164 * columns + 503) / 504),
            height: min(rows, (442 * rows + 711) / 712)
        )
    }

    static func openBuildsSettingsPlacement(slot: Int?, columns: Int, rows: Int) -> RemoteGridPlacement {
        let span = openBuildsSettingsSpan(columns: columns, rows: rows)
        if let slot, slot >= 0,
           slot % columns + span.width <= columns,
           slot / columns + span.height <= rows {
            return RemoteGridPlacement(slot: slot, span: span)
        }
        let row = min((150 * rows + 711) / 712, rows - span.height)
        return RemoteGridPlacement(slot: row * columns + columns - span.width, span: span)
    }

    static func openBuildsSettingsPlacement(for page: RemotePage) -> RemoteGridPlacement? {
        guard page.layout == .openBuildsController else { return nil }
        return openBuildsSettingsPlacement(
            slot: page.openBuildsController?.settingsSlot,
            columns: page.gridColumns,
            rows: page.gridRows
        )
    }

    static func reservedCells(for page: RemotePage) -> Set<Int> {
        openBuildsSettingsPlacement(for: page).map { cells(for: $0, columns: page.gridColumns) } ?? []
    }

    /// New settings-panel slot (clamped onto the page), or nil if it would cover a control.
    static func movedOpenBuildsSettings(
        on page: RemotePage,
        controls: [RemoteControl],
        to requestedSlot: Int
    ) -> Int? {
        guard let current = openBuildsSettingsPlacement(for: page) else { return nil }
        let columns = page.gridColumns
        let rows = page.gridRows
        let span = current.span
        let column = min(max(requestedSlot % columns, 0), columns - span.width)
        let row = min(max(requestedSlot / columns, 0), rows - span.height)
        let moved = RemoteGridPlacement(slot: row * columns + column, span: span)
        guard moved.slot != current.slot else { return nil }
        let controlCells = placements(
            for: controls, columns: columns, rows: rows, reserved: reservedCells(for: page)
        ).compactMap { $0 }.reduce(into: Set<Int>()) { $0.formUnion(cells(for: $1, columns: columns)) }
        return cells(for: moved, columns: columns).isDisjoint(with: controlCells) ? moved.slot : nil
    }

    static func placements(
        for controls: [RemoteControl],
        columns: Int,
        rows: Int,
        reserved: Set<Int> = []
    ) -> [RemoteGridPlacement?] {
        var occupied = reserved
        var result = [RemoteGridPlacement?](repeating: nil, count: controls.count)

        func place(_ index: Int, at slot: Int) {
            guard let candidate = placement(for: controls[index], at: slot, columns: columns, rows: rows) else { return }
            let candidateCells = cells(for: candidate, columns: columns)
            guard occupied.isDisjoint(with: candidateCells) else { return }
            occupied.formUnion(candidateCells)
            result[index] = candidate
        }

        for index in controls.indices {
            if let slot = controls[index].layoutSlot { place(index, at: slot) }
        }
        for index in controls.indices where result[index] == nil {
            for slot in 0..<(columns * rows) where result[index] == nil {
                place(index, at: slot)
            }
        }
        return result
    }

    /// Final anchor slot for every control, or nil if the drop isn't possible.
    /// Controls under the drop move into the space it left, or else the nearest free spot.
    static func rearranged(
        _ controls: [RemoteControl],
        moving sourceIndex: Int,
        to requestedSlot: Int,
        columns: Int,
        rows: Int,
        reserved: Set<Int> = []
    ) -> [Int?]? {
        let current = placements(for: controls, columns: columns, rows: rows, reserved: reserved)
        guard current.indices.contains(sourceIndex),
              let source = current[sourceIndex],
              let requested = placement(
                  for: controls[sourceIndex], at: requestedSlot, columns: columns, rows: rows
              ),
              requested.slot != source.slot else { return nil }

        let requestedCells = cells(for: requested, columns: columns)
        guard reserved.isDisjoint(with: requestedCells) else { return nil }
        let occupants = current.indices.filter { index in
            index != sourceIndex && current[index].map {
                !requestedCells.isDisjoint(with: cells(for: $0, columns: columns))
            } == true
        }
        var slots = current.map { $0?.slot }
        slots[sourceIndex] = requested.slot
        var occupied = reserved.union(requestedCells)
        for index in current.indices where index != sourceIndex && !occupants.contains(index) {
            if let pinned = current[index] { occupied.formUnion(cells(for: pinned, columns: columns)) }
        }

        let columnShift = source.slot % columns - requested.slot % columns
        let rowShift = source.slot / columns - requested.slot / columns
        for index in occupants {
            guard let original = current[index] else { continue }
            func distance(_ slot: Int) -> Int {
                let dx = slot % columns - original.slot % columns
                let dy = slot / columns - original.slot / columns
                return dx * dx + dy * dy
            }
            let shifted = translatedSlot(
                from: original.slot, columnOffset: columnShift, rowOffset: rowShift,
                columns: columns, rows: rows
            )
            let nearest = (0..<(columns * rows)).sorted { (distance($0), $0) < (distance($1), $1) }
            let fit = ([shifted].compactMap { $0 } + nearest).lazy.compactMap { candidate -> RemoteGridPlacement? in
                guard let moved = placement(for: controls[index], at: candidate, columns: columns, rows: rows),
                      moved.slot == candidate,
                      occupied.isDisjoint(with: cells(for: moved, columns: columns)) else { return nil }
                return moved
            }.first
            guard let fit else { return nil }
            slots[index] = fit.slot
            occupied.formUnion(cells(for: fit, columns: columns))
        }
        return slots
    }

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
                let components = controls[index].textBox?.sourceText.split(separator: "|") ?? []
                let axis = components.indices.contains(1) ? components[1].lowercased() : "x"
                controls[index].layoutSlot = ["x": 0, "y": 3, "z": 6][axis] ?? 0
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
    static let maximumControlsPerPage = 24

    var version = currentVersion
    var updatedAtMilliseconds: Int64 = 0
    var wifiSSID = ""
    var wifiPassword = ""
    var macHost = ""
    var macPort = 43_821
    var macToken = ""
    var computers: [RemoteComputer] = []
    var screensaverDelaySeconds = 30
    var buttonQualityRefreshInterval = 10
    /// Nominal device points; preview renderers convert this using their device scale.
    var maxButtonTextSize = 24 {
        didSet {
            let clamped = min(24, max(9, maxButtonTextSize))
            if maxButtonTextSize != clamped { maxButtonTextSize = clamped }
        }
    }
    var elementRefreshDelayMilliseconds = 20
    var buttonBackground: RemoteButtonBackground = .outline
    var buttonTexture = RemoteButtonTexture()
    var temperatureUnit: RemoteTemperatureUnit = .celsius
    var timeZoneOffsetMinutes = TimeZone.current.secondsFromGMT() / 60
    var pages: [RemotePage]

    init(maxButtonTextSize: Int = 24, pages: [RemotePage]) {
        self.maxButtonTextSize = min(24, max(9, maxButtonTextSize))
        self.pages = pages
    }

    func buttonBackground(for control: RemoteControl) -> RemoteButtonBackground {
        control.buttonBackground ?? buttonBackground
    }

    func buttonTexture(for control: RemoteControl) -> RemoteButtonTexture {
        control.buttonTexture ?? buttonTexture
    }

    private enum CodingKeys: String, CodingKey {
        case version, updatedAtMilliseconds, wifiSSID, wifiPassword, macHost, macPort, macToken
        case computers, screensaverDelaySeconds, buttonQualityRefreshInterval, maxButtonTextSize
        case elementRefreshDelayMilliseconds, buttonBackground, buttonTexture, temperatureUnit
        case timeZoneOffsetMinutes, pages
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
        updatedAtMilliseconds = try container.decodeIfPresent(
            Int64.self, forKey: .updatedAtMilliseconds
        ) ?? 0
        wifiSSID = try container.decodeIfPresent(String.self, forKey: .wifiSSID) ?? ""
        wifiPassword = try container.decodeIfPresent(String.self, forKey: .wifiPassword) ?? ""
        macHost = try container.decodeIfPresent(String.self, forKey: .macHost) ?? ""
        macPort = try container.decodeIfPresent(Int.self, forKey: .macPort) ?? 43_821
        macToken = try container.decodeIfPresent(String.self, forKey: .macToken) ?? ""
        computers = try container.decodeIfPresent([RemoteComputer].self, forKey: .computers) ?? []
        screensaverDelaySeconds = try container.decodeIfPresent(Int.self, forKey: .screensaverDelaySeconds) ?? 30
        buttonQualityRefreshInterval = try container.decodeIfPresent(
            Int.self, forKey: .buttonQualityRefreshInterval
        ) ?? 10
        maxButtonTextSize = min(24, max(9, try container.decodeIfPresent(
            Int.self, forKey: .maxButtonTextSize
        ) ?? 24))
        elementRefreshDelayMilliseconds = try container.decodeIfPresent(
            Int.self, forKey: .elementRefreshDelayMilliseconds
        ) ?? 20
        buttonBackground = try container.decodeIfPresent(
            RemoteButtonBackground.self, forKey: .buttonBackground
        ) ?? .outline
        buttonTexture = try container.decodeIfPresent(
            RemoteButtonTexture.self, forKey: .buttonTexture
        ) ?? RemoteButtonTexture()
        temperatureUnit = try container.decodeIfPresent(RemoteTemperatureUnit.self, forKey: .temperatureUnit) ?? .celsius
        timeZoneOffsetMinutes = try container.decodeIfPresent(Int.self, forKey: .timeZoneOffsetMinutes)
            ?? TimeZone.current.secondsFromGMT() / 60
        pages = try container.decode([RemotePage].self, forKey: .pages)
        if decodedVersion < 6 {
            pages = pages.map { $0.upgradingGeneratedThermostat() }
        }
    }

    mutating func markUpdated(now: Date = Date()) {
        let currentMilliseconds = Int64(now.timeIntervalSince1970 * 1_000)
        let nextRevision = updatedAtMilliseconds == .max
            ? Int64.max : updatedAtMilliseconds + 1
        updatedAtMilliseconds = max(nextRevision, currentMilliseconds)
    }

    static let starter = RemoteProfile(pages: [
        RemotePage(name: "Main", controls: [
            RemoteControl(title: "Previous", symbol: "backward.fill", kind: .button, action: .init(type: .computerMedia, text: "previous")),
            RemoteControl(title: "Play / Pause", symbol: "playpause.fill", kind: .button, action: .init(type: .computerMedia, text: "playPause")),
            RemoteControl(title: "Next", symbol: "forward.fill", kind: .button, action: .init(type: .computerMedia, text: "next")),
            RemoteControl(title: "Lights", symbol: "lightbulb.fill", kind: .button, action: .init(type: .wledPower, text: "toggle")),
        ]),
    ])

    /// Existing controls whose settings differ, or nil when anything else changed
    /// (pages, control order or membership, profile settings), which needs a full upload.
    static func changedControls(from old: RemoteProfile, to new: RemoteProfile) -> [ControlLocation]? {
        guard old.pages.count == new.pages.count else { return nil }
        var oldShape = old
        var newShape = new
        oldShape.updatedAtMilliseconds = 0
        newShape.updatedAtMilliseconds = 0
        var changes: [ControlLocation] = []
        for pageIndex in new.pages.indices {
            let oldControls = old.pages[pageIndex].controls
            let newControls = new.pages[pageIndex].controls
            guard oldControls.map(\.id) == newControls.map(\.id) else { return nil }
            for controlIndex in newControls.indices where oldControls[controlIndex] != newControls[controlIndex] {
                changes.append(ControlLocation(page: pageIndex, control: controlIndex))
            }
            oldShape.pages[pageIndex].controls = []
            newShape.pages[pageIndex].controls = []
        }
        return oldShape == newShape ? changes : nil
    }

    /// Body for the M5Paper's `POST /remote/controls`, encoded exactly like the full profile upload.
    func controlUpdatePayload(for changes: [ControlLocation]) throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: devicePayload) as? [String: Any],
              let pages = object["pages"] as? [[String: Any]] else {
            throw CocoaError(.coderInvalidValue)
        }
        let controls: [[String: Any]] = try changes.map { change in
            guard pages.indices.contains(change.page),
                  let pageControls = pages[change.page]["controls"] as? [[String: Any]],
                  pageControls.indices.contains(change.control) else {
                throw CocoaError(.coderInvalidValue)
            }
            return ["pageID": pages[change.page]["id"] ?? "", "control": pageControls[change.control]]
        }
        var body: [String: Any] = [
            "updatedAtMilliseconds": updatedAtMilliseconds,
            "controls": controls,
        ]
        body["buttonBackground"] = object["buttonBackground"]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
    }

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

struct ControlLocation: Equatable, Sendable {
    let page: Int
    let control: Int
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
        .init(id: "lock.open.fill", title: "Unlock"),
        .init(id: "powerplug.fill", title: "Plug"),
        .init(id: "scope", title: "Target"),
        .init(id: "move.3d", title: "Move"),
        .init(id: "wifi", title: "Wi-Fi"),
        .init(id: "slider.horizontal.3", title: "Sliders"),
        .init(id: "music.note", title: "Music"),
        .init(id: "display", title: "Display"),
    ]
}