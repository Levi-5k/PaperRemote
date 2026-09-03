import Combine
import CoreBluetooth
import Foundation
import NetworkExtension
import UIKit

@MainActor
final class PaperGIFBluetoothManager: NSObject, ObservableObject {
    struct DeviceMedia: Identifiable, Equatable, Sendable {
        let index: UInt8
        let packageID: String?
        let name: String
        let frameCount: UInt16
        let isActive: Bool

        var id: UInt8 { index }
    }

    struct WiFiNetwork: Identifiable, Equatable, Sendable {
        let ssid: String
        let rssi: Int
        let isSecure: Bool

        var id: String { ssid }
    }

    enum ConnectionState: Equatable {
        case bluetoothUnavailable
        case searching
        case connecting
        case connected

        var description: String {
            switch self {
            case .bluetoothUnavailable: "Bluetooth unavailable"
            case .searching: "Looking for M5Paper"
            case .connecting: "Connecting"
            case .connected: "Connected"
            }
        }
    }

    enum WiFiConnectionState: Equatable {
        case checking
        case connecting
        case unavailable
        case connected

        var description: String {
            switch self {
            case .checking: "Checking"
            case .connecting: "Connecting"
            case .unavailable: "Not connected"
            case .connected: "Connected"
            }
        }
    }

    enum HomeWiFiState: Equatable {
        case notConfigured
        case connecting
        case connected
        case failed(String)

        var description: String {
            switch self {
            case .notConfigured: "Not configured"
            case .connecting: "Connecting"
            case .connected: "Connected"
            case .failed(let message): message
            }
        }

        var systemImage: String {
            switch self {
            case .notConfigured: "wifi.slash"
            case .connecting: "wifi"
            case .connected: "wifi.circle.fill"
            case .failed: "exclamationmark.triangle.fill"
            }
        }
    }

    enum TransferTransport {
        case bluetooth
        case wifi
    }

    private enum BluetoothTransferKind {
        case media
        case remoteProfile

        var finishOpcode: UInt8 {
            switch self {
            case .media: 0x12
            case .remoteProfile: 0x42
            }
        }
    }

    static func preferredTransferTransport(
        homeWiFiState: HomeWiFiState,
        hasHomeWiFiEndpoint: Bool
    ) -> TransferTransport {
        homeWiFiState == .connected && hasHomeWiFiEndpoint ? .wifi : .bluetooth
    }

    static func isDeviceWiFiReachable(device: String, ready: Bool) -> Bool {
        return device == "paperGIF"
    }

    static func deviceMediaWithActiveSelection(
        _ media: [DeviceMedia],
        activeIndex: UInt8?
    ) -> [DeviceMedia] {
        guard let activeIndex else { return media }
        return media.map { item in
            DeviceMedia(
                index: item.index,
                packageID: item.packageID,
                name: item.name,
                frameCount: item.frameCount,
                isActive: item.index == activeIndex
            )
        }
    }

    private struct WiFiStatusResponse: Decodable {
        let device: String
        let ready: Bool
    }

    private struct WiFiUploadResponse: Decodable {
        let ok: Bool
        let id: String
        let name: String
        let frameCount: UInt16
        let libraryCount: Int
    }

    private struct WiFiUploadChunkResponse: Decodable {
        let ok: Bool
        let received: Int
    }

    private struct WiFiLibraryResponse: Decodable {
        struct Item: Decodable {
            let index: UInt8
            let id: String
            let name: String
            let frameCount: UInt16
            let active: Bool
        }

        let items: [Item]
    }

    @Published private(set) var connectionState = ConnectionState.bluetoothUnavailable
    @Published private(set) var wifiConnectionState = WiFiConnectionState.checking
    @Published private(set) var wifiEnabled = false
    @Published private(set) var transferProgress = 0.0
    @Published private(set) var transferStatus: String?
    @Published private(set) var transferMediaID: UUID?
    @Published private(set) var deviceMedia: [DeviceMedia] = []
    @Published private(set) var isLoadingDeviceLibrary = false
    @Published private(set) var deletingDeviceMediaIndex: UInt8?
    @Published private(set) var deviceLibraryError: String?
    @Published private(set) var wifiConnectionError: String?
    @Published private(set) var homeWiFiState = HomeWiFiState.notConfigured
    @Published private(set) var nearbyWiFiNetworks: [WiFiNetwork] = []
    @Published private(set) var isScanningWiFiNetworks = false
    @Published private(set) var wifiScanError: String?
    @Published private(set) var remoteSyncStatus: String?
    @Published private(set) var isTransferring = false {
        didSet {
            UIApplication.shared.isIdleTimerDisabled = isTransferring
        }
    }

