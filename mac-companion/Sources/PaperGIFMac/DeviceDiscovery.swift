import Combine
import Darwin
@preconcurrency import Foundation

private struct SendableDeviceService: @unchecked Sendable {
    let value: NetService
}

private struct SendableDeviceBrowser: @unchecked Sendable {
    let value: NetServiceBrowser
}

@MainActor
final class DeviceDiscovery: NSObject, ObservableObject {
    struct Device: Identifiable, Equatable, Sendable {
        let name: String
        let host: String
        let port: Int

        var id: String { "\(host):\(port)" }
        var address: String { port == 80 ? host : "\(host):\(port)" }
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var isScanning = false
    @Published private(set) var scanMessage: String?

    nonisolated private static let maximumConcurrentProbes = 64
    nonisolated private static let maximumSweepHosts = 1_024

    private var browser: NetServiceBrowser?
    private var services: [String: NetService] = [:]
    private var bonjourDeviceIDs: Set<String> = []
    private var scanTask: Task<Void, Never>?

    func start(preferredAddress: String? = nil) {
        stop()
        devices = []
        bonjourDeviceIDs = []
        let browser = NetServiceBrowser()
        browser.delegate = self
        browser.includesPeerToPeer = true
        browser.searchForServices(ofType: "_papergif-device._tcp.", inDomain: "local.")
        self.browser = browser
        scan(preferredAddress: preferredAddress)
    }

    func stop() {
        browser?.stop()
        browser?.delegate = nil
        browser = nil
        services.values.forEach {
            $0.stop()
            $0.delegate = nil
        }
        services = [:]
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    /// Probes the saved address and every host on the local IPv4 subnets for a paperGIF `/status` reply.
    func scan(preferredAddress: String?) {
        scanTask?.cancel()
        isScanning = true
        scanMessage = nil
        scanTask = Task { [weak self] in
            let found = await Self.probeNetwork(preferredAddress: preferredAddress)
            guard !Task.isCancelled, let self else { return }
            self.finishScan(found)
        }
    }

    private func finishScan(_ found: [Device]) {
        let foundIDs = Set(found.map(\.id))
        devices.removeAll { !bonjourDeviceIDs.contains($0.id) && !foundIDs.contains($0.id) }
        for device in found where !devices.contains(where: { $0.id == device.id }) {
            devices.append(device)
        }
        devices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        scanTask = nil
        isScanning = false
        scanMessage = devices.isEmpty
            ? "No M5Paper found. Wake it and make sure it is on this Mac's network."
            : nil
    }

    private func key(for service: NetService) -> String {
        "\(service.name).\(service.type).\(service.domain)"
    }

    nonisolated static func isPaperGIFStatus(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["device"] as? String == "paperGIF"
    }

    /// Host addresses (host byte order) on an interface's subnet, limited to its surrounding /24.
    nonisolated static func sweepHosts(address: UInt32, netmask: UInt32) -> [UInt32] {
        let mask = netmask | 0xFFFF_FF00
        let network = address & mask
        let broadcast = network | ~mask
        guard broadcast > network &+ 1 else { return [] }
        return ((network + 1)..<broadcast).filter { $0 != address }
    }

    nonisolated private static func localSweepHosts() -> [String] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(interfaces) }
        var hosts: [String] = []
        var seen = Set<UInt32>()
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard flags & (IFF_UP | IFF_RUNNING) == (IFF_UP | IFF_RUNNING),
                  flags & (IFF_LOOPBACK | IFF_POINTOPOINT) == 0,
                  let address = entry.ifa_addr, let netmask = entry.ifa_netmask,
                  address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let hostAddress = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let hostMask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            guard hostAddress >> 16 != 0xA9FE else { continue }
            for host in sweepHosts(address: hostAddress, netmask: hostMask) where seen.insert(host).inserted {
                guard hosts.count < maximumSweepHosts else { return hosts }
                hosts.append("\(host >> 24).\((host >> 16) & 0xFF).\((host >> 8) & 0xFF).\(host & 0xFF)")
            }
        }
        return hosts
    }

    nonisolated private static func probeNetwork(preferredAddress: String?) async -> [Device] {
        var candidates = localSweepHosts()
        if let preferred = preferredHost(from: preferredAddress) {
            candidates.removeAll { $0 == preferred }
            candidates.insert(preferred, at: 0)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1.5
        configuration.timeoutIntervalForResource = 2
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 1
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        return await withTaskGroup(of: Device?.self) { group in
            var pending = candidates.makeIterator()
            for _ in 0..<maximumConcurrentProbes {
                guard let host = pending.next() else { break }
                group.addTask { await probe(host, session: session) }
            }
            var found: [Device] = []
            while let result = await group.next() {
                if let result, !found.contains(where: { $0.id == result.id }) {
                    found.append(result)
                }
                if !Task.isCancelled, let host = pending.next() {
                    group.addTask { await probe(host, session: session) }
                }
            }
            return found
        }
    }

    nonisolated private static func preferredHost(from address: String?) -> String? {
        let trimmed = address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed.contains("://") ? trimmed : "http://\(trimmed)"),
              let host = components.host, !host.isEmpty else { return nil }
        return host
    }

    nonisolated private static func probe(_ host: String, session: URLSession) async -> Device? {
        guard let ipv4 = await resolvedIPv4(host) else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = ipv4
        components.path = "/status"
        guard let url = components.url,
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              isPaperGIFStatus(data) else { return nil }
        return Device(name: "M5Paper \(ipv4)", host: ipv4, port: 80)
    }

    nonisolated private static func resolvedIPv4(_ host: String) async -> String? {
        var parsed = in_addr()
        if inet_pton(AF_INET, host, &parsed) == 1 { return host }
        return await Task.detached {
            var hints = addrinfo()
            hints.ai_family = AF_INET
            hints.ai_socktype = SOCK_STREAM
            var results: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &results) == 0, let results else { return nil }
            defer { freeaddrinfo(results) }
            guard let address = results.pointee.ai_addr else { return nil }
            return ipv4Address(from: [Data(bytes: address, count: Int(results.pointee.ai_addrlen))])
        }.value
    }

    nonisolated static func ipv4Address(from addresses: [Data]?) -> String? {
        for data in addresses ?? [] {
            let address = data.withUnsafeBytes { buffer -> String? in
                guard let baseAddress = buffer.baseAddress,
                      buffer.count >= MemoryLayout<sockaddr>.size else { return nil }
                let socketAddress = baseAddress.assumingMemoryBound(to: sockaddr.self)
                guard socketAddress.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(
                    socketAddress,
                    socklen_t(buffer.count),
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                ) == 0 else { return nil }
                return String(cString: host)
            }
            if let address {
                return address
            }
        }
        return nil
    }
}

