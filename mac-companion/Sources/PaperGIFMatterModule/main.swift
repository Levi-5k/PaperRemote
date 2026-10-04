import Foundation
import Matter
import Security

private struct ActionRequest: Decodable {
    let type: String
    let host: String?
    let text: String
    let value: Int
    let valueTenths: Int?
    let modifiers: [String]
}

private struct ActionResponse: Codable {
    let succeeded: Bool
    let changed: Bool
    let message: String?
}

private struct RequestKind: Decodable {
    let type: String
}

// Sent only by the companion app's own UI; device actions are limited to the manifest's runtime actions.
private struct ManageRequest: Decodable {
    let command: String
    let setupCode: String?
    let name: String?
    let device: Int?
}

private struct ManageResponse: Encodable {
    let succeeded: Bool
    let message: String?
    let devices: [MatterNode]
    var on: Bool? = nil
}

private struct MatterNode: Codable {
    let id: UInt64
    var name: String
    var endpoint: UInt16
    /// Short permanent number that M5Paper buttons store in `value`; 0 means "newest device".
    var number: Int

    init(id: UInt64, name: String, endpoint: UInt16, number: Int) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.number = number
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UInt64.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        endpoint = try container.decode(UInt16.self, forKey: .endpoint)
        number = try container.decodeIfPresent(Int.self, forKey: .number) ?? 0
    }
}

private struct MatterState: Codable {
    var ipk: Data
    var privateKey: Data
    var fabricID: UInt64
    var nextNodeID: UInt64
    var nodes: [MatterNode]
    var fabricCreated: Bool
}

@available(macOS 13.3, *)
private final class MatterStorage: NSObject, MTRStorage {
    private let fileURL: URL
    private let lock = NSLock()
    private var values: [String: Data]

    init(directory: URL) throws {
        fileURL = directory.appendingPathComponent("matter-storage.plist")
        if let data = try? Data(contentsOf: fileURL),
           let stored = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Data] {
            values = stored
        } else {
            values = [:]
        }
        super.init()
    }

    func storageData(forKey key: String) -> Data? {
        lock.withLock { values[key] }
    }

    func setStorageData(_ value: Data, forKey key: String) -> Bool {
        lock.withLock {
            values[key] = value
            return persist()
        }
    }

    func removeStorageData(forKey key: String) -> Bool {
        lock.withLock {
            guard values.removeValue(forKey: key) != nil else { return false }
            return persist()
        }
    }

    private func persist() -> Bool {
        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: values,
                format: .binary,
                options: 0
            )
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
            return true
        } catch {
            return false
        }
    }
}

@available(macOS 13.3, *)
private final class MatterKeypair: NSObject, MTRKeypair {
    let privateKey: SecKey

    init(privateKeyData: Data) throws {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 256,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(
            privateKeyData as CFData,
            attributes as CFDictionary,
            &error
        ) else {
            throw error?.takeRetainedValue() ?? MatterModuleError.invalidPrivateKey
        }
        privateKey = key
        super.init()
    }

    func publicKey() -> Unmanaged<SecKey> {
        Unmanaged.passRetained(SecKeyCopyPublicKey(privateKey)!)
    }

    @available(macOS 15.4, *)
    func copyPublicKey() -> SecKey {
        SecKeyCopyPublicKey(privateKey)!
    }

    func signMessageECDSA_DER(_ message: Data) -> Data {
        var error: Unmanaged<CFError>?
        return SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            message as CFData,
            &error
        ) as Data? ?? Data()
    }
}

@available(macOS 13.3, *)
private final class CommissioningDelegate: NSObject, MTRDeviceControllerDelegate {
    let nodeID: NSNumber
    let semaphore = DispatchSemaphore(value: 0)
    private(set) var error: Error?

    init(nodeID: NSNumber) {
        self.nodeID = nodeID
    }

    func controller(
        _ controller: MTRDeviceController,
        commissioningSessionEstablishmentDone error: Error?
    ) {
        if let error {
            self.error = error
            semaphore.signal()
            return
        }
        do {
            try controller.commissionNode(
                withID: nodeID,
                commissioningParams: MTRCommissioningParameters()
            )
        } catch {
            self.error = error
            semaphore.signal()
        }
    }

