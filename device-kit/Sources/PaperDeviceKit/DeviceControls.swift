import Combine
import Foundation

public struct DeviceControlOption: Codable, Equatable, Hashable, Sendable {
    public var value: String
    public var name: String

    public init(value: String, name: String) {
        self.value = value
        self.name = name
    }
}

public enum DeviceControlKind: String, Codable, Sendable {
    case toggle, range, select, action
}

public enum DeviceControlValue: Codable, Equatable, Hashable, Sendable {
    case bool(Bool)
    case number(Double)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else {
            throw DecodingError.typeMismatch(Self.self, .init(
                codingPath: decoder.codingPath, debugDescription: "Control values are booleans, numbers or strings."))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .number(let value):
            if value.rounded() == value, abs(value) < 1e15 { try container.encode(Int64(value)) }
            else { try container.encode(value) }
        case .string(let value): try container.encode(value)
        }
    }

    public var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var numberValue: Double? { if case .number(let value) = self { value } else { nil } }
    public var stringValue: String? { if case .string(let value) = self { value } else { nil } }
}

public struct DeviceControl: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var kind: DeviceControlKind
    public var group: String?
    public var minimum: Double?
    public var maximum: Double?
    public var step: Double?
    public var unit: String?
    public var options: [DeviceControlOption]?
    public var readOnly: Bool?
    public var confirm: Bool?

    public init(id: String, name: String, kind: DeviceControlKind, group: String? = nil,
                minimum: Double? = nil, maximum: Double? = nil, step: Double? = nil, unit: String? = nil,
                options: [DeviceControlOption]? = nil, readOnly: Bool? = nil, confirm: Bool? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.group = group
        self.minimum = minimum
        self.maximum = maximum
        self.step = step
        self.unit = unit
        self.options = options
        self.readOnly = readOnly
        self.confirm = confirm
    }

    public var isReadOnly: Bool { readOnly == true }
    public var requiresConfirmation: Bool { confirm == true }

    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 64 &&
            id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-".unicodeScalars.contains($0) }
    }

    public func validate() throws {
        guard Self.isValidID(id), !name.isEmpty, name.utf8.count <= 128,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              (group ?? "x").utf8.count <= 64, group?.isEmpty != true,
              (unit ?? "x").utf8.count <= 16, unit?.isEmpty != true else {
            throw DeviceContractError.invalid("device control identity")
        }
        switch kind {
        case .range:
            guard let minimum, let maximum, let step,
                  [minimum, maximum, step].allSatisfy(\.isFinite),
                  minimum < maximum, (maximum - minimum).isFinite,
                  step > 0, step <= maximum - minimum else {
                throw DeviceContractError.invalid("control \(id) range")
            }
        case .select:
            guard let options, (1...32).contains(options.count),
                  Set(options.map(\.value)).count == options.count,
                  options.allSatisfy({ !$0.value.isEmpty && $0.value.utf8.count <= 64 &&
                      !$0.name.isEmpty && $0.name.utf8.count <= 128 }) else {
                throw DeviceContractError.invalid("control \(id) options")
            }
        case .action:
            guard readOnly == nil, options == nil, minimum == nil else {
                throw DeviceContractError.invalid("action control \(id) has value fields")
            }
        case .toggle:
            break
        }
    }

    /// Validates a proposed value and snaps ranges to `step`, anchored at `minimum`.
    public func normalized(_ value: DeviceControlValue?) throws -> DeviceControlValue? {
        guard !isReadOnly else { throw DeviceControlError.readOnly }
        switch kind {
        case .action:
            guard value == nil else { throw DeviceControlError.invalidValue }
            return nil
        case .toggle:
            guard let flag = value?.boolValue else { throw DeviceControlError.invalidValue }
            return .bool(flag)
        case .select:
            guard let choice = value?.stringValue,
                  options?.contains(where: { $0.value == choice }) == true else {
                throw DeviceControlError.invalidValue
            }
            return .string(choice)
        case .range:
            guard let number = value?.numberValue, number.isFinite,
                  let minimum, let maximum, let step else { throw DeviceControlError.invalidValue }
            let clamped = min(maximum, max(minimum, number))
            let steps = ((clamped - minimum) / step).rounded(.toNearestOrAwayFromZero)
            return .number(min(maximum, minimum + steps * step))
        }
    }

    func accepts(_ value: DeviceControlValue) -> Bool {
        switch (kind, value) {
        case (.toggle, .bool): true
        case (.select, .string(let choice)): options?.contains(where: { $0.value == choice }) == true
        case (.range, .number(let number)):
            number.isFinite && number >= (minimum ?? -.infinity) && number <= (maximum ?? .infinity)
        default: false
        }
    }
}

