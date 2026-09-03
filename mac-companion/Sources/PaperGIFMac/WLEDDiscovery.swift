import Combine
import Foundation
import Network

@MainActor
final class WLEDDiscovery: ObservableObject {
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

    @Published private(set) var devices: [Device] = []
    @Published private(set) var isSearching = false
    @Published private(set) var presetsByHost: [String: [Preset]] = [:]
    @Published private(set) var errorMessage: String?

    private var browser: NWBrowser?
    private var verificationTasks: [String: Task<Void, Never>] = [:]
    private var scanTimeoutTask: Task<Void, Never>?
    private let queue = DispatchQueue(label: "paperGIF.mac.wled-discovery")

    func start() {
        stop()
        devices = []
        errorMessage = nil
        isSearching = true
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_wled._tcp", domain: nil), using: parameters)
        browser.stateUpdateHandler = { state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .failed(let error) = state {
                    self.errorMessage = "WLED discovery failed: \(error.localizedDescription)"
                    self.isSearching = false
                }
            }
        }
        browser.browseResultsChangedHandler = { results, _ in
            Task { @MainActor [weak self] in self?.resolve(results) }
        }
        browser.start(queue: queue)
        self.browser = browser
        scanTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.isSearching = false
        }
    }

    func stop() {
        browser?.cancel()
        browser = nil
        verificationTasks.values.forEach { $0.cancel() }
        verificationTasks = [:]
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        isSearching = false
    }

    func presets(for host: String) -> [Preset] {
        presetsByHost[host.lowercased()] ?? []
    }

    func device(at address: String) async throws -> Device {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed.contains("://") ? trimmed : "http://\(trimmed)"),
              components.scheme?.lowercased() == "http",
              let host = components.host,
              !host.isEmpty else {
            throw WLEDDiscoveryError.invalidAddress
        }
        let candidate = Device(
            serviceName: host,
            name: host,
            host: host,
            port: components.port ?? 80,
            macAddress: ""
        )
        guard let verified = await verify(candidate) else {
            throw WLEDDiscoveryError.unreachable(candidate.actionHost)
        }
        devices.removeAll { $0.id == verified.id || $0.actionHost == verified.actionHost }
        devices.append(verified)
        devices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return verified
    }

    func loadPresets(for device: Device) async {
        let key = device.actionHost.lowercased()
        guard presetsByHost[key] == nil else { return }
        guard let url = httpURL(host: device.host, port: device.port, path: "/presets.json") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let records = try JSONDecoder().decode([String: WLEDPreset].self, from: data)
            presetsByHost[key] = records.compactMap { id, preset in
                guard let number = Int(id), number > 0 else { return nil }
                let name = preset.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return Preset(id: number, name: name.isEmpty ? "Preset \(number)" : name)
            }.sorted { $0.id < $1.id }
        } catch {
            errorMessage = "Could not load presets from \(device.name)."
        }
    }

    private func resolve(_ results: Set<NWBrowser.Result>) {
        let candidates = results.compactMap(Self.device(from:))
        let names = Set(candidates.map(\.serviceName))
        devices.removeAll { !names.contains($0.serviceName) }
        for candidate in candidates where verificationTasks[candidate.serviceName] == nil {
            verificationTasks[candidate.serviceName] = Task { [weak self] in
                guard let self else { return }
                let verified = await self.verify(candidate)
                guard !Task.isCancelled else { return }
                self.verificationTasks.removeValue(forKey: candidate.serviceName)
                guard let verified else { return }
                self.devices.removeAll { $0.serviceName == candidate.serviceName || $0.id == verified.id }
                self.devices.append(verified)
                self.devices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                self.scanTimeoutTask?.cancel()
                self.scanTimeoutTask = nil
                self.isSearching = false
            }
        }
    }

    private func verify(_ device: Device) async -> Device? {
        guard let url = httpURL(host: device.host, port: device.port, path: "/json/info") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let info = try? JSONDecoder().decode(WLEDInfo.self, from: data) else { return nil }
        let configuredName = info.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let address = info.ip?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Device(
            serviceName: device.serviceName,
            name: configuredName.isEmpty || configuredName.caseInsensitiveCompare("WLED") == .orderedSame
                ? device.serviceName : configuredName,
            host: address.isEmpty ? device.host : address,
            port: device.port,
            macAddress: info.mac ?? ""
        )
    }

    private func httpURL(host: String, port: Int, path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = path
        return components.url
    }

    nonisolated private static func device(from result: NWBrowser.Result) -> Device? {
        guard case .service(let name, _, _, _) = result.endpoint else { return nil }
        return Device(serviceName: name, name: name, host: "\(name).local", port: 80, macAddress: "")
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

private enum WLEDDiscoveryError: LocalizedError {
    case invalidAddress
    case unreachable(String)

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            "Enter a hostname or IP address, such as wled.local or 192.168.1.50."
        case .unreachable(let address):
            "Could not reach a WLED device at \(address)."
        }
    }
}