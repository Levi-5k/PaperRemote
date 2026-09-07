import Combine
import Darwin
@preconcurrency import Foundation

private struct SendableNetService: @unchecked Sendable {
    let value: NetService
}

private struct SendableNetServiceBrowser: @unchecked Sendable {
    let value: NetServiceBrowser
}

@MainActor
final class PaperGIFComputerDiscovery: NSObject, ObservableObject {
    struct Computer: Identifiable, Equatable, Sendable {
        let name: String
        let host: String
        let port: Int

        var id: String { "\(host):\(port)" }
    }

    enum State: Equatable {
        case idle
        case searching
        case ready
        case failed(String)
    }

    @Published private(set) var computers: [Computer] = []
    @Published private(set) var state = State.idle

    private var browser: NetServiceBrowser?
    private var services: [String: NetService] = [:]
    private var searchTimeoutTask: Task<Void, Never>?

    func start() {
        stop()
        computers = []
        state = .searching

        let browser = NetServiceBrowser()
        browser.delegate = self
        browser.includesPeerToPeer = true
        browser.searchForServices(ofType: "_papergif._tcp.", inDomain: "local.")
        self.browser = browser

        searchTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, let self, self.state == .searching else { return }
            self.state = .ready
        }
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
        searchTimeoutTask?.cancel()
        searchTimeoutTask = nil
        if state == .searching {
            state = .idle
        }
    }

    private func serviceKey(_ service: NetService) -> String {
        "\(service.name).\(service.type).\(service.domain)"
    }

    private static func resolvedHost(for service: NetService) -> String? {
        if let address = service.addresses?.compactMap(numericIPv4Host).first {
            return address
        }
        return service.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private static func numericIPv4Host(from data: Data) -> String? {
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return nil }
            let address = baseAddress.assumingMemoryBound(to: sockaddr.self)
            guard Int32(address.pointee.sa_family) == AF_INET else { return nil }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let hostCapacity = socklen_t(host.count)
            guard getnameinfo(
                address,
                socklen_t(data.count),
                &host,
                hostCapacity,
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { return nil }
            return String(cString: host)
        }
    }
}

extension PaperGIFComputerDiscovery: NetServiceBrowserDelegate {
    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        let sendableBrowser = SendableNetServiceBrowser(value: browser)
        let sendableService = SendableNetService(value: service)
        Task { @MainActor [weak self] in
            guard let self, self.browser === sendableBrowser.value else { return }
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
        let sendableBrowser = SendableNetServiceBrowser(value: browser)
        let sendableService = SendableNetService(value: service)
        Task { @MainActor [weak self] in
            guard let self, self.browser === sendableBrowser.value else { return }
            let service = sendableService.value
            self.services.removeValue(forKey: self.serviceKey(service))
            self.computers.removeAll { $0.name == service.name }
        }
    }

    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didNotSearch errorDict: [String: NSNumber]
    ) {
        let sendableBrowser = SendableNetServiceBrowser(value: browser)
        Task { @MainActor [weak self] in
            guard let self, self.browser === sendableBrowser.value else { return }
            self.state = .failed("Computer search failed. Check Local Network access in Settings.")
        }
    }
}

extension PaperGIFComputerDiscovery: NetServiceDelegate {
    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        let sendableService = SendableNetService(value: sender)
        Task { @MainActor [weak self] in
            let sender = sendableService.value
            guard let self,
                self.services[self.serviceKey(sender)] === sender,
                                    let host = Self.resolvedHost(for: sender),
                                    !host.isEmpty,
                  sender.port > 0 else { return }
            self.services.removeValue(forKey: self.serviceKey(sender))
            sender.stop()
            sender.delegate = nil
            let computer = Computer(name: sender.name, host: host, port: sender.port)
            self.computers.removeAll { $0.id == computer.id || $0.name == computer.name }
            self.computers.append(computer)
            self.computers.sort {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            self.searchTimeoutTask?.cancel()
            self.searchTimeoutTask = nil
            self.state = .ready
        }
    }

    nonisolated func netService(
        _ sender: NetService,
        didNotResolve errorDict: [String: NSNumber]
    ) {
        let sendableService = SendableNetService(value: sender)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let sender = sendableService.value
            guard self.services[self.serviceKey(sender)] === sender else { return }
            self.services.removeValue(forKey: self.serviceKey(sender))
            sender.stop()
            sender.delegate = nil
            if self.services.isEmpty && self.computers.isEmpty {
                self.state = .failed("Found \(sender.name), but couldn’t resolve its address.")
            }
        }
    }
}
