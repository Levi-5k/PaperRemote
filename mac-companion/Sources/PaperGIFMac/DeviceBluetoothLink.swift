import CoreBluetooth
import Foundation
import PaperDeviceKit

/// Frame-level state for one BLE connection: serialized control requests,
/// unsolicited snapshots and relayed computer actions. Independent of
/// CoreBluetooth so it can be tested with a fake writer.
@MainActor
final class DeviceBLEChannel {
    private struct Pending {
        let id: UUID
        let continuation: CheckedContinuation<DeviceControlSnapshot, Error>
        var awaitingStatus: Bool
    }

    var onSnapshot: ((DeviceControlSnapshot) -> Void)?
    var onRegistration: ((Bool) -> Void)?
    private(set) var isOpen = false

    private let actionHandler: (Data) async -> Bool
    private let timeout: Duration
    private var writer: ((Data) -> Void)?
    private var snapshots = DeviceBLEFrames.SnapshotAssembler()
    private var relays = DeviceBLEFrames.RelayAssembler()
    private var pending: Pending?
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(timeout: Duration = .seconds(4), actionHandler: @escaping (Data) async -> Bool) {
        self.timeout = timeout
        self.actionHandler = actionHandler
    }

    func open(writer: @escaping (Data) -> Void) {
        self.writer = writer
        isOpen = true
    }

    func close() {
        isOpen = false
        writer = nil
        snapshots.reset()
        relays.reset()
        fail(pending?.id, DeviceControlError.transport("Bluetooth disconnected"))
    }

    func register(token: String) throws {
        guard let writer else { throw DeviceControlError.transport("Bluetooth is not connected") }
        writer(try DeviceBLEFrames.relayRegistration(role: .computer, token: token))
    }

    func requestSnapshot() async throws -> DeviceControlSnapshot {
        try await request(Data([DeviceBLEFrames.requestSnapshot]), awaitsStatus: false)
    }

    func set(_ request: DeviceControlSetRequest) async throws -> DeviceControlSnapshot {
        try await self.request(try DeviceBLEFrames.setRequest(request), awaitsStatus: true)
    }

    func receive(_ value: Data) {
        guard let opcode = value.first else { return }
        switch opcode {
        case DeviceBLEFrames.snapshotFragment:
            do {
                guard let snapshot = try snapshots.receive(value) else { return }
                if let pending, !pending.awaitingStatus {
                    complete(pending.id, .success(snapshot))
                } else {
                    onSnapshot?(snapshot)
                }
            } catch {
                fail(pending?.id, error)
            }
        case DeviceBLEFrames.setStatus:
            guard value.count >= 2, let current = pending else { return }
            if let error = DeviceControlError(bleStatus: value[value.startIndex + 1]) {
                fail(current.id, error)
            } else {
                pending?.awaitingStatus = false
            }
        case DeviceBLEFrames.relayRegistered:
            onRegistration?(value.count >= 2 && value[value.startIndex + 1] == 0)
        case DeviceBLEFrames.relayAction:
            guard let action = try? relays.receive(value) else { return }
            Task { [weak self] in
                guard let self else { return }
                let delivered = await self.actionHandler(action.body)
                self.writer?(DeviceBLEFrames.relayAck(sequence: action.sequence, delivered: delivered))
            }
        default:
            break
        }
    }

    private func request(_ frame: Data, awaitsStatus: Bool) async throws -> DeviceControlSnapshot {
        await acquire()
        defer { release() }
        guard let writer else { throw DeviceControlError.transport("Bluetooth is not connected") }
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            pending = Pending(id: id, continuation: continuation, awaitingStatus: awaitsStatus)
            writer(frame)
            let timeout = self.timeout
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.fail(id, DeviceControlError.transport("Bluetooth request timed out"))
            }
        }
    }

    private func complete(_ id: UUID, _ result: Result<DeviceControlSnapshot, Error>) {
        guard let current = pending, current.id == id else { return }
        pending = nil
        current.continuation.resume(with: result)
    }

    private func fail(_ id: UUID?, _ error: Error) {
        guard let id else { return }
        complete(id, .failure(error))
    }

    private func acquire() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

