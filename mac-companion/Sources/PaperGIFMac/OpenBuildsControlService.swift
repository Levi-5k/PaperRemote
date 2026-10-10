import Foundation
import SocketIO

struct OpenBuildsEmission: Equatable {
    enum Payload: Equatable {
        case boolean(Bool)
        case integer(Int)
        case string(String)
        case jogXY(x: Double, y: Double, feed: Int)
        case stop(stop: Bool, jog: Bool, abort: Bool)
    }

    let event: String
    let payload: Payload
}

struct OpenBuildsPosition: Equatable {
    let x: Double
    let y: Double
    let z: Double
}

enum OpenBuildsCommandMapper {
    static func emission(
        command: String,
        value: Int,
        valueTenths: Int? = nil,
        modifiers: [String] = []
    ) -> OpenBuildsEmission? {
        let unitScale = modifiers.contains("units=in") ? 25.4 : 1
        let distance = distance(in: modifiers, fallbackTenths: valueTenths ?? value * 10) * unitScale
        let xyFeed = scaledFeed(feed(in: modifiers) ?? 1_000, by: unitScale)
        let zFeed = scaledFeed(feed(in: modifiers) ?? 500, by: unitScale)
        return switch command {
        case "jogXNegative": jog(axis: "X", direction: -1, distance: distance, feed: xyFeed)
        case "jogXPositive": jog(axis: "X", direction: 1, distance: distance, feed: xyFeed)
        case "jogYNegative": jog(axis: "Y", direction: -1, distance: distance, feed: xyFeed)
        case "jogYPositive": jog(axis: "Y", direction: 1, distance: distance, feed: xyFeed)
        case "jogZNegative": jog(axis: "Z", direction: -1, distance: distance, feed: zFeed)
        case "jogZPositive": jog(axis: "Z", direction: 1, distance: distance, feed: zFeed)
        case "jogXNegativeYNegative": jogXY(xDirection: -1, yDirection: -1, distance: distance, feed: xyFeed)
        case "jogXNegativeYPositive": jogXY(xDirection: -1, yDirection: 1, distance: distance, feed: xyFeed)
        case "jogXPositiveYNegative": jogXY(xDirection: 1, yDirection: -1, distance: distance, feed: xyFeed)
        case "jogXPositiveYPositive": jogXY(xDirection: 1, yDirection: 1, distance: distance, feed: xyFeed)
        case "continuousJogXNegative": continuousJog(x: -1, y: 0, feed: scaledFeed(value, by: unitScale))
        case "continuousJogXPositive": continuousJog(x: 1, y: 0, feed: scaledFeed(value, by: unitScale))
        case "continuousJogYNegative": continuousJog(x: 0, y: -1, feed: scaledFeed(value, by: unitScale))
        case "continuousJogYPositive": continuousJog(x: 0, y: 1, feed: scaledFeed(value, by: unitScale))
        case "continuousJogXNegativeYNegative": continuousJog(x: -1, y: -1, feed: scaledFeed(value, by: unitScale))
        case "continuousJogXNegativeYPositive": continuousJog(x: -1, y: 1, feed: scaledFeed(value, by: unitScale))
        case "continuousJogXPositiveYNegative": continuousJog(x: 1, y: -1, feed: scaledFeed(value, by: unitScale))
        case "continuousJogXPositiveYPositive": continuousJog(x: 1, y: 1, feed: scaledFeed(value, by: unitScale))
        case "cancelJog": OpenBuildsEmission(event: "stop", payload: .stop(stop: false, jog: true, abort: false))
        case "pause": OpenBuildsEmission(event: "pause", payload: .boolean(true))
        case "resume": OpenBuildsEmission(event: "resume", payload: .boolean(true))
        case "stop": OpenBuildsEmission(event: "stop", payload: .stop(stop: true, jog: false, abort: false))
        case "abort": OpenBuildsEmission(event: "stop", payload: .stop(stop: false, jog: false, abort: true))
        case "unlock": OpenBuildsEmission(event: "clearAlarm", payload: .integer(2))
        case "home": OpenBuildsEmission(event: "runCommand", payload: .string("$H\n"))
        case "zeroX": zero(axis: "X")
        case "zeroY": zero(axis: "Y")
        case "zeroZ": zero(axis: "Z")
        default: nil
        }
    }

