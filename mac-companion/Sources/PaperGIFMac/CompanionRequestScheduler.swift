import Foundation

/// A connection's receive deadline is replaced only after a complete, validated
/// request arrives. Both network and worker queues consult this lifetime.
final class CompanionRequestLifetime {
    private enum Phase { case receiving, queued, running, finished }
    private let lock = NSLock()
    private var phase = Phase.receiving
    private var deadline: DispatchTime

    init(receiveTimeout: TimeInterval = 10, now: DispatchTime = .now()) {
        deadline = now + receiveTimeout
    }

    var nextDeadline: DispatchTime? {
        lock.lock()
        defer { lock.unlock() }
        return phase == .finished ? nil : deadline
    }

    func admit(timeout: TimeInterval, now: DispatchTime = .now()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard phase == .receiving, now < deadline else { return false }
        deadline = now + timeout
        phase = .queued
        return true
    }

    func begin(now: DispatchTime = .now()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard phase == .queued, now < deadline else { return false }
        phase = .running
        return true
    }

    @discardableResult
    func expire(now: DispatchTime = .now()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard phase != .finished, now >= deadline else { return false }
        phase = .finished
        return true
    }

    func cancel() {
        lock.lock()
        phase = .finished
        lock.unlock()
    }
}

/// Fixed serial lanes preserve command order without letting polling, catalog
/// scans or cloud operations monopolize interactive controls.
final class CompanionRequestScheduler {
    enum Lane: CaseIterable {
        case interactive, climate, text, catalog

        static func action(_ type: String) -> Lane {
            type.hasPrefix("netHome") ? .climate : .interactive
        }

        // Leave time to deliver a response before firmware's 5/35/15s limits.
        var timeout: TimeInterval {
            switch self {
            case .interactive: return 4
            case .climate: return 33
            case .text: return 14
            case .catalog: return 30
            }
        }
    }

    private let queues: [Lane: DispatchQueue] = Dictionary(uniqueKeysWithValues:
        Lane.allCases.map { lane in
            (lane, DispatchQueue(label: "paperGIF.companion.\(lane)",
                qos: lane == .interactive ? .userInitiated : .utility))
        })
    private let lock = NSLock()
    private var outstanding: [Lane: Int] = [:]
    private let capacity: Int

    init(capacity: Int = 16) {
        self.capacity = capacity
    }

    @discardableResult
    func submit(
        on lane: Lane,
        lifetime: CompanionRequestLifetime,
        work: @escaping () -> Void
    ) -> Bool {
        lock.lock()
        guard outstanding[lane, default: 0] < capacity else {
            lock.unlock()
            return false
        }
        outstanding[lane, default: 0] += 1
        // Enqueue while holding the lock so concurrent submitters cannot invert
        // the accepted order. Expired entries still count until dequeued.
        queues[lane]!.async { [self] in
            defer {
                lock.lock()
                outstanding[lane, default: 0] -= 1
                lock.unlock()
            }
            guard lifetime.begin() else { return }
            work()
        }
        lock.unlock()
        return true
    }
}