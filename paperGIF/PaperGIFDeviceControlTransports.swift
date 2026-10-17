import Foundation
import PaperDeviceKit

/// Request/response state for device controls over the BLE control characteristic.
/// Requests are serialized: one `0x50`/`0x52` exchange is in flight at a time.
@MainActor
final class PaperGIFBLEControlChannel {
    /// Writes a frame to the control characteristic; returns false when Bluetooth is unavailable.
    var write: ((Data) -> Bool)?
    /// Receives snapshots the device pushes without a pending request.
    var onUnsolicitedSnapshot: ((DeviceControlSnapshot) -> Void)?

    private enum Stage { case awaitingStatus, awaitingSnapshot }

    private struct Pending {
        let id: UUID
        var stage: Stage
        let continuation: CheckedContinuation<DeviceControlSnapshot, Error>
    }

    private let timeout: Duration
    private var assembler = DeviceBLEFrames.SnapshotAssembler()
    private var pending: Pending?
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(timeout: Duration = .seconds(4)) {
        self.timeout = timeout
    }

    var hasPendingRequest: Bool { pending != nil }

    func snapshot() async throws -> DeviceControlSnapshot {
        try await perform(Data([DeviceBLEFrames.requestSnapshot]), stage: .awaitingSnapshot)
    }

    func set(_ request: DeviceControlSetRequest) async throws -> DeviceControlSnapshot {
        try await perform(try DeviceBLEFrames.setRequest(request), stage: .awaitingStatus)
    }

    /// Handles a control notification. Returns true when the frame belongs to device controls.
    @discardableResult
    func receive(_ frame: Data) -> Bool {
        guard let opcode = frame.first else { return false }
        switch opcode {
        case DeviceBLEFrames.setStatus:
            guard var current = pending, current.stage == .awaitingStatus else { return true }
            guard frame.count >= 2 else {
                complete(current.id, with: .failure(DeviceControlError.malformed("set status")))
                return true
            }
            if let error = DeviceControlError(bleStatus: frame[frame.startIndex + 1]) {
                complete(current.id, with: .failure(error))
            } else {
                current.stage = .awaitingSnapshot
                pending = current
            }
            return true
        case DeviceBLEFrames.snapshotFragment:
            do {
                guard let snapshot = try assembler.receive(frame) else { return true }
                if let current = pending, current.stage == .awaitingSnapshot {
                    complete(current.id, with: .success(snapshot))
                } else {
                    onUnsolicitedSnapshot?(snapshot)
                }
            } catch {
                if let current = pending, current.stage == .awaitingSnapshot {
                    complete(current.id, with: .failure(error))
                }
            }
            return true
        default:
            return false
        }
    }

    /// Fails the in-flight request, for example when the device answers an unknown opcode.
    @discardableResult
    func failPendingRequest(_ error: DeviceControlError) -> Bool {
        guard let current = pending else { return false }
        complete(current.id, with: .failure(error))
        return true
    }

    /// Ends the connection: in-flight requests fail with a transport error.
    func reset(reason: String = "Bluetooth disconnected") {
        assembler.reset()
        if let current = pending {
            complete(current.id, with: .failure(DeviceControlError.transport(reason)))
        }
    }

    private func perform(_ frame: Data, stage: Stage) async throws -> DeviceControlSnapshot {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        guard let write else { throw DeviceControlError.transport("Bluetooth is not connected") }
        let id = UUID()
        let timeout = timeout
        return try await withCheckedThrowingContinuation { continuation in
            pending = Pending(id: id, stage: stage, continuation: continuation)
            guard write(frame) else {
                complete(id, with: .failure(DeviceControlError.transport("Bluetooth is not connected")))
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.complete(id, with: .failure(DeviceControlError.transport("Bluetooth request timed out")))
            }
        }
    }

    private func complete(_ id: UUID, with result: Result<DeviceControlSnapshot, Error>) {
        guard let current = pending, current.id == id else { return }
        pending = nil
        current.continuation.resume(with: result)
    }

    private func acquire() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

nonisolated struct PaperGIFBLEControlTransport: DeviceControlTransport {
    let name = "Bluetooth"
    let channel: PaperGIFBLEControlChannel

    func snapshot() async throws -> DeviceControlSnapshot {
        try await channel.snapshot()
    }

    func set(_ request: DeviceControlSetRequest) async throws -> DeviceControlSnapshot {
        try await channel.set(request)
    }
}

/// Skips a transport for a while after it fails to connect, so a lost Wi-Fi
/// route does not delay every request before falling back to Bluetooth.
nonisolated final class PaperGIFBackoffControlTransport: DeviceControlTransport, @unchecked Sendable {
    let base: any DeviceControlTransport
    private let interval: TimeInterval
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var unavailableUntil: Date?

    init(_ base: any DeviceControlTransport, interval: TimeInterval = 30,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.base = base
        self.interval = interval
        self.now = now
    }

    var name: String { base.name }

    func snapshot() async throws -> DeviceControlSnapshot {
        try await attempt { try await self.base.snapshot() }
    }

    func set(_ request: DeviceControlSetRequest) async throws -> DeviceControlSnapshot {
        try await attempt { try await self.base.set(request) }
    }

    private func attempt(_ operation: () async throws -> DeviceControlSnapshot) async throws -> DeviceControlSnapshot {
        let skipUntil = lock.withLock { unavailableUntil }
        if let skipUntil, now() < skipUntil {
            throw DeviceControlError.transport("\(base.name) was recently unreachable")
        }
        do {
            let snapshot = try await operation()
            lock.withLock { unavailableUntil = nil }
            return snapshot
        } catch let error as DeviceControlError where error.isTransportFailure {
            let until = now().addingTimeInterval(interval)
            lock.withLock { unavailableUntil = until }
            throw error
        }
    }
}

/// Which routes reach the selected device's controls. Tokens are resolved only when transports are built.
struct PaperGIFDeviceControlRoutes: Equatable {
    enum Credential: Equatable {
        case stored(deviceID: String)
        case bearer(String)
    }