    func controller(
        _ controller: MTRDeviceController,
        commissioningComplete error: Error?
    ) {
        self.error = error
        semaphore.signal()
    }

    @available(macOS 14.0, *)
    func controller(
        _ controller: MTRDeviceController,
        commissioningComplete error: Error?,
        nodeID: NSNumber?
    ) {
        self.error = error
        semaphore.signal()
    }
}

@available(macOS 13.3, *)
private final class MatterHub {
    private let stateURL: URL
    private var state: MatterState
    private let factory: MTRDeviceControllerFactory
    private let controller: MTRDeviceController
    private let callbackQueue = DispatchQueue(label: "paperGIF.module.matter.callbacks")
    private var commissioningDelegate: CommissioningDelegate?

    init(stateDirectory: URL) throws {
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        stateURL = stateDirectory.appendingPathComponent("hub.json")
        state = try Self.loadOrCreateState(at: stateURL)
        let storage = try MatterStorage(directory: stateDirectory)
        let keypair = try MatterKeypair(privateKeyData: state.privateKey)
        factory = MTRDeviceControllerFactory.sharedInstance()
        if !factory.isRunning {
            let factoryParameters = MTRDeviceControllerFactoryParams(storage: storage)
            // Matter.framework ships no production attestation roots for third-party controllers.
            factoryParameters.productAttestationAuthorityCertificates = Self.trustedAttestationRoots()
            try factory.start(factoryParameters)
        }

        let startup = MTRDeviceControllerStartupParams(
            ipk: state.ipk,
            fabricID: NSNumber(value: state.fabricID),
            nocSigner: keypair
        )
        startup.vendorID = 0xFFF1
        if state.fabricCreated {
            controller = try factory.createController(onExistingFabric: startup)
        } else {
            controller = try factory.createController(onNewFabric: startup)
            state.fabricCreated = true
            try saveState()
        }
        if Self.assignMissingNumbers(&state.nodes) {
            try saveState()
        }
    }

    deinit {
        controller.shutdown()
        factory.stop()
    }

    /// CSA production PAA roots bundled in the app's Resources/MatterPAA (or a --paa directory).
    private static func trustedAttestationRoots() -> [Data] {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let directory = argument(after: "--paa").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? executable.deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/MatterPAA", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "der" }.compactMap { try? Data(contentsOf: $0) }
    }

    func commission(setupCode: String, name: String = "Matter switch") throws -> MatterNode {
        let payload: MTRSetupPayload
        if #available(macOS 14.6, *) {
            guard let parsed = MTRSetupPayload(payload: setupCode) else {
                throw MatterModuleError.invalidSetupCode
            }
            payload = parsed
        } else {
            payload = try MTRSetupPayload(onboardingPayload: setupCode)
        }

