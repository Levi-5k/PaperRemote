import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Private-network checks for direct phone requests. Matches `local_http_policy.h` and
/// `normalizeLocalHttpAuthority`, including the stricter host check used for WLED.
enum PaperGIFPhoneLocalHTTP {
    static let maximumURLLength = 159

    static func authority(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.lowercased().hasPrefix("https://") else { return nil }
        var authority = trimmed
        if authority.lowercased().hasPrefix("http://") {
            authority.removeFirst(7)
        }
        while authority.hasSuffix("/") {
            authority.removeLast()
        }
        guard !authority.isEmpty,
              authority.rangeOfCharacter(from: CharacterSet(charactersIn: "/@?#\r\n ")) == nil,
              let host = hostAndPort(in: authority) else { return nil }
        let numeric = ipv4(host.host)
        if let numeric {
            return isPrivateIPv4(numeric.0, numeric.1) ? authority : nil
        }
        return isLocalHostname(host.host) ? authority : nil
    }

    static func isAllowedMethod(_ method: String) -> Bool {
        method == "GET" || method == "POST"
    }

    static func isAllowedPath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("\r") && !path.contains("\n") &&
            !path.contains("#") && !path.contains("://")
    }

    private static func hostAndPort(in authority: String) -> (host: String, port: String?)? {
        guard let separator = authority.lastIndex(of: ":") else { return (authority, nil) }
        let host = String(authority[..<separator])
        let port = String(authority[authority.index(after: separator)...])
        guard !host.isEmpty, !port.isEmpty, port.count <= 5, port.allSatisfy(\.isNumber),
              let value = Int(port), (1...65_535).contains(value), String(value) == port else { return nil }
        return (host, port)
    }

    private static func ipv4(_ host: String) -> (UInt8, UInt8)? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard (1...3).contains(part.count), part.allSatisfy(\.isNumber),
                  let value = Int(part), (0...255).contains(value) else { return nil }
            bytes.append(UInt8(value))
        }
        return (bytes[0], bytes[1])
    }

    private static func isPrivateIPv4(_ first: UInt8, _ second: UInt8) -> Bool {
        first == 10 || first == 127 ||
            (first == 169 && second == 254) ||
            (first == 172 && second >= 16 && second <= 31) ||
            (first == 192 && second == 168)
    }

    private static func isLocalHostname(_ host: String) -> Bool {
        let normalized = host.lowercased()
        return normalized.count > 6 && normalized.hasSuffix(".local")
    }
}

enum PaperGIFPhoneActionMessage {
    static let unavailable = "Not available on the phone"
    static let selectComputer = "Select computer"
    static let computerNotConfigured = "Computer is not configured"
    static let invalidAddress = "Invalid device address"
    static let deviceIDRequired = "Device ID required"
    static let deviceKeyRequired = "Device key required"
    static let invalidPath = "Invalid request path"
    static let invalidMethod = "Invalid HTTP method"
    static let urlTooLong = "Request URL too long"
    static let pageNotFound = "Page not found"
    static let setpointUnavailable = "Setpoint unavailable"
    static let encryptFailed = "Could not encrypt request"
    static let sending = "Sending"
    static let sent = "Sent"
    static let failed = "Request failed"
    static let pageChanged = "Page changed"
}

struct PaperGIFPhoneRemoteSession: Equatable, Sendable {
    var selectedPageID: UUID?
    var toggleOn: [UUID: Bool] = [:]
    var values: [UUID: Int] = [:]
    var valueTenths: [UUID: Int] = [:]
    /// Text, media positions and touch times reported by or sent to the computers.
    var texts: [UUID: String] = [:]
    var timelines: [UUID: PaperGIFPhoneMediaTimeline] = [:]
    var lastInputAt: [UUID: Date] = [:]

    func isOn(_ control: PaperGIFRemoteControl) -> Bool {
        toggleOn[control.id] ?? false
    }

    func value(for control: PaperGIFRemoteControl) -> Int {
        values[control.id] ?? control.action.value
    }

    func tenths(for control: PaperGIFRemoteControl) -> Int {
        valueTenths[control.id] ?? control.action.valueTenths ?? control.action.value * 10
    }
}

struct PaperGIFPhoneSetpointUpdate: Equatable, Sendable {
    var controlID: UUID
    var value: Int
    var valueTenths: Int
}

