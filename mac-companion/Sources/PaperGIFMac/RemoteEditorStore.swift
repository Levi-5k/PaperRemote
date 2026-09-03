import Combine
import Foundation

struct DeviceWiFiNetwork: Decodable, Identifiable, Sendable {
    let ssid: String
    let rssi: Int
    let secure: Bool

    var id: String { ssid }
}

@MainActor
final class RemoteEditorStore: ObservableObject {
    enum SendState: Equatable {
        case idle
        case loading
        case sending
        case succeeded(String)
        case failed(String)
    }

    @Published var profile: RemoteProfile {
        didSet { scheduleSave() }
    }
    @Published var deviceAddress: String {
        didSet { scheduleSave() }
    }
    @Published var selectedPageID: UUID?
    @Published var selectedControlID: UUID?
    @Published private(set) var sendState = SendState.idle
    @Published private(set) var wifiNetworks: [DeviceWiFiNetwork] = []
    @Published private(set) var isScanningWiFi = false
    @Published private(set) var wifiScanError: String?
    let localComputer: RemoteComputer

    private var saveTask: Task<Void, Never>?

    init(computerName: String, host: String, port: Int, token: String) {
        let document = Self.loadDocument()
        profile = document?.profile ?? .starter
        deviceAddress = document?.deviceAddress ?? "192.168.4.1"

        let computer = RemoteComputer(name: computerName, host: host, port: port, token: token)
        localComputer = computer
        if profile.computers.isEmpty {
            profile.computers = [computer]
        } else if let index = profile.computers.firstIndex(where: { $0.host == host }) {
            profile.computers[index].name = computerName
            profile.computers[index].port = port
            profile.computers[index].token = token
        } else {
            profile.computers.append(computer)
        }
        profile.macHost = host
        profile.macPort = port
        profile.macToken = token
        selectedPageID = profile.pages.first?.id
    }

    func addLocalComputer() {
        if let existing = profile.computers.first(where: { $0.host == localComputer.host }) {
            var updated = localComputer
            updated.id = existing.id
            upsertComputer(updated)
        } else {
            upsertComputer(localComputer)
        }
    }

    var selectedPageIndex: Int? {
        guard let selectedPageID else { return nil }
        return profile.pages.firstIndex { $0.id == selectedPageID }
    }

    var selectedControlLocation: (page: Int, control: Int)? {
        guard let selectedControlID else { return nil }
        for pageIndex in profile.pages.indices {
            if let controlIndex = profile.pages[pageIndex].controls.firstIndex(where: { $0.id == selectedControlID }) {
                return (pageIndex, controlIndex)
            }
        }
        return nil
    }

    var validationMessage: String? {
        if profile.pages.isEmpty { return "Add at least one page." }
        if profile.pages.count > 8 { return "A remote can contain at most 8 pages." }
        if profile.pages.contains(where: { $0.controls.count > 16 }) {
            return "Each page can contain at most 16 controls."
        }
        if profile.pages.contains(where: { layoutUnitsUsed(on: $0) > 16 }) {
            return "A page has more controls than fit on the display."
        }
        if profile.pages.contains(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "Every page needs a name."
        }
        if profile.pages.flatMap(\.controls).contains(where: { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "Every control needs a label."
        }
        return nil
    }

    func addPage() {
        guard profile.pages.count < 8 else { return }
        let page = RemotePage(name: "Page \(profile.pages.count + 1)", controls: [])
        profile.pages.append(page)
        selectedPageID = page.id
        selectedControlID = nil
    }

    func deleteSelectedPage() {
        guard profile.pages.count > 1, let index = selectedPageIndex else { return }
        profile.pages.remove(at: index)
        selectedPageID = profile.pages[min(index, profile.pages.count - 1)].id
        selectedControlID = nil
    }

    func movePages(from offsets: IndexSet, to destination: Int) {
        let moving = offsets.sorted().map { profile.pages[$0] }
        for index in offsets.sorted(by: >) { profile.pages.remove(at: index) }
        let removedBeforeDestination = offsets.filter { $0 < destination }.count
        profile.pages.insert(contentsOf: moving, at: destination - removedBeforeDestination)
    }

    func addControl(_ control: RemoteControl) {
        guard let pageIndex = selectedPageIndex,
              profile.pages[pageIndex].controls.count < 16,
              layoutUnitsUsed(on: profile.pages[pageIndex]) + layoutUnits(for: control) <= 16 else { return }
        profile.pages[pageIndex].controls.append(control)
        selectedControlID = control.id
    }

    func canAddControl(ofKind kind: RemoteControlKind) -> Bool {
        guard let pageIndex = selectedPageIndex else { return false }
        let page = profile.pages[pageIndex]
        let units = kind == .slider ? 1 : 2
        return page.controls.count < 16 && layoutUnitsUsed(on: page) + units <= 16
    }

    func deleteSelectedControl() {
        guard let location = selectedControlLocation else { return }
        profile.pages[location.page].controls.remove(at: location.control)
        selectedControlID = nil
    }

    func duplicateSelectedControl() {
        guard let location = selectedControlLocation,
              profile.pages[location.page].controls.count < 16 else { return }
        var copy = profile.pages[location.page].controls[location.control]
        guard layoutUnitsUsed(on: profile.pages[location.page]) + layoutUnits(for: copy) <= 16 else { return }
        copy.id = UUID()
        copy.title += " Copy"
        copy.layoutSlot = nil
        profile.pages[location.page].controls.append(copy)
        selectedControlID = copy.id
    }

    func moveSelectedControl(by offset: Int) {
        guard let location = selectedControlLocation else { return }
        let destination = location.control + offset
        guard profile.pages[location.page].controls.indices.contains(destination) else { return }
        profile.pages[location.page].controls.swapAt(location.control, destination)
    }

    func upsertComputer(_ computer: RemoteComputer) {
        if let index = profile.computers.firstIndex(where: { $0.id == computer.id }) {
            profile.computers[index] = computer
        } else if profile.computers.count < 8 {
            profile.computers.append(computer)
        }
        synchronizeDefaultComputer()
    }

    func deleteComputer(_ id: UUID) {
        profile.computers.removeAll { $0.id == id }
        for pageIndex in profile.pages.indices {
            for controlIndex in profile.pages[pageIndex].controls.indices
            where profile.pages[pageIndex].controls[controlIndex].action.computerID == id.uuidString {
                profile.pages[pageIndex].controls[controlIndex].action.computerID = nil
            }
        }
        synchronizeDefaultComputer()
    }

    func addWLEDPage(name: String, host: String) {
        guard profile.pages.count < 8 else { return }
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty, !hasWLEDControls(host: normalizedHost) else { return }
        let page = RemotePage(name: name, controls: [
            RemoteControl(
                title: "Power",
                symbol: "power",
                tintHex: "F2C14E",
                kind: .button,
                action: .init(type: .wledPower, host: normalizedHost, text: "toggle")
            ),
            RemoteControl(
                title: "Brightness",
                symbol: "sun.max.fill",
                tintHex: "F2C14E",
                kind: .slider,
                action: .init(type: .wledBrightness, host: normalizedHost)
            ),
            RemoteControl(
                title: "Preset 1",
                symbol: "sparkles",
                tintHex: "F2C14E",
                kind: .button,
                action: .init(type: .wledPreset, host: normalizedHost, value: 1)
            ),
        ])
        profile.pages.append(page)
        selectedPageID = page.id
        selectedControlID = nil
    }

    func hasWLEDControls(host: String) -> Bool {
        let normalized = Self.normalizedHost(host)
        return profile.pages.flatMap(\.controls).contains {
            Self.normalizedHost($0.action.host) == normalized &&
                [.wledPower, .wledPreset, .wledBrightness].contains($0.action.type)
        }
    }

    func layoutUnitsUsed(on page: RemotePage) -> Int {
        page.controls.reduce(0) { $0 + layoutUnits(for: $1) }
    }

    func canChangeSelectedControl(to kind: RemoteControlKind) -> Bool {
        guard let location = selectedControlLocation else { return false }
        let page = profile.pages[location.page]
        let control = page.controls[location.control]
        let newUnits = kind == .slider ? 1 : 2
        return layoutUnitsUsed(on: page) - layoutUnits(for: control) + newUnits <= 16
    }

    func moveControl(_ controlID: UUID, to requestedSlot: Int) {
        guard let pageIndex = selectedPageIndex,
              let sourceIndex = profile.pages[pageIndex].controls.firstIndex(where: { $0.id == controlID }) else { return }
        let source = profile.pages[pageIndex].controls[sourceIndex]
        guard let destination = RemoteGrid.placement(for: source, at: requestedSlot) else { return }
        let destinationSlots = RemoteGrid.cells(for: destination)
        for index in profile.pages[pageIndex].controls.indices where index != sourceIndex {
            let control = profile.pages[pageIndex].controls[index]
            guard let placement = RemoteGrid.placement(
                for: control,
                at: control.layoutSlot ?? -1
            ) else { continue }
            let slots = RemoteGrid.cells(for: placement)
            if !destinationSlots.isDisjoint(with: slots) {
                profile.pages[pageIndex].controls[index].layoutSlot = nil
            }
        }
        profile.pages[pageIndex].controls[sourceIndex].layoutSlot = destination.slot
    }

    func send() async {
        if let validationMessage {
            sendState = .failed(validationMessage)
            return
        }
        sendState = .sending
        do {
            let url = try Self.remoteURL(from: deviceAddress)
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(localComputer.token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try profile.devicePayload
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  response.statusCode == 200 || response.statusCode == 201 else {
                let detail = String(data: data, encoding: .utf8) ?? "No response body"
                throw SendError.rejected(detail)
            }
            sendState = .succeeded("Remote installed on \(url.host ?? deviceAddress)")
            saveImmediately()
        } catch {
            sendState = .failed(error.localizedDescription)
        }
    }

    func loadFromDevice() async {
        sendState = .loading
        do {
            let url = try Self.remoteURL(from: deviceAddress)
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.setValue("Bearer \(localComputer.token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  response.statusCode == 200 else {
                let detail = String(data: data, encoding: .utf8) ?? "No response body"
                throw SendError.loadRejected(detail)
            }
            let loadedProfile = try JSONDecoder().decode(RemoteProfile.self, from: data)
            guard Self.validationMessage(for: loadedProfile) == nil else {
                throw SendError.invalidProfile
            }
            profile = loadedProfile
            selectedPageID = loadedProfile.pages.first?.id
            selectedControlID = nil
            sendState = .succeeded("Loaded settings from \(url.host ?? deviceAddress)")
            saveImmediately()
        } catch {
            sendState = .failed("Could not load from M5Paper: \(error.localizedDescription)")
        }
    }

    func scanWiFiNetworks() async {
        isScanningWiFi = true
        wifiScanError = nil
        defer { isScanningWiFi = false }
        do {
            let url = try Self.deviceURL(from: deviceAddress, path: "/wifi/networks")
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue("Bearer \(localComputer.token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw SendError.wifiScanRejected
            }
            let result = try JSONDecoder().decode(DeviceWiFiScanResponse.self, from: data)
            let strongestByName = Dictionary(grouping: result.networks.filter { !$0.ssid.isEmpty }, by: \.ssid)
                .compactMapValues { $0.max(by: { $0.rssi < $1.rssi }) }
            wifiNetworks = strongestByName.values.sorted { $0.rssi > $1.rssi }
        } catch {
            wifiScanError = "Could not scan through M5Paper: \(error.localizedDescription)"
        }
    }

    func saveImmediately() {
        saveTask?.cancel()
        let document = RemoteEditorDocument(profile: profile, deviceAddress: deviceAddress)
        do {
            let directory = Self.documentURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(document).write(to: Self.documentURL, options: .atomic)
        } catch {
            sendState = .failed("Could not save the editor: \(error.localizedDescription)")
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.saveImmediately()
        }
    }

    private static var documentURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("paperGIF Mac", isDirectory: true)
            .appendingPathComponent("remote-editor.json")
    }

    private static func loadDocument() -> RemoteEditorDocument? {
        guard let data = try? Data(contentsOf: documentURL) else { return nil }
        return try? JSONDecoder().decode(RemoteEditorDocument.self, from: data)
    }

    private static func remoteURL(from address: String) throws -> URL {
        try deviceURL(from: address, path: "/remote")
    }

    private static func deviceURL(from address: String, path: String) throws -> URL {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed.contains("://") ? trimmed : "http://\(trimmed)"),
              components.scheme?.lowercased() == "http",
              components.host != nil else {
            throw SendError.invalidAddress
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw SendError.invalidAddress }
        return url
    }

    private static func validationMessage(for profile: RemoteProfile) -> String? {
        if profile.version != RemoteProfile.currentVersion { return "The profile version is unsupported." }
        if profile.pages.isEmpty || profile.pages.count > 8 { return "The profile has an invalid page count." }
        if profile.pages.contains(where: { $0.controls.count > 16 }) {
            return "The profile has too many controls on a page."
        }
        return nil
    }

    private func layoutUnits(for control: RemoteControl) -> Int {
        control.gridSpan.width * control.gridSpan.height
    }

    private func synchronizeDefaultComputer() {
        if let computer = profile.computers.first {
            profile.macHost = computer.host
            profile.macPort = computer.port
            profile.macToken = computer.token
        } else {
            profile.macHost = ""
            profile.macPort = 43_821
            profile.macToken = ""
        }
    }

    private static func normalizedHost(_ host: String) -> String {
        var normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("http://") { normalized.removeFirst("http://".count) }
        if normalized.hasPrefix("https://") { normalized.removeFirst("https://".count) }
        while normalized.hasSuffix("/") { normalized.removeLast() }
        return normalized
    }
}

private struct RemoteEditorDocument: Codable {
    var profile: RemoteProfile
    var deviceAddress: String
}

private struct DeviceWiFiScanResponse: Decodable {
    let networks: [DeviceWiFiNetwork]
}

private enum SendError: LocalizedError {
    case invalidAddress
    case invalidProfile
    case loadRejected(String)
    case rejected(String)
    case wifiScanRejected

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            "Enter the M5Paper address, such as 192.168.4.1 or papergif.local."
        case .invalidProfile:
            "The device returned an invalid remote profile."
        case .loadRejected(let detail):
            "The M5Paper did not return a remote profile: \(detail)"
        case .rejected(let detail):
            "The M5Paper rejected the remote profile: \(detail)"
        case .wifiScanRejected:
            "The M5Paper did not return nearby networks."
        }
    }
}