    private static let serviceUUID = CBUUID(string: "7A230001-7D2A-4C7B-9C42-504749460001")
    private static let controlUUID = CBUUID(string: "7A230002-7D2A-4C7B-9C42-504749460001")
    private static let dataUUID = CBUUID(string: "7A230003-7D2A-4C7B-9C42-504749460001")
    private static let savedPeripheralKey = "bluetooth.savedPeripheralIdentifier"
    private static let maximumUnacknowledgedUploadBytes = 64 * 1024
    private static let wifiUploadChunkBytes = 8 * 1024 * 1024
    private static let wifiDeviceURL = URL(string: "http://192.168.4.1")!
    private static let wifiPassword = "paperdisplay"
    private static let savedWiFiSSIDKey = "wifi.savedSSID"

    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var controlCharacteristic: CBCharacteristic?
    private var dataCharacteristic: CBCharacteristic?
    private var uploadData: Data?
    private var pendingRemoteProfile: PaperGIFRemoteProfile?
    private var bluetoothTransferKind: BluetoothTransferKind?
    private var uploadOffset = 0
    private var acknowledgedUploadOffset = 0
    private var isAwaitingCompletion = false
    private var preparationTimeout: Task<Void, Never>?
    private var chunkTimeout: Task<Void, Never>?
    private var completionTimeout: Task<Void, Never>?
    private var connectionTimeout: Task<Void, Never>?
    private var deviceLibraryTimeout: Task<Void, Never>?
    private var wifiJoinTask: Task<Void, Never>?
    private var wifiScanTimeout: Task<Void, Never>?
    private var expectedDeviceMediaCount = 0
    private var expectedWiFiNetworkCount = 0
    private var wifiSSID: String?
    private var failedWiFiProbes = 0
    private var homeWiFiDeviceURL: URL?
    private var homeWiFiAuthorization: String?
    private var isBluetoothSuspendedForWiFiTransfer = false