        let nodeID = state.nextNodeID
        // Never reuse a node ID from a failed attempt; the controller may hold a stale session for it.
        state.nextNodeID += 1
        try saveState()
        let delegate = CommissioningDelegate(nodeID: NSNumber(value: nodeID))
        commissioningDelegate = delegate
        controller.setDeviceControllerDelegate(delegate, queue: callbackQueue)
        try controller.setupCommissioningSession(
            with: payload,
            newNodeID: NSNumber(value: nodeID)
        )
        guard delegate.semaphore.wait(timeout: .now() + 120) == .success else {
            commissioningDelegate = nil
            throw MatterModuleError.commissioningTimedOut
        }
        commissioningDelegate = nil
        if let error = delegate.error {
            throw error
        }
        let node = MatterNode(
            id: nodeID,
            name: name,
            endpoint: 1,
            number: (state.nodes.map(\.number).max() ?? 0) + 1
        )
        state.nodes.append(node)
        try saveState()
        return node
    }

    func manage(_ request: ManageRequest) -> ManageResponse {
        switch request.command {
        case "list":
            return ManageResponse(succeeded: true, message: nil, devices: state.nodes)
        case "state":
            return readPowerState(deviceNumber: request.device ?? 0)
        case "commission":
            guard let setupCode = request.setupCode, !setupCode.isEmpty else {
                return ManageResponse(succeeded: false, message: "Enter the pairing code.", devices: state.nodes)
            }
            let trimmedName = String((request.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            do {
                let node = try commission(setupCode: setupCode, name: trimmedName.isEmpty ? "Matter switch" : trimmedName)
                return ManageResponse(succeeded: true, message: "Added \(node.name).", devices: state.nodes)
            } catch {
                return ManageResponse(succeeded: false, message: error.localizedDescription, devices: state.nodes)
            }
        default:
            return ManageResponse(succeeded: false, message: "Unsupported request", devices: state.nodes)
        }
    }

    private static func assignMissingNumbers(_ nodes: inout [MatterNode]) -> Bool {
        var next = (nodes.map(\.number).max() ?? 0) + 1
        var changed = false
        for index in nodes.indices where nodes[index].number <= 0 {
            nodes[index].number = next
            next += 1
            changed = true
        }
        return changed
    }

    private func node(numbered number: Int) -> MatterNode? {
        number > 0 ? state.nodes.first { $0.number == number } : state.nodes.last
    }

    func perform(command: String, deviceNumber: Int) -> ActionResponse {
        guard let node = node(numbered: deviceNumber) else {
            return ActionResponse(
                succeeded: false,
                changed: false,
                message: state.nodes.isEmpty
                    ? "No Matter device has been commissioned"
                    : "Matter device #\(deviceNumber) is no longer on this Mac"
            )
        }
        let semaphore = DispatchSemaphore(value: 0)
        var commandError: Error?
        let device = MTRDevice(nodeID: NSNumber(value: node.id), controller: controller)
        guard let cluster = MTRClusterOnOff(
            device: device,
            endpointID: NSNumber(value: node.endpoint),
            queue: callbackQueue
        ) else {
            return ActionResponse(succeeded: false, changed: false, message: "On/Off cluster unavailable")
        }
        let completion: MTRStatusCompletion = { error in
            commandError = error
            semaphore.signal()
        }
        switch command {
        case "on":
            cluster.on(with: nil, expectedValues: nil, expectedValueInterval: nil, completion: completion)
        case "off":
            cluster.off(with: nil, expectedValues: nil, expectedValueInterval: nil, completion: completion)
        case "toggle":
            cluster.toggle(with: nil, expectedValues: nil, expectedValueInterval: nil, completion: completion)
        default:
            return ActionResponse(succeeded: false, changed: false, message: "Unsupported command")
        }
        guard semaphore.wait(timeout: .now() + 20) == .success else {
            return ActionResponse(succeeded: false, changed: false, message: "Matter command timed out")
        }
        if let commandError {
            return ActionResponse(succeeded: false, changed: false, message: commandError.localizedDescription)
        }
        return ActionResponse(succeeded: true, changed: true, message: "\(node.name): \(command)")
    }

    /// Reads the OnOff attribute from the device itself so the M5Paper shows real state.
    private func readPowerState(deviceNumber: Int) -> ManageResponse {
        guard let node = node(numbered: deviceNumber) else {
            return ManageResponse(succeeded: false, message: "No such Matter device", devices: state.nodes)
        }
        let device = MTRBaseDevice(nodeID: NSNumber(value: node.id), controller: controller)
        guard let cluster = MTRBaseClusterOnOff(
            device: device,
            endpointID: NSNumber(value: node.endpoint),
            queue: callbackQueue
        ) else {
            return ManageResponse(succeeded: false, message: "On/Off cluster unavailable", devices: state.nodes)
        }
        let semaphore = DispatchSemaphore(value: 0)
        var value: Bool?
        var readError: Error?
        cluster.readAttributeOnOff { result, error in
            value = result?.boolValue
            readError = error
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 10) == .success else {
            return ManageResponse(succeeded: false, message: "Matter state read timed out", devices: state.nodes)
        }
        guard let value else {
            return ManageResponse(
                succeeded: false,
                message: readError?.localizedDescription ?? "No state reported",
                devices: state.nodes
            )
        }
        return ManageResponse(succeeded: true, message: nil, devices: state.nodes, on: value)
    }

    func nodesJSON() throws -> Data {
        try JSONEncoder().encode(state.nodes)
    }

    private func saveState() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }

    private static func loadOrCreateState(at url: URL) throws -> MatterState {
        if let data = try? Data(contentsOf: url),
           let state = try? JSONDecoder().decode(MatterState.self, from: data) {
            return state
        }
        let keyAttributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 256,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(keyAttributes as CFDictionary, &error),
              let keyData = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            throw error?.takeRetainedValue() ?? MatterModuleError.keyGenerationFailed
        }
        return MatterState(
            ipk: randomData(count: 16),
            privateKey: keyData,
            fabricID: UInt64.random(in: 1...UInt64.max),
            nextNodeID: 0x1234_4321_0001,
            nodes: [],
            fabricCreated: false
        )
    }
}

