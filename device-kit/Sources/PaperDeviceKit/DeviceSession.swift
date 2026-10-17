import Combine
import Foundation

public enum DeviceAdapterKind: String, Codable, Sendable {
    case native
    case legacyM5Paper
}

public struct SavedDevice: Codable, Equatable, Identifiable, Sendable {
    public var descriptor: DeviceDescriptor
    public var address: String
    public var adapter: DeviceAdapterKind
    public var layoutOverride: DeviceLayout?
    public var profile: Data?
    public var id: String { descriptor.deviceID }
}

public protocol DeviceAdapter: Sendable {
    func identify(address: String) async throws -> (DeviceDescriptor, DeviceAdapterKind)
}

public struct NativeDeviceAdapter: DeviceAdapter {
    private let request: @Sendable (URLRequest, Int) async throws -> (Data, Int)

    public init(request: @escaping @Sendable (URLRequest, Int) async throws -> (Data, Int) = {
        try await DeviceHTTP.request($0, maximumBytes: $1)
    }) {
        self.request = request
    }

    public func identify(address: String) async throws -> (DeviceDescriptor, DeviceAdapterKind) {
        let url = try DeviceHTTP.endpoint(address, path: "/device")
        let (data, status) = try await request(URLRequest(url: url), 65_536)
        if status == 200 { return (try DeviceDescriptor.decode(data), .native) }
        guard status == 404 else {
            throw DeviceContractError.unsupported("descriptor HTTP \(status); no compatible adapter")
        }
        let statusURL = try DeviceHTTP.endpoint(address, path: "/status")
        let (statusData, statusCode) = try await request(URLRequest(url: statusURL), 4096)
        struct LegacyStatus: Decodable { let device: String; let firmware: String? }
        guard statusCode == 200,
              let legacy = try? JSONDecoder().decode(LegacyStatus.self, from: statusData),
              legacy.device == "paperGIF" else {
            throw DeviceContractError.unsupported("no descriptor or recognized legacy protocol; a protocol adapter is required")
        }
        return (.legacyM5Paper(deviceID: "legacy:\(statusURL.host ?? address):\(statusURL.port ?? 80)",
                               firmwareVersion: legacy.firmware ?? "legacy"), .legacyM5Paper)
    }
}

@MainActor
public final class DeviceSession: ObservableObject {
    @Published public private(set) var descriptor: DeviceDescriptor?
    @Published public private(set) var layout: DeviceLayout?
    @Published public var address = "" {
        didSet {
            if address != oldValue {
                isVerified = false
                catalogTask?.cancel()
                isLoading = false
                message = "Address changed. Connect to verify this device."
                generation = UUID()
            }
        }
    }
    @Published public private(set) var message: String?
    @Published public private(set) var isLoading = false
    @Published public private(set) var records: [SavedDevice] = []
    @Published public private(set) var selectedID: String?
    @Published public private(set) var isVerified = false
    public var profileData: Data? { records.first(where: { $0.id == selectedID })?.profile }
    public var adapter: DeviceAdapterKind? { records.first(where: { $0.id == selectedID })?.adapter }

    private let storageURL: URL
    private let catalog: DeviceCatalog
    private var catalogTask: Task<Void, Never>?
    private var generation = UUID()

    deinit { catalogTask?.cancel() }

    public init(storageURL: URL? = nil, catalog: DeviceCatalog = DeviceCatalog()) {
        self.storageURL = storageURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PaperRemote/devices.json")
        self.catalog = catalog
        if FileManager.default.fileExists(atPath: self.storageURL.path) {
            do {
                records = try JSONDecoder().decode([SavedDevice].self, from: Data(contentsOf: self.storageURL))
                guard Set(records.map(\.id)).count == records.count else {
                    throw DeviceContractError.invalid("duplicate saved device IDs")
                }
                for record in records {
                    try record.descriptor.validate()
                    try record.layoutOverride?.validate(
                        inputIDs: Set(record.descriptor.inputs.map(\.id)), hasDisplay: record.descriptor.display != nil)
                }
            } catch {
                records = []
                message = "Saved devices could not be loaded: \(error.localizedDescription)"
            }
        }
    }

    public func connect(address: String, adapter: any DeviceAdapter = NativeDeviceAdapter()) async throws {
        catalogTask?.cancel()
        let operation = UUID()
        descriptor = nil
        isVerified = false
        layout = nil
        selectedID = nil
        self.address = address
        generation = operation
        isLoading = true
        do {
            let (descriptor, kind) = try await adapter.identify(address: address)
            try Task.checkCancellation()
            guard generation == operation else { throw CancellationError() }
            try await install(descriptor, address: address, adapter: kind, operation: operation)
        } catch {
            if generation == operation {
                isLoading = false
                message = error.localizedDescription
            }
            throw error
        }
    }

