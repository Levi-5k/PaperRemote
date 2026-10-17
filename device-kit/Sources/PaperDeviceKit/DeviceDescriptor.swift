import Foundation

public enum DeviceContractError: LocalizedError {
    case invalid(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let reason): return "Invalid device data: \(reason)"
        case .unsupported(let reason): return "Unsupported device: \(reason)"
        }
    }
}

public struct DeviceRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    func validate(inWidth width: Double, height: Double) throws {
        guard [x, y, self.width, self.height].allSatisfy(\.isFinite),
              x >= 0, y >= 0, self.width > 0, self.height > 0,
              x + self.width <= width, y + self.height <= height else {
            throw DeviceContractError.invalid("layout rectangle is outside board bounds")
        }
    }
}

public struct DeviceInputPlacement: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public var rect: DeviceRect { DeviceRect(x: x, y: y, width: width, height: height) }

    public init(id: String, x: Double, y: Double, width: Double, height: Double) {
        self.id = id
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct DeviceLayout: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double
    public var screen: DeviceRect?
    public var inputs: [DeviceInputPlacement]

    public init(width: Double, height: Double, screen: DeviceRect? = nil,
                inputs: [DeviceInputPlacement] = []) {
        self.width = width
        self.height = height
        self.screen = screen
        self.inputs = inputs
    }

    public func validate(inputIDs: Set<String>, hasDisplay: Bool) throws {
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width <= 100_000, height <= 100_000,
              inputs.count <= 128, Set(inputs.map(\.id)).count == inputs.count else {
            throw DeviceContractError.invalid("board geometry or duplicate input placement")
        }
        guard hasDisplay || screen == nil else {
            throw DeviceContractError.invalid("screenless board has a screen rectangle")
        }
        try screen?.validate(inWidth: width, height: height)
        for placement in inputs {
            guard inputIDs.contains(placement.id) else {
                throw DeviceContractError.invalid("layout refers to unknown input \(placement.id)")
            }
            try placement.rect.validate(inWidth: width, height: height)
        }
    }

    public static func generated(display: DeviceDisplay?, inputs: [DeviceInput]) -> DeviceLayout {
        let columns = max(1, min(4, inputs.count))
        let rows = (inputs.count + columns - 1) / columns
        let screenHeight = display == nil ? 0.0 : 240.0
        let width = 320.0
        let height = max(100, screenHeight + Double(rows) * 72 + 32)
        let screen = display.map { display -> DeviceRect in
            let scale = min(288 / Double(display.width), 208 / Double(display.height))
            let w = Double(display.width) * scale
            let h = Double(display.height) * scale
            return DeviceRect(x: (width - w) / 2, y: 16, width: w, height: h)
        }
        return DeviceLayout(
            width: width, height: height, screen: screen,
            inputs: inputs.enumerated().map { offset, input in
                DeviceInputPlacement(id: input.id,
                    x: 16 + Double(offset % columns) * 72,
                    y: screenHeight + 16 + Double(offset / columns) * 72,
                    width: 56, height: 56)
            }
        )
    }
}

public struct DeviceDisplay: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var touch: Bool
    public var pixelFormat: String
    public var rotation: Int

    public init(width: Int, height: Int, touch: Bool, pixelFormat: String, rotation: Int = 0) {
        self.width = width
        self.height = height
        self.touch = touch
        self.pixelFormat = pixelFormat
        self.rotation = rotation
    }
}

public struct DeviceInput: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var kind: String
    public var events: [String]
    public var minimum: Double?
    public var maximum: Double?

    public init(id: String, name: String, kind: String, events: [String],
                minimum: Double? = nil, maximum: Double? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.events = events
        self.minimum = minimum
        self.maximum = maximum
    }
}

public struct DeviceCapabilities: Codable, Equatable, Sendable {
    public var profileVersions: [Int]
    public var media: Bool
    public var firmwareUpdate: Bool
    public var maxProfileBytes: Int
    public var maxControls: Int
    public var maxPages: Int
    /// Transports the device supports (`http`, `ble`); nil when not advertised.
    public var transports: [String]?

    public init(profileVersions: [Int], media: Bool, firmwareUpdate: Bool,
                maxProfileBytes: Int, maxControls: Int, maxPages: Int, transports: [String]? = nil) {
        self.profileVersions = profileVersions
        self.media = media
        self.firmwareUpdate = firmwareUpdate
        self.maxProfileBytes = maxProfileBytes
        self.maxControls = maxControls
        self.maxPages = maxPages
        self.transports = transports
    }

    public func supports(transport: String) -> Bool { transports?.contains(transport) ?? false }
}