struct PaperGIFPhoneNetworkRequest: Equatable, Sendable {
    enum Delivery: Equatable, Sendable {
        case immediate
        case paced(key: String)
        case trailing(key: String)
    }

    var url: URL
    var method: String
    var headers: [String: String]
    var body: Data?
    var controlID: UUID
    var delivery: Delivery
    var coalescingKey: String?
    /// OpenBuilds stop. A release must still be sent while another request is in flight.
    var isSafety = false
    var isSlider = false
    var recordsToggle = false
    var toggleOnAfterSuccess = false

    var blocksControl: Bool { delivery == .immediate && !isSafety && !isSlider }
}

struct PaperGIFPhoneActionOutcome: Equatable, Sendable {
    enum Effect: Equatable, Sendable {
        case none
        case navigate(UUID)
        case request(PaperGIFPhoneNetworkRequest)
        case unsupported(String)
        case rejected(String)
    }

    var effect: Effect
    var setpoint: PaperGIFPhoneSetpointUpdate?

    static let none = Self(effect: .none)
    static func unsupported(_ message: String) -> Self { Self(effect: .unsupported(message)) }
    static func rejected(_ message: String) -> Self { Self(effect: .rejected(message)) }
}

enum PaperGIFPhoneActionPhase: Equatable, Sendable {
    case press
    case release
    case slide(Int, final: Bool)
}

/// Latest-value coalescing. Sliders send about every 80 ms; temperature steps trail by 500 ms.
struct PaperGIFPhoneRequestScheduler: Equatable {
    var sliderInterval: TimeInterval = 0.08
    var trailingDelay: TimeInterval = 0.5
    private var lastPacedAt: [String: TimeInterval] = [:]
    private var pending: [String: Pending] = [:]

    struct Pending: Equatable {
        var request: PaperGIFPhoneNetworkRequest
        var due: TimeInterval
    }

    mutating func submit(
        _ request: PaperGIFPhoneNetworkRequest,
        at now: TimeInterval
    ) -> PaperGIFPhoneNetworkRequest? {
        switch request.delivery {
        case .immediate:
            if let key = request.coalescingKey {
                pending[key] = nil
                lastPacedAt[key] = now
            }
            return request
        case .paced(let key):
            if let last = lastPacedAt[key], now - last < sliderInterval {
                pending[key] = Pending(request: request, due: last + sliderInterval)
                return nil
            }
            lastPacedAt[key] = now
            pending[key] = nil
            return request
        case .trailing(let key):
            pending[key] = Pending(request: request, due: now + trailingDelay)
            return nil
        }
    }

    mutating func flush(at now: TimeInterval) -> [PaperGIFPhoneNetworkRequest] {
        pending.keys.filter { pending[$0]?.due ?? .infinity <= now }.sorted().compactMap { key in
            guard let item = pending.removeValue(forKey: key) else { return nil }
            lastPacedAt[key] = now
            return item.request
        }
    }

    mutating func flushAll(at now: TimeInterval) -> [PaperGIFPhoneNetworkRequest] {
        let keys = pending.keys.sorted()
        let requests = keys.compactMap { pending[$0]?.request }
        pending.removeAll()
        for key in keys { lastPacedAt[key] = now }
        return requests
    }
}

enum PaperGIFPhoneActionRunner {
    static func sliderRange(
        for action: PaperGIFRemoteAction,
        unit: PaperGIFTemperatureUnit
    ) -> ClosedRange<Int> {
        switch action.type {
        case .wledBrightness, .computerMedia, .iPhoneMedia:
            return action.type == .wledBrightness || action.text == "volume" || action.text == "seek"
                ? 0...255 : 0...100
        case .wledPreset:
            return 1...250
        case .netHomeTemperature:
            return unit == .celsius ? 16...30 : 61...86
        case .netHomeFan:
            return 0...100
        default:
            return 0...100
        }
    }

