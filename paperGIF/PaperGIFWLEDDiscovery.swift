import Combine
import Foundation
import Network

@MainActor
final class PaperGIFWLEDDiscovery: ObservableObject {
    struct Device: Identifiable, Equatable, Sendable {
        let serviceName: String
        let name: String
        let host: String
        let port: Int
        let macAddress: String

        var id: String { macAddress.isEmpty ? "\(host):\(port)" : macAddress }
        var actionHost: String { port == 80 ? host : "\(host):\(port)" }
    }

    struct Preset: Identifiable, Equatable, Sendable {
        let id: Int
        let name: String
    }

    enum State: Equatable {
        case idle
        case searching
        case ready
        case failed(String)
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var state = State.idle
    @Published private(set) var presetsByHost: [String: [Preset]] = [:]
    @Published private(set) var loadingPresetHosts: Set<String> = []
    @Published private(set) var presetErrorsByHost: [String: String] = [:]

    private var browser: NWBrowser?
    private var verificationTasks: [String: Task<Void, Never>] = [:]
    private var scanTimeoutTask: Task<Void, Never>?
    private let queue = DispatchQueue(label: "paperGIF.wled-discovery")

    func start() {
        stop()
        devices = []
        state = .searching

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: "_wled._tcp", domain: nil),
            using: parameters
        )
        browser.stateUpdateHandler = { state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    break
                case .failed(let error):
                    self.state = .failed("WLED scan failed: \(error.localizedDescription)")
                case .cancelled:
                    if self.state == .searching {
                        self.state = .idle
                    }
                default:
                    break
                }
            }
        }
        browser.browseResultsChangedHandler = { results, _ in
            Task { @MainActor [weak self] in
                self?.resolve(results)
            }
        }
        browser.start(queue: queue)
        self.browser = browser
        scanTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, let self, self.state == .searching else { return }
            self.state = .ready
        }
    }

    func stop() {
        browser?.cancel()
        browser = nil
        verificationTasks.values.forEach { $0.cancel() }
        verificationTasks = [:]
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        if state == .searching {
            state = .idle
        }
    }

    private func resolve(_ results: Set<NWBrowser.Result>) {
        let discoveredDevices = results.compactMap(Self.device(from:))
        let serviceNames = Set(discoveredDevices.map(\.serviceName))
        devices.removeAll { !serviceNames.contains($0.serviceName) }
        let removedServiceNames = verificationTasks.keys.filter { !serviceNames.contains($0) }
        for serviceName in removedServiceNames {
            verificationTasks[serviceName]?.cancel()
            verificationTasks.removeValue(forKey: serviceName)
        }

        for device in discoveredDevices {
            if !devices.contains(where: { $0.serviceName == device.serviceName }) {
                devices.append(device)
            }
            guard verificationTasks[device.serviceName] == nil else { continue }
            verificationTasks[device.serviceName] = Task { [weak self] in
                guard let self else { return }
                let verifiedDevice = await self.verify(device)
                guard !Task.isCancelled else { return }
                self.finishVerification(device.serviceName, with: verifiedDevice)
            }
        }
        devices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if !devices.isEmpty {
            scanTimeoutTask?.cancel()
            scanTimeoutTask = nil
            state = .ready
        }
    }

    func device(at address: String) async throws -> Device {
        let candidate = try Self.manualDevice(from: address)
        guard let verifiedDevice = await verify(candidate) else {
            throw DiscoveryError.unreachable(candidate.actionHost)
        }
        devices.removeAll { $0.id == verifiedDevice.id || $0.actionHost == verifiedDevice.actionHost }
        devices.append(verifiedDevice)
        devices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        state = .ready
        return verifiedDevice
    }

    func presets(for device: Device) -> [Preset] {
        presetsByHost[Self.normalizedHost(device.actionHost)] ?? []
    }

    func isLoadingPresets(for device: Device) -> Bool {
        loadingPresetHosts.contains(Self.normalizedHost(device.actionHost))
    }

    func presetError(for device: Device) -> String? {
        presetErrorsByHost[Self.normalizedHost(device.actionHost)]
    }

    func loadPresets(for device: Device, force: Bool = false) async {
        let hostKey = Self.normalizedHost(device.actionHost)
        guard !loadingPresetHosts.contains(hostKey),
              force || presetsByHost[hostKey] == nil else { return }

        loadingPresetHosts.insert(hostKey)
        presetErrorsByHost.removeValue(forKey: hostKey)
        defer { loadingPresetHosts.remove(hostKey) }

        var components = URLComponents()
        components.scheme = "http"
        components.host = device.host
        components.port = device.port
        components.path = "/presets.json"
        guard let url = components.url else {
            presetErrorsByHost[hostKey] = "The WLED address is invalid."
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  response.statusCode == 200 else {
                presetErrorsByHost[hostKey] = "WLED didn’t return its presets."
                return
            }
            presetsByHost[hostKey] = try Self.decodePresets(from: data)
        } catch {
            presetErrorsByHost[hostKey] = "Couldn’t load presets from \(device.name)."
        }
    }

    nonisolated static func decodePresets(from data: Data) throws -> [Preset] {
        let records = try JSONDecoder().decode([String: WLEDPreset].self, from: data)
        return records.compactMap { key, preset in
            guard let id = Int(key), id > 0 else { return nil }
            let trimmedName = preset.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Preset(id: id, name: trimmedName.isEmpty ? "Preset \(id)" : trimmedName)
        }
        .sorted { $0.id < $1.id }
    }

    private func verify(_ device: Device) async -> Device? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = device.host
        components.port = device.port
        components.path = "/json/info"
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let response = response as? HTTPURLResponse,
              response.statusCode == 200,
              let info = try? JSONDecoder().decode(WLEDInfo.self, from: data) else {
                        return nil
        }

        let configuredName = info.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let reportedAddress = info.ip?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayName = configuredName.isEmpty || configuredName.caseInsensitiveCompare("WLED") == .orderedSame
            ? device.serviceName
            : configuredName
        return Device(
            serviceName: device.serviceName,
            name: displayName,
            host: reportedAddress.isEmpty ? device.host : reportedAddress,
            port: device.port,
            macAddress: info.mac ?? device.macAddress
        )
    }

    private func finishVerification(_ serviceName: String, with verifiedDevice: Device?) {
        verificationTasks.removeValue(forKey: serviceName)
        guard let verifiedDevice,
              devices.contains(where: { $0.serviceName == serviceName }) else { return }
        devices.removeAll { $0.id == verifiedDevice.id || $0.serviceName == serviceName }
        devices.append(verifiedDevice)
        devices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    nonisolated private static func device(from result: NWBrowser.Result) -> Device? {
        guard case .service(let name, _, _, _) = result.endpoint else { return nil }
        let macAddress: String
        if case .bonjour(let record) = result.metadata {
            macAddress = record.dictionary["mac"] ?? ""
        } else {
            macAddress = ""
        }
        return Device(
            serviceName: name,
            name: name,
            host: "\(name).local",
            port: 80,
            macAddress: macAddress
        )
    }

    nonisolated private static func manualDevice(from address: String) throws -> Device {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddress.isEmpty,
              let components = URLComponents(string: trimmedAddress.contains("://")
                ? trimmedAddress
                : "http://\(trimmedAddress)"),
              components.scheme?.lowercased() == "http",
              let host = components.host,
              !host.isEmpty else {
            throw DiscoveryError.invalidAddress
        }
        return Device(
            serviceName: host,
            name: host,
            host: host,
            port: components.port ?? 80,
            macAddress: ""
        )
    }

    nonisolated private static func normalizedHost(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private enum DiscoveryError: LocalizedError {
    case invalidAddress
    case unreachable(String)

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            "Enter a hostname or IP address, such as wled.local or 192.168.1.50."
        case .unreachable(let address):
            "Couldn’t reach a WLED device at \(address)."
        }
    }
}

private struct WLEDInfo: Decodable {
    let name: String?
    let mac: String?
    let ip: String?
}

private struct WLEDPreset: Decodable {
    let name: String?

    enum CodingKeys: String, CodingKey {
        case name = "n"
    }
}