struct BLEDeviceControlTransport: DeviceControlTransport {
    let name = "Bluetooth"
    let channel: DeviceBLEChannel

    func snapshot() async throws -> DeviceControlSnapshot {
        try await channel.requestSnapshot()
    }

    func set(_ request: DeviceControlSetRequest) async throws -> DeviceControlSnapshot {
        try await channel.set(request)
    }
}

/// Connects to the device over BLE only while it is unreachable on the LAN,
/// registers this Mac as its direct action relay, and doubles as a control
/// transport. Disconnects as soon as LAN delivery works again.
@MainActor
final class DeviceBluetoothRelay: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case searching
        case connected(String)
        case unavailable(String)
    }

    struct Target: Equatable {
        var address: String
        var token: String
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var controlTransport: BLEDeviceControlTransport?
    @Published private(set) var lanReachable = true

    let channel: DeviceBLEChannel

    private static let serviceUUID = CBUUID(string: "7A230001-7D2A-4C7B-9C42-504749460001")
    private static let controlUUID = CBUUID(string: "7A230002-7D2A-4C7B-9C42-504749460001")
    private static let peripheralKey = "BluetoothRelayPeripheral"

    private let probe: @Sendable (String) async -> Bool
    private var target: Target?
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var rejected: Set<UUID> = []
    private var monitor: Task<Void, Never>?
    private var scanTimeout: Task<Void, Never>?
    private var connectTimeout: Task<Void, Never>?
    private var skipSavedPeripheral = false
    private var unreachableCount = 0

    init(
        actionHandler: @escaping (Data) async -> Bool,
        probe: @escaping @Sendable (String) async -> Bool = DeviceBluetoothRelay.isReachable
    ) {
        channel = DeviceBLEChannel(actionHandler: actionHandler)
        self.probe = probe
        super.init()
        channel.onRegistration = { [weak self] accepted in self?.registered(accepted) }
    }

    /// Sets the device to watch; `nil` stops monitoring and disconnects.
    func watch(_ target: Target?) {
        guard target != self.target else { return }
        self.target = target
        rejected = []
        unreachableCount = 0
        lanReachable = true
        disconnect()
        monitor?.cancel()
        monitor = nil
        guard let target, !target.address.isEmpty, !target.token.isEmpty else {
            state = .idle
            return
        }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let reachable = await self.probe(target.address)
                guard !Task.isCancelled else { return }
                self.updateReachability(reachable)
                try? await Task.sleep(for: .seconds(reachable ? 30 : 15))
            }
        }
    }

    func updateReachability(_ reachable: Bool) {
        unreachableCount = reachable ? 0 : unreachableCount + 1
        // Two misses in a row avoid connecting BLE for a single dropped probe.
        lanReachable = reachable || unreachableCount < 2
        if lanReachable {
            if peripheral != nil || state == .searching { disconnect() }
            skipSavedPeripheral = false
            state = .idle
        } else if peripheral == nil {
            startSearching()
        }
    }

    nonisolated static func isReachable(_ address: String) async -> Bool {
        guard let url = try? DeviceHTTP.endpoint(address, path: "/status") else { return false }
        return (try? await DeviceHTTP.request(URLRequest(url: url), maximumBytes: 4_096, timeout: 3)) != nil
    }

    private func startSearching() {
        guard target != nil else { return }
        state = .searching
        guard let central else {
            // Created lazily so the Bluetooth prompt only appears when BLE is needed.
            central = CBCentralManager(delegate: self, queue: .main)
            return
        }
        guard central.state == .poweredOn else {
            state = .unavailable(Self.describe(central.state))
            return
        }
        if !skipSavedPeripheral,
           let saved = UserDefaults.standard.string(forKey: Self.peripheralKey).flatMap(UUID.init(uuidString:)),
           !rejected.contains(saved),
           let known = central.retrievePeripherals(withIdentifiers: [saved]).first {
            connect(known)
            return
        }
        central.scanForPeripherals(withServices: [Self.serviceUUID])
        scanTimeout?.cancel()
        scanTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, !Task.isCancelled, self.peripheral == nil else { return }
            self.central?.stopScan()
            self.state = .unavailable("Device not found over Bluetooth")
        }
    }

    private func connect(_ peripheral: CBPeripheral) {
        scanTimeout?.cancel()
        central?.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        central?.connect(peripheral)
        connectTimeout?.cancel()
        connectTimeout = Task { [weak self, weak peripheral] in
            try? await Task.sleep(for: .seconds(12))
            // CoreBluetooth connects never time out; an out-of-range saved device would wait forever.
            guard let self, let peripheral, !Task.isCancelled,
                  self.peripheral === peripheral, !self.channel.isOpen else { return }
            self.skipSavedPeripheral = true
            self.disconnect()
            if !self.lanReachable { self.startSearching() }
        }
    }

    private func disconnect() {
        scanTimeout?.cancel()
        connectTimeout?.cancel()
        central?.stopScan()
        channel.close()
        controlTransport = nil
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
    }

    private func registered(_ accepted: Bool) {
        guard let peripheral else { return }
        if accepted {
            skipSavedPeripheral = false
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.peripheralKey)
            state = .connected(peripheral.name ?? "Device")
            controlTransport = BLEDeviceControlTransport(channel: channel)
            DiagnosticLog.info("Bluetooth relay registered with \(peripheral.name ?? "device")")
        } else {
            // Another paperGIF device that doesn't know this Mac's token.
            rejected.insert(peripheral.identifier)
            disconnect()
            if !lanReachable { startSearching() }
        }
    }

    private static func describe(_ state: CBManagerState) -> String {
        switch state {
        case .unauthorized: "Bluetooth permission is off for paperGIF Mac"
        case .poweredOff: "Bluetooth is off"
        case .unsupported: "Bluetooth is not supported on this Mac"
        default: "Bluetooth is not ready"
        }
    }
}