    static func adjustedTemperature(
        currentTenths: Int,
        step: Int,
        unit: PaperGIFTemperatureUnit
    ) -> (value: Int, tenths: Int) {
        let current = min(300, max(160, currentTenths))
        let tenths: Int
        if unit == .fahrenheit {
            let currentDisplay = Int((Double(current) * 9 / 50 + 32).rounded())
            let nextDisplay = min(86, max(61, currentDisplay + step))
            let halfSteps = Int((Double(nextDisplay - 32) * 10 / 9).rounded())
            tenths = min(300, max(160, halfSteps * 5))
        } else {
            tenths = min(300, max(160, current + step * 10))
        }
        return (Int((Double(tenths) / 10).rounded()), tenths)
    }

    static func prepare(
        profile: PaperGIFRemoteProfile,
        page: PaperGIFRemotePage,
        control: PaperGIFRemoteControl,
        phase: PaperGIFPhoneActionPhase,
        session: PaperGIFPhoneRemoteSession,
        now: Date = Date(),
        ewelinkIV: Data? = nil,
        ewelinkSequence: String? = nil
    ) -> PaperGIFPhoneActionOutcome {
        switch phase {
        case .release:
            return release(profile: profile, page: page, control: control)
        case .slide(let value, let final):
            return slide(
                profile: profile, page: page, control: control, value: value, final: final,
                session: session
            )
        case .press:
            if control.kind == .textBox {
                return textTap(
                    profile: profile, page: page, control: control, session: session,
                    now: now, ewelinkIV: ewelinkIV, ewelinkSequence: ewelinkSequence
                )
            }
            return fire(
                profile: profile, page: page, control: control, action: control.action,
                session: session, now: now, ewelinkIV: ewelinkIV, ewelinkSequence: ewelinkSequence
            )
        }
    }

    static func isContinuousJog(_ action: PaperGIFRemoteAction, on page: PaperGIFRemotePage) -> Bool {
        preparedOpenBuilds(action, page: page).text.hasPrefix("continuousJog")
    }

    private static func release(
        profile: PaperGIFRemoteProfile,
        page: PaperGIFRemotePage,
        control: PaperGIFRemoteControl
    ) -> PaperGIFPhoneActionOutcome {
        let action = preparedOpenBuilds(control.action, page: page)
        guard action.type == .openBuilds, action.text.hasPrefix("continuousJog") else { return .none }
        var cancel = action
        cancel.text = "cancelJog"
        cancel.value = 0
        cancel.valueTenths = 0
        cancel.modifiers = []
        return companion(
            profile: profile, controlID: control.id, action: cancel, delivery: .immediate,
            isSafety: true
        )
    }

    private static func slide(
        profile: PaperGIFRemoteProfile,
        page: PaperGIFRemotePage,
        control: PaperGIFRemoteControl,
        value: Int,
        final: Bool,
        session: PaperGIFPhoneRemoteSession
    ) -> PaperGIFPhoneActionOutcome {
        guard control.kind == .slider else { return .none }
        let range = sliderRange(for: control.action, unit: profile.temperatureUnit)
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        var action = control.action
        var setpoint: PaperGIFPhoneSetpointUpdate?
        if action.type == .netHomeTemperature {
            let tenths = min(
                300,
                max(160, profile.temperatureUnit.celsiusTenthsValue(displayValue: clamped))
            )
            action.valueTenths = tenths
            action.value = Int((Double(tenths) / 10).rounded())
            setpoint = PaperGIFPhoneSetpointUpdate(
                controlID: control.id, value: action.value, valueTenths: tenths
            )
        } else {
            action.value = clamped
        }
        var outcome = fire(
            profile: profile, page: page, control: control, action: action, session: session,
            now: Date(), ewelinkIV: nil, ewelinkSequence: nil
        )
        guard case .request(var request) = outcome.effect else { return outcome }
        let key = control.id.uuidString
        request.isSlider = true
        request.delivery = final ? .immediate : .paced(key: key)
        request.coalescingKey = key
        outcome.effect = .request(request)
        outcome.setpoint = setpoint
        return outcome
    }

    private static func textTap(
        profile: PaperGIFRemoteProfile,
        page: PaperGIFRemotePage,
        control: PaperGIFRemoteControl,
        session: PaperGIFPhoneRemoteSession,
        now: Date,
        ewelinkIV: Data?,
        ewelinkSequence: String?
    ) -> PaperGIFPhoneActionOutcome {
        switch control.textBox?.tapBehavior {
        case .action:
            guard let action = control.textBox?.tapAction else { return .none }
            return fire(
                profile: profile, page: page, control: control, action: action, session: session,
                now: now, ewelinkIV: ewelinkIV, ewelinkSequence: ewelinkSequence
            )
        case .refresh:
            return .unsupported(PaperGIFPhoneActionMessage.unavailable)
        default:
            return .none
        }
    }

