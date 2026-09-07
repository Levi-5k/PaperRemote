import Combine
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

    private var browser: NetServiceBrowser?
    private var services: [String: NetService] = [:]

    func start() {
        stop()
        devices = []
        let browser = NetServiceBrowser()
        browser.delegate = self
        browser.includesPeerToPeer = true
        browser.searchForServices(ofType: "_papergif-device._tcp.", inDomain: "local.")
        self.browser = browser
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
    }

    private func key(for service: NetService) -> String {
        "\(service.name).\(service.type).\(service.domain)"
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
                  let host = sender.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
                  !host.isEmpty,
                  sender.port > 0 else { return }
            services.removeValue(forKey: key(for: sender))
            sender.stop()
            sender.delegate = nil
            let device = Device(name: sender.name, host: host, port: sender.port)
            devices.removeAll { $0.id == device.id || $0.name == device.name }
            devices.append(device)
            devices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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