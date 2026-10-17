import CoreBluetooth
import Foundation
import PaperDeviceKit

/// Lists nearby PaperRemote devices over Bluetooth and reads each one's native
/// descriptor, so boards that are not on the LAN still appear in the device picker.
@MainActor
final class DeviceBluetoothScanner: NSObject, ObservableObject {
    struct Nearby: Identifiable, Equatable {
        let id: UUID
        var name: String
        var rssi: Int
        var lastSeen: Date
        var descriptor: DeviceDescriptor?
        var problem: String?

        var tag: String { "ble:\(id.uuidString)" }
        var displayName: String { descriptor?.name ?? name }
    }

    @Published private(set) var nearby: [Nearby] = []
    @Published private(set) var status: String?

    nonisolated static let serviceUUID = CBUUID(string: "7A230001-7D2A-4C7B-9C42-504749460001")
    nonisolated static let descriptorUUID = CBUUID(string: "7A230004-7D2A-4C7B-9C42-504749460001")
    nonisolated static let expiry: TimeInterval = 30

    private var central: CBCentralManager?
    private var isRunning = false
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var queue: [UUID] = []
    private var identifying: CBPeripheral?
    private var characteristic: CBCharacteristic?
    private var reader = DeviceBLEDescriptorReader()
    private var identifyTimeout: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var failures: [UUID: Date] = [:]

    func start() {
        guard !isRunning else { return }
        isRunning = true
        if let central {
            if central.state == .poweredOn { scan() }
        } else {
            central = CBCentralManager(delegate: self, queue: .main)
        }
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.expire(now: Date())
            }
        }
    }

    func stop() {
        isRunning = false
        expiryTask?.cancel()
        central?.stopScan()
        finishIdentifying()
        queue.removeAll()
    }

    func refresh() {
        failures.removeAll()
        for index in nearby.indices where nearby[index].descriptor == nil {
            nearby[index].problem = nil
            enqueue(nearby[index].id)
        }
    }

    func device(tag: String) -> Nearby? { nearby.first { $0.tag == tag } }

    func expire(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.expiry)
        nearby.removeAll { $0.lastSeen < cutoff && $0.id != identifying?.identifier }
    }

    /// Records an advertisement; exposed for tests.
    func noteAdvertisement(id: UUID, name: String?, rssi: Int, at date: Date = Date()) -> Bool {
        if let index = nearby.firstIndex(where: { $0.id == id }) {
            if let name, !name.isEmpty { nearby[index].name = name }
            if rssi != 127 { nearby[index].rssi = rssi }
            nearby[index].lastSeen = date
            return nearby[index].descriptor == nil && nearby[index].problem == nil
        }
        nearby.append(Nearby(id: id, name: name?.isEmpty == false ? name! : "PaperRemote device",
                             rssi: rssi, lastSeen: date))
        return true
    }

    private func scan() {
        central?.scanForPeripherals(withServices: [Self.serviceUUID],
                                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        status = "Searching Bluetooth"
    }

    private func enqueue(_ id: UUID) {
        guard identifying?.identifier != id, !queue.contains(id) else { return }
        if let failed = failures[id], Date().timeIntervalSince(failed) < 60 { return }
        queue.append(id)
        identifyNext()
    }

    private func identifyNext() {
        guard identifying == nil, isRunning, let central else { return }
        while let id = queue.first {
            queue.removeFirst()
            guard let peripheral = peripherals[id] else { continue }
            identifying = peripheral
            characteristic = nil
            reader = DeviceBLEDescriptorReader()
            peripheral.delegate = self
            central.connect(peripheral)
            identifyTimeout?.cancel()
            identifyTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(12))
                guard !Task.isCancelled, let self, self.identifying === peripheral else { return }
                self.fail(peripheral, "Timed out reading device details")
            }
            return
        }
    }

    private func requestPage(_ peripheral: CBPeripheral) {
        guard let characteristic else { return }
        peripheral.writeValue(DeviceBLEDescriptorReader.offsetRequest(reader.nextOffset),
                              for: characteristic, type: .withResponse)
    }

    private func fail(_ peripheral: CBPeripheral, _ message: String) {
        failures[peripheral.identifier] = Date()
        if let index = nearby.firstIndex(where: { $0.id == peripheral.identifier }) {
            nearby[index].problem = message
        }
        finishIdentifying()
    }

    private func finishIdentifying() {
        identifyTimeout?.cancel()
        if let identifying { central?.cancelPeripheralConnection(identifying) }
        identifying = nil
        characteristic = nil
        identifyNext()
    }
}

extension DeviceBluetoothScanner: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:
                if isRunning { scan() }
            case .unauthorized:
                status = "Bluetooth permission denied"
            case .poweredOff:
                status = "Bluetooth is off"
            default:
                status = nil
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            peripherals[peripheral.identifier] = peripheral
            let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
            if noteAdvertisement(id: peripheral.identifier, name: name, rssi: RSSI.intValue) {
                enqueue(peripheral.identifier)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            guard identifying === peripheral else { return }
            peripheral.discoverServices([Self.serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            guard identifying === peripheral else { return }
            fail(peripheral, error?.localizedDescription ?? "Could not connect")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            guard identifying === peripheral else { return }
            fail(peripheral, "Disconnected while reading device details")
        }
    }
}

extension DeviceBluetoothScanner: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard identifying === peripheral else { return }
            guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
                fail(peripheral, "PaperRemote service not found")
                return
            }
            peripheral.discoverCharacteristics([Self.descriptorUUID], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        MainActor.assumeIsolated {
            guard identifying === peripheral else { return }
            guard let found = service.characteristics?.first(where: { $0.uuid == Self.descriptorUUID }) else {
                fail(peripheral, "Firmware does not publish device details over Bluetooth")
                return
            }
            characteristic = found
            requestPage(peripheral)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            guard identifying === peripheral, characteristic.uuid == Self.descriptorUUID else { return }
            if let error {
                fail(peripheral, error.localizedDescription)
                return
            }
            peripheral.readValue(for: characteristic)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            guard identifying === peripheral, characteristic.uuid == Self.descriptorUUID else { return }
            if let error {
                fail(peripheral, error.localizedDescription)
                return
            }
            do {
                if let descriptor = try reader.append(characteristic.value ?? Data()) {
                    if let index = nearby.firstIndex(where: { $0.id == peripheral.identifier }) {
                        nearby[index].descriptor = descriptor
                        nearby[index].problem = nil
                    }
                    finishIdentifying()
                } else {
                    requestPage(peripheral)
                }
            } catch {
                fail(peripheral, error.localizedDescription)
            }
        }
    }
}