    private static func fire(
        profile: PaperGIFRemoteProfile,
        page: PaperGIFRemotePage,
        control: PaperGIFRemoteControl,
        action: PaperGIFRemoteAction,
        session: PaperGIFPhoneRemoteSession,
        now: Date,
        ewelinkIV: Data?,
        ewelinkSequence: String?
    ) -> PaperGIFPhoneActionOutcome {
        switch action.type {
        case .iPhoneMedia, .iPhoneHomePower, .netHomeAuto:
            return .unsupported(PaperGIFPhoneActionMessage.unavailable)
        case .page:
            guard let id = profile.pages.first(where: {
                $0.id.uuidString.caseInsensitiveCompare(action.text) == .orderedSame
            })?.id else { return .rejected(PaperGIFPhoneActionMessage.pageNotFound) }
            return PaperGIFPhoneActionOutcome(effect: .navigate(id))
        case .netHomeTemperatureStep:
            return temperatureStep(profile: profile, control: control, action: action, session: session)
        case .wledPower, .wledPreset, .wledBrightness:
            return wled(control: control, action: action, session: session)
        case .eWeLinkPower:
            return eWeLink(
                control: control, action: action, session: session, now: now,
                iv: ewelinkIV, sequence: ewelinkSequence
            )
        case .localHTTP:
            return localHTTP(controlID: control.id, action: action)
        case .computerMedia, .computerKey, .computerOpen, .appleShortcut, .computerScript,
             .openBuilds, .netHomePower, .netHomeTemperature, .netHomeMode, .netHomeFan, .module:
            let prepared = action.type == .openBuilds ? preparedOpenBuilds(action, page: page) : action
            return companion(
                profile: profile, controlID: control.id, action: prepared, delivery: .immediate
            )
        }
    }

    private static func temperatureStep(
        profile: PaperGIFRemoteProfile,
        control: PaperGIFRemoteControl,
        action: PaperGIFRemoteAction,
        session: PaperGIFPhoneRemoteSession
    ) -> PaperGIFPhoneActionOutcome {
        guard let setpoint = profile.pages.lazy.flatMap(\.controls).first(where: {
            $0.action.type == .netHomeTemperature &&
                $0.action.host == action.host &&
                ($0.action.computerID ?? "") == (action.computerID ?? "")
        }) else { return .rejected(PaperGIFPhoneActionMessage.setpointUnavailable) }
        let adjusted = adjustedTemperature(
            currentTenths: session.tenths(for: setpoint), step: action.value, unit: profile.temperatureUnit
        )
        var emitted = setpoint.action
        emitted.value = adjusted.value
        emitted.valueTenths = adjusted.tenths
        let key = setpoint.id.uuidString
        var outcome = companion(
            profile: profile, controlID: setpoint.id, action: emitted, delivery: .trailing(key: key)
        )
        guard case .request(var request) = outcome.effect else { return outcome }
        request.coalescingKey = key
        outcome.effect = .request(request)
        outcome.setpoint = PaperGIFPhoneSetpointUpdate(
            controlID: setpoint.id, value: adjusted.value, valueTenths: adjusted.tenths
        )
        return outcome
    }