extension DeviceDiscovery: NetServiceBrowserDelegate {
    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        let sendableBrowser = SendableDeviceBrowser(value: browser)
        let sendable = SendableDeviceService(value: service)
        Task { @MainActor [weak self] in
            guard let self, self.browser === sendableBrowser.value else { return }
            let service = sendable.value
            services[key(for: service)] = service
            service.delegate = self
            service.resolve(withTimeout: 5)
        }
    }

    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        let sendableBrowser = SendableDeviceBrowser(value: browser)
        let sendable = SendableDeviceService(value: service)
        Task { @MainActor [weak self] in
            guard let self, self.browser === sendableBrowser.value else { return }
            let service = sendable.value
            services.removeValue(forKey: key(for: service))
            for device in devices where device.name == service.name {
                bonjourDeviceIDs.remove(device.id)
            }
            devices.removeAll { $0.name == service.name }
        }
    }
}

extension DeviceDiscovery: NetServiceDelegate {
    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        let sendable = SendableDeviceService(value: sender)
        Task { @MainActor [weak self] in
            let sender = sendable.value
            guard let self,
                services[key(for: sender)] === sender,
                  sender.port > 0 else { return }
            let resolvedHost = sender.hostName?.trimmingCharacters(
                in: CharacterSet(charactersIn: ".")
            )
            guard let host = Self.ipv4Address(from: sender.addresses) ?? resolvedHost,
                  !host.isEmpty else { return }
            services.removeValue(forKey: key(for: sender))
            sender.stop()
            sender.delegate = nil
            let device = Device(name: sender.name, host: host, port: sender.port)
            devices.removeAll { $0.id == device.id || $0.name == device.name }
            devices.append(device)
            bonjourDeviceIDs.insert(device.id)
            devices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            scanMessage = nil
        }
    }

    nonisolated func netService(
        _ sender: NetService,
        didNotResolve errorDict: [String: NSNumber]
    ) {
        let sendable = SendableDeviceService(value: sender)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let sender = sendable.value
            guard services[key(for: sender)] === sender else { return }
            services.removeValue(forKey: key(for: sender))
            sender.stop()
            sender.delegate = nil
        }
    }
}