public struct DeviceDescriptor: Codable, Equatable, Identifiable, Sendable {
    public var schemaVersion: Int
    public var protocolVersion: Int
    public var deviceID: String
    public var name: String
    public var manufacturer: String
    public var boardID: String
    public var hardwareRevision: String
    public var firmwareVersion: String
    public var display: DeviceDisplay?
    public var inputs: [DeviceInput]
    public var layout: DeviceLayout
    public var capabilities: DeviceCapabilities
    /// Device-exposed settings, sensors and commands, surfaced automatically by clients.
    public var controls: [DeviceControl]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, protocolVersion, deviceID, name, manufacturer, boardID
        case hardwareRevision, firmwareVersion, display, inputs, layout, capabilities, controls
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        deviceID = try container.decode(String.self, forKey: .deviceID)
        name = try container.decode(String.self, forKey: .name)
        manufacturer = try container.decode(String.self, forKey: .manufacturer)
        boardID = try container.decode(String.self, forKey: .boardID)
        hardwareRevision = try container.decode(String.self, forKey: .hardwareRevision)
        firmwareVersion = try container.decode(String.self, forKey: .firmwareVersion)
        guard container.contains(.display) else {
            throw DecodingError.keyNotFound(CodingKeys.display, .init(
                codingPath: decoder.codingPath, debugDescription: "Display presence must be explicit."))
        }
        display = try container.decodeIfPresent(DeviceDisplay.self, forKey: .display)
        inputs = try container.decode([DeviceInput].self, forKey: .inputs)
        if container.contains(.layout) {
            layout = try container.decode(DeviceLayout.self, forKey: .layout)
        } else {
            layout = .generated(display: display, inputs: inputs)
        }
        capabilities = try container.decode(DeviceCapabilities.self, forKey: .capabilities)
        controls = try container.decodeIfPresent([DeviceControl].self, forKey: .controls) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(deviceID, forKey: .deviceID)
        try container.encode(name, forKey: .name)
        try container.encode(manufacturer, forKey: .manufacturer)
        try container.encode(boardID, forKey: .boardID)
        try container.encode(hardwareRevision, forKey: .hardwareRevision)
        try container.encode(firmwareVersion, forKey: .firmwareVersion)
        if let display { try container.encode(display, forKey: .display) }
        else { try container.encodeNil(forKey: .display) }
        try container.encode(inputs, forKey: .inputs)
        try container.encode(layout, forKey: .layout)
        try container.encode(capabilities, forKey: .capabilities)
        if !controls.isEmpty { try container.encode(controls, forKey: .controls) }
    }

    public var id: String { deviceID }
    public var isM5Paper: Bool { boardID == "m5stack.m5paper" && hardwareRevision == "1.0" }
    public var canUseLegacyMedia: Bool {
        isM5Paper && capabilities.media && display?.width == 540 &&
            display?.height == 960 && display?.pixelFormat == "gray4"
    }

    public init(schemaVersion: Int = 1, protocolVersion: Int = 1, deviceID: String,
                name: String, manufacturer: String, boardID: String, hardwareRevision: String,
                firmwareVersion: String, display: DeviceDisplay?, inputs: [DeviceInput],
                layout: DeviceLayout, capabilities: DeviceCapabilities, controls: [DeviceControl] = []) {
        self.schemaVersion = schemaVersion
        self.protocolVersion = protocolVersion
        self.deviceID = deviceID
        self.name = name
        self.manufacturer = manufacturer
        self.boardID = boardID
        self.hardwareRevision = hardwareRevision
        self.firmwareVersion = firmwareVersion
        self.display = display
        self.inputs = inputs
        self.layout = layout
        self.capabilities = capabilities
        self.controls = controls
    }

    public func validate() throws {
        guard schemaVersion == 1, protocolVersion == 1 else {
            throw DeviceContractError.unsupported("descriptor or protocol version")
        }
        for value in [deviceID, name, manufacturer, boardID, hardwareRevision, firmwareVersion] {
            guard !value.isEmpty, value.utf8.count <= 128,
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw DeviceContractError.invalid("missing or oversized identity")
            }
        }
        if let display {
            guard (1...8192).contains(display.width), (1...8192).contains(display.height),
                  display.width * display.height <= 16_777_216,
                  ["mono1", "gray4", "rgb565"].contains(display.pixelFormat),
                  [0, 90, 180, 270].contains(display.rotation) else {
                throw DeviceContractError.invalid("display dimensions, rotation or pixel format")
            }
        }
        guard inputs.count <= 128, Set(inputs.map(\.id)).count == inputs.count else {
            throw DeviceContractError.invalid("too many inputs or duplicate input IDs")
        }
        for input in inputs {
            let permitted: Set<String>
            switch input.kind {
            case "button": permitted = ["press", "hold", "release"]
            case "encoder": permitted = ["rotate", "press", "hold", "release"]
            case "dial", "slider": permitted = ["change"]
            default: throw DeviceContractError.invalid("unknown input kind")
            }
            guard !input.id.isEmpty, input.id.utf8.count <= 64,
                  !input.name.isEmpty, input.name.utf8.count <= 128,
                  !input.events.isEmpty, Set(input.events).count == input.events.count,
                  Set(input.events).isSubset(of: permitted) else {
                throw DeviceContractError.invalid("input identity or events")
            }
            if input.kind == "dial" || input.kind == "slider" {
                guard let minimum = input.minimum, let maximum = input.maximum,
                      minimum.isFinite, maximum.isFinite, minimum < maximum else {
                    throw DeviceContractError.invalid("absolute input range")
                }
            }
        }
        guard !capabilities.profileVersions.isEmpty,
              capabilities.profileVersions.contains(where: { [6, 7].contains($0) }),
              (1...1_048_576).contains(capabilities.maxProfileBytes),
              (0...1024).contains(capabilities.maxControls),
              (1...128).contains(capabilities.maxPages),
              display != nil || !capabilities.media else {
            throw DeviceContractError.invalid("capability limits or media on a screenless board")
        }
        try layout.validate(inputIDs: Set(inputs.map(\.id)), hasDisplay: display != nil)
        guard controls.count <= 64, Set(controls.map(\.id)).count == controls.count,
              capabilities.transports.map({ !$0.isEmpty && Set($0).count == $0.count &&
                  Set($0).isSubset(of: ["http", "ble"]) }) ?? true else {
            throw DeviceContractError.invalid("too many or duplicate device controls, or unknown transports")
        }
        try controls.forEach { try $0.validate() }
    }

    public static func decode(_ data: Data) throws -> DeviceDescriptor {
        guard data.count <= 65_536 else { throw DeviceContractError.invalid("descriptor exceeds 64 KiB") }
        let result = try JSONDecoder().decode(Self.self, from: data)
        try result.validate()
        return result
    }

    public static func legacyM5Paper(deviceID: String, firmwareVersion: String = "legacy") -> Self {
        Self(deviceID: deviceID, name: "M5Paper", manufacturer: "M5Stack",
             boardID: "m5stack.m5paper", hardwareRevision: "1.0", firmwareVersion: firmwareVersion,
             display: DeviceDisplay(width: 540, height: 960, touch: true, pixelFormat: "gray4"),
             inputs: [], layout: DeviceLayout(width: 540, height: 960,
                screen: DeviceRect(x: 0, y: 0, width: 540, height: 960)),
             capabilities: DeviceCapabilities(profileVersions: [6], media: true,
                firmwareUpdate: true, maxProfileBytes: 262_144, maxControls: 24, maxPages: 8))
    }
}

