import Foundation

@MainActor
final class MatterDeviceManager: ObservableObject {
    nonisolated static let moduleID = "matter-switch"

    struct Device: Decodable, Identifiable, Equatable {
        let id: UInt64
        let name: String
        /// Stored in a button's `value` to choose this device.
        let number: Int

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UInt64.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            number = try container.decodeIfPresent(Int.self, forKey: .number) ?? 0
        }

        private enum CodingKeys: String, CodingKey { case id, name, number }
    }

    private struct Response: Decodable {
        let succeeded: Bool
        let message: String?
        let devices: [Device]
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var isBusy = false
    @Published private(set) var isAdding = false
    @Published private(set) var status: String?
    @Published private(set) var lastAddSucceeded = false

    private let host: ModuleRuntimeHost

    init(host: ModuleRuntimeHost) {
        self.host = host
    }

    func refresh() async {
        guard !isBusy else { return }
        await run(ModuleManageRequest(command: "list"), reportSuccess: false)
    }

    /// `wifiSSID`/`wifiPassword` are only needed for factory-new Wi-Fi devices; they are passed through, never stored.
    func add(pairingCode: String, name: String, wifiSSID: String? = nil, wifiPassword: String? = nil) async {
        await waitUntilIdle()
        isAdding = true
        lastAddSucceeded = false
        status = "Adding \(name.isEmpty ? "device" : name)… keep it in pairing mode. This can take up to 2 minutes."
        let request = ModuleManageRequest(
            command: "commission",
            setupCode: Self.normalizedPairingCode(pairingCode),
            name: name,
            wifiSSID: wifiSSID,
            wifiPassword: wifiPassword
        )
        lastAddSucceeded = await run(request, reportSuccess: true)
        isAdding = false
    }

    func rename(_ device: Device, to name: String) async {
        await waitUntilIdle()
        var request = ModuleManageRequest(command: "rename", name: name)
        request.device = device.number
        await run(request, reportSuccess: true)
    }

    func remove(_ device: Device) async {
        await waitUntilIdle()
        var request = ModuleManageRequest(command: "remove")
        request.device = device.number
        await run(request, reportSuccess: true)
    }

    // A list refresh is quick; waiting keeps a user action from being dropped while one runs.
    private func waitUntilIdle() async {
        while isBusy {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Accepts Apple Home's 11-digit code with dashes/spaces, or an `MT:` QR payload.
    nonisolated static func normalizedPairingCode(_ code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.uppercased().hasPrefix("MT:") { return trimmed }
        return trimmed.filter(\.isNumber)
    }

    nonisolated static func isPlausiblePairingCode(_ code: String) -> Bool {
        let normalized = normalizedPairingCode(code)
        return normalized.uppercased().hasPrefix("MT:") ? normalized.count > 3 : [11, 21].contains(normalized.count)
    }

    @discardableResult
    private func run(_ request: ModuleManageRequest, reportSuccess: Bool) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        let host = host
        do {
            let data = try await Task.detached {
                try host.manage(moduleID: Self.moduleID, request)
            }.value
            let response = try JSONDecoder().decode(Response.self, from: data)
            devices = response.devices
            if !response.succeeded || reportSuccess {
                status = response.message
            }
            if response.succeeded {
                if request.command == "commission" { DiagnosticLog.info("Matter device added: \(response.message ?? "")") }
            } else {
                DiagnosticLog.error("Matter \(request.command) failed: \(response.message ?? "unknown error")")
            }
            return response.succeeded
        } catch {
            status = error.localizedDescription
            DiagnosticLog.error("Matter \(request.command) failed", error: error)
            return false
        }
    }
}