    var httpAddress: String?
    var httpCredential: Credential?
    var bluetooth = false

    var isEmpty: Bool { httpAddress == nil && !bluetooth }

    /// Builds transports in preference order; Wi-Fi backs off after failures when Bluetooth can take over.
    func transports(
        bluetoothChannel: PaperGIFBLEControlChannel,
        storedToken: (String) -> String = PaperGIFDeviceCredentials.token(for:)
    ) -> [any DeviceControlTransport] {
        var transports: [any DeviceControlTransport] = []
        if let httpAddress, let httpCredential {
            let token = switch httpCredential {
            case .stored(let deviceID): storedToken(deviceID)
            case .bearer(let value): value
            }
            let http = HTTPDeviceControlTransport(address: httpAddress, token: token)
            transports.append(bluetooth ? PaperGIFBackoffControlTransport(http) : http)
        }
        if bluetooth {
            transports.append(PaperGIFBLEControlTransport(channel: bluetoothChannel))
        }
        return transports
    }

    static func resolve(
        descriptor: DeviceDescriptor,
        sessionSelectedID: String?,
        sessionAddress: String,
        sessionVerified: Bool,
        homeWiFiURL: URL?,
        homeWiFiAuthorization: String?,
        bluetoothDescriptor: DeviceDescriptor?,
        bluetoothReady: Bool
    ) -> Self {
        var routes = Self()
        let transports = descriptor.capabilities.transports
        if transports?.contains("http") ?? true {
            let address = sessionAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            if sessionVerified, sessionSelectedID == descriptor.deviceID, !address.isEmpty {
                routes.httpAddress = address
                routes.httpCredential = .stored(deviceID: descriptor.deviceID)
            } else if let homeWiFiURL, let homeWiFiAuthorization,
                      bluetoothDescriptor?.deviceID == descriptor.deviceID {
                routes.httpAddress = homeWiFiURL.absoluteString
                routes.httpCredential = .bearer(homeWiFiAuthorization)
            }
        }
        // A descriptor without transports was read over Bluetooth here, which implies BLE.
        if bluetoothReady, let bluetoothDescriptor, bluetoothDescriptor.deviceID == descriptor.deviceID,
           bluetoothDescriptor.capabilities.transports?.contains("ble") ?? true {
            routes.bluetooth = true
        }
        return routes
    }
}

enum PaperGIFTransportFailure {
    private static let transportCodes: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
        .cannotFindHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff,
        .callIsActive, .resourceUnavailable,
    ]

    /// True for failures to reach the device. Device rejections, authorization and
    /// validation errors are not retried over another transport.
    static func isTransportFailure(_ error: Error) -> Bool {
        if let error = error as? DeviceControlError { return error.isTransportFailure }
        if let error = error as? URLError { return transportCodes.contains(error.code) }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain &&
            transportCodes.contains(URLError.Code(rawValue: nsError.code))
    }
}

/// Forwards device → computer actions that reach the phone over the BLE relay.
enum PaperGIFRelayForwarder {
    struct Destination: Equatable {
        var host: String
        var port: Int
        var token: String
    }

    /// Distinct non-empty computer pairing tokens, in profile order.
    static func registrationTokens(for profile: PaperGIFRemoteProfile) -> [String] {
        var seen = Set<String>()
        return (profile.computers.map(\.token) + [profile.macToken]).filter {
            !$0.isEmpty && $0.utf8.count <= 128 && seen.insert($0).inserted
        }
    }

    static func destination(for computerID: String, in profile: PaperGIFRemoteProfile) -> Destination? {
        let id = computerID.trimmingCharacters(in: .whitespaces)
        if !id.isEmpty, id.lowercased() != "legacy" {
            guard let computer = profile.computers.first(where: {
                $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame
            }) else { return nil }
            return Destination(host: computer.host, port: computer.port, token: computer.token)
        }
        if !profile.macHost.isEmpty {
            return Destination(host: profile.macHost, port: profile.macPort, token: profile.macToken)
        }
        return profile.computers.first(where: { !$0.token.isEmpty && $0.token == profile.macToken })
            .map { Destination(host: $0.host, port: $0.port, token: $0.token) }
    }

    static func request(for body: Data, to destination: Destination) -> URLRequest? {
        let host = destination.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, (1...65_535).contains(destination.port) else { return nil }
        let urlHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        guard !host.contains("/"), !host.contains("@"),
              let url = URL(string: "http://\(urlHost):\(destination.port)/action"),
              url.host != nil else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !destination.token.isEmpty {
            request.setValue("Bearer \(destination.token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Posts the action to its computer; returns whether the computer accepted it.
    static func deliver(
        _ action: DeviceBLEFrames.RelayAction,
        profile: PaperGIFRemoteProfile?,
        send: (URLRequest) async throws -> Int
    ) async -> Bool {
        guard let profile,
              let destination = destination(for: action.computerID, in: profile),
              let request = request(for: action.body, to: destination) else { return false }
        do { return (200..<300).contains(try await send(request)) }
        catch { return false }
    }

    static func sendOverLAN(_ request: URLRequest) async throws -> Int {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = false
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 6
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}