public enum DeviceControlError: LocalizedError, Equatable {
    case unauthorized, unknownControl, invalidValue, readOnly, busy
    case unsupported(String)
    case transport(String)
    case malformed(String)

    public init(code: String) {
        switch code {
        case "unauthorized": self = .unauthorized
        case "unknown_control": self = .unknownControl
        case "invalid_value": self = .invalidValue
        case "read_only": self = .readOnly
        case "busy": self = .busy
        default: self = .malformed("unrecognized device error")
        }
    }

    public init?(bleStatus: UInt8) {
        switch bleStatus {
        case 0: return nil
        case 1: self = .unknownControl
        case 2: self = .invalidValue
        case 3: self = .readOnly
        default: self = .busy
        }
    }

    /// Only transport failures may be retried over another transport.
    public var isTransportFailure: Bool { if case .transport = self { true } else { false } }

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "The device rejected this companion's pairing token."
        case .unknownControl: "The device no longer has this control. Reconnect to refresh it."
        case .invalidValue: "The device rejected that value."
        case .readOnly: "This control is read-only."
        case .busy: "The device is busy. Try again in a moment."
        case .unsupported(let reason): reason
        case .transport(let reason): "Could not reach the device: \(reason)"
        case .malformed(let reason): "The device sent an invalid control response: \(reason)"
        }
    }
}

public struct DeviceControlSnapshot: Codable, Equatable, Sendable {
    public var values: [String: DeviceControlValue]

    public init(values: [String: DeviceControlValue]) { self.values = values }

    /// Keeps only well-typed values for declared stateful controls.
    public func filtered(for controls: [DeviceControl]) -> [String: DeviceControlValue] {
        var result: [String: DeviceControlValue] = [:]
        for control in controls where control.kind != .action {
            if let value = values[control.id], control.accepts(value) { result[control.id] = value }
        }
        return result
    }

    public static func decode(_ data: Data) throws -> DeviceControlSnapshot {
        guard data.count <= 65_536 else { throw DeviceControlError.malformed("snapshot exceeds 64 KiB") }
        do { return try JSONDecoder().decode(Self.self, from: data) }
        catch { throw DeviceControlError.malformed("snapshot") }
    }
}

public struct DeviceControlSetRequest: Codable, Equatable, Sendable {
    public var id: String
    public var value: DeviceControlValue?

    public init(id: String, value: DeviceControlValue?) {
        self.id = id
        self.value = value
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self)
    }
}

/// A route to a device's controls. Implementations throw `DeviceControlError`.
public protocol DeviceControlTransport: Sendable {
    var name: String { get }
    func snapshot() async throws -> DeviceControlSnapshot
    func set(_ request: DeviceControlSetRequest) async throws -> DeviceControlSnapshot
}

public struct HTTPDeviceControlTransport: DeviceControlTransport {
    public let name = "Wi-Fi"
    private let address: String
    private let token: String
    private let request: @Sendable (URLRequest, Int) async throws -> (Data, Int)

    public init(address: String, token: String,
                request: @escaping @Sendable (URLRequest, Int) async throws -> (Data, Int) = {
                    try await DeviceHTTP.request($0, maximumBytes: $1, timeout: 4)
                }) {
        self.address = address
        self.token = token
        self.request = request
    }

    public func snapshot() async throws -> DeviceControlSnapshot {
        var request = URLRequest(url: try endpoint())
        authorize(&request)
        let (data, status) = try await perform(request)
        guard status == 200 else { throw Self.rejection(data, status: status) }
        return try DeviceControlSnapshot.decode(data)
    }

