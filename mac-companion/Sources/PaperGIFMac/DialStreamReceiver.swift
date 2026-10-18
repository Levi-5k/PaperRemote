import Foundation
import Network

/// One low-latency dial value sent by a device over UDP to the companion's action port.
struct DialStreamDatagram: Equatable {
    let boot: UInt32
    let seq: UInt32
    let action: Data

    static let maximumSize = 2_048

    static func parse(_ data: Data, token: String) -> DialStreamDatagram? {
        guard data.count <= maximumSize,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "paperGIF.dialStream",
              (object["version"] as? NSNumber)?.intValue == 1,
              let boot = (object["boot"] as? NSNumber).flatMap({ UInt32(exactly: $0.doubleValue) }),
              let seq = (object["seq"] as? NSNumber).flatMap({ UInt32(exactly: $0.doubleValue) }),
              let supplied = object["token"] as? String,
              !token.isEmpty, constantTimeEqual(supplied, token),
              let action = object["action"] as? [String: Any],
              let encoded = try? JSONSerialization.data(withJSONObject: action) else { return nil }
        return DialStreamDatagram(boot: boot, seq: seq, action: encoded)
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// Drops duplicate and out-of-order datagrams per sender. A new boot ID (device restart)
/// starts a fresh sequence.
struct DialStreamOrdering {
    private var latest: [String: (boot: UInt32, seq: UInt32)] = [:]

    mutating func accept(sender: String, boot: UInt32, seq: UInt32) -> Bool {
        if let previous = latest[sender], previous.boot == boot, seq &- previous.seq == 0 || seq &- previous.seq > UInt32.max / 2 {
            return false
        }
        latest[sender] = (boot, seq)
        return true
    }
}

/// Receives dial-stream datagrams and applies only the newest value for each action, so a
/// slow action (for example a system volume change) never builds up a backlog.
final class DialStreamReceiver {
    private let port: UInt16
    private let token: String
    private let handler: (RemoteRequest) -> Void
    private let queue = DispatchQueue(label: "paperGIF.dialStream.receive")
    private let workQueue = DispatchQueue(label: "paperGIF.dialStream.apply")
    private var listener: NWListener?
    private var ordering = DialStreamOrdering()
    private var pending: [String: RemoteRequest] = [:]
    private var pendingOrder: [String] = []
    private var draining = false

    init(port: UInt16, token: String, handler: @escaping (RemoteRequest) -> Void) {
        self.port = port
        self.token = token
        self.handler = handler
    }

    func start() throws {
        guard let networkPort = NWEndpoint.Port(rawValue: port) else { return }
        let listener = try NWListener(using: .udp, on: networkPort)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receive(on: connection)
        }
        listener.stateUpdateHandler = { state in
            if case let .failed(error) = state { DiagnosticLog.error("Dial stream listener failed", error: error) }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else { return }
            if let data { self.handle(data, from: connection.endpoint) }
            if error == nil { self.receive(on: connection) } else { connection.cancel() }
        }
    }

    private func handle(_ data: Data, from endpoint: NWEndpoint) {
        guard let datagram = DialStreamDatagram.parse(data, token: token),
              ordering.accept(sender: Self.senderKey(endpoint), boot: datagram.boot, seq: datagram.seq),
              let request = try? JSONDecoder().decode(RemoteRequest.self, from: datagram.action) else { return }
        let key = "\(request.type)|\(request.text)|\(request.host ?? "")"
        if pending.updateValue(request, forKey: key) == nil { pendingOrder.append(key) }
        guard !draining else { return }
        draining = true
        drain()
    }

    private func drain() {
        guard !pendingOrder.isEmpty else {
            draining = false
            return
        }
        let key = pendingOrder.removeFirst()
        guard let request = pending.removeValue(forKey: key) else { return drain() }
        workQueue.async { [weak self] in
            self?.handler(request)
            self?.queue.async { self?.drain() }
        }
    }

    private static func senderKey(_ endpoint: NWEndpoint) -> String {
        guard case let .hostPort(host, _) = endpoint else { return String(describing: endpoint) }
        return String(describing: host)
    }
}
