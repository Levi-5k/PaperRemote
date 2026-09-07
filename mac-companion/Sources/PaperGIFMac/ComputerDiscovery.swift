import Combine
@preconcurrency import Foundation

private struct SendableNetService: @unchecked Sendable {
    let value: NetService
}

private struct SendableNetServiceBrowser: @unchecked Sendable {
    let value: NetServiceBrowser
}

@MainActor
final class ComputerDiscovery: NSObject, ObservableObject {
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
    private var timeoutTask: Task<Void, Never>?

    func start() {
        stop()
        computers = []
        state = .searching
        let browser = NetServiceBrowser()
        browser.delegate = self
        browser.includesPeerToPeer = true
        browser.searchForServices(ofType: "_papergif._tcp.", inDomain: "local.")
        self.browser = browser
        timeoutTask = Task { [weak self] in
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
        timeoutTask?.cancel()
        timeoutTask = nil
        if state == .searching { state = .idle }
    }

    private func key(for service: NetService) -> String {
        "\(service.name).\(service.type).\(service.domain)"
    }
}

extension ComputerDiscovery: NetServiceBrowserDelegate {
    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        let sendableBrowser = SendableNetServiceBrowser(value: browser)
        let sendable = SendableNetService(value: service)
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
        let sendableBrowser = SendableNetServiceBrowser(value: browser)
        let sendable = SendableNetService(value: service)
        Task { @MainActor [weak self] in
            guard let self, self.browser === sendableBrowser.value else { return }
            let service = sendable.value
            services.removeValue(forKey: key(for: service))
            computers.removeAll { $0.name == service.name }
        }
    }

    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didNotSearch errorDict: [String: NSNumber]
    ) {
        let sendableBrowser = SendableNetServiceBrowser(value: browser)
        Task { @MainActor [weak self] in
            guard let self, self.browser === sendableBrowser.value else { return }
            self.state = .failed("Computer search failed. Check Local Network access.")
        }
    }
}

extension ComputerDiscovery: NetServiceDelegate {
    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        let sendable = SendableNetService(value: sender)
        Task { @MainActor [weak self] in
            let sender = sendable.value
            guard let self,
                services[key(for: sender)] === sender,
                  let host = sender.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
                  !host.isEmpty,
                  sender.port > 0 else { return }
            services.removeValue(forKey: key(for: sender))
            sender.stop()
            sender.delegate = nil
            let computer = Computer(name: sender.name, host: host, port: sender.port)
            computers.removeAll { $0.id == computer.id || $0.name == computer.name }
            computers.append(computer)
            computers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            timeoutTask?.cancel()
            timeoutTask = nil
            state = .ready
        }
    }

    nonisolated func netService(
        _ sender: NetService,
        didNotResolve errorDict: [String: NSNumber]
    ) {
        let sendable = SendableNetService(value: sender)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let sender = sendable.value
            guard services[key(for: sender)] === sender else { return }
            services.removeValue(forKey: key(for: sender))
            sender.stop()
            sender.delegate = nil
            if services.isEmpty && computers.isEmpty {
                state = .failed("Found \(sender.name), but could not resolve its address.")
            }
        }
    }
}