    public func set(_ setRequest: DeviceControlSetRequest) async throws -> DeviceControlSnapshot {
        var request = URLRequest(url: try endpoint())
        request.httpMethod = "POST"
        request.httpBody = try setRequest.encoded()
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        let (data, status) = try await perform(request)
        struct Response: Decodable { let ok: Bool; let error: String?; let values: [String: DeviceControlValue]? }
        guard status == 200, let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw Self.rejection(data, status: status)
        }
        guard response.ok, let values = response.values else {
            throw DeviceControlError(code: response.error ?? "")
        }
        return DeviceControlSnapshot(values: values)
    }

    private func endpoint() throws -> URL {
        do { return try DeviceHTTP.endpoint(address, path: "/device/controls") }
        catch { throw DeviceControlError.unsupported("The device has no valid network address.") }
    }

    private func authorize(_ request: inout URLRequest) {
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, Int) {
        do { return try await self.request(request, 65_536) }
        catch is CancellationError { throw CancellationError() }
        catch let error as DeviceContractError { throw DeviceControlError.malformed(error.localizedDescription) }
        catch { throw DeviceControlError.transport(error.localizedDescription) }
    }

    static func rejection(_ data: Data, status: Int) -> DeviceControlError {
        struct Rejection: Decodable { let error: String }
        if let rejection = try? JSONDecoder().decode(Rejection.self, from: data) {
            return DeviceControlError(code: rejection.error)
        }
        switch status {
        case 401, 403: return .unauthorized
        case 404: return .unsupported("This firmware does not expose device controls.")
        case 409, 503: return .busy
        default: return .malformed("HTTP \(status)")
        }
    }
}

/// Pure encoders/decoders for the BLE device-control and relay opcodes.
public enum DeviceBLEFrames {
    public static let requestSnapshot: UInt8 = 0x50
    public static let snapshotFragment: UInt8 = 0x51
    public static let setControl: UInt8 = 0x52
    public static let setStatus: UInt8 = 0x53
    public static let registerRelay: UInt8 = 0x70
    public static let relayRegistered: UInt8 = 0x71
    public static let relayAction: UInt8 = 0x72
    public static let relayAcknowledgement: UInt8 = 0x73
    public static let maximumSetRequestBytes = 240
    public static let maximumMessageBytes = 65_536

    public enum RelayRole: UInt8, Sendable { case computer = 0, forwarder = 1 }

    public static func setRequest(_ request: DeviceControlSetRequest) throws -> Data {
        let body = try request.encoded()
        guard body.count <= maximumSetRequestBytes else {
            throw DeviceControlError.unsupported("Control request exceeds the Bluetooth limit.")
        }
        return Data([setControl]) + body
    }

    public static func relayRegistration(role: RelayRole, token: String) throws -> Data {
        let bytes = Data(token.utf8)
        guard !bytes.isEmpty, bytes.count <= 128 else {
            throw DeviceControlError.unsupported("Pairing token is missing or too long.")
        }
        return Data([registerRelay, role.rawValue]) + bytes
    }

    public static func relayAck(sequence: UInt8, delivered: Bool) -> Data {
        Data([relayAcknowledgement, sequence, delivered ? 0 : 1])
    }

    /// Reassembles `0x51` snapshot fragments.
    public struct SnapshotAssembler: Sendable {
        private var buffer = Data()
        public init() {}

        public mutating func reset() { buffer.removeAll(keepingCapacity: true) }

        /// Returns the decoded snapshot when the final fragment arrives.
        public mutating func receive(_ frame: Data) throws -> DeviceControlSnapshot? {
            let frame = Data(frame)
            guard frame.count >= 2, frame[frame.startIndex] == snapshotFragment else { return nil }
            buffer.append(frame.dropFirst(2))
            guard buffer.count <= maximumMessageBytes else {
                reset()
                throw DeviceControlError.malformed("snapshot exceeds 64 KiB")
            }
            guard frame[frame.startIndex + 1] & 0x01 != 0 else { return nil }
            defer { reset() }
            return try DeviceControlSnapshot.decode(buffer)
        }
    }

    public struct RelayAction: Equatable, Sendable {
        public var sequence: UInt8
        public var computerID: String
        public var body: Data
    }

    /// Reassembles `0x72` relay frames, keyed by sequence number.
    public struct RelayAssembler: Sendable {
        private var buffers: [UInt8: Data] = [:]
        public init() {}

        public mutating func reset() { buffers.removeAll() }

        public mutating func receive(_ frame: Data) throws -> RelayAction? {
            let frame = Data(frame)
            guard frame.count >= 3, frame[frame.startIndex] == relayAction else { return nil }
            let sequence = frame[frame.startIndex + 1]
            var buffer = buffers[sequence] ?? Data()
            buffer.append(frame.dropFirst(3))
            guard buffer.count <= maximumMessageBytes, buffers.count <= 8 else {
                buffers[sequence] = nil
                throw DeviceControlError.malformed("relay message exceeds limits")
            }
            guard frame[frame.startIndex + 2] & 0x01 != 0 else {
                buffers[sequence] = buffer
                return nil
            }
            buffers[sequence] = nil
            guard let root = try? JSONSerialization.jsonObject(with: buffer) as? [String: Any],
                  let computerID = root["computerId"] as? String,
                  let body = root["body"] as? [String: Any],
                  let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
                throw DeviceControlError.malformed("relay action")
            }
            return RelayAction(sequence: sequence, computerID: computerID, body: bodyData)
        }
    }
}