    public func applyDescriptor(_ descriptor: DeviceDescriptor, address: String) async throws {
        try descriptor.validate()
        self.address = address
        let operation = UUID()
        generation = operation
        try await install(descriptor, address: address, adapter: .native, operation: operation)
    }

    private func install(_ descriptor: DeviceDescriptor, address: String,
                         adapter: DeviceAdapterKind, operation: UUID) async throws {
        try descriptor.validate()
        self.descriptor = descriptor
        isVerified = true
        self.address = address
        selectedID = descriptor.deviceID
        if let index = records.firstIndex(where: { $0.id == descriptor.deviceID }) {
            records[index].descriptor = descriptor
            records[index].address = address
            records[index].adapter = adapter
        } else {
            if descriptor.isM5Paper, let legacyIndex = records.firstIndex(where: {
                $0.adapter == .legacyM5Paper && $0.address == address
            }) {
                records[legacyIndex].descriptor = descriptor
                records[legacyIndex].adapter = adapter
            } else {
                records.append(SavedDevice(descriptor: descriptor, address: address, adapter: adapter))
            }
        }
        layout = records.first(where: { $0.id == selectedID })?.layoutOverride ?? descriptor.layout
        message = "Using device layout; checking GitHub..."
        try persist()
        isLoading = true
        catalogTask?.cancel()
        let catalog = self.catalog
        catalogTask = Task { [weak self] in
            let result = await catalog.resolve(descriptor: descriptor)
            guard !Task.isCancelled, let self, self.generation == operation else { return }
            self.layout = self.records.first(where: { $0.id == self.selectedID })?.layoutOverride ?? result.layout
            self.message = result.message
            self.isLoading = false
        }
    }

    public func select(id: String) {
        catalogTask?.cancel()
        generation = UUID()
        isLoading = false
        isVerified = false
        guard let record = records.first(where: { $0.id == id }) else {
            message = "Saved device not found."
            return
        }
        selectedID = id
        descriptor = record.descriptor
        layout = record.layoutOverride ?? record.descriptor.layout
        address = record.address
        message = "Saved device selected. Connect to verify current capabilities."
    }

    public func saveProfile(_ data: Data) throws {
        guard let index = records.firstIndex(where: { $0.id == selectedID }) else {
            throw DeviceContractError.invalid("select a device before saving its profile")
        }
        guard data.count <= records[index].descriptor.capabilities.maxProfileBytes else {
            throw DeviceContractError.invalid("profile exceeds device limit")
        }
        records[index].profile = data
        try persist()
    }

    public func setLayoutOverride(_ layout: DeviceLayout) throws {
        guard let index = records.firstIndex(where: { $0.id == selectedID }) else {
            throw DeviceContractError.invalid("select a device before editing its layout")
        }
        let descriptor = records[index].descriptor
        try layout.validate(inputIDs: Set(descriptor.inputs.map(\.id)), hasDisplay: descriptor.display != nil)
        records[index].layoutOverride = layout
        self.layout = layout
        try persist()
    }

    public func loadProfile(token: String) async throws -> Data {
        guard let descriptor, isVerified else { throw DeviceContractError.unsupported("connect to verify the selected device") }
        let operation = generation
        var request = URLRequest(url: try DeviceHTTP.endpoint(address, path: "/remote"))
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, status) = try await DeviceHTTP.request(request, maximumBytes: descriptor.capabilities.maxProfileBytes)
        guard operation == generation else { throw CancellationError() }
        guard status == 200 else {
            throw DeviceContractError.invalid("profile read HTTP \(status): \(Self.responseError(data))")
        }
        return data
    }

    public func sendProfile(_ data: Data, token: String) async throws {
        guard let descriptor, isVerified else { throw DeviceContractError.unsupported("connect to verify the selected device") }
        guard data.count <= descriptor.capabilities.maxProfileBytes,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = root["version"] as? Int,
              descriptor.capabilities.profileVersions.contains(version) else {
            throw DeviceContractError.invalid("profile size or negotiated version")
        }
        let operation = generation
        var request = URLRequest(url: try DeviceHTTP.endpoint(address, path: "/remote"))
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (response, status) = try await DeviceHTTP.request(request, maximumBytes: 65_536)
        guard operation == generation else { throw CancellationError() }
        guard status == 200 || status == 201 else {
            throw DeviceContractError.invalid("profile upload HTTP \(status): \(Self.responseError(response))")
        }
        try DeviceHTTP.validateProfileAcknowledgement(response, status: status)
        try saveProfile(data)
    }

    private static func responseError(_ data: Data) -> String {
        struct Rejection: Decodable { let error: String }
        guard let rejection = try? JSONDecoder().decode(Rejection.self, from: data) else {
            return "the device did not provide a valid error response"
        }
        return String(rejection.error.prefix(256))
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: storageURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}
