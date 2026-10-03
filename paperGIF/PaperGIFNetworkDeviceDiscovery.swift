import Combine
import Darwin
@preconcurrency import Foundation

private struct SendableNetworkService: @unchecked Sendable {
    let value: NetService
}

private struct SendableNetworkServiceBrowser: @unchecked Sendable {
    let value: NetServiceBrowser
}

@MainActor
final class PaperGIFNetworkDeviceDiscovery: NSObject, ObservableObject {
    enum Kind: String, Sendable {
        case http = "HTTP device"
        case eWeLink = "eWeLink plug"
        case shellyGen1 = "Shelly Gen 1"
        case shellyGen2 = "Shelly Gen 2+"

        var isShelly: Bool { self == .shellyGen1 || self == .shellyGen2 }
        var isEWeLink: Bool { self == .eWeLink }
    }

    struct Device: Identifiable, Equatable, Sendable {
        let serviceName: String
        let name: String
        let host: String
        let port: Int
        let kind: Kind
        let deviceID: String?
        let requiresDeviceKey: Bool

        init(
            serviceName: String,
            name: String,
            host: String,
            port: Int,
            kind: Kind,
            deviceID: String? = nil,
            requiresDeviceKey: Bool = false
        ) {
            self.serviceName = serviceName
            self.name = name
            self.host = host
            self.port = port
            self.kind = kind
            self.deviceID = deviceID
            self.requiresDeviceKey = requiresDeviceKey
        }

        var id: String { "\(host.lowercased()):\(port)" }
        var actionHost: String { port == 80 ? host : "\(host):\(port)" }
        var togglePath: String {
            switch kind {
            case .shellyGen1: "/relay/0?turn=toggle"
            case .shellyGen2: "/rpc/Switch.Toggle?id=0"
            case .http, .eWeLink: "/"
            }
        }
    }

    enum State: Equatable {
        case idle
        case searching
        case ready
        case failed(String)
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var state = State.idle

    private var browsers: [NetServiceBrowser] = []
    private var services: [String: NetService] = [:]
    private var searchTimeoutTask: Task<Void, Never>?

    func start() {
        stop()
        devices = []
        state = .searching

        for type in ["_shelly._tcp.", "_ewelink._tcp.", "_http._tcp."] {
            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.includesPeerToPeer = true
            browser.searchForServices(ofType: type, inDomain: "local.")
            browsers.append(browser)
        }

        searchTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(7))
            guard !Task.isCancelled, let self, self.state == .searching else { return }
            self.state = .ready
        }
    }

    func stop() {
        browsers.forEach {
            $0.stop()
            $0.delegate = nil
        }
        browsers = []
        services.values.forEach {
            $0.stop()
            $0.delegate = nil
        }
        services = [:]
        searchTimeoutTask?.cancel()
        searchTimeoutTask = nil
        if state == .searching {
            state = .idle
        }
    }

    private func serviceKey(_ service: NetService) -> String {
        "\(service.name).\(service.type).\(service.domain)"
    }

    private func addResolvedService(_ service: NetService) {
        guard let host = Self.resolvedHost(for: service), service.port > 0 else { return }
        let txt = Self.txtValues(for: service)
        let kind = Self.initialKind(for: service)
        let candidate = Device(
            serviceName: service.name,
            name: service.name,
            host: host,
            port: service.port,
            kind: kind,
            deviceID: kind.isEWeLink ? txt["id"] : nil,
            requiresDeviceKey: kind.isEWeLink && txt["encrypt"] == "true"
        )
        Task {
            let device = await Self.identify(candidate)
            if let existing = devices.firstIndex(where: { $0.id == device.id }) {
                if devices[existing].kind == .http || device.kind.isShelly {
                    devices[existing] = device
                }
            } else {
                devices.append(device)
            }
            devices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            searchTimeoutTask?.cancel()
            searchTimeoutTask = nil
            state = .ready
        }
    }

    nonisolated private static func initialKind(for service: NetService) -> Kind {
        let identity = "\(service.name) \(service.type)".lowercased()
        if identity.contains("ewelink") { return .eWeLink }
        return identity.contains("shelly") ? .shellyGen1 : .http
    }

    nonisolated private static func identify(_ device: Device) async -> Device {
        guard !device.kind.isEWeLink else { return device }
        if let info = await json(host: device.host, port: device.port, path: "/rpc/Shelly.GetDeviceInfo") {
            let name = string(info["name"]) ?? string(info["id"]) ?? device.name
            return Device(
                serviceName: device.serviceName,
                name: name,
                host: device.host,
                port: device.port,
                kind: .shellyGen2
            )
        }
        if let info = await json(host: device.host, port: device.port, path: "/shelly") {
            let name = string(info["name"]) ?? string(info["type"]) ?? device.name
            return Device(
                serviceName: device.serviceName,
                name: name,
                host: device.host,
                port: device.port,
                kind: .shellyGen1
            )
        }
        return device
    }

    nonisolated private static func txtValues(for service: NetService) -> [String: String] {
        guard let data = service.txtRecordData() else { return [:] }
        return NetService.dictionary(fromTXTRecord: data).reduce(into: [:]) { result, item in
            guard let value = String(data: item.value, encoding: .utf8) else { return }
            result[item.key.lowercased()] = value
        }
    }

    nonisolated private static func json(
        host: String,
        port: Int,
        path: String
    ) async -> [String: Any]? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = path
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        guard let (data, response) = try? await URLSession(configuration: configuration).data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    nonisolated private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated private static func resolvedHost(for service: NetService) -> String? {
        if let address = service.addresses?.compactMap(numericIPv4Host).first {
            return address
        }
        return service.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    nonisolated private static func numericIPv4Host(from data: Data) -> String? {
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return nil }
            let address = baseAddress.assumingMemoryBound(to: sockaddr.self)
            guard Int32(address.pointee.sa_family) == AF_INET else { return nil }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                address,
                socklen_t(data.count),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { return nil }
            return String(cString: host)
        }
    }
}

extension PaperGIFNetworkDeviceDiscovery: NetServiceBrowserDelegate {
    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        let sendableBrowser = SendableNetworkServiceBrowser(value: browser)
        let sendableService = SendableNetworkService(value: service)
        Task { @MainActor [weak self] in
            guard let self, self.browsers.contains(where: { $0 === sendableBrowser.value }) else { return }
            let service = sendableService.value
            self.services[self.serviceKey(service)] = service
            service.delegate = self
            service.resolve(withTimeout: 5)
        }
    }

    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        let sendableService = SendableNetworkService(value: service)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let service = sendableService.value
            self.services.removeValue(forKey: self.serviceKey(service))
            self.devices.removeAll { $0.serviceName == service.name }
        }
    }

    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didNotSearch errorDict: [String: NSNumber]
    ) {
        Task { @MainActor [weak self] in
            self?.state = .failed("Network device search failed. Check Local Network access in Settings.")
        }
    }
}

extension PaperGIFNetworkDeviceDiscovery: NetServiceDelegate {
    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        let sendableService = SendableNetworkService(value: sender)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let service = sendableService.value
            guard self.services[self.serviceKey(service)] === service else { return }
            self.services.removeValue(forKey: self.serviceKey(service))
            service.stop()
            service.delegate = nil
            self.addResolvedService(service)
        }
    }

    nonisolated func netService(
        _ sender: NetService,
        didNotResolve errorDict: [String: NSNumber]
    ) {
        let sendableService = SendableNetworkService(value: sender)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let service = sendableService.value
            self.services.removeValue(forKey: self.serviceKey(service))
            service.stop()
            service.delegate = nil
        }
    }
}