/// Shared state for a device's auto-generated control surface. Transports are
/// tried in order; only transport failures fall through to the next one.
@MainActor
public final class DeviceControlsModel: ObservableObject {
    @Published public private(set) var controls: [DeviceControl] = []
    @Published public private(set) var values: [String: DeviceControlValue] = [:]
    @Published public private(set) var pendingIDs: Set<String> = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: String?
    @Published public private(set) var activeTransport: String?

    private var transports: [any DeviceControlTransport] = []
    private var generation = UUID()
    private var setTasks: [String: Task<Void, Never>] = [:]

    public init() {}

    public var groups: [(name: String, controls: [DeviceControl])] {
        var order: [String] = []
        var grouped: [String: [DeviceControl]] = [:]
        for control in controls {
            let name = control.group ?? "Device"
            if grouped[name] == nil { order.append(name) }
            grouped[name, default: []].append(control)
        }
        return order.map { ($0, grouped[$0]!) }
    }

    /// Replaces the device and its transports; previous requests are ignored.
    public func configure(controls: [DeviceControl], transports: [any DeviceControlTransport]) {
        generation = UUID()
        setTasks.values.forEach { $0.cancel() }
        setTasks = [:]
        pendingIDs = []
        self.controls = controls
        self.transports = transports
        values = [:]
        error = nil
        activeTransport = nil
        isLoading = false
    }

    public func refresh() async {
        guard !controls.isEmpty else { return }
        let operation = generation
        isLoading = true
        defer { if operation == generation { isLoading = false } }
        do {
            let (snapshot, transport) = try await run { try await $0.snapshot() }
            guard operation == generation else { return }
            apply(snapshot, via: transport)
        } catch {
            guard operation == generation, !(error is CancellationError) else { return }
            self.error = error.localizedDescription
        }
    }

    /// Applies a device-pushed snapshot (for example an unsolicited BLE update).
    public func receive(_ snapshot: DeviceControlSnapshot, via transport: String) {
        apply(snapshot, via: transport)
    }

    /// Sends a value; rapid updates to one control coalesce to the latest value.
    public func set(_ control: DeviceControl, to value: DeviceControlValue?) {
        let normalized: DeviceControlValue?
        do { normalized = try control.normalized(value) }
        catch { self.error = error.localizedDescription; return }
        let operation = generation
        let previous = values[control.id]
        if let normalized { values[control.id] = normalized }
        pendingIDs.insert(control.id)
        setTasks[control.id]?.cancel()
        setTasks[control.id] = Task { [weak self] in
            guard let self else { return }
            do {
                let request = DeviceControlSetRequest(id: control.id, value: normalized)
                let (snapshot, transport) = try await self.run { try await $0.set(request) }
                guard operation == self.generation, !Task.isCancelled else { return }
                self.finish(control.id)
                self.apply(snapshot, via: transport)
            } catch {
                guard operation == self.generation, !Task.isCancelled, !(error is CancellationError) else { return }
                self.finish(control.id)
                self.values[control.id] = previous
                self.error = error.localizedDescription
            }
        }
    }

    private func finish(_ id: String) {
        pendingIDs.remove(id)
        setTasks[id] = nil
    }

    private func apply(_ snapshot: DeviceControlSnapshot, via transport: String) {
        var merged = snapshot.filtered(for: controls)
        // Keep optimistic values for controls with a newer request in flight.
        for id in pendingIDs { merged[id] = values[id] ?? merged[id] }
        values = merged
        activeTransport = transport
        error = nil
    }

    private func run(_ operation: (any DeviceControlTransport) async throws -> DeviceControlSnapshot)
        async throws -> (DeviceControlSnapshot, String) {
        guard !transports.isEmpty else {
            throw DeviceControlError.unsupported("Connect over Wi-Fi or Bluetooth to control this device.")
        }
        var lastError: Error = DeviceControlError.transport("no route")
        for transport in transports {
            do { return (try await operation(transport), transport.name) }
            catch let error as DeviceControlError where error.isTransportFailure { lastError = error }
        }
        throw lastError
    }
}