    override init() {
        super.init()
        wifiSSID = UserDefaults.standard.string(forKey: Self.savedWiFiSSIDKey)
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    var canSend: Bool {
        (connectionState == .connected || wifiConnectionState == .connected) && !isTransferring
    }

    var canAccessDeviceLibrary: Bool {
        connectionState == .connected || wifiConnectionState == .connected
    }

    func scanForWiFiNetworks() {
        guard connectionState == .connected,
              !isTransferring,
              let peripheral,
              let controlCharacteristic else {
            wifiScanError = "Connect to the M5Paper over Bluetooth to scan."
            return
        }
        nearbyWiFiNetworks = []
        expectedWiFiNetworkCount = 0
        wifiScanError = nil
        isScanningWiFiNetworks = true
        peripheral.writeValue(Data([0x33]), for: controlCharacteristic, type: .withResponse)
        startWiFiScanTimeout(seconds: .seconds(20))
    }

    func monitorWiFiConnection() async {
        while !Task.isCancelled {
            if !isTransferring && wifiConnectionState != .connecting {
                _ = await probeWiFiConnection()
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func connectToDeviceWiFi() {
        guard wifiConnectionState != .connecting else { return }
        wifiConnectionError = nil
        wifiConnectionState = .connecting

        Task { [weak self] in
            guard let self else { return }
            if await self.probeWiFiConnection() {
                return
            }

            if self.connectionState == .connected,
               let peripheral = self.peripheral,
               let controlCharacteristic = self.controlCharacteristic {
                self.wifiEnabled = true
                peripheral.writeValue(Data([0x30]), for: controlCharacteristic, type: .withResponse)
                self.startWiFiInfoTimeout()
            } else if let wifiSSID = self.wifiSSID {
                self.joinDeviceWiFi(ssid: wifiSSID)
            } else {
                self.failWiFiConnection("Connect to the M5Paper over Bluetooth first")
            }
        }
    }

    func setDeviceWiFiEnabled(_ enabled: Bool) {
        if enabled {
            connectToDeviceWiFi()
        } else {
            disconnectDeviceWiFi()
        }
    }

    private func disconnectDeviceWiFi() {
        guard !isTransferring else { return }
        wifiEnabled = false
        wifiConnectionError = nil

        Task { [weak self] in
            guard let self else { return }
            var request = URLRequest(url: Self.wifiDeviceURL.appending(path: "wifi/off"))
            request.httpMethod = "POST"
            request.timeoutInterval = 3

            let configuration = URLSessionConfiguration.ephemeral
            configuration.allowsCellularAccess = false
            configuration.waitsForConnectivity = false
            configuration.timeoutIntervalForRequest = 3
            configuration.timeoutIntervalForResource = 4
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }

            do {
                let (_, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse,
                      response.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                if let wifiSSID = self.wifiSSID {
                    NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: wifiSSID)
                }
                self.wifiJoinTask?.cancel()
                self.wifiConnectionState = .unavailable
            } catch {
                self.wifiEnabled = true
                self.wifiConnectionError = "Connect to the M5Paper Wi-Fi before turning it off"
            }
        }
    }

    private func startWiFiInfoTimeout() {
        wifiJoinTask?.cancel()
        wifiJoinTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, self.wifiConnectionState == .connecting else { return }
            if let wifiSSID = self.wifiSSID {
                self.joinDeviceWiFi(ssid: wifiSSID)
            } else {
                self.failWiFiConnection("The M5Paper did not provide its Wi-Fi network")
            }
        }
    }

    private func joinDeviceWiFiAfterStartup(ssid: String) {
        wifiJoinTask?.cancel()
        wifiJoinTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, self.wifiConnectionState == .connecting else { return }
            self.joinDeviceWiFi(ssid: ssid)
        }
    }

    private func joinDeviceWiFi(ssid: String) {
        wifiJoinTask?.cancel()
        let configuration = NEHotspotConfiguration(
            ssid: ssid,
            passphrase: Self.wifiPassword,
            isWEP: false
        )
        configuration.joinOnce = true
        NEHotspotConfigurationManager.shared.apply(configuration) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    let nsError = error as NSError
                    guard nsError.domain == NEHotspotConfigurationErrorDomain,
                          nsError.code == NEHotspotConfigurationError.alreadyAssociated.rawValue else {
                        self.failWiFiConnection(error.localizedDescription)
                        return
                    }
                }
                await self.waitForDeviceWiFi()
            }
        }
    }

    private func waitForDeviceWiFi() async {
        for _ in 0..<20 {
            if await probeWiFiConnection() {
                wifiConnectionError = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        failWiFiConnection("Could not reach the M5Paper Wi-Fi")
    }

    private func failWiFiConnection(_ message: String) {
        wifiJoinTask?.cancel()
        wifiConnectionState = .unavailable
        wifiConnectionError = message
    }

    func refreshDeviceLibrary() {
        if wifiConnectionState == .connected {
            deviceLibraryTimeout?.cancel()
            deviceLibraryError = nil
            isLoadingDeviceLibrary = true
            Task { [weak self] in
                guard let self else { return }
                do {
                    self.deviceMedia = try await self.fetchWiFiLibrary()
                    self.isLoadingDeviceLibrary = false
                } catch {
                    self.failDeviceLibrary("Could not load the library over Wi-Fi")
                }
            }
            return
        }

        guard connectionState == .connected,
              !isTransferring,
              let peripheral,
              let controlCharacteristic else { return }
        deviceLibraryTimeout?.cancel()
        deviceMedia = []
        expectedDeviceMediaCount = 0
        deviceLibraryError = nil
        isLoadingDeviceLibrary = true
        peripheral.writeValue(Data([0x20]), for: controlCharacteristic, type: .withResponse)
        startDeviceLibraryTimeout()
    }

    func selectDeviceMedia(_ media: DeviceMedia) {
        guard !isTransferring else { return }
        deviceMedia = Self.deviceMediaWithActiveSelection(deviceMedia, activeIndex: media.index)

        if connectionState == .connected,
           let peripheral,
           let controlCharacteristic {
            peripheral.writeValue(Data([0x25, media.index]), for: controlCharacteristic, type: .withResponse)
            return
        }

        if wifiConnectionState == .connected {
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.selectDeviceMediaOverWiFi(index: media.index)
                } catch {
                    self.deviceMedia = Self.deviceMediaWithActiveSelection(
                        self.deviceMedia,
                        activeIndex: nil
                    )
                    self.deviceLibraryError = "Could not switch the device view"
                }
            }
        }
    }

    func deleteDeviceMedia(_ media: DeviceMedia) {
        guard connectionState == .connected,
              !isTransferring,
              deletingDeviceMediaIndex == nil,
              let peripheral,
              let controlCharacteristic else { return }
        deviceLibraryError = nil
        deletingDeviceMediaIndex = media.index
        peripheral.writeValue(Data([0x23, media.index]), for: controlCharacteristic, type: .withResponse)
        startDeviceLibraryTimeout()
    }

    func send(_ data: Data, name: String, mediaID: UUID? = nil) {
        guard canSend else { return }
        let transport = Self.preferredTransferTransport(
            homeWiFiState: homeWiFiState,
            hasHomeWiFiEndpoint: homeWiFiDeviceURL != nil && homeWiFiAuthorization != nil
        )

        deviceLibraryTimeout?.cancel()
        isLoadingDeviceLibrary = false
        transferMediaID = mediaID
        transferProgress = 0
        transferStatus = transport == .bluetooth ? "Preparing transfer" : "Checking device Wi-Fi"
        isTransferring = true

        Task { [weak self] in
            guard let self else { return }
            switch transport {
            case .bluetooth:
                self.beginBluetoothUpload(data, name: name)
            case .wifi:
                guard let deviceURL = self.homeWiFiDeviceURL,
                      let authorization = self.homeWiFiAuthorization else {
                    self.beginBluetoothUpload(data, name: name)
                    return
                }
                if await self.probeWiFiConnection(
                    at: deviceURL,
                    authorization: authorization,
                    updatesAccessPointState: false
                ), await self.suspendBluetoothForWiFiTransfer() {
                    await self.sendOverWiFi(
                        data,
                        name: name,
                        deviceURL: deviceURL,
                        authorization: authorization
                    )
                } else {
                    self.transferStatus = "Home Wi-Fi unavailable; using Bluetooth"
                    if self.connectionState == .connected {
                        self.beginBluetoothUpload(data, name: name)
                    } else {
                        self.failTransfer("Could not switch the M5Paper to Wi-Fi")
                    }
                }
            }
        }
    }

    private func suspendBluetoothForWiFiTransfer() async -> Bool {
        guard let peripheral, let controlCharacteristic,
              connectionState == .connected else { return false }
        transferStatus = "Switching to full-speed Wi-Fi"
        isBluetoothSuspendedForWiFiTransfer = true
        peripheral.writeValue(Data([0x38]), for: controlCharacteristic, type: .withResponse)
        for _ in 0..<30 {
            if self.controlCharacteristic == nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        isBluetoothSuspendedForWiFiTransfer = false
        return false
    }

    private func reconnectAfterWiFiTransfer() async {
        guard isBluetoothSuspendedForWiFiTransfer else { return }
        isBluetoothSuspendedForWiFiTransfer = false
        try? await Task.sleep(for: .milliseconds(750))
        reconnectOrScan()
    }

    func syncRemoteProfile(_ profile: PaperGIFRemoteProfile) {
        guard connectionState == .connected else {
            remoteSyncStatus = "Connect to the M5Paper over Bluetooth"
            return
        }
        guard let data = profile.devicePayload else {
            remoteSyncStatus = "Could not encode the remote profile"
            return
        }
        guard !isTransferring else {
            pendingRemoteProfile = profile
            remoteSyncStatus = "Waiting to sync latest changes"
            return
        }

        pendingRemoteProfile = nil
        transferMediaID = nil
        transferProgress = 0
        transferStatus = "Preparing remote"
        remoteSyncStatus = "Preparing remote"
        isTransferring = true
        beginBluetoothTransfer(data, command: 0x40, kind: .remoteProfile)
    }

    private func syncPendingRemoteProfile() {
        guard let profile = pendingRemoteProfile else { return }
        pendingRemoteProfile = nil
        syncRemoteProfile(profile)
    }

    private func beginBluetoothUpload(_ data: Data, name: String) {
        guard let peripheral, let controlCharacteristic else {
            failTransfer("Connect to the M5Paper Wi-Fi or Bluetooth")
            return
        }

        var command = Data([0x10])
        command.appendLittleEndian(UInt32(clamping: data.count))
        command.appendLittleEndian(data.crc32)
        let title = name.unicodeScalars
            .compactMap { scalar in
                scalar.isASCII && scalar.value >= 0x20 && scalar.value <= 0x7E
                    ? UInt8(scalar.value)
                    : nil
            }
        command.append(contentsOf: title.prefix(48))
        beginBluetoothTransfer(data, command: command, kind: .media)
    }

    private func beginBluetoothTransfer(
        _ data: Data,
        command: UInt8,
        kind: BluetoothTransferKind
    ) {
        var request = Data([command])
        request.appendLittleEndian(UInt32(clamping: data.count))
        request.appendLittleEndian(data.crc32)
        beginBluetoothTransfer(data, command: request, kind: kind)
    }

    private func beginBluetoothTransfer(
        _ data: Data,
        command: Data,
        kind: BluetoothTransferKind
    ) {
        guard let peripheral, let controlCharacteristic else {
            failTransfer("Connect to the M5Paper over Bluetooth")
            return
        }

        uploadData = data
        bluetoothTransferKind = kind
        uploadOffset = 0
        acknowledgedUploadOffset = 0
        isAwaitingCompletion = false
        chunkTimeout?.cancel()
        completionTimeout?.cancel()
        transferStatus = kind == .media ? "Preparing transfer" : "Preparing remote"
        preparationTimeout?.cancel()
        preparationTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled,
                  let self,
                  self.isTransferring,
                  self.uploadOffset == 0 else { return }
            self.failTransfer("The M5Paper did not respond")
        }
        peripheral.writeValue(command, for: controlCharacteristic, type: .withResponse)
    }

    private func probeWiFiConnection(
        at deviceURL: URL = PaperGIFBluetoothManager.wifiDeviceURL,
        authorization: String? = nil,
        updatesAccessPointState: Bool = true
    ) async -> Bool {
        var request = URLRequest(url: deviceURL.appending(path: "status"))
        request.timeoutInterval = 1
        if let authorization {
            request.setValue("Bearer \(authorization)", forHTTPHeaderField: "Authorization")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = false
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 1
        configuration.timeoutIntervalForResource = 2
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  response.statusCode == 200,
                  let status = try? JSONDecoder().decode(WiFiStatusResponse.self, from: data),
                  Self.isDeviceWiFiReachable(device: status.device, ready: status.ready) else {
                if updatesAccessPointState {
                    recordFailedWiFiProbe()
                }
                return false
            }
            guard updatesAccessPointState else { return true }
            failedWiFiProbes = 0
            if wifiConnectionState != .connected {
                wifiConnectionState = .connected
            }
            if !wifiEnabled {
                wifiEnabled = true
            }
            if wifiConnectionError != nil {
                wifiConnectionError = nil
            }
            return true
        } catch {
            if updatesAccessPointState {
                recordFailedWiFiProbe()
            }
            return false
        }
    }

    private func recordFailedWiFiProbe() {
        let isInitialCheck = wifiConnectionState == .checking
        failedWiFiProbes += 1
        guard (isInitialCheck || failedWiFiProbes >= 8),
              wifiConnectionState != .connecting,
              !isTransferring else { return }
        if wifiConnectionState != .unavailable {
            wifiConnectionState = .unavailable
        }
        if connectionState == .connected, wifiEnabled {
            wifiEnabled = false
        }
    }

    private func fetchWiFiLibrary(
        from deviceURL: URL = PaperGIFBluetoothManager.wifiDeviceURL,
        authorization: String? = nil
    ) async throws -> [DeviceMedia] {
        var request = URLRequest(url: deviceURL.appending(path: "library"))
        request.timeoutInterval = 5
        if let authorization {
            request.setValue("Bearer \(authorization)", forHTTPHeaderField: "Authorization")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = false
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let library = try JSONDecoder().decode(WiFiLibraryResponse.self, from: data)
        return library.items.map {
            DeviceMedia(
                index: $0.index,
                packageID: $0.id,
                name: $0.name,
                frameCount: $0.frameCount,
                isActive: $0.active
            )
        }
    }

    private func selectDeviceMediaOverWiFi(index: UInt8) async throws {
        var request = URLRequest(url: Self.wifiDeviceURL.appending(path: "library/active"))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "index=\(index)".data(using: .utf8)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = false
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        deviceMedia = Self.deviceMediaWithActiveSelection(deviceMedia, activeIndex: index)
    }

    private func sendOverWiFi(
        _ data: Data,
        name: String,
        deviceURL: URL,
        authorization: String
    ) async {
        transferStatus = "Sending over Wi-Fi"
        transferProgress = 0.05

        let safeName = sanitizedTitle(name)

        do {
            var offset = 0
            var installed: WiFiUploadResponse?
            while offset < data.count {
                let upperBound = min(offset + Self.wifiUploadChunkBytes, data.count)
                let isFinal = upperBound == data.count
                let boundary = "paperGIF-\(UUID().uuidString)"
                let header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"media\"; filename=\"\(safeName).pgif\"\r\nContent-Type: application/octet-stream\r\n\r\n"
                let footer = "\r\n--\(boundary)--\r\n"
                var body = Data()
                body.reserveCapacity(header.utf8.count + upperBound - offset + footer.utf8.count)
                body.append(contentsOf: header.utf8)
                body.append(data[offset..<upperBound])
                body.append(contentsOf: footer.utf8)

                var request = URLRequest(url: deviceURL.appending(path: "upload"))
                request.httpMethod = "POST"
                let timeout: TimeInterval = offset == 0 ? 120 : (isFinal ? 60 : 30)
                request.timeoutInterval = timeout
                request.setValue("close", forHTTPHeaderField: "Connection")
                request.setValue(
                    "multipart/form-data; boundary=\(boundary)",
                    forHTTPHeaderField: "Content-Type"
                )
                request.setValue(String(data.count), forHTTPHeaderField: "X-PGIF-Size")
                request.setValue(String(offset), forHTTPHeaderField: "X-PGIF-Offset")
                request.setValue(String(upperBound - offset), forHTTPHeaderField: "X-PGIF-Chunk-Size")
                request.setValue(isFinal ? "1" : "0", forHTTPHeaderField: "X-PGIF-Final")
                request.setValue("Bearer \(authorization)", forHTTPHeaderField: "Authorization")

                let configuration = URLSessionConfiguration.ephemeral
                configuration.allowsCellularAccess = false
                configuration.waitsForConnectivity = false
                configuration.timeoutIntervalForRequest = timeout
                configuration.timeoutIntervalForResource = timeout + 30
                let session = URLSession(configuration: configuration)
                defer { session.invalidateAndCancel() }
                let (responseData, response) = try await session.upload(for: request, from: body)
                session.finishTasksAndInvalidate()
                guard let response = response as? HTTPURLResponse,
                      response.statusCode == (isFinal ? 201 : 200) else {
                    throw URLError(.badServerResponse)
                }

                if isFinal {
                    guard let response = try? JSONDecoder().decode(WiFiUploadResponse.self, from: responseData),
                          response.ok else {
                        throw URLError(.cannotParseResponse)
                    }
                    installed = response
                    transferStatus = "Installing media"
                } else {
                    guard let response = try? JSONDecoder().decode(WiFiUploadChunkResponse.self, from: responseData),
                          response.ok, response.received == upperBound else {
                        throw URLError(.cannotParseResponse)
                    }
                }

                offset = upperBound
                transferProgress = min(Double(offset) / Double(data.count) * 0.95, 0.95)
            }

            guard let installed else { throw URLError(.badServerResponse) }
            transferStatus = "Verifying device library"
            let library = try await fetchWiFiLibrary(
                from: deviceURL,
                authorization: authorization
            )
            guard library.count == installed.libraryCount,
                  library.contains(where: {
                      $0.packageID == installed.id && $0.isActive &&
                          $0.name == installed.name && $0.frameCount == installed.frameCount
                  }) else {
                throw URLError(.cannotParseResponse)
            }

            deviceMedia = library
            transferProgress = 1
            transferStatus = "Media installed over Wi-Fi"
            isTransferring = false
            transferMediaID = nil
        } catch {
            failTransfer("Wi-Fi transfer failed: \(error.localizedDescription)")
        }
        await reconnectAfterWiFiTransfer()
    }

    private func sanitizedTitle(_ name: String) -> String {
        let title = name.unicodeScalars.compactMap { scalar -> Character? in
            guard scalar.isASCII,
                  scalar.value >= 0x20,
                  scalar.value <= 0x7E,
                  scalar != "\"",
                  scalar != "\\" else { return nil }
            return Character(scalar)
        }
        let result = String(title.prefix(48)).trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? "Media" : result
    }

    func forgetDevice() {
        connectionTimeout?.cancel()
        UserDefaults.standard.removeObject(forKey: Self.savedPeripheralKey)
        if let peripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        } else {
            beginScanning()
        }
    }

    private func reconnectOrScan() {
        guard let identifierString = UserDefaults.standard.string(forKey: Self.savedPeripheralKey),
              let identifier = UUID(uuidString: identifierString),
              let savedPeripheral = centralManager.retrievePeripherals(withIdentifiers: [identifier]).first else {
            beginScanning()
            return
        }

        connectionState = .connecting
        peripheral = savedPeripheral
        savedPeripheral.delegate = self
        centralManager.connect(savedPeripheral)
        startConnectionTimeout(for: savedPeripheral, forgetSavedDevice: true)
    }

    private func beginScanning() {
        guard centralManager.state == .poweredOn else { return }
        connectionTimeout?.cancel()
        connectionState = .searching
        centralManager.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func finishConnectingIfReady() {
        guard controlCharacteristic != nil, dataCharacteristic != nil, let peripheral else { return }
        if let controlCharacteristic {
            peripheral.setNotifyValue(true, for: controlCharacteristic)
        }
    }

    private func startConnectionTimeout(for peripheral: CBPeripheral, forgetSavedDevice: Bool) {
        connectionTimeout?.cancel()
        connectionTimeout = Task { [weak self, weak peripheral] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled,
                  let self,
                  let peripheral,
                  self.connectionState == .connecting,
                  self.peripheral === peripheral else { return }
            if forgetSavedDevice {
                UserDefaults.standard.removeObject(forKey: Self.savedPeripheralKey)
            }
            self.centralManager.cancelPeripheralConnection(peripheral)
        }
    }

    private func pumpUpload() {
        guard isTransferring,
              let uploadData,
              let peripheral,
              let dataCharacteristic else { return }

        guard acknowledgedUploadOffset < uploadData.count else {
            requestFinish()
            return
        }

        let maximumLength = min(512, peripheral.maximumWriteValueLength(for: .withoutResponse))
        let sendLimit = min(
            acknowledgedUploadOffset + Self.maximumUnacknowledgedUploadBytes,
            uploadData.count
        )
        while uploadOffset < sendLimit && peripheral.canSendWriteWithoutResponse {
            let end = min(uploadOffset + maximumLength, sendLimit)
            peripheral.writeValue(
                uploadData[uploadOffset..<end],
                for: dataCharacteristic,
                type: .withoutResponse
            )
            uploadOffset = end
        }

        transferProgress = Double(acknowledgedUploadOffset) / Double(uploadData.count)
        startUploadProgressTimeout(expectedOffset: acknowledgedUploadOffset)
    }

    private func startUploadProgressTimeout(expectedOffset: Int) {
        chunkTimeout?.cancel()
        chunkTimeout = Task { [weak self, weak peripheral] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled,
                  let self,
                  self.isTransferring,
                  self.acknowledgedUploadOffset == expectedOffset else { return }
            self.failTransfer("The M5Paper stopped receiving data")
            if let peripheral {
                self.centralManager.cancelPeripheralConnection(peripheral)
            }
        }
    }

    private func requestFinish() {
        guard !isAwaitingCompletion,
              let uploadData,
              acknowledgedUploadOffset == uploadData.count,
              let bluetoothTransferKind,
              let peripheral,
              let controlCharacteristic else { return }
        isAwaitingCompletion = true
        transferStatus = bluetoothTransferKind == .media ? "Installing media" : "Installing remote"
        peripheral.writeValue(
            Data([bluetoothTransferKind.finishOpcode]),
            for: controlCharacteristic,
            type: .withResponse
        )
        completionTimeout?.cancel()
        completionTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled,
                  let self,
                  self.isTransferring else { return }
            self.failTransfer("The M5Paper did not finish installing the media")
        }
    }

    private func handleControlNotification(_ data: Data) {
        guard let opcode = data.first else { return }
        switch opcode {
        case 0x11, 0x41:
            preparationTimeout?.cancel()
            transferStatus = bluetoothTransferKind == .media ? "Sending media" : "Sending remote"
            remoteSyncStatus = bluetoothTransferKind == .remoteProfile ? transferStatus : remoteSyncStatus
            pumpUpload()
        case 0x13:
            preparationTimeout?.cancel()
            chunkTimeout?.cancel()
            completionTimeout?.cancel()
            transferProgress = 1
            transferStatus = "Media installed"
            isTransferring = false
            transferMediaID = nil
            uploadData = nil
            bluetoothTransferKind = nil
            refreshDeviceLibrary()
        case 0x43:
            preparationTimeout?.cancel()
            chunkTimeout?.cancel()
            completionTimeout?.cancel()
            transferProgress = 1
            transferStatus = "Remote synced"
            remoteSyncStatus = "Remote synced"
            isTransferring = false
            uploadData = nil
            bluetoothTransferKind = nil
            syncPendingRemoteProfile()
        case 0x7F:
            if isTransferring {
                failTransfer("The M5Paper rejected the transfer")
            } else if isScanningWiFiNetworks {
                failWiFiScan("The M5Paper could not scan for networks")
            } else {
                failDeviceLibrary("The M5Paper rejected the library request")
            }
        case 0x14, 0x44:
            acknowledgeUploadOffset(uploadData?.count ?? 0)
            requestFinish()
        case 0x15, 0x45:
            handleUploadProgress(data)
        case 0x21:
            handleDeviceLibraryCount(data)
        case 0x22:
            handleDeviceLibraryItem(data)
        case 0x24:
            handleDeviceMediaDeleted(data)
        case 0x31:
            guard data.count > 1,
                  let ssid = String(bytes: data.dropFirst(), encoding: .utf8),
                  ssid.hasPrefix("paperGIF-") else {
                failWiFiConnection("The M5Paper returned an invalid Wi-Fi network")
                return
            }
            wifiJoinTask?.cancel()
            wifiSSID = ssid
            wifiEnabled = true
            UserDefaults.standard.set(ssid, forKey: Self.savedWiFiSSIDKey)
            joinDeviceWiFiAfterStartup(ssid: ssid)
        case 0x32:
            failWiFiConnection("The M5Paper could not start Wi-Fi")
        case 0x34:
            handleWiFiNetworkCount(data)
        case 0x35:
            handleWiFiNetwork(data)
        case 0x36:
            handleHomeWiFiStatus(data)
        default:
            break
        }
    }

    private func handleHomeWiFiStatus(_ data: Data) {
        guard data.count == 4 || data.count == 16 else { return }
        let reason = UInt16(data[2]) | UInt16(data[3]) << 8
        if data[1] != 2 {
            homeWiFiDeviceURL = nil
            homeWiFiAuthorization = nil
        }
        switch data[1] {
        case 0:
            homeWiFiState = .notConfigured
        case 1:
            homeWiFiState = .connecting
        case 2:
            homeWiFiState = .connected
            guard data.count == 16 else { return }
            let address = data[4..<8].map(String.init).joined(separator: ".")
            let authorization = data[8..<16]
                .map { String(format: "%02X", $0) }
                .joined()
            guard address != "0.0.0.0",
                  let deviceURL = URL(string: "http://\(address)") else { return }
            homeWiFiDeviceURL = deviceURL
            homeWiFiAuthorization = authorization
        case 3:
            let message: String
            switch reason {
            case 15, 202, 204:
                message = "Wi-Fi authentication failed"
            case 201:
                message = "Wi-Fi network was not found"
            case 0:
                message = "Wi-Fi connection timed out"
            default:
                message = "Wi-Fi failed (reason \(reason))"
            }
            homeWiFiState = .failed(message)
        default:
            break
        }
    }

    private func handleWiFiNetworkCount(_ data: Data) {
        guard data.count == 2 else {
            failWiFiScan("The M5Paper returned an invalid network list")
            return
        }
        wifiScanTimeout?.cancel()
        expectedWiFiNetworkCount = Int(data[1])
        if expectedWiFiNetworkCount == 0 {
            isScanningWiFiNetworks = false
        } else {
            requestWiFiNetwork(at: 0)
        }
    }

    private func handleWiFiNetwork(_ data: Data) {
        guard data.count >= 4 else {
            failWiFiScan("The M5Paper returned an invalid network")
            return
        }
        wifiScanTimeout?.cancel()
        let index = Int(data[1])
        guard index < expectedWiFiNetworkCount else {
            failWiFiScan("The M5Paper returned an unexpected network")
            return
        }
        if let ssid = String(bytes: data.dropFirst(4), encoding: .utf8), !ssid.isEmpty {
            let network = WiFiNetwork(
                ssid: ssid,
                rssi: Int(Int8(bitPattern: data[2])),
                isSecure: data[3] == 1
            )
            if let existingIndex = nearbyWiFiNetworks.firstIndex(where: { $0.ssid == ssid }) {
                if nearbyWiFiNetworks[existingIndex].rssi < network.rssi {
                    nearbyWiFiNetworks[existingIndex] = network
                }
            } else {
                nearbyWiFiNetworks.append(network)
            }
            nearbyWiFiNetworks.sort { $0.rssi > $1.rssi }
        }
        if index + 1 < expectedWiFiNetworkCount {
            requestWiFiNetwork(at: UInt8(index + 1))
        } else {
            isScanningWiFiNetworks = false
        }
    }

    private func requestWiFiNetwork(at index: UInt8) {
        guard let peripheral, let controlCharacteristic else {
            failWiFiScan("The M5Paper disconnected during the scan")
            return
        }
        peripheral.writeValue(Data([0x35, index]), for: controlCharacteristic, type: .withResponse)
        startWiFiScanTimeout(seconds: .seconds(5))
    }

    private func startWiFiScanTimeout(seconds: Duration) {
        wifiScanTimeout?.cancel()
        wifiScanTimeout = Task { [weak self] in
            try? await Task.sleep(for: seconds)
            guard !Task.isCancelled, let self, self.isScanningWiFiNetworks else { return }
            self.failWiFiScan("The network scan timed out")
        }
    }

    private func failWiFiScan(_ message: String) {
        wifiScanTimeout?.cancel()
        isScanningWiFiNetworks = false
        expectedWiFiNetworkCount = 0
        wifiScanError = message
    }

    private func handleDeviceLibraryCount(_ data: Data) {
        guard data.count == 2 else {
            failDeviceLibrary("The M5Paper returned an invalid library")
            return
        }
        deviceLibraryTimeout?.cancel()
        wifiScanTimeout?.cancel()
        expectedDeviceMediaCount = Int(data[1])
        if expectedDeviceMediaCount == 0 {
            isLoadingDeviceLibrary = false
            return
        }
        requestDeviceLibraryItem(at: 0)
    }

    private func handleUploadProgress(_ data: Data) {
        guard data.count == 5 else {
            failTransfer("The M5Paper returned invalid transfer progress")
            return
        }
        let receivedBytes = UInt32(data[1]) |
            UInt32(data[2]) << 8 |
            UInt32(data[3]) << 16 |
            UInt32(data[4]) << 24
        acknowledgeUploadOffset(Int(receivedBytes))
    }

    private func acknowledgeUploadOffset(_ offset: Int) {
        guard isTransferring,
              let uploadData,
              offset > acknowledgedUploadOffset,
              offset <= uploadOffset,
              offset <= uploadData.count else { return }
        chunkTimeout?.cancel()
        acknowledgedUploadOffset = offset
        transferProgress = Double(offset) / Double(uploadData.count)
        pumpUpload()
    }

    private func handleDeviceLibraryItem(_ data: Data) {
        guard data.count >= 5,
                            Int(data[1]) == deviceMedia.count else {
            failDeviceLibrary("The M5Paper returned an invalid library item")
            return
        }
        deviceLibraryTimeout?.cancel()
        let frameCount = UInt16(data[3]) | UInt16(data[4]) << 8
        let name = String(bytes: data.dropFirst(5), encoding: .utf8) ?? "Untitled"
        deviceMedia.append(DeviceMedia(
            index: data[1],
            packageID: nil,
            name: name.isEmpty ? "Untitled" : name,
            frameCount: frameCount,
            isActive: data[2] == 1
        ))
        if deviceMedia.count < expectedDeviceMediaCount {
            requestDeviceLibraryItem(at: UInt8(deviceMedia.count))
        } else {
            isLoadingDeviceLibrary = false
        }
    }

    private func requestDeviceLibraryItem(at index: UInt8) {
        guard let peripheral, let controlCharacteristic else { return }
        peripheral.writeValue(Data([0x22, index]), for: controlCharacteristic, type: .withResponse)
        startDeviceLibraryTimeout()
    }

    private func handleDeviceMediaDeleted(_ data: Data) {
        guard data.count == 3,
              deletingDeviceMediaIndex == data[1] else {
            failDeviceLibrary("The M5Paper returned an invalid delete response")
            return
        }
        deviceLibraryTimeout?.cancel()
        deletingDeviceMediaIndex = nil
        if data[2] == 1 {
            refreshDeviceLibrary()
        } else {
            deviceLibraryError = "The M5Paper could not delete that item"
        }
    }

    private func startDeviceLibraryTimeout() {
        deviceLibraryTimeout?.cancel()
        deviceLibraryTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            self.failDeviceLibrary("The M5Paper did not respond")
        }
    }

    private func failDeviceLibrary(_ message: String) {
        deviceLibraryTimeout?.cancel()
        isLoadingDeviceLibrary = false
        deletingDeviceMediaIndex = nil
        deviceLibraryError = message
    }

    private func failTransfer(_ message: String) {
        preparationTimeout?.cancel()
        chunkTimeout?.cancel()
        completionTimeout?.cancel()
        if bluetoothTransferKind == .remoteProfile {
            remoteSyncStatus = message
        }
        transferStatus = message
        isTransferring = false
        transferMediaID = nil
        uploadData = nil
        pendingRemoteProfile = nil
        bluetoothTransferKind = nil
        uploadOffset = 0
        acknowledgedUploadOffset = 0
        isAwaitingCompletion = false
    }

    private func resetConnection() {
        connectionTimeout?.cancel()
        preparationTimeout?.cancel()
        chunkTimeout?.cancel()
        completionTimeout?.cancel()
        deviceLibraryTimeout?.cancel()
        peripheral = nil
        controlCharacteristic = nil
        dataCharacteristic = nil
        uploadData = nil
        pendingRemoteProfile = nil
        bluetoothTransferKind = nil
        uploadOffset = 0
        acknowledgedUploadOffset = 0
        isAwaitingCompletion = false
        isTransferring = false
        transferMediaID = nil
        deviceMedia = []
        isLoadingDeviceLibrary = false
        deletingDeviceMediaIndex = nil
        deviceLibraryError = nil
        expectedDeviceMediaCount = 0
        isScanningWiFiNetworks = false
        expectedWiFiNetworkCount = 0
    }
}

