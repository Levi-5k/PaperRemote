import Foundation

@MainActor
final class MatterDeviceManager: ObservableObject {
    nonisolated static let moduleID = "matter-switch"

    struct Device: Decodable, Identifiable, Equatable {
        let id: UInt64
        let name: String
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

    func add(pairingCode: String, name: String) async {
        guard !isBusy else { return }
        isAdding = true
        lastAddSucceeded = false
        status = "Adding \(name.isEmpty ? "device" : name)… keep it in pairing mode. This can take up to 2 minutes."
        let request = ModuleManageRequest(
            command: "commission",
            setupCode: Self.normalizedPairingCode(pairingCode),
            name: name
        )
        lastAddSucceeded = await run(request, reportSuccess: true)
        isAdding = false
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
            return response.succeeded
        } catch {
            status = error.localizedDescription
            return false
        }
    }
}