    private static func wled(
        control: PaperGIFRemoteControl,
        action: PaperGIFRemoteAction,
        session: PaperGIFPhoneRemoteSession
    ) -> PaperGIFPhoneActionOutcome {
        guard let authority = PaperGIFPhoneLocalHTTP.authority(from: action.host) else {
            return .rejected(PaperGIFPhoneActionMessage.invalidAddress)
        }
        let urlString = "http://\(authority)/json/state"
        guard urlString.count <= PaperGIFPhoneLocalHTTP.maximumURLLength,
              let url = URL(string: urlString) else {
            return .rejected(PaperGIFPhoneActionMessage.urlTooLong)
        }
        var payload: [String: Any]
        var recordsToggle = false
        var nextOn = false
        switch action.type {
        case .wledPower:
            if control.isToggle == true {
                nextOn = !session.isOn(control)
                payload = ["on": nextOn]
                recordsToggle = true
            } else if action.text == "on" {
                payload = ["on": true]
            } else if action.text == "off" {
                payload = ["on": false]
            } else {
                payload = ["on": "t"]
            }
        case .wledPreset:
            payload = ["ps": min(250, max(1, action.value))]
        case .wledBrightness:
            payload = ["bri": min(255, max(0, action.value))]
        default:
            return .unsupported(PaperGIFPhoneActionMessage.unavailable)
        }
        guard let body = json(payload) else { return .rejected(PaperGIFPhoneActionMessage.encryptFailed) }
        return PaperGIFPhoneActionOutcome(effect: .request(PaperGIFPhoneNetworkRequest(
            url: url, method: "POST", headers: ["Content-Type": "application/json"], body: body,
            controlID: control.id, delivery: .immediate, coalescingKey: control.id.uuidString,
            recordsToggle: recordsToggle, toggleOnAfterSuccess: nextOn
        )))
    }

    private static func eWeLink(
        control: PaperGIFRemoteControl,
        action: PaperGIFRemoteAction,
        session: PaperGIFPhoneRemoteSession,
        now: Date,
        iv injectedIV: Data?,
        sequence injectedSequence: String?
    ) -> PaperGIFPhoneActionOutcome {
        guard let authority = PaperGIFPhoneLocalHTTP.authority(from: action.host) else {
            return .rejected(PaperGIFPhoneActionMessage.invalidAddress)
        }
        guard let deviceID = action.deviceID, !deviceID.isEmpty else {
            return .rejected(PaperGIFPhoneActionMessage.deviceIDRequired)
        }
        guard let deviceKey = action.deviceKey, !deviceKey.isEmpty else {
            return .rejected(PaperGIFPhoneActionMessage.deviceKeyRequired)
        }
        let urlString = "http://\(authority)/zeroconf/switch"
        guard urlString.count <= PaperGIFPhoneLocalHTTP.maximumURLLength,
              let url = URL(string: urlString) else {
            return .rejected(PaperGIFPhoneActionMessage.urlTooLong)
        }
        let explicitOn = action.text == "on"
        let explicitOff = action.text == "off"
        let turnOn = explicitOn || (!explicitOff && !session.isOn(control))
        guard let encrypted = PaperGIFPhoneEWeLink.encrypt(
            turnOn: turnOn, deviceKey: deviceKey, iv: injectedIV
        ) else { return .rejected(PaperGIFPhoneActionMessage.encryptFailed) }
        let sequence = injectedSequence ?? PaperGIFPhoneEWeLink.sequence(at: now)
        guard let body = json([
            "sequence": sequence,
            "deviceid": deviceID,
            "selfApikey": "123",
            "encrypt": true,
            "iv": encrypted.iv,
            "data": encrypted.data,
        ]) else { return .rejected(PaperGIFPhoneActionMessage.encryptFailed) }
        return PaperGIFPhoneActionOutcome(effect: .request(PaperGIFPhoneNetworkRequest(
            url: url, method: "POST", headers: ["Content-Type": "application/json"], body: body,
            controlID: control.id, delivery: .immediate, coalescingKey: control.id.uuidString,
            recordsToggle: !explicitOn && !explicitOff, toggleOnAfterSuccess: turnOn
        )))
    }

    private static func localHTTP(
        controlID: UUID,
        action: PaperGIFRemoteAction
    ) -> PaperGIFPhoneActionOutcome {
        guard let authority = PaperGIFPhoneLocalHTTP.authority(from: action.host) else {
            return .rejected(PaperGIFPhoneActionMessage.invalidAddress)
        }
        guard PaperGIFPhoneLocalHTTP.isAllowedPath(action.text) else {
            return .rejected(PaperGIFPhoneActionMessage.invalidPath)
        }
        let method = action.httpMethod ?? "GET"
        guard PaperGIFPhoneLocalHTTP.isAllowedMethod(method) else {
            return .rejected(PaperGIFPhoneActionMessage.invalidMethod)
        }
        let urlString = "http://\(authority)\(action.text)"
        guard urlString.count <= PaperGIFPhoneLocalHTTP.maximumURLLength,
              let url = URL(string: urlString) else {
            return .rejected(PaperGIFPhoneActionMessage.urlTooLong)
        }
        let body = method == "POST" ? action.httpBody?.data(using: .utf8) : nil
        return PaperGIFPhoneActionOutcome(effect: .request(PaperGIFPhoneNetworkRequest(
            url: url, method: method, headers: [:], body: body, controlID: controlID,
            delivery: .immediate, coalescingKey: controlID.uuidString
        )))
    }

