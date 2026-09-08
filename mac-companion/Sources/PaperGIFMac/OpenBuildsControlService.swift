import Foundation
import SocketIO

struct OpenBuildsEmission: Equatable {
    enum Payload: Equatable {
        case boolean(Bool)
        case integer(Int)
        case string(String)
        case jogXY(x: Int, y: Int, feed: Int)
        case stop(stop: Bool, jog: Bool, abort: Bool)
    }

    let event: String
    let payload: Payload
}

enum OpenBuildsCommandMapper {
    static func emission(command: String, value: Int) -> OpenBuildsEmission? {
        switch command {
        case "jogXNegative": jog(axis: "X", direction: -1, distance: value, feed: 1_000)
        case "jogXPositive": jog(axis: "X", direction: 1, distance: value, feed: 1_000)
        case "jogYNegative": jog(axis: "Y", direction: -1, distance: value, feed: 1_000)
        case "jogYPositive": jog(axis: "Y", direction: 1, distance: value, feed: 1_000)
        case "jogZNegative": jog(axis: "Z", direction: -1, distance: value, feed: 500)
        case "jogZPositive": jog(axis: "Z", direction: 1, distance: value, feed: 500)
        case "jogXNegativeYNegative": jogXY(xDirection: -1, yDirection: -1, distance: value)
        case "jogXNegativeYPositive": jogXY(xDirection: -1, yDirection: 1, distance: value)
        case "jogXPositiveYNegative": jogXY(xDirection: 1, yDirection: -1, distance: value)
        case "jogXPositiveYPositive": jogXY(xDirection: 1, yDirection: 1, distance: value)
        case "pause": OpenBuildsEmission(event: "pause", payload: .boolean(true))
        case "resume": OpenBuildsEmission(event: "resume", payload: .boolean(true))
        case "stop": OpenBuildsEmission(event: "stop", payload: .stop(stop: true, jog: false, abort: false))
        case "abort": OpenBuildsEmission(event: "stop", payload: .stop(stop: false, jog: false, abort: true))
        case "unlock": OpenBuildsEmission(event: "clearAlarm", payload: .integer(2))
        case "home": OpenBuildsEmission(event: "runCommand", payload: .string("$H\n"))
        default: nil
        }
    }

    private static func jog(axis: String, direction: Int, distance: Int, feed: Int) -> OpenBuildsEmission? {
        guard (1...100).contains(distance) else { return nil }
        return OpenBuildsEmission(
            event: "jog",
            payload: .string("\(axis),\(direction * distance),\(feed)")
        )
    }

    private static func jogXY(xDirection: Int, yDirection: Int, distance: Int) -> OpenBuildsEmission? {
        guard (1...100).contains(distance) else { return nil }
        return OpenBuildsEmission(
            event: "jogXY",
            payload: .jogXY(x: xDirection * distance, y: yDirection * distance, feed: 1_000)
        )
    }
}

final class OpenBuildsControlService {
    private static let defaultPorts = [3_000, 3_020, 3_200, 3_220]

    func perform(host: String?, command: String, value: Int) -> Bool {
        guard let emission = OpenBuildsCommandMapper.emission(command: command, value: value) else {
            return false
        }
        for endpoint in Self.endpoints(host: host ?? "") where isOpenBuildsControl(endpoint) {
            return emit(emission, to: endpoint)
        }
        return false
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
}