    private static func zero(axis: String) -> OpenBuildsEmission {
        OpenBuildsEmission(event: "runCommand", payload: .string("G10 L20 P1 \(axis)0\n"))
    }

    private static func jog(axis: String, direction: Int, distance: Double, feed: Int) -> OpenBuildsEmission? {
        guard (0.001...100).contains(distance), (100...10_000).contains(feed) else { return nil }
        return OpenBuildsEmission(
            event: "jog",
            payload: .string("\(axis),\(number(Double(direction) * distance)),\(feed)")
        )
    }

    private static func jogXY(xDirection: Int, yDirection: Int, distance: Double, feed: Int) -> OpenBuildsEmission? {
        guard (0.001...100).contains(distance), (100...10_000).contains(feed) else { return nil }
        return OpenBuildsEmission(
            event: "jogXY",
            payload: .jogXY(x: Double(xDirection) * distance, y: Double(yDirection) * distance, feed: feed)
        )
    }

    private static func continuousJog(x: Int, y: Int, feed: Int) -> OpenBuildsEmission? {
        guard (100...10_000).contains(feed), x != 0 || y != 0 else { return nil }
        let xWord = x == 0 ? "" : " X\(x * 1_000)"
        let yWord = y == 0 ? "" : " Y\(y * 1_000)"
        return OpenBuildsEmission(
            event: "runCommand",
            payload: .string("$J=G91 G21\(xWord)\(yWord) F\(feed)\n")
        )
    }

    private static func feed(in modifiers: [String]) -> Int? {
        modifiers.lazy.compactMap { modifier -> Int? in
            guard modifier.hasPrefix("feed=") else { return nil }
            return Int(modifier.dropFirst(5))
        }.first
    }

    private static func distance(in modifiers: [String], fallbackTenths: Int) -> Double {
        let thousandths = modifiers.lazy.compactMap { modifier -> Int? in
            guard modifier.hasPrefix("dist=") else { return nil }
            return Int(modifier.dropFirst(5))
        }.first
        return Double(thousandths ?? fallbackTenths * 100) / 1_000
    }

    private static func scaledFeed(_ feed: Int, by scale: Double) -> Int {
        Int((Double(feed) * scale).rounded())
    }

    private static func number(_ value: Double) -> String {
        let formatted = String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
        return formatted.replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }
}

enum OpenBuildsCommandPolicy {
    static func allows(command: String, runStatus: String?) -> Bool {
        if ["cancelJog", "stop", "abort"].contains(command) {
            return true
        }
        guard let normalized = runStatus?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(), !normalized.isEmpty else {
            return false
        }
        let state = normalized.split(separator: ":", maxSplits: 1).first.map(String.init) ?? normalized
        return switch command {
        case "pause": state == "run"
        case "resume": state == "hold" || normalized == "door:0"
        case "home": state == "idle" || state == "alarm"
        case "unlock": state == "alarm"
        default: state == "idle"
        }
    }
}

final class OpenBuildsControlService {
    private static let defaultPorts = [3_000, 3_020, 3_200, 3_220]
    private let positionSessionsLock = NSLock()
    private var positionSessions: [URL: OpenBuildsPositionSession] = [:]

    func perform(host: String?, command: String, value: Int, valueTenths: Int?, modifiers: [String]) -> Bool {
        guard let emission = OpenBuildsCommandMapper.emission(
            command: command,
            value: value,
            valueTenths: valueTenths,
            modifiers: modifiers
        ) else {
            return false
        }
        for endpoint in Self.endpoints(host: host ?? "") where isOpenBuildsControl(endpoint) {
            if !OpenBuildsCommandPolicy.allows(command: command, runStatus: nil) {
                let runStatus = positionSession(for: endpoint).runStatus()
                guard OpenBuildsCommandPolicy.allows(command: command, runStatus: runStatus) else {
                    return false
                }
            }
            return emit(emission, to: endpoint)
        }
        return false
    }