    private static func companion(
        profile: PaperGIFRemoteProfile,
        controlID: UUID,
        action: PaperGIFRemoteAction,
        delivery: PaperGIFPhoneNetworkRequest.Delivery,
        isSafety: Bool = false,
        isSlider: Bool = false
    ) -> PaperGIFPhoneActionOutcome {
        guard let destination = PaperGIFRelayForwarder.destination(
            for: action.computerID ?? "", in: profile
        ) else { return .rejected(PaperGIFPhoneActionMessage.selectComputer) }
        var payload: [String: Any] = [
            "type": action.type.rawValue,
            "host": action.host,
            "text": action.text,
            "value": action.value,
            "modifiers": action.modifiers,
        ]
        if action.type == .netHomeTemperature || action.type == .openBuilds {
            payload["valueTenths"] = action.valueTenths ?? action.value * 10
        }
        guard let body = json(payload),
              !destination.token.isEmpty,
              let urlRequest = PaperGIFRelayForwarder.request(for: body, to: destination),
              let url = urlRequest.url else {
            return .rejected(PaperGIFPhoneActionMessage.computerNotConfigured)
        }
        return PaperGIFPhoneActionOutcome(effect: .request(PaperGIFPhoneNetworkRequest(
            url: url, method: "POST", headers: urlRequest.allHTTPHeaderFields ?? [:], body: body,
            controlID: controlID, delivery: delivery, coalescingKey: controlID.uuidString,
            isSafety: isSafety, isSlider: isSlider
        )))
    }

    static func preparedOpenBuilds(
        _ action: PaperGIFRemoteAction,
        page: PaperGIFRemotePage
    ) -> PaperGIFRemoteAction {
        guard action.type == .openBuilds, let controller = page.openBuildsController else { return action }
        var action = action
        action.host = controller.host
        let incremental = action.text.hasPrefix("jog")
        let continuous = action.text.hasPrefix("continuousJog")
        guard incremental || continuous else { return action }
        if controller.jogMode == .continuous && incremental {
            action.text = "continuousJog" + action.text.dropFirst(3)
        } else if controller.jogMode == .incremental && continuous {
            action.text = "jog" + action.text.dropFirst(13)
        }
        action.valueTenths = controller.jogDistanceTenths
        action.value = controller.jogMode == .continuous
            ? controller.jogSpeed
            : max(1, (controller.jogDistanceThousandths + 500) / 1_000)
        action.modifiers = [
            "feed=\(controller.jogSpeed)",
            "units=\(controller.units.rawValue)",
            "dist=\(controller.jogDistanceThousandths)",
        ]
        return action
    }

    private static func json(_ object: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        return try? JSONSerialization.data(withJSONObject: object)
    }
}

enum PaperGIFPhoneEWeLink {
    static func sequence(at date: Date) -> String {
        let millis = UInt64(max(0, (date.timeIntervalSince1970 * 1_000).rounded()))
        return String(format: "%010llu%03llu", millis / 1_000, millis % 1_000)
    }

