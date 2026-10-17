import Foundation
import PaperDeviceKit
import Testing
@testable import paperGIF

private final class FrameLog {
    var frames: [Data] = []
}

private final class StubControlTransport: DeviceControlTransport, @unchecked Sendable {
    let name: String
    private let lock = NSLock()
    private var calls = 0
    private let result: Result<DeviceControlSnapshot, DeviceControlError>

    init(name: String, result: Result<DeviceControlSnapshot, DeviceControlError>) {
        self.name = name
        self.result = result
    }

    var callCount: Int { lock.withLock { calls } }

    func snapshot() async throws -> DeviceControlSnapshot {
        lock.withLock { calls += 1 }
        return try result.get()
    }

    func set(_ request: DeviceControlSetRequest) async throws -> DeviceControlSnapshot {
        lock.withLock { calls += 1 }
        return try result.get()
    }
}

@MainActor
struct PaperGIFDeviceControlsTests {
    private func snapshotFrame(_ json: String, final: Bool = true) -> Data {
        Data([DeviceBLEFrames.snapshotFragment, final ? 1 : 0]) + Data(json.utf8)
    }

    private func channel(timeout: Duration = .seconds(4), log: FrameLog, accepts: Bool = true) -> PaperGIFBLEControlChannel {
        let channel = PaperGIFBLEControlChannel(timeout: timeout)
        channel.write = { frame in
            log.frames.append(frame)
            return accepts
        }
        return channel
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: BLE control channel

    @Test func setWaitsForStatusThenSnapshot() async throws {
        let log = FrameLog()
        let channel = channel(log: log)
        let request = DeviceControlSetRequest(id: "led", value: .bool(true))
        let task = Task { try await channel.set(request) }
        await waitUntil { log.frames.count == 1 }
        #expect(log.frames.first == (try DeviceBLEFrames.setRequest(request)))
        #expect(log.frames.first?.first == 0x52)

        channel.receive(Data([DeviceBLEFrames.setStatus, 0]))
        channel.receive(snapshotFrame(#"{"values":{"led":"#, final: false))
        channel.receive(snapshotFrame(#"true,"brightness":40}}"#))
        let snapshot = try await task.value
        #expect(snapshot.values["led"] == .bool(true))
        #expect(snapshot.values["brightness"] == .number(40))
        #expect(!channel.hasPendingRequest)
    }

    @Test func snapshotBeforeStatusIsNotTakenAsTheSetResult() async throws {
        let log = FrameLog()
        let channel = channel(log: log)
        var pushed: [DeviceControlSnapshot] = []
        channel.onUnsolicitedSnapshot = { pushed.append($0) }
        let task = Task { try await channel.set(DeviceControlSetRequest(id: "led", value: .bool(false))) }
        await waitUntil { log.frames.count == 1 }
        channel.receive(snapshotFrame(#"{"values":{"led":true}}"#))
        #expect(pushed.count == 1)
        channel.receive(Data([DeviceBLEFrames.setStatus, 0]))
        channel.receive(snapshotFrame(#"{"values":{"led":false}}"#))
        #expect(try await task.value.values["led"] == .bool(false))
    }

    @Test func nonzeroStatusMapsToDeviceError() async {
        let log = FrameLog()
        let channel = channel(log: log)
        let task = Task { try await channel.set(DeviceControlSetRequest(id: "mode", value: .string("x"))) }
        await waitUntil { log.frames.count == 1 }
        channel.receive(Data([DeviceBLEFrames.setStatus, 2]))
        await #expect(throws: DeviceControlError.invalidValue) { try await task.value }
    }

    @Test func snapshotRequestWritesOpcodeAndAssemblesFragments() async throws {
        let log = FrameLog()
        let channel = channel(log: log)
        let task = Task { try await channel.snapshot() }
        await waitUntil { log.frames.count == 1 }
        #expect(log.frames == [Data([0x50])])
        channel.receive(snapshotFrame(#"{"values":{"mode":"#, final: false))
        channel.receive(snapshotFrame(#""eco"}}"#))
        #expect(try await task.value.values["mode"] == .string("eco"))
    }

    @Test func timeoutsAndFailedWritesAreTransportFailures() async {
        let log = FrameLog()
        let slow = channel(timeout: .milliseconds(30), log: log)
        do {
            _ = try await slow.snapshot()
            Issue.record("expected a timeout")
        } catch let error as DeviceControlError {
            #expect(error.isTransportFailure)
        } catch { Issue.record("unexpected \(error)") }

        let offline = channel(log: FrameLog(), accepts: false)
        await #expect(throws: DeviceControlError.self) { try await offline.snapshot() }
        let unwired = PaperGIFBLEControlChannel()
        do {
            _ = try await unwired.snapshot()
        } catch let error as DeviceControlError {
            #expect(error.isTransportFailure)
        } catch { Issue.record("unexpected \(error)") }
    }

    @Test func requestsAreSerialized() async throws {
        let log = FrameLog()
        let channel = channel(log: log)
        let first = Task { try await channel.snapshot() }
        await waitUntil { log.frames.count == 1 }
        let second = Task { try await channel.set(DeviceControlSetRequest(id: "led", value: .bool(true))) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(log.frames.count == 1)
        channel.receive(snapshotFrame(#"{"values":{"led":false}}"#))
        #expect(try await first.value.values["led"] == .bool(false))
        await waitUntil { log.frames.count == 2 }
        #expect(log.frames.last?.first == DeviceBLEFrames.setControl)
        channel.receive(Data([DeviceBLEFrames.setStatus, 0]))
        channel.receive(snapshotFrame(#"{"values":{"led":true}}"#))
        #expect(try await second.value.values["led"] == .bool(true))
    }

    @Test func unsolicitedSnapshotsAreForwardedAndResetFailsPending() async {
        let log = FrameLog()
        let channel = channel(log: log)
        var pushed: [DeviceControlSnapshot] = []
        channel.onUnsolicitedSnapshot = { pushed.append($0) }
        #expect(channel.receive(snapshotFrame(#"{"values":{"battery":81}}"#)))
        #expect(pushed.first?.values["battery"] == .number(81))
        #expect(!channel.receive(Data([0x13])))

        let task = Task { try await channel.snapshot() }
        await waitUntil { log.frames.count == 1 }
        channel.reset()
        do {
            _ = try await task.value
            Issue.record("expected a transport failure")
        } catch let error as DeviceControlError {
            #expect(error.isTransportFailure)
        } catch { Issue.record("unexpected \(error)") }

        let rejected = Task { try await channel.snapshot() }
        await waitUntil { log.frames.count == 2 }
        #expect(channel.failPendingRequest(.unsupported("old firmware")))
        await #expect(throws: DeviceControlError.unsupported("old firmware")) { try await rejected.value }
        #expect(!channel.failPendingRequest(.busy))
    }

    // MARK: Model integration

    @Test func modelFallsBackFromUnreachableWiFiToBluetooth() async throws {
        let log = FrameLog()
        let channel = channel(log: log)
        let wifi = StubControlTransport(name: "Wi-Fi", result: .failure(.transport("offline")))
        let backoff = PaperGIFBackoffControlTransport(wifi)
        let model = DeviceControlsModel()
        let led = DeviceControl(id: "led", name: "LED", kind: .toggle)
        model.configure(controls: [led], transports: [backoff, PaperGIFBLEControlTransport(channel: channel)])

        let refresh = Task { await model.refresh() }
        await waitUntil { log.frames.count == 1 }
        channel.receive(snapshotFrame(#"{"values":{"led":false,"other":1}}"#))
        await refresh.value
        #expect(model.activeTransport == "Bluetooth")
        #expect(model.values == ["led": .bool(false)])
        #expect(wifi.callCount == 1)

        model.set(led, to: .bool(true))
        #expect(model.pendingIDs == ["led"])
        await waitUntil { log.frames.count == 2 }
        #expect(wifi.callCount == 1, "Wi-Fi is skipped while backing off")
        channel.receive(Data([DeviceBLEFrames.setStatus, 0]))
        channel.receive(snapshotFrame(#"{"values":{"led":true}}"#))
        await waitUntil { model.pendingIDs.isEmpty }
        #expect(model.values["led"] == .bool(true))

        model.receive(DeviceControlSnapshot(values: ["led": .bool(false)]), via: "Bluetooth")
        #expect(model.values["led"] == .bool(false))
    }

    @Test func deviceRejectionsDoNotFallThroughOrBackOff() async throws {
        let rejecting = StubControlTransport(name: "Wi-Fi", result: .failure(.unauthorized))
        let backoff = PaperGIFBackoffControlTransport(rejecting)
        await #expect(throws: DeviceControlError.unauthorized) { try await backoff.snapshot() }
        await #expect(throws: DeviceControlError.unauthorized) { try await backoff.snapshot() }
        #expect(rejecting.callCount == 2)

        let working = StubControlTransport(name: "Wi-Fi", result: .success(.init(values: ["x": .number(1)])))
        let clock = Date(timeIntervalSince1970: 0)
        let expiring = PaperGIFBackoffControlTransport(
            StubControlTransport(name: "Wi-Fi", result: .failure(.transport("down"))), interval: 30, now: { clock })
        await #expect(throws: DeviceControlError.self) { try await expiring.snapshot() }
        #expect(try await PaperGIFBackoffControlTransport(working).snapshot().values["x"] == .number(1))
    }

    // MARK: Routes

    @Test func routesPreferVerifiedWiFiAndRequireTheSameBluetoothDevice() {
        let descriptor = controlDescriptor(id: "dev-1", transports: ["http", "ble"])
        let both = PaperGIFDeviceControlRoutes.resolve(
            descriptor: descriptor, sessionSelectedID: "dev-1", sessionAddress: "192.168.1.9",
            sessionVerified: true, homeWiFiURL: nil, homeWiFiAuthorization: nil,
            bluetoothDescriptor: descriptor, bluetoothReady: true)
        #expect(both.httpAddress == "192.168.1.9")
        #expect(both.httpCredential == .stored(deviceID: "dev-1"))
        #expect(both.bluetooth)

        let otherDevice = PaperGIFDeviceControlRoutes.resolve(
            descriptor: descriptor, sessionSelectedID: "dev-1", sessionAddress: "",
            sessionVerified: true, homeWiFiURL: URL(string: "http://10.0.0.4"), homeWiFiAuthorization: "abc",
            bluetoothDescriptor: controlDescriptor(id: "dev-2", transports: ["ble"]), bluetoothReady: true)
        #expect(otherDevice.isEmpty)

        let homeWiFi = PaperGIFDeviceControlRoutes.resolve(
            descriptor: descriptor, sessionSelectedID: "dev-1", sessionAddress: "",
            sessionVerified: true, homeWiFiURL: URL(string: "http://10.0.0.4"), homeWiFiAuthorization: "abc",
            bluetoothDescriptor: descriptor, bluetoothReady: false)
        #expect(homeWiFi.httpAddress == "http://10.0.0.4")
        #expect(homeWiFi.httpCredential == .bearer("abc"))
        #expect(!homeWiFi.bluetooth)

        let wifiOnly = controlDescriptor(id: "dev-1", transports: ["http"])
        let noBLE = PaperGIFDeviceControlRoutes.resolve(
            descriptor: wifiOnly, sessionSelectedID: "dev-1", sessionAddress: "",
            sessionVerified: false, homeWiFiURL: nil, homeWiFiAuthorization: nil,
            bluetoothDescriptor: wifiOnly, bluetoothReady: true)
        #expect(noBLE.isEmpty)

        let bleRead = controlDescriptor(id: "dev-1", transports: nil)
        #expect(PaperGIFDeviceControlRoutes.resolve(
            descriptor: bleRead, sessionSelectedID: "dev-1", sessionAddress: "",
            sessionVerified: true, homeWiFiURL: nil, homeWiFiAuthorization: nil,
            bluetoothDescriptor: bleRead, bluetoothReady: true).bluetooth)
    }

    @Test func transportListOrdersWiFiFirst() {
        let channel = PaperGIFBLEControlChannel()
        var routes = PaperGIFDeviceControlRoutes()
        routes.httpAddress = "192.168.1.9"
        routes.httpCredential = .stored(deviceID: "dev-1")
        routes.bluetooth = true
        var requestedToken: String?
        let transports = routes.transports(bluetoothChannel: channel) { requestedToken = $0; return "secret" }
        #expect(transports.map(\.name) == ["Wi-Fi", "Bluetooth"])
        #expect(transports.first is PaperGIFBackoffControlTransport)
        #expect(requestedToken == "dev-1")
        routes.bluetooth = false
        let wifiOnly = routes.transports(bluetoothChannel: channel) { _ in "" }
        #expect(wifiOnly.map(\.name) == ["Wi-Fi"])
        #expect(wifiOnly.first is HTTPDeviceControlTransport)
        #expect(PaperGIFDeviceControlRoutes().transports(bluetoothChannel: channel).isEmpty)
    }

    private func controlDescriptor(id: String, transports: [String]?) -> DeviceDescriptor {
        DeviceDescriptor(
            deviceID: id, name: "Panel", manufacturer: "PaperRemote", boardID: "test.board",
            hardwareRevision: "1", firmwareVersion: "1.0", display: nil, inputs: [],
            layout: .generated(display: nil, inputs: []),
            capabilities: DeviceCapabilities(profileVersions: [7], media: false, firmwareUpdate: false,
                maxProfileBytes: 1024, maxControls: 4, maxPages: 1, transports: transports),
            controls: [DeviceControl(id: "led", name: "LED", kind: .toggle)]
        )
    }

    @Test func nativeBluetoothAccessDoesNotRequireTheM5PaperAdapter() {
        let native = controlDescriptor(id: "supermini", transports: ["http", "ble"])
        let access = PaperGIFBluetoothAccess(descriptor: native, selectedDeviceID: native.deviceID)
        #expect(!access.legacy)
        #expect(access.nativeProfiles)
        #expect(access.controls)
        #expect(access.notifications)
        let other = PaperGIFBluetoothAccess(descriptor: native, selectedDeviceID: "m5")
        #expect(!other.notifications)
        #expect(!other.nativeProfiles)
        let httpOnly = PaperGIFBluetoothAccess(
            descriptor: controlDescriptor(id: "http", transports: ["http"]), selectedDeviceID: "http")
        #expect(!httpOnly.notifications)
        #expect(!httpOnly.nativeProfiles)
        let m5 = PaperGIFBluetoothAccess(descriptor: .legacyM5Paper(deviceID: "m5"), selectedDeviceID: "m5")
        #expect(m5.legacy)
        #expect(m5.notifications)
        #expect(!m5.nativeProfiles)
        #expect(!PaperGIFBluetoothAccess(descriptor: nil, selectedDeviceID: nil).notifications)
    }

    @Test func savedDeviceWithoutPeripheralMappingFindsOnlyTheRequestedDescriptor() {
        let m5ID = UUID(), knobID = UUID()
        let target = PaperGIFBluetoothTarget.savedDevice("m5")
        #expect(target.shouldInspect(m5ID, knownDeviceID: nil))
        #expect(target.shouldInspect(m5ID, knownDeviceID: "m5"))
        #expect(!target.shouldInspect(knobID, knownDeviceID: "knob"))
        #expect(target.accepts(m5ID, descriptor: .legacyM5Paper(deviceID: "m5")))
        #expect(!target.accepts(knobID, descriptor: controlDescriptor(id: "knob", transports: ["ble"])))
        let nearby = PaperGIFBluetoothTarget.nearby(knobID)
        #expect(nearby.shouldInspect(knobID, knownDeviceID: nil))
        #expect(!nearby.shouldInspect(m5ID, knownDeviceID: nil))
        #expect(nearby.accepts(knobID, descriptor: controlDescriptor(id: "knob", transports: ["ble"])))
    }

    @Test func legacyM5PaperBluetoothReusesSavedWiFiIdentity() {
        let peripheral = UUID(), saved: Set = ["papergif-3c689a004f8c"]
        #expect(PaperGIFBluetoothTarget.legacyM5PaperID(
            peripheralID: peripheral, target: .savedDevice("papergif-3c689a004f8c"),
            selectedID: "knob", mappedID: nil, savedM5PaperIDs: saved) == "papergif-3c689a004f8c")
        #expect(PaperGIFBluetoothTarget.legacyM5PaperID(
            peripheralID: peripheral, target: nil,
            selectedID: "papergif-3c689a004f8c", mappedID: nil, savedM5PaperIDs: saved) == "papergif-3c689a004f8c")
        #expect(PaperGIFBluetoothTarget.legacyM5PaperID(
            peripheralID: peripheral, target: .savedDevice("knob"),
            selectedID: "knob", mappedID: nil, savedM5PaperIDs: saved) == peripheral.uuidString)
        #expect(PaperGIFBluetoothTarget.legacyM5PaperID(
            peripheralID: peripheral, target: nil, selectedID: nil,
            mappedID: nil, savedM5PaperIDs: []) == peripheral.uuidString)
    }

    @Test func nativeRefreshUsesBluetoothAndReceivesItsSnapshot() async throws {
        let descriptor = controlDescriptor(id: "knob", transports: ["http", "ble"])
        let access = PaperGIFBluetoothAccess(descriptor: descriptor, selectedDeviceID: descriptor.deviceID)
        let routes = PaperGIFDeviceControlRoutes.resolve(
            descriptor: descriptor, sessionSelectedID: descriptor.deviceID, sessionAddress: "",
            sessionVerified: true, homeWiFiURL: nil, homeWiFiAuthorization: nil,
            bluetoothDescriptor: descriptor, bluetoothReady: access.notifications)
        #expect(routes.bluetooth)
        let log = FrameLog()
        let channel = channel(log: log)
        let model = DeviceControlsModel()
        model.configure(controls: descriptor.controls, transports: routes.transports(bluetoothChannel: channel))
        let refresh = Task { await model.refresh() }
        await waitUntil { log.frames.count == 1 }
        #expect(log.frames == [Data([0x50])])
        channel.receive(snapshotFrame(#"{"values":{"led":true}}"#))
        await refresh.value
        #expect(model.values["led"] == .bool(true))
        #expect(model.activeTransport == "Bluetooth")
        #expect(model.error == nil)
        #expect(!model.isLoading)
    }

    // MARK: Relay forwarding

    private func relayProfile() -> (PaperGIFRemoteProfile, PaperGIFRemoteComputer, PaperGIFRemoteComputer) {
        var profile = PaperGIFRemoteProfile.starter
        let desk = PaperGIFRemoteComputer(name: "Desk", host: "192.168.1.20", port: 43_821, token: "desk-token")
        let studio = PaperGIFRemoteComputer(name: "Studio", host: "studio.local", port: 5000, token: "studio-token")
        let duplicate = PaperGIFRemoteComputer(name: "Desk again", host: "192.168.1.21", token: "desk-token")
        profile.computers = [desk, studio, duplicate]
        profile.macHost = "192.168.1.30"
        profile.macPort = 43_822
        profile.macToken = "legacy-token"
        return (profile, desk, studio)
    }

    private func relayAction(sequence: UInt8, computerID: String) throws -> DeviceBLEFrames.RelayAction {
        var assembler = DeviceBLEFrames.RelayAssembler()
        let json = #"{"computerId":"\#(computerID)","body":{"type":"keyboard","text":"cmd+c"}}"#
        return try #require(try assembler.receive(Data([DeviceBLEFrames.relayAction, sequence, 1]) + Data(json.utf8)))
    }

    @Test func relayRegistersEachDistinctTokenOnce() throws {
        let (profile, _, _) = relayProfile()
        #expect(PaperGIFRelayForwarder.registrationTokens(for: profile) == ["desk-token", "studio-token", "legacy-token"])
        var empty = PaperGIFRemoteProfile.starter
        empty.computers = [PaperGIFRemoteComputer(name: "Blank", host: "h", token: "")]
        empty.macToken = ""
        #expect(PaperGIFRelayForwarder.registrationTokens(for: empty).isEmpty)
        let frame = try DeviceBLEFrames.relayRegistration(role: .forwarder, token: "desk-token")
        #expect(frame.prefix(2) == Data([0x70, 1]))
    }

    @Test func relayFindsComputersByIDWithLegacyFallback() {
        let (profile, desk, studio) = relayProfile()
        #expect(PaperGIFRelayForwarder.destination(for: studio.id.uuidString.lowercased(), in: profile) ==
            .init(host: "studio.local", port: 5000, token: "studio-token"))
        #expect(PaperGIFRelayForwarder.destination(for: desk.id.uuidString, in: profile)?.token == "desk-token")
        let legacy = PaperGIFRelayForwarder.Destination(host: "192.168.1.30", port: 43_822, token: "legacy-token")
        #expect(PaperGIFRelayForwarder.destination(for: "", in: profile) == legacy)
        #expect(PaperGIFRelayForwarder.destination(for: "legacy", in: profile) == legacy)
        #expect(PaperGIFRelayForwarder.destination(for: UUID().uuidString, in: profile) == nil)
        #expect(PaperGIFRelayForwarder.destination(for: "not-a-uuid", in: profile) == nil)
    }

    @Test func relayRequestPostsToActionWithBearerToken() throws {
        let body = Data(#"{"type":"keyboard"}"#.utf8)
        let request = try #require(PaperGIFRelayForwarder.request(
            for: body, to: .init(host: "192.168.1.20", port: 43_821, token: "desk-token")))
        #expect(request.url?.absoluteString == "http://192.168.1.20:43821/action")
        #expect(request.httpMethod == "POST")
        #expect(request.httpBody == body)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer desk-token")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.timeoutInterval <= 5)
        #expect(PaperGIFRelayForwarder.request(for: body, to: .init(host: "", port: 1, token: "t")) == nil)
        #expect(PaperGIFRelayForwarder.request(for: body, to: .init(host: "a/b", port: 1, token: "t")) == nil)
        #expect(PaperGIFRelayForwarder.request(for: body, to: .init(host: "h", port: 0, token: "t")) == nil)
    }

    @Test func relayDeliveryReportsAckStatus() async throws {
        let (profile, desk, _) = relayProfile()
        var sent: [URLRequest] = []
        let action = try relayAction(sequence: 7, computerID: desk.id.uuidString)
        let delivered = await PaperGIFRelayForwarder.deliver(action, profile: profile) { request in
            sent.append(request)
            return 200
        }
        #expect(delivered)
        #expect(sent.first?.url?.host == "192.168.1.20")
        let body = try #require(sent.first?.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(object == ["type": "keyboard", "text": "cmd+c"])
        #expect(DeviceBLEFrames.relayAck(sequence: action.sequence, delivered: delivered) == Data([0x73, 7, 0]))

        let unknown = try relayAction(sequence: 8, computerID: UUID().uuidString)
        #expect(!(await PaperGIFRelayForwarder.deliver(unknown, profile: profile) { _ in 200 }))
        #expect(DeviceBLEFrames.relayAck(sequence: 8, delivered: false) == Data([0x73, 8, 1]))
        #expect(!(await PaperGIFRelayForwarder.deliver(action, profile: profile) { _ in 400 }))
        #expect(!(await PaperGIFRelayForwarder.deliver(action, profile: profile) { _ in throw URLError(.timedOut) }))
        #expect(!(await PaperGIFRelayForwarder.deliver(action, profile: nil) { _ in 200 }))
    }

    // MARK: Fallback classification

    @Test func onlyReachabilityErrorsTriggerBluetoothFallback() {
        for code in [URLError.Code.timedOut, .networkConnectionLost, .notConnectedToInternet,
                     .cannotConnectToHost, .cannotFindHost] {
            #expect(PaperGIFTransportFailure.isTransportFailure(URLError(code)))
        }
        #expect(PaperGIFTransportFailure.isTransportFailure(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
        #expect(PaperGIFTransportFailure.isTransportFailure(DeviceControlError.transport("x")))
        #expect(!PaperGIFTransportFailure.isTransportFailure(URLError(.badServerResponse)))
        #expect(!PaperGIFTransportFailure.isTransportFailure(URLError(.cannotParseResponse)))
        #expect(!PaperGIFTransportFailure.isTransportFailure(URLError(.cancelled)))
        #expect(!PaperGIFTransportFailure.isTransportFailure(DeviceContractError.invalid("HTTP 401")))
        #expect(!PaperGIFTransportFailure.isTransportFailure(DeviceControlError.unauthorized))
        #expect(!PaperGIFTransportFailure.isTransportFailure(CancellationError()))
    }

    // MARK: Presentation

    @Test func controlValuesFormatWithUnitsAndOptionNames() {
        let brightness = DeviceControl(id: "b", name: "Brightness", kind: .range, minimum: 0, maximum: 100, step: 1, unit: "%")
        #expect(PaperGIFDeviceControlRow.format(.number(42), for: brightness) == "42%")
        let temperature = DeviceControl(id: "t", name: "Temp", kind: .range, minimum: 0, maximum: 40, step: 0.5, unit: "°C")
        #expect(PaperGIFDeviceControlRow.format(.number(21.5), for: temperature) == "21.5 °C")
        let mode = DeviceControl(id: "m", name: "Mode", kind: .select,
                                 options: [DeviceControlOption(value: "eco", name: "Economy")])
        #expect(PaperGIFDeviceControlRow.format(.string("eco"), for: mode) == "Economy")
        #expect(PaperGIFDeviceControlRow.format(.bool(true), for: mode) == "On")
        #expect(PaperGIFDeviceControlRow.format(nil, for: mode) == "—")
    }
}
