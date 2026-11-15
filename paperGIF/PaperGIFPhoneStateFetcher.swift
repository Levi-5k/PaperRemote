import Foundation

/// Elapsed/duration reported by a computer, advanced locally while playing.
struct PaperGIFPhoneMediaTimeline: Equatable, Sendable {
    var elapsedMilliseconds: Int
    var durationMilliseconds: Int
    var playing: Bool
    var sampledAt: Date

    func elapsed(at now: Date) -> Int {
        let advance = playing ? Int(max(0, now.timeIntervalSince(sampledAt)) * 1000) : 0
        return min(durationMilliseconds, elapsedMilliseconds + advance)
    }

    func fraction(at now: Date) -> Double {
        durationMilliseconds > 0 ? Double(elapsed(at: now)) / Double(durationMilliseconds) : 0
    }

    func label(at now: Date) -> String {
        func clock(_ milliseconds: Int) -> String {
            let seconds = milliseconds / 1000
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        }
        return "\(clock(elapsed(at: now))) / \(clock(durationMilliseconds))"
    }
}

/// Asks the computers for what the M5Paper shows from them (`POST /text-source`):
/// now playing, media position, volume, play state, module state and command output.
enum PaperGIFPhoneStateFetcher {
    struct Item: Encodable, Equatable, Sendable {
        let id: String
        let source: String
        let sourceText: String
        let placeholder: String
    }

    struct Reply: Decodable, Equatable, Sendable {
        let id: String
        let text: String
        let available: Bool
        let value: Int?
        let elapsedMilliseconds: Int?
        let durationMilliseconds: Int?
        let playing: Bool?
    }

    struct Batch: Equatable, Sendable {
        let destination: PaperGIFRelayForwarder.Destination
        let items: [Item]
    }

    /// Ignore reported values for this long after the user touches a control, so polls don't fight the finger.
    static let inputHold: TimeInterval = 2

    static func item(for control: PaperGIFRemoteControl) -> Item? {
        let id = control.id.uuidString
        let action = control.action
        if action.type == .computerMedia {
            if control.kind == .slider, action.text == "volume" {
                return Item(id: id, source: "outputVolume", sourceText: "", placeholder: "")
            }
            if control.kind == .button, action.text == "playPause" {
                return Item(id: id, source: "playbackState", sourceText: "", placeholder: "")
            }
            if control.kind == .slider, action.text == "seek" {
                return Item(id: id, source: PaperGIFRemoteTextSource.nowPlaying.rawValue,
                            sourceText: control.textBox?.sourceText ?? "",
                            placeholder: control.textBox?.placeholder ?? "")
            }
        }
        if action.type == .module, control.kind == .button, control.isToggle == true {
            return Item(id: id, source: "moduleState", sourceText: "\(action.host)#\(action.value)", placeholder: "")
        }
        if control.kind == .textBox, let box = control.textBox,
           [.computerScript, .appleShortcut, .nowPlaying, .openBuildsPosition].contains(box.source) {
            return Item(id: id, source: box.source.rawValue, sourceText: box.sourceText, placeholder: box.placeholder)
        }
        return nil
    }

    /// One batch per computer for the controls on this page that show computer state.
    static func batches(for page: PaperGIFRemotePage, profile: PaperGIFRemoteProfile) -> [Batch] {
        var batches: [Batch] = []
        for control in page.controls {
            guard let item = item(for: control) else { continue }
            let computerID = control.kind == .textBox
                ? control.textBox?.computerID?.uuidString ?? control.action.computerID
                : control.action.computerID
            guard let destination = PaperGIFRelayForwarder.destination(for: computerID ?? "", in: profile),
                  !destination.token.isEmpty else { continue }
            if let index = batches.firstIndex(where: { $0.destination == destination }) {
                batches[index] = Batch(destination: destination, items: batches[index].items + [item])
            } else {
                batches.append(Batch(destination: destination, items: [item]))
            }
        }
        return batches
    }

    static func fetch(_ batch: Batch) async -> [Reply]? {
        guard var request = PaperGIFRelayForwarder.request(for: Data(), to: batch.destination),
              var components = request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }),
              let body = try? JSONEncoder().encode(["items": batch.items]) else { return nil }
        components.path = "/text-source"
        request.url = components.url
        request.httpBody = body
        request.setValue("1", forHTTPHeaderField: "X-PGIF-No-Push")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = false
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        struct Response: Decodable { let items: [Reply] }
        return (try? JSONDecoder().decode(Response.self, from: data))?.items
    }

    static func apply(
        _ replies: [Reply],
        on page: PaperGIFRemotePage,
        to session: inout PaperGIFPhoneRemoteSession,
        now: Date
    ) {
        for reply in replies {
            guard let control = page.controls.first(where: {
                $0.id.uuidString.caseInsensitiveCompare(reply.id) == .orderedSame
            }), let item = item(for: control) else { continue }
            let touched = session.lastInputAt[control.id].map { now.timeIntervalSince($0) < inputHold } ?? false
            if let duration = reply.durationMilliseconds, duration > 0, let elapsed = reply.elapsedMilliseconds,
               reply.available {
                session.timelines[control.id] = PaperGIFPhoneMediaTimeline(
                    elapsedMilliseconds: min(elapsed, duration), durationMilliseconds: duration,
                    playing: reply.playing ?? (reply.value ?? 0 != 0), sampledAt: now
                )
            } else if item.source == "nowPlaying" || item.source == "playbackState" {
                session.timelines[control.id] = nil
            }
            switch item.source {
            case "outputVolume":
                if reply.available, let value = reply.value, !touched { session.values[control.id] = value }
            case "playbackState", "moduleState":
                if reply.available, let value = reply.value, !touched { session.toggleOn[control.id] = value != 0 }
            default:
                if reply.available || control.kind == .textBox {
                    session.texts[control.id] = reply.text
                } else {
                    session.texts[control.id] = nil
                }
            }
        }
    }
}