    static func encrypt(
        turnOn: Bool,
        deviceKey: String,
        iv injectedIV: Data? = nil
    ) -> (data: String, iv: String)? {
        let iv: Data
        if let injectedIV {
            guard injectedIV.count == 16 else { return nil }
            iv = injectedIV
        } else {
            var random = Data(count: 16)
            let status = random.withUnsafeMutableBytes {
                SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
            }
            guard status == errSecSuccess else { return nil }
            iv = random
        }
        let plaintext = Data(#"{"switch":"\#(turnOn ? "on" : "off")"}"#.utf8)
        let digest = Insecure.MD5.hash(data: Data(deviceKey.utf8))
        let key = Data(digest)
        var output = Data(count: plaintext.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        let written = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        written.initialize(to: 0)
        defer {
            written.deinitialize(count: 1)
            written.deallocate()
        }
        let status: CCCryptorStatus = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                plaintext.withUnsafeBytes { plainBytes in
                    output.withUnsafeMutableBytes { outputBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                            plainBytes.baseAddress, plaintext.count,
                            outputBytes.baseAddress, outputCapacity, written
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        output.removeSubrange(written.pointee..<output.count)
        return (
            output.base64EncodedString(),
            iv.base64EncodedString()
        )
    }
}

enum PaperGIFPhoneTextRenderer {
    static func text(
        for control: PaperGIFRemoteControl,
        profile: PaperGIFRemoteProfile,
        session: PaperGIFPhoneRemoteSession,
        now: Date,
        calendar: Calendar = .current
    ) -> String {
        guard let box = control.textBox else { return control.title }
        switch box.source {
        case .staticText:
            return box.sourceText
        case .dateTime:
            return dateText(box.dateFormat, date: now, calendar: calendar)
        case .controlValue:
            return controlValue(id: box.referencedControlID, profile: profile, session: session)
                ?? box.placeholder
        case .computerScript, .appleShortcut, .nowPlaying, .openBuildsPosition:
            return session.texts[control.id] ?? box.placeholder
        }
    }

    static func dateText(_ format: String, date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents(
            [.year, .month, .day, .weekday, .hour, .minute, .second], from: date
        )
        let month = min(12, max(1, parts.month ?? 1))
        let weekday = min(7, max(1, parts.weekday ?? 1)) - 1
        let hour = parts.hour ?? 0
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        var output = ""
        var index = format.startIndex
        while index < format.endIndex && output.count < 192 {
            if format[index] != "%" {
                output.append(format[index])
                index = format.index(after: index)
                continue
            }
            let tokenIndex = format.index(after: index)
            guard tokenIndex < format.endIndex else {
                output.append("%")
                break
            }
            switch format[tokenIndex] {
            case "%": output.append("%")
            case "Y": output += padded(parts.year ?? 0, width: 4)
            case "y": output += padded((parts.year ?? 0) % 100, width: 2)
            case "m": output += padded(month, width: 2)
            case "b": output += shortMonths[month - 1]
            case "B": output += longMonths[month - 1]
            case "d": output += padded(parts.day ?? 0, width: 2)
            case "e": output += padded(parts.day ?? 0, width: 2, pad: " ")
            case "a": output += shortWeekdays[weekday]
            case "A": output += longWeekdays[weekday]
            case "H": output += padded(hour, width: 2)
            case "I": output += padded(twelve, width: 2)
            case "M": output += padded(parts.minute ?? 0, width: 2)
            case "S": output += padded(parts.second ?? 0, width: 2)
            case "p": output += hour < 12 ? "AM" : "PM"
            default:
                output.append("%")
                output.append(format[tokenIndex])
            }
            index = format.index(after: tokenIndex)
        }
        return output
    }

    private static func controlValue(
        id: UUID?,
        profile: PaperGIFRemoteProfile,
        session: PaperGIFPhoneRemoteSession
    ) -> String? {
        guard let id, let referenced = profile.pages.lazy.flatMap(\.controls).first(where: { $0.id == id }) else {
            return nil
        }
        switch referenced.action.type {
        case .netHomeTemperature:
            let display = profile.temperatureUnit.displayValue(celsiusTenths: session.tenths(for: referenced))
            return "\(display) \(profile.temperatureUnit == .fahrenheit ? "F" : "C")"
        case .netHomeFan:
            return "\(session.value(for: referenced))%"
        default:
            if referenced.kind == .slider { return String(session.value(for: referenced)) }
            return session.isOn(referenced) ? "On" : "Off"
        }
    }

    private static func padded(_ value: Int, width: Int, pad: Character = "0") -> String {
        let digits = String(value)
        return String(repeating: pad, count: max(0, width - digits.count)) + digits
    }

    private static let shortMonths = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]
    private static let longMonths = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]
    private static let shortWeekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let longWeekdays = [
        "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
    ]
}

enum PaperGIFPhoneRequestSender {
    static func send(_ request: PaperGIFPhoneNetworkRequest) async -> Bool {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: 5)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (field, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        do {
            let status = try await PaperGIFRelayForwarder.sendOverLAN(urlRequest)
            return (200..<300).contains(status)
        } catch {
            return false
        }
    }
}