extension DeviceBluetoothRelay: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            if central.state == .poweredOn {
                if !lanReachable, peripheral == nil { startSearching() }
            } else {
                disconnect()
                if !lanReachable { state = .unavailable(Self.describe(central.state)) }
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        MainActor.assumeIsolated {
            guard self.peripheral == nil, !rejected.contains(peripheral.identifier) else { return }
            connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            guard self.peripheral === peripheral else { return }
            peripheral.discoverServices([Self.serviceUUID])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated { lost(peripheral) }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated { lost(peripheral) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard self.peripheral === peripheral,
                  let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
                if self.peripheral === peripheral { reject(peripheral) }
                return
            }
            peripheral.discoverCharacteristics([Self.controlUUID], for: service)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            guard self.peripheral === peripheral,
                  let control = service.characteristics?.first(where: { $0.uuid == Self.controlUUID }) else {
                if self.peripheral === peripheral { reject(peripheral) }
                return
            }
            peripheral.setNotifyValue(true, for: control)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            guard self.peripheral === peripheral, characteristic.uuid == Self.controlUUID else { return }
            guard error == nil, characteristic.isNotifying, let target else {
                reject(peripheral)
                return
            }
            channel.open { [weak peripheral] frame in
                peripheral?.writeValue(frame, for: characteristic, type: .withResponse)
            }
            do {
                try channel.register(token: target.token)
            } catch {
                reject(peripheral)
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            guard self.peripheral === peripheral, error == nil,
                  characteristic.uuid == Self.controlUUID, let value = characteristic.value else { return }
            channel.receive(value)
        }
    }

    private func reject(_ peripheral: CBPeripheral) {
        rejected.insert(peripheral.identifier)
        disconnect()
        if !lanReachable { startSearching() }
    }

    private func lost(_ peripheral: CBPeripheral) {
        guard self.peripheral === peripheral else { return }
        channel.close()
        controlTransport = nil
        self.peripheral = nil
        guard !lanReachable else { return }
        state = .searching
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !self.lanReachable, self.peripheral == nil else { return }
            self.startSearching()
        }
    }
}