    func position(host: String) -> OpenBuildsPosition? {
        for endpoint in Self.endpoints(host: host) where isOpenBuildsControl(endpoint) {
            if let position = positionSession(for: endpoint).position() {
                return position
            }
        }
        return nil
    }

    static func endpoints(host: String) -> [URL] {
        let rawHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawTarget = rawHost.isEmpty ? "127.0.0.1" : rawHost
        guard !rawTarget.contains("/"),
              !rawTarget.contains("?"),
              !rawTarget.contains("#"),
              !rawTarget.contains("@"),
              let components = URLComponents(string: "http://\(rawTarget)"),
              components.scheme == "http",
              let hostname = components.host,
              isLocalNetworkHost(hostname) else {
            return []
        }
        if let port = components.port {
            return [URL(string: "http://\(hostname):\(port)")!]
        }
        return defaultPorts.compactMap { URL(string: "http://\(hostname):\($0)") }
    }

    private static func isLocalNetworkHost(_ host: String) -> Bool {
        let normalized = host.lowercased()
        if normalized == "localhost" || normalized == "::1" || normalized.hasSuffix(".local") {
            return true
        }
        let octets = normalized.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
            return false
        }
        return octets[0] == 10 ||
            (octets[0] == 127) ||
            (octets[0] == 169 && octets[1] == 254) ||
            (octets[0] == 172 && (16...31).contains(octets[1])) ||
            (octets[0] == 192 && octets[1] == 168)
    }

    private func isOpenBuildsControl(_ endpoint: URL) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var matched = false
        var request = URLRequest(url: endpoint.appendingPathComponent("api/version"))
        request.timeoutInterval = 1
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let response = response as? HTTPURLResponse,
                  response.statusCode == 200,
                  let data,
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            matched = payload["application"] as? String == "OMD"
        }.resume()
        _ = semaphore.wait(timeout: .now() + 1.25)
        return matched
    }

    private func emit(_ emission: OpenBuildsEmission, to endpoint: URL) -> Bool {
        let callbackQueue = DispatchQueue(label: "paperGIF.openbuilds.socket")
        let manager = SocketManager(socketURL: endpoint, config: [
            .log(false),
            .reconnects(false),
            .forceNew(true),
            .forceWebsockets(true),
            .handleQueue(callbackQueue),
        ])
        let socket = manager.defaultSocket
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var succeeded = false
        var finished = false
        let finish: (Bool) -> Void = { result in
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            succeeded = result
            semaphore.signal()
        }
        socket.on(clientEvent: .connect) { _, _ in
            let completion = { finish(true) }
            switch emission.payload {
            case let .boolean(value): socket.emit(emission.event, value, completion: completion)
            case let .integer(value): socket.emit(emission.event, value, completion: completion)
            case let .string(value): socket.emit(emission.event, value, completion: completion)
            case let .jogXY(x, y, feed):
                socket.emit(emission.event, ["x": x, "y": y, "feed": feed], completion: completion)
            case let .stop(stop, jog, abort):
                socket.emit(
                    emission.event,
                    ["stop": stop, "jog": jog, "abort": abort],
                    completion: completion
                )
            }
        }
        socket.on(clientEvent: .error) { _, _ in finish(false) }
        socket.connect(withPayload: nil, timeoutAfter: 3) { finish(false) }
        _ = semaphore.wait(timeout: .now() + 3.5)
        socket.disconnect()
        socket.removeAllHandlers()
        return succeeded
    }

    private func positionSession(for endpoint: URL) -> OpenBuildsPositionSession {
        positionSessionsLock.lock()
        defer { positionSessionsLock.unlock() }
        if let session = positionSessions[endpoint] {
            return session
        }
        let session = OpenBuildsPositionSession(endpoint: endpoint)
        positionSessions[endpoint] = session
        return session
    }

    static func position(from status: [String: Any]) -> OpenBuildsPosition? {
        guard let machine = status["machine"] as? [String: Any],
              let position = machine["position"] as? [String: Any],
              let work = position["work"] as? [String: Any],
              let x = number(work["x"]),
              let y = number(work["y"]),
              let z = number(work["z"]) else {
            return nil
        }
        return OpenBuildsPosition(x: x, y: y, z: z)
    }

    static func runStatus(from status: [String: Any]) -> String? {
        guard let comms = status["comms"] as? [String: Any],
              let runStatus = comms["runStatus"] as? String else { return nil }
        let normalized = runStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

private final class OpenBuildsPositionSession {
    private static let freshness: TimeInterval = 2
    private let manager: SocketManager
    private let socket: SocketIOClient
    private let condition = NSCondition()
    private var connectionActive = false
    private var latestPosition: OpenBuildsPosition?
    private var latestPositionAt = Date.distantPast
    private var latestRunStatus: String?
    private var latestRunStatusAt = Date.distantPast

    init(endpoint: URL) {
        let callbackQueue = DispatchQueue(label: "paperGIF.openbuilds.status.\(endpoint.port ?? 0)")
        manager = SocketManager(socketURL: endpoint, config: [
            .log(false),
            .reconnects(false),
            .forceNew(true),
            .forceWebsockets(true),
            .handleQueue(callbackQueue),
        ])
        socket = manager.defaultSocket
        socket.on("status") { [weak self] data, _ in
            guard let payload = data.first as? [String: Any] else { return }
            self?.publish(
                position: OpenBuildsControlService.position(from: payload),
                runStatus: OpenBuildsControlService.runStatus(from: payload)
            )
        }
        socket.on(clientEvent: .connect) { [weak self] _, _ in
            self?.setConnectionActive(true)
        }
        socket.on(clientEvent: .disconnect) { [weak self] _, _ in
            self?.setConnectionActive(false)
        }
        socket.on(clientEvent: .error) { [weak self] _, _ in
            self?.setConnectionActive(false)
        }
    }

    deinit {
        socket.disconnect()
        socket.removeAllHandlers()
    }

    func position() -> OpenBuildsPosition? {
        condition.lock()
        if let latestPosition, Date().timeIntervalSince(latestPositionAt) <= Self.freshness {
            condition.unlock()
            return latestPosition
        }
        let shouldConnect = !connectionActive
        if shouldConnect {
            connectionActive = true
        }
        condition.unlock()

        if shouldConnect {
            socket.connect(withPayload: nil, timeoutAfter: 3) { [weak self] in
                self?.setConnectionActive(false)
            }
        }

        condition.lock()
        let deadline = Date().addingTimeInterval(3.5)
        while Date().timeIntervalSince(latestPositionAt) > Self.freshness &&
            connectionActive && condition.wait(until: deadline) {}
        let result = Date().timeIntervalSince(latestPositionAt) <= Self.freshness
            ? latestPosition : nil
        condition.unlock()
        return result
    }

    func runStatus() -> String? {
        condition.lock()
        if let latestRunStatus, Date().timeIntervalSince(latestRunStatusAt) <= Self.freshness {
            condition.unlock()
            return latestRunStatus
        }
        let shouldConnect = !connectionActive
        if shouldConnect {
            connectionActive = true
        }
        condition.unlock()

        if shouldConnect {
            socket.connect(withPayload: nil, timeoutAfter: 3) { [weak self] in
                self?.setConnectionActive(false)
            }
        }

        condition.lock()
        let deadline = Date().addingTimeInterval(3.5)
        while Date().timeIntervalSince(latestRunStatusAt) > Self.freshness &&
            connectionActive && condition.wait(until: deadline) {}
        let result = Date().timeIntervalSince(latestRunStatusAt) <= Self.freshness
            ? latestRunStatus : nil
        condition.unlock()
        return result
    }

    private func publish(position: OpenBuildsPosition?, runStatus: String?) {
        guard position != nil || runStatus != nil else { return }
        condition.lock()
        let now = Date()
        if let position {
            latestPosition = position
            latestPositionAt = now
        }
        if let runStatus {
            latestRunStatus = runStatus
            latestRunStatusAt = now
        }
        condition.broadcast()
        condition.unlock()
    }

    private func setConnectionActive(_ active: Bool) {
        condition.lock()
        connectionActive = active
        condition.broadcast()
        condition.unlock()
    }
}