public struct DeviceHardwareBinding<Action: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var inputID: String
    public var event: String
    public var mode: String
    public var direction: String?
    public var action: Action
    public var minimum: Double
    public var maximum: Double
    public var step: Double

    public init(inputID: String, event: String, mode: String = "action", action: Action,
                minimum: Double = 0, maximum: Double = 100, step: Double = 1, direction: String? = nil) {
        self.inputID = inputID
        self.event = event
        self.mode = mode
        self.direction = direction
        self.action = action
        self.minimum = minimum
        self.maximum = maximum
        self.step = step
    }

    public func validate(for descriptor: DeviceDescriptor) throws {
        guard descriptor.capabilities.profileVersions.contains(7),
              let input = descriptor.inputs.first(where: { $0.id == inputID }),
              input.events.contains(event),
              ["action", "relative", "absolute"].contains(mode),
              [minimum, maximum, step].allSatisfy(\.isFinite),
              minimum < maximum, (maximum - minimum).isFinite,
              step > 0, step <= maximum - minimum,
              ((maximum - minimum) / step).isFinite else {
            throw DeviceContractError.invalid("hardware binding or range")
        }
        guard mode != "relative" || (input.kind == "encoder" && event == "rotate"),
              mode != "absolute" || (["dial", "slider"].contains(input.kind) && event == "change"),
              direction == nil || (mode == "action" && event == "rotate" &&
                ["negative", "positive"].contains(direction!)) else {
            throw DeviceContractError.invalid("binding mode does not match input")
        }
    }

    public func adjustedValue(current: Double, value: Double, sourceMinimum: Double = 0,
                              sourceMaximum: Double = 1) throws -> Double {
        guard [current, value, minimum, maximum, step, sourceMinimum, sourceMaximum].allSatisfy(\.isFinite),
              minimum < maximum, step > 0, sourceMinimum < sourceMaximum else {
            throw DeviceContractError.invalid("adjustment range or non-finite event")
        }
        let raw: Double
        switch mode {
        case "relative": raw = current + value * step
        case "absolute":
            let unit = min(1, max(0, (value - sourceMinimum) / (sourceMaximum - sourceMinimum)))
            raw = minimum + unit * (maximum - minimum)
        default: throw DeviceContractError.invalid("action binding has no adjustable value")
        }
        guard raw.isFinite, (maximum - minimum).isFinite,
              ((raw - minimum) / step).isFinite else {
            throw DeviceContractError.invalid("adjustment exceeds numeric range")
        }
        return min(maximum, max(minimum, minimum + ((raw - minimum) / step).rounded() * step))
    }
}