extension PaperGIFBluetoothManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            if central.state == .poweredOn {
                reconnectOrScan()
            } else {
                connectionState = .bluetoothUnavailable
                resetConnection()
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
            central.stopScan()
            connectionState = .connecting
            self.peripheral = peripheral
            peripheral.delegate = self
            central.connect(peripheral)
            startConnectionTimeout(for: peripheral, forgetSavedDevice: true)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            startConnectionTimeout(for: peripheral, forgetSavedDevice: true)
            peripheral.discoverServices([Self.serviceUUID])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            connectionTimeout?.cancel()
            resetConnection()
            beginScanning()
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            connectionTimeout?.cancel()
            if isBluetoothSuspendedForWiFiTransfer {
                self.peripheral = nil
                controlCharacteristic = nil
                dataCharacteristic = nil
                connectionState = .searching
                return
            }
            resetConnection()
            reconnectOrScan()
        }
    }
}

extension PaperGIFBluetoothManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard error == nil, let services = peripheral.services else {
                centralManager.cancelPeripheralConnection(peripheral)
                return
            }
            for service in services where service.uuid == Self.serviceUUID {
                peripheral.discoverCharacteristics([Self.controlUUID, Self.dataUUID], for: service)
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            guard error == nil else {
                centralManager.cancelPeripheralConnection(peripheral)
                return
            }
            for characteristic in service.characteristics ?? [] {
                switch characteristic.uuid {
                case Self.controlUUID:
                    controlCharacteristic = characteristic
                case Self.dataUUID:
                    dataCharacteristic = characteristic
                default:
                    break
                }
            }
            finishConnectingIfReady()
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            guard error == nil, characteristic.uuid == Self.controlUUID, let value = characteristic.value else { return }
            handleControlNotification(value)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            guard characteristic.uuid == Self.controlUUID else { return }
            guard error == nil, characteristic.isNotifying else {
                centralManager.cancelPeripheralConnection(peripheral)
                return
            }
            connectionTimeout?.cancel()
            connectionState = .connected
            wifiEnabled = false
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.savedPeripheralKey)
            peripheral.writeValue(Data([0x37]), for: characteristic, type: .withResponse)
            refreshDeviceLibrary()
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            if let error {
                if isTransferring {
                    failTransfer(error.localizedDescription)
                } else if isLoadingDeviceLibrary || deletingDeviceMediaIndex != nil {
                    failDeviceLibrary(error.localizedDescription)
                }
            }
        }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            if isTransferring {
                pumpUpload()
            }
        }
    }
}

private extension Data {
    var crc32: UInt32 {
        reduce(UInt32.max) { partialResult, byte in
            var crc = partialResult ^ UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB8_8320 : 0)
            }
            return crc
        } ^ UInt32.max
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}