private enum MatterModuleError: LocalizedError {
    case invalidPrivateKey
    case keyGenerationFailed
    case invalidSetupCode
    case commissioningTimedOut
    case unsupportedSystem

    var errorDescription: String? {
        switch self {
        case .invalidPrivateKey: "The stored Matter fabric key is invalid."
        case .keyGenerationFailed: "Could not generate a Matter fabric key."
        case .invalidSetupCode: "The Matter setup code is invalid."
        case .commissioningTimedOut: "Matter commissioning timed out. Put the device in pairing mode and retry."
        case .unsupportedSystem: "Matter modules require macOS 13.3 or later."
        }
    }
}

private func randomData(count: Int) -> Data {
    var data = Data(count: count)
    data.withUnsafeMutableBytes { bytes in
        _ = SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
    }
    return data
}

private extension NSLock {
    func withLock<Result>(_ body: () -> Result) -> Result {
        lock()
        defer { unlock() }
        return body()
    }
}

private func argument(after name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name),
          CommandLine.arguments.indices.contains(index + 1) else { return nil }
    return CommandLine.arguments[index + 1]
}

private func writeJSONLine<Response: Encodable>(_ response: Response) {
    guard let data = try? JSONEncoder().encode(response) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

let defaultState = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("paperGIF Mac/module-state/matter-switch", isDirectory: true)
let stateDirectory = URL(fileURLWithPath: argument(after: "--state") ?? defaultState.path, isDirectory: true)

@available(macOS 13.3, *)
func runMatterModule() throws {
    let hub = try MatterHub(stateDirectory: stateDirectory)
    if let setupCode = argument(after: "--commission") {
        let node = try hub.commission(setupCode: setupCode)
        writeJSONLine(ActionResponse(succeeded: true, changed: true, message: "Commissioned node \(node.id)"))
    } else if CommandLine.arguments.contains("--list") {
        FileHandle.standardOutput.write(try hub.nodesJSON())
        FileHandle.standardOutput.write(Data([0x0A]))
    } else if let command = ["on", "off", "toggle"].first(where: {
        CommandLine.arguments.contains("--\($0)")
    }) {
        writeJSONLine(hub.perform(command: command, deviceNumber: 0))
    } else if CommandLine.arguments.contains("--json-lines") {
        while let line = readLine() {
            guard let data = line.data(using: .utf8) else { continue }
            if (try? JSONDecoder().decode(RequestKind.self, from: data))?.type == "manage" {
                guard let request = try? JSONDecoder().decode(ManageRequest.self, from: data) else {
                    writeJSONLine(ManageResponse(succeeded: false, message: "Invalid manage request", devices: []))
                    continue
                }
                writeJSONLine(hub.manage(request))
                continue
            }
            guard let request = try? JSONDecoder().decode(ActionRequest.self, from: data),
                  request.type == "module",
                  request.host == "matter-switch" else {
                writeJSONLine(ActionResponse(succeeded: false, changed: false, message: "Invalid module request"))
                continue
            }
            writeJSONLine(hub.perform(command: request.text, deviceNumber: request.value))
        }
    } else {
        writeJSONLine(ActionResponse(succeeded: false, changed: false, message: "Specify --commission, --list, --on, --off, --toggle, or --json-lines"))
        exit(2)
    }
}

do {
    guard #available(macOS 13.3, *) else {
        throw MatterModuleError.unsupportedSystem
    }
    try runMatterModule()
} catch {
    writeJSONLine(ActionResponse(succeeded: false, changed: false, message: error.localizedDescription))
    exit(1)
}