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

    private struct ProfileSyncRequest {
        let generation: UInt64
        let url: URL
        let token: String
        let payload: Data
    }

    private enum ProfileSyncResult {
        case succeeded(String)
        case failed(String)
    }

    @Published var profile: RemoteProfile {
        didSet {
            scheduleSave()
            scheduleLiveSync()
        }
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
    @Published private(set) var netHomeUnits: [NetHomeUnit] = []
    @Published private(set) var isLoadingNetHomeUnits = false
    @Published private(set) var netHomeError: String?
    let localComputer: RemoteComputer

    private var saveTask: Task<Void, Never>?
    private var liveSyncTask: Task<Void, Never>?
    private var profileSyncTask: Task<Void, Never>?
    private var profileSyncRetryTask: Task<Void, Never>?
    private var pendingProfileSync: ProfileSyncRequest?
    private var profileSyncGeneration: UInt64 = 0
    private var isApplyingDeviceProfile = false
    private let netHomeService: NetHomeService?
    private var knownNetHomeUnits: [NetHomeUnit] = []
    private var netHomeNameAliases: [String: String] = [:]

    init(
        computerName: String,
        host: String,
        port: Int,
        token: String,
        netHomeService: NetHomeService? = nil
    ) {
        self.netHomeService = netHomeService
        let document = Self.loadDocument()
        profile = document?.profile ?? .starter
        deviceAddress = document?.deviceAddress ?? "192.168.4.1"
        knownNetHomeUnits = document?.netHomeUnits ?? []
        netHomeNameAliases = document?.netHomeNameAliases ?? [:]
        netHomeService?.registerUnitNameAliases(netHomeNameAliases)

        var computer = RemoteComputer(name: computerName, host: host, port: port, token: token)
        if let existing = document?.profile.computers.first(where: { $0.host.caseInsensitiveCompare(host) == .orderedSame }) {
            computer.id = existing.id
        }
        localComputer = computer
        if profile.computers.isEmpty {
            profile.computers = [computer]
        } else if let index = profile.computers.firstIndex(where: { $0.host.caseInsensitiveCompare(host) == .orderedSame }) {
            profile.computers[index] = computer
        } else {
            profile.computers.append(computer)
        }
        let duplicateComputerIDs = Set(profile.computers.compactMap { candidate in
            candidate.id != computer.id && candidate.host.caseInsensitiveCompare(host) == .orderedSame
                ? candidate.id.uuidString
                : nil
        })
        if !duplicateComputerIDs.isEmpty {
            profile.computers.removeAll { duplicateComputerIDs.contains($0.id.uuidString) }
            for pageIndex in profile.pages.indices {
                for controlIndex in profile.pages[pageIndex].controls.indices {
                    if let computerID = profile.pages[pageIndex].controls[controlIndex].action.computerID,
                       duplicateComputerIDs.contains(computerID) {
                        profile.pages[pageIndex].controls[controlIndex].action.computerID = computer.id.uuidString
                    }
                    if let computerID = profile.pages[pageIndex].controls[controlIndex].textBox?.tapAction?.computerID,
                       duplicateComputerIDs.contains(computerID) {
                        profile.pages[pageIndex].controls[controlIndex].textBox?.tapAction?.computerID = computer.id.uuidString
                    }
                }
            }
        }
        profile.macHost = host
        profile.macPort = port
        profile.macToken = token
        selectedPageID = profile.pages.first?.id
    }

    func addLocalComputer() {
        if let existing = profile.computers.first(where: { $0.host.caseInsensitiveCompare(localComputer.host) == .orderedSame }) {
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
        if profile.pages.contains(where: { $0.controls.count > RemoteProfile.maximumControlsPerPage }) {
            return "Each page can contain at most \(RemoteProfile.maximumControlsPerPage) controls."
        }
        if profile.pages.contains(where: { layoutUnitsUsed(on: $0) > $0.gridColumns * $0.gridRows }) {
            return "A page has more controls than fit on the display."
        }
        if profile.pages.contains(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "Every page needs a name."
        }
        if profile.pages.flatMap(\.controls).contains(where: {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                $0.symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                ($0.iconBitmap?.isEmpty ?? true)
        }) {
            return "Every control needs a label or icon."
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

    func addPage(_ page: RemotePage) {
        guard profile.pages.count < 8 else { return }
        profile.pages.append(page)
        selectedPageID = page.id
        selectedControlID = nil
    }

    @discardableResult
    func updateModulePages(from module: PaperModuleManifest) -> Int {
        let definitions = Dictionary(uniqueKeysWithValues: (module.pages ?? []).map { ($0.id, $0) })
        var updatedProfile = profile
        var updatedCount = 0
        for index in updatedProfile.pages.indices {
            let existing = updatedProfile.pages[index]
            guard existing.moduleID == module.id,
                  let modulePageID = existing.modulePageID,
                  let definition = definitions[modulePageID] else { continue }
            updatedProfile.pages[index] = ModuleCatalog.updatedPage(
                existing,
                from: definition,
                moduleID: module.id
            )
            updatedCount += 1
        }
        guard updatedCount > 0 else { return 0 }
        profile = updatedProfile
        if let selectedControlID,
           !profile.pages.flatMap(\.controls).contains(where: { $0.id == selectedControlID }) {
            self.selectedControlID = nil
        }
        return updatedCount
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
              profile.pages[pageIndex].controls.count < RemoteProfile.maximumControlsPerPage,
                            layoutUnitsUsed(on: profile.pages[pageIndex]) +
                                layoutUnits(for: control, on: profile.pages[pageIndex]) <=
                                profile.pages[pageIndex].gridColumns * profile.pages[pageIndex].gridRows else { return }
        profile.pages[pageIndex].controls.append(control)
        selectedControlID = control.id
    }

    func canAddControl(ofKind kind: RemoteControlKind) -> Bool {
        guard let pageIndex = selectedPageIndex else { return false }
        let page = profile.pages[pageIndex]
        let units = kind == .slider ? 1 : 2
        return page.controls.count < RemoteProfile.maximumControlsPerPage &&
            layoutUnitsUsed(on: page) + units <= page.gridColumns * page.gridRows
    }

    func deleteSelectedControl() {
        guard let location = selectedControlLocation else { return }
        profile.pages[location.page].controls.remove(at: location.control)
        selectedControlID = nil
    }

    func duplicateSelectedControl() {
        guard let location = selectedControlLocation,
              profile.pages[location.page].controls.count < RemoteProfile.maximumControlsPerPage else { return }
        var copy = profile.pages[location.page].controls[location.control]
        guard layoutUnitsUsed(on: profile.pages[location.page]) +
            layoutUnits(for: copy, on: profile.pages[location.page]) <=
            profile.pages[location.page].gridColumns * profile.pages[location.page].gridRows else { return }
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

    func refreshNetHomeUnits() async {
        guard let netHomeService else {
            netHomeError = "NetHome Plus is unavailable."
            return
        }
        isLoadingNetHomeUnits = true
        netHomeError = nil
        let result = await Task.detached { () -> (units: [NetHomeUnit], error: String?) in
            do {
                return (try netHomeService.listUnits(), nil)
            } catch {
                return ([], error.localizedDescription)
            }
        }.value
        let reconciliation = Self.reconcileNetHomeProfile(
            profile,
            previousUnits: knownNetHomeUnits,
            currentUnits: result.units,
            existingAliases: netHomeNameAliases,
            localComputerID: localComputer.id.uuidString
        )
        knownNetHomeUnits = result.units
        netHomeNameAliases = reconciliation.aliases
        netHomeService.registerUnitNameAliases(reconciliation.aliases)
        netHomeUnits = result.units
        if reconciliation.profile != profile {
            profile = reconciliation.profile
        }
        netHomeError = result.error
        isLoadingNetHomeUnits = false
        saveImmediately()
        if result.error == nil {
            liveSyncTask?.cancel()
            liveSyncTask = nil
            enqueueProfileSync(validateEditorFields: false)
        }
    }

    func addNetHomePage(unit: NetHomeUnit) {
        guard profile.pages.count < 8, !hasNetHomeControls(unitName: unit.name) else { return }
        let computerID = profile.computers.first(where: {
            $0.host.caseInsensitiveCompare(localComputer.host) == .orderedSame
        })?.id.uuidString
        let page = RemotePage.netHomeThermostat(unit: unit.name, computerID: computerID)
        profile.pages.append(page)
        selectedPageID = page.id
        selectedControlID = nil
    }

    func hasNetHomeControls(unitName: String) -> Bool {
        profile.pages.flatMap(\.controls).contains {
            $0.action.host.caseInsensitiveCompare(unitName) == .orderedSame &&
                [.netHomePower, .netHomeTemperature, .netHomeMode, .netHomeFan, .netHomeAuto]
                    .contains($0.action.type)
        }
    }

    func layoutUnitsUsed(on page: RemotePage) -> Int {
        page.controls.reduce(0) { $0 + layoutUnits(for: $1, on: page) }
    }

    func canChangeSelectedControl(to kind: RemoteControlKind) -> Bool {
        guard let location = selectedControlLocation else { return false }
        let page = profile.pages[location.page]
        if page.gridColumns * page.gridRows > 16 {
            return true
        }
        let control = page.controls[location.control]
        let newUnits = kind == .slider ? 1 : 2
        return layoutUnitsUsed(on: page) - layoutUnits(for: control, on: page) + newUnits <=
            page.gridColumns * page.gridRows
    }

    func moveControl(_ controlID: UUID, to requestedSlot: Int) {
        guard let pageIndex = selectedPageIndex,
              let sourceIndex = profile.pages[pageIndex].controls.firstIndex(where: { $0.id == controlID }) else { return }
        let page = profile.pages[pageIndex]
        let source = profile.pages[pageIndex].controls[sourceIndex]
        guard let destination = RemoteGrid.placement(
            for: source, at: requestedSlot, columns: page.gridColumns, rows: page.gridRows
        ) else { return }
        let destinationSlots = RemoteGrid.cells(for: destination, columns: page.gridColumns)
        for index in profile.pages[pageIndex].controls.indices where index != sourceIndex {
            let control = profile.pages[pageIndex].controls[index]
            guard let placement = RemoteGrid.placement(
                for: control,
                at: control.layoutSlot ?? -1,
                columns: page.gridColumns,
                rows: page.gridRows
            ) else { continue }
            let slots = RemoteGrid.cells(for: placement, columns: page.gridColumns)
            if !destinationSlots.isDisjoint(with: slots) {
                profile.pages[pageIndex].controls[index].layoutSlot = nil
            }
        }
        profile.pages[pageIndex].controls[sourceIndex].layoutSlot = destination.slot
    }

    func send() async {
        liveSyncTask?.cancel()
        liveSyncTask = nil
        enqueueProfileSync()
    }

    private func enqueueProfileSync(validateEditorFields: Bool = true) {
        let validationMessage = validateEditorFields
            ? validationMessage
            : Self.validationMessage(for: profile)
        if let validationMessage {
            sendState = .failed(validationMessage)
            return
        }
        do {
            profileSyncRetryTask?.cancel()
            profileSyncRetryTask = nil
            let url = try Self.remoteURL(from: deviceAddress)
            profileSyncGeneration &+= 1
            pendingProfileSync = ProfileSyncRequest(
                generation: profileSyncGeneration,
                url: url,
                token: localComputer.token,
                payload: try profile.devicePayload
            )
            sendState = .sending
            startProfileSyncIfNeeded()
        } catch {
            sendState = .failed(error.localizedDescription)
        }
    }

    private func startProfileSyncIfNeeded() {
        guard profileSyncTask == nil, pendingProfileSync != nil else { return }
        profileSyncTask = Task { [weak self] in
            await self?.drainProfileSyncQueue()
        }
    }

    private func drainProfileSyncQueue() async {
        while let sync = pendingProfileSync {
            pendingProfileSync = nil
            let result = await Self.performProfileSync(sync)
            guard sync.generation == profileSyncGeneration,
                  pendingProfileSync == nil else { continue }
            switch result {
            case .succeeded(let host):
                profileSyncRetryTask?.cancel()
                profileSyncRetryTask = nil
                sendState = .succeeded("Remote installed on \(host)")
                saveImmediately()
            case .failed(let message):
                sendState = .failed(message)
                scheduleProfileSyncRetry(sync)
            }
        }
        profileSyncTask = nil
    }

    private func scheduleProfileSyncRetry(_ sync: ProfileSyncRequest) {
        profileSyncRetryTask?.cancel()
        profileSyncRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self,
                  sync.generation == self.profileSyncGeneration,
                  self.pendingProfileSync == nil else { return }
            self.profileSyncRetryTask = nil
            self.pendingProfileSync = sync
            self.startProfileSyncIfNeeded()
        }
    }

    private nonisolated static func performProfileSync(
        _ sync: ProfileSyncRequest
    ) async -> ProfileSyncResult {
        do {
            var request = URLRequest(url: sync.url)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(sync.token)", forHTTPHeaderField: "Authorization")
            request.httpBody = sync.payload
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  response.statusCode == 200 || response.statusCode == 201 else {
                let detail = String(data: data, encoding: .utf8) ?? "No response body"
                throw SendError.rejected(detail)
            }
            return .succeeded(sync.url.host ?? sync.url.absoluteString)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func loadFromDevice() async {
        guard pendingProfileSync == nil, profileSyncTask == nil, profileSyncRetryTask == nil else {
            sendState = .failed("Waiting to install local changes on M5Paper")
            return
        }
        profileSyncGeneration &+= 1
        pendingProfileSync = nil
        liveSyncTask?.cancel()
        liveSyncTask = nil
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
            let reconciledProfile = Self.reconcileNetHomeProfile(
                loadedProfile,
                previousUnits: knownNetHomeUnits,
                currentUnits: netHomeUnits,
                existingAliases: netHomeNameAliases,
                localComputerID: localComputer.id.uuidString
            ).profile
            guard Self.validationMessage(for: reconciledProfile) == nil else {
                throw SendError.invalidProfile
            }
            isApplyingDeviceProfile = true
            profile = reconciledProfile
            isApplyingDeviceProfile = false
            selectedPageID = reconciledProfile.pages.first?.id
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
        let document = RemoteEditorDocument(
            profile: profile,
            deviceAddress: deviceAddress,
            netHomeUnits: knownNetHomeUnits,
            netHomeNameAliases: netHomeNameAliases
        )
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

    private func scheduleLiveSync() {
        guard !isApplyingDeviceProfile else { return }
        liveSyncTask?.cancel()
        liveSyncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, self.validationMessage == nil else { return }
            self.liveSyncTask = nil
            self.enqueueProfileSync()
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
        if profile.pages.contains(where: { $0.controls.count > RemoteProfile.maximumControlsPerPage }) {
            return "The profile has too many controls on a page."
        }
        return nil
    }

    private func layoutUnits(for control: RemoteControl, on page: RemotePage) -> Int {
        let span = control.gridSpan(columns: page.gridColumns, rows: page.gridRows)
        return span.width * span.height
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

    static func reconcileNetHomeProfile(
        _ source: RemoteProfile,
        previousUnits: [NetHomeUnit],
        currentUnits: [NetHomeUnit],
        existingAliases: [String: String] = [:],
        localComputerID: String
    ) -> (profile: RemoteProfile, aliases: [String: String]) {
        var aliases = Dictionary(uniqueKeysWithValues: existingAliases.map {
            ($0.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), $0.value)
        })
        let previousByID = Dictionary(uniqueKeysWithValues: previousUnits.map { ($0.id, $0) })
        for unit in currentUnits {
            guard let previous = previousByID[unit.id],
                  previous.name.caseInsensitiveCompare(unit.name) != .orderedSame else { continue }
            aliases[previous.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] = unit.name
        }

        let defaultComputerID = source.computers.first?.id.uuidString
        let targetsLocalComputer: (RemoteAction) -> Bool = { action in
            action.computerID.map { $0 == localComputerID } ?? (defaultComputerID == localComputerID)
        }
        let isNetHomeAction: (RemoteActionType) -> Bool = { type in
            switch type {
            case .netHomePower, .netHomeTemperature, .netHomeTemperatureStep,
                 .netHomeMode, .netHomeFan, .netHomeAuto:
                true
            default:
                false
            }
        }
        let configuredNames = Set(source.pages.flatMap(\.controls).compactMap { control -> String? in
            guard isNetHomeAction(control.action.type), targetsLocalComputer(control.action) else { return nil }
            return control.action.host
        })
        let currentNames = Set(currentUnits.map { $0.name.lowercased() })
        let unresolvedNames = configuredNames.filter {
            let normalized = $0.lowercased()
            let resolved = aliases[normalized]?.lowercased() ?? normalized
            return !currentNames.contains(resolved)
        }
        let usedCurrentNames = Set(configuredNames.compactMap { name -> String? in
            let normalized = name.lowercased()
            let resolved = aliases[normalized]?.lowercased() ?? normalized
            return currentNames.contains(resolved) ? resolved : nil
        })
        let unusedUnits = currentUnits.filter { !usedCurrentNames.contains($0.name.lowercased()) }
        if unresolvedNames.count == 1, unusedUnits.count == 1,
           let oldName = unresolvedNames.first, let unit = unusedUnits.first {
            aliases[oldName.lowercased()] = unit.name
        }

        for key in aliases.keys {
            var resolved = aliases[key] ?? key
            var visited: Set<String> = [key]
            while let next = aliases[resolved.lowercased()], visited.insert(resolved.lowercased()).inserted {
                resolved = next
            }
            aliases[key] = resolved
        }

        var profile = source
        for pageIndex in profile.pages.indices {
            let originalPageName = profile.pages[pageIndex].name
            if let renamedPage = aliases[originalPageName.lowercased()] {
                profile.pages[pageIndex].name = renamedPage
            }
            for controlIndex in profile.pages[pageIndex].controls.indices {
                var action = profile.pages[pageIndex].controls[controlIndex].action
                if isNetHomeAction(action.type), targetsLocalComputer(action),
                   let renamedUnit = aliases[action.host.lowercased()] {
                    action.host = renamedUnit
                    profile.pages[pageIndex].controls[controlIndex].action = action
                }
                if var tapAction = profile.pages[pageIndex].controls[controlIndex].textBox?.tapAction,
                   isNetHomeAction(tapAction.type), targetsLocalComputer(tapAction),
                   let renamedUnit = aliases[tapAction.host.lowercased()] {
                    tapAction.host = renamedUnit
                    profile.pages[pageIndex].controls[controlIndex].textBox?.tapAction = tapAction
                }
            }
        }
        return (profile, aliases)
    }
}

private struct RemoteEditorDocument: Codable {
    var profile: RemoteProfile
    var deviceAddress: String
    var netHomeUnits: [NetHomeUnit]?
    var netHomeNameAliases: [String: String]?
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