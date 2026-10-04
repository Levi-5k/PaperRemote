import Combine
import HomeKit
import NetworkExtension
import SwiftUI
import UIKit

private struct PaperGIFPairingRequest: Encodable {
    let deviceName: String
}

private struct PaperGIFPairingResponse: Decodable {
    let token: String
}

private struct PaperGIFNetHomeUnit: Decodable, Sendable {
    let id: String
    let name: String
}

private struct PaperGIFConnectedNetHomeUnit: Identifiable, Sendable {
    let unit: PaperGIFNetHomeUnit
    let computer: PaperGIFRemoteComputer

    var id: String { "\(computer.id.uuidString):\(unit.id)" }
}

private enum PaperGIFRemoteEditorPanel: String, CaseIterable, Identifiable {
    case layout = "Layout"
    case connections = "Connections"

    var id: Self { self }
}

struct PaperGIFRemoteView: View {
    @Binding var profile: PaperGIFRemoteProfile
    @ObservedObject var bluetoothManager: PaperGIFBluetoothManager

    @StateObject private var computerDiscovery = PaperGIFComputerDiscovery()
    @StateObject private var wledDiscovery = PaperGIFWLEDDiscovery()
    @StateObject private var networkDeviceDiscovery = PaperGIFNetworkDeviceDiscovery()
    @StateObject private var homeManager = PaperGIFHomeManager()
    @State private var saveError: String?
    @State private var wifiStatus: String?
    @State private var computerStatus: String?
    @State private var wledStatus: String?
    @State private var networkDeviceStatus: String?
    @State private var homeStatus: String?
    @State private var isSettingUpMatter = false
    @State private var matterSetupManager = HMAccessorySetupManager()
    @State private var manualNetworkAddress = ""
    @State private var manualWLEDAddress = ""
    @State private var isReadingWiFi = false
    @State private var isConnectingComputer = false
    @State private var isConnectingWLED = false
    @State private var isLoadingNetHomeUnits = false
    @State private var netHomeUnits: [PaperGIFConnectedNetHomeUnit] = []
    @State private var netHomeStatus: String?
    @State private var showsAdvancedComputerSettings = false
    @State private var showsManualWLED = false
    @State private var selectedComputerID: UUID?
    @State private var computerDraftName = ""
    @State private var computerDraftHost = ""
    @State private var computerDraftPort = 43_821
    @State private var computerDraftToken = ""
    @State private var selectedPanel = PaperGIFRemoteEditorPanel.layout
    @State private var liveSyncTask: Task<Void, Never>?
    @State private var liveSyncStatus: String?
    @State private var availableModules = (try? PaperGIFModuleCatalog.bundledModules()) ?? []
    @State private var isLoadingModules = false
    @State private var moduleStatus: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Remote Editor", selection: $selectedPanel) {
                    ForEach(PaperGIFRemoteEditorPanel.allCases) { panel in
                        Text(panel.rawValue).tag(panel)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 10)

                List {
                    if selectedPanel == .layout {
                        pagesSection
                        modulesSection
                        screensaverSection
                        saveSection
                    } else {
                        deviceWiFiSection
                        computerSection
                        temperatureUnitSection
                        netHomeSection
                        homeSection
                        networkDevicesSection
                        wledSection
                    }
                }
            }
            .navigationTitle("Remote")
            .toolbar {
                if selectedPanel == .layout {
                    EditButton()
                }
            }
            .onAppear {
                computerDiscovery.start()
                wledDiscovery.start()
                networkDeviceDiscovery.start()
                prepareComputerDraft()
                if bluetoothManager.connectionState == .connected,
                   bluetoothManager.nearbyWiFiNetworks.isEmpty {
                    bluetoothManager.scanForWiFiNetworks()
                }
            }
            .onDisappear {
                computerDiscovery.stop()
                wledDiscovery.stop()
                networkDeviceDiscovery.stop()
                liveSyncTask?.cancel()
            }
            .task { await refreshNetHomeUnits() }
            .task { await refreshModuleCatalog() }
            .onChange(of: bluetoothManager.remoteSyncStatus) {
                if let status = bluetoothManager.remoteSyncStatus,
                   wifiStatus != nil {
                    wifiStatus = status
                }
                if bluetoothManager.remoteSyncStatus == "Remote synced" {
                    liveSyncStatus = "Live on M5Paper"
                }
                if bluetoothManager.remoteSyncStatus == "Loaded remote from M5Paper" {
                    liveSyncTask?.cancel()
                    selectedComputerID = nil
                    prepareComputerDraft()
                    liveSyncStatus = "Loaded from M5Paper"
                }
                if bluetoothManager.remoteSyncStatus == "Could not load remote from M5Paper",
                   bluetoothManager.connectionState == .connected {
                    liveSyncStatus = "Sending saved remote over Bluetooth…"
                    bluetoothManager.syncRemoteProfile(profile)
                }
            }
            .onChange(of: bluetoothManager.connectionState) {
                if bluetoothManager.connectionState == .connected,
                   bluetoothManager.nearbyWiFiNetworks.isEmpty {
                    bluetoothManager.scanForWiFiNetworks()
                }
            }
            .onChange(of: homeManager.powerServices) {
                Task { await shareHomeAccessories() }
            }
            .onChange(of: profile.computers) {
                Task { await shareHomeAccessories() }
            }
            .alert("Couldn’t Save Remote", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(saveError ?? "Unknown error")
            }
        }
    }

    private var deviceWiFiSection: some View {
        Section {
            LabeledContent("M5Paper") {
                Label(
                    bluetoothManager.connectionState.description,
                    systemImage: bluetoothManager.connectionState == .connected
                        ? "checkmark.circle.fill"
                        : "antenna.radiowaves.left.and.right"
                )
                .foregroundStyle(
                    bluetoothManager.connectionState == .connected
                        ? Color.green
                        : Color.secondary
                )
            }
            LabeledContent("Home Wi-Fi") {
                Label(
                    bluetoothManager.homeWiFiState.description,
                    systemImage: bluetoothManager.homeWiFiState.systemImage
                )
                .foregroundStyle(
                    bluetoothManager.homeWiFiState == .connected
                        ? Color.green
                        : Color.secondary
                )
            }
            Button {
                bluetoothManager.scanForWiFiNetworks()
            } label: {
                Label(
                    bluetoothManager.isScanningWiFiNetworks ? "Scanning…" : "Scan for Networks",
                    systemImage: "wifi"
                )
            }
            .disabled(
                bluetoothManager.connectionState != .connected ||
                bluetoothManager.isScanningWiFiNetworks ||
                bluetoothManager.isTransferring
            )

            if bluetoothManager.isScanningWiFiNetworks {
                ProgressView()
            }

            ForEach(bluetoothManager.nearbyWiFiNetworks) { network in
                Button {
                    profile.wifiSSID = network.ssid
                    if !network.isSecure {
                        profile.wifiPassword = ""
                    }
                    wifiStatus = "Selected \(network.ssid)"
                } label: {
                    HStack {
                        Label(network.ssid, systemImage: network.isSecure ? "lock.fill" : "wifi")
                        Spacer()
                        Text("\(network.rssi) dBm")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if profile.wifiSSID == network.ssid {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            if let error = bluetoothManager.wifiScanError {
                Text(error)
                    .foregroundStyle(.secondary)
            }

            if !profile.wifiSSID.isEmpty {
                LabeledContent("Selected Network", value: profile.wifiSSID)
                if selectedWiFiRequiresPassword {
                    SecureField("Wi-Fi password", text: $profile.wifiPassword)
                }
            }

            Button {
                useCurrentWiFi()
            } label: {
                Label(
                    isReadingWiFi ? "Reading Network…" : "Use This iPhone’s Wi-Fi",
                    systemImage: "wifi"
                )
            }
            .disabled(isReadingWiFi)

            Button {
                guard save() else { return }
                wifiStatus = "Sending Wi-Fi settings…"
                bluetoothManager.syncRemoteProfile(profile)
            } label: {
                Label("Send Wi-Fi Settings", systemImage: "paperplane")
            }
            .disabled(
                profile.wifiSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                bluetoothManager.connectionState != .connected ||
                bluetoothManager.isTransferring
            )

            if let wifiStatus {
                Text(wifiStatus)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Device Wi-Fi")
        } footer: {
            Text("The M5Paper scans nearby networks over Bluetooth. Select the same Wi-Fi used by your computers, then send the settings.")
        }
    }

    private var selectedWiFiRequiresPassword: Bool {
        bluetoothManager.nearbyWiFiNetworks.first { $0.ssid == profile.wifiSSID }?.isSecure ?? true
    }

    private var computerSection: some View {
        Section {
            ForEach(profile.computers) { computer in
                Button {
                    selectPairedComputer(computer)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Label(computer.name, systemImage: "desktopcomputer")
                            Text("\(computer.host):\(computer.port)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selectedComputerID == computer.id {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            Button {
                computerDiscovery.start()
            } label: {
                Label(
                    computerDiscovery.state == .searching ? "Searching…" : "Search for Computers",
                    systemImage: "magnifyingglass"
                )
            }
            .disabled(computerDiscovery.state == .searching)

            if computerDiscovery.state == .searching {
                ProgressView()
            }

            ForEach(computerDiscovery.computers) { computer in
                Button {
                    selectDiscoveredComputer(computer)
                } label: {
                    HStack {
                        Label(computer.name, systemImage: "desktopcomputer")
                        Spacer()
                        Image(systemName: pairedComputer(for: computer) == nil
                            ? "plus.circle"
                            : "checkmark.circle.fill")
                            .foregroundStyle(pairedComputer(for: computer) == nil
                                ? Color.accentColor
                                : Color.green)
                    }
                }
                .buttonStyle(.plain)
            }

            if computerDiscovery.state == .ready && computerDiscovery.computers.isEmpty {
                ContentUnavailableView(
                    "No Computers Found",
                    systemImage: "desktopcomputer.trianglebadge.exclamationmark"
                )
            }

            if case .failed(let message) = computerDiscovery.state {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }

            TextField("Computer name", text: $computerDraftName)

            Button {
                connectComputer()
            } label: {
                Label(
                    isConnectingComputer
                        ? (computerDraftToken.isEmpty ? "Waiting for Approval…" : "Testing…")
                        : (computerDraftToken.isEmpty ? "Request Pairing" : "Test Connection"),
                    systemImage: computerDraftToken.isEmpty ? "link.badge.plus" : "network"
                )
            }
            .disabled(
                isConnectingComputer ||
                computerDraftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                computerDraftHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                (selectedComputerID == nil && profile.computers.count >= 8)
            )

            DisclosureGroup("Advanced", isExpanded: $showsAdvancedComputerSettings) {
                TextField("Host", text: $computerDraftHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Stepper("Port: \(computerDraftPort)", value: $computerDraftPort, in: 1...65_535)
            }

            if let computerStatus {
                Text(computerStatus)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Computers")
        } footer: {
            Text("Run paperGIF Mac, select a discovered computer, then approve the pairing request on that Mac. Individual controls can target any paired computer.")
        }
    }

    private var screensaverSection: some View {
        Section("Display") {
            Stepper(
                "Start after \(profile.screensaverDelaySeconds) seconds",
                value: screensaverDelayBinding,
                in: 10...3_600,
                step: 10
            )
            Stepper(
                "Quality refresh every \(profile.buttonQualityRefreshInterval) presses",
                value: $profile.buttonQualityRefreshInterval,
                in: 1...100
            )
            Stepper(
                "Element spacing: \(profile.elementRefreshDelayMilliseconds) ms",
                value: $profile.elementRefreshDelayMilliseconds,
                in: 0...500,
                step: 5
            )
        }
    }

    private var temperatureUnitSection: some View {
        Section("Temperature") {
            Picker("Units", selection: $profile.temperatureUnit) {
                Text("Celsius").tag(PaperGIFTemperatureUnit.celsius)
                Text("Fahrenheit").tag(PaperGIFTemperatureUnit.fahrenheit)
            }
            .pickerStyle(.segmented)
        }
    }

    private var netHomeSection: some View {
        Section {
            Button {
                Task { await refreshNetHomeUnits() }
            } label: {
                Label(
                    isLoadingNetHomeUnits ? "Refreshing…" : "Refresh AC Units",
                    systemImage: "arrow.clockwise"
                )
            }
            .disabled(isLoadingNetHomeUnits || profile.computers.isEmpty)

            if isLoadingNetHomeUnits {
                ProgressView()
            }

            ForEach(netHomeUnits) { connection in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(connection.unit.name, systemImage: "snowflake")
                        Spacer()
                        if hasNetHomeControls(for: connection) {
                            Label("Added", systemImage: "checkmark.circle.fill")
                                .font(.subheadline)
                                .foregroundStyle(.green)
                        }
                    }
                    Text("NetHome Plus via \(connection.computer.name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !hasNetHomeControls(for: connection) {
                        Button {
                            addNetHomePage(for: connection)
                        } label: {
                            Label("Add Thermostat Page", systemImage: "plus.circle.fill")
                        }
                        .buttonStyle(.bordered)
                        .disabled(profile.pages.count >= 8)
                    }
                }
            }

            if let netHomeStatus {
                Text(netHomeStatus)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Air Conditioners")
        } footer: {
            Text("Sign in to NetHome Plus on a paired Mac. Adding a unit creates power, setpoint, fan, mode, and sensor auto controls.")
        }
    }

    private var wledSection: some View {
        Section {
            Button {
                wledStatus = nil
                wledDiscovery.start()
            } label: {
                Label(
                    wledDiscovery.state == .searching
                        ? "Scanning…"
                        : (wledDiscovery.devices.isEmpty ? "Scan for WLED Devices" : "Scan Again"),
                    systemImage: "dot.radiowaves.left.and.right"
                )
            }
            .disabled(wledDiscovery.state == .searching)

            if wledDiscovery.state == .searching {
                ProgressView()
            }

            ForEach(wledDiscovery.devices) { device in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(device.name, systemImage: "lightbulb.fill")
                        Spacer()
                        if hasWLEDControls(for: device) {
                            Label("Added", systemImage: "checkmark.circle.fill")
                                .font(.subheadline)
                                .foregroundStyle(.green)
                        }
                    }
                    Text(device.actionHost)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    if !hasWLEDControls(for: device) {
                        Button {
                            addWLEDControls(for: device)
                        } label: {
                            Label("Add WLED Page", systemImage: "plus.circle.fill")
                        }
                        .buttonStyle(.bordered)
                        .disabled(profile.pages.count >= 8)
                    }
                }
            }

            if wledDiscovery.state == .ready && wledDiscovery.devices.isEmpty {
                Label("No WLED devices found", systemImage: "lightbulb.slash")
                    .foregroundStyle(.secondary)
            }

            if case .failed(let message) = wledDiscovery.state {
                Text(message)
                    .foregroundStyle(.secondary)
            }

            if let wledStatus {
                Text(wledStatus)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup("Add by Address", isExpanded: $showsManualWLED) {
                TextField("Hostname or IP address", text: $manualWLEDAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .onSubmit(connectManualWLED)

                Button(action: connectManualWLED) {
                    Label(
                        isConnectingWLED ? "Connecting…" : "Connect and Add Page",
                        systemImage: "link"
                    )
                }
                .disabled(
                    isConnectingWLED ||
                    manualWLEDAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    profile.pages.count >= 8
                )
            }
        } header: {
            Text("WLED Devices")
        } footer: {
            Text("The iPhone, M5Paper, and WLED device must use the same Wi-Fi. Adding a device creates a page with power, brightness, and preset controls.")
        }
    }

    private var homeSection: some View {
        Section {
            if homeManager.authorizationStatus.contains(.authorized) {
                Button {
                    homeManager.refreshAccessories()
                } label: {
                    Label(
                        homeManager.isRefreshing ? "Refreshing Home…" : "Refresh Home Accessories",
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(homeManager.isRefreshing)

                ForEach(homeManager.powerServices) { service in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(service.displayName, systemImage: "powerplug.fill")
                            Spacer()
                            if hasHomePowerControl(for: service) {
                                Label("Added", systemImage: "checkmark.circle.fill")
                                    .font(.subheadline)
                                    .foregroundStyle(.green)
                            }
                        }
                        Text(service.homeName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            homeStatus = "Toggling \(service.displayName)…"
                            homeManager.performPowerCommand(
                                "toggle",
                                accessoryID: service.accessoryID,
                                serviceID: service.serviceID
                            ) { error in
                                Task { @MainActor in
                                    homeStatus = error.map {
                                        "Couldn’t control \(service.displayName): \($0.localizedDescription)"
                                    } ?? "Toggled \(service.displayName)."
                                }
                            }
                        } label: {
                            Label("Test Power", systemImage: "power")
                        }
                        .buttonStyle(.bordered)
                        .disabled(!service.isReachable)
                        if !hasHomePowerControl(for: service) {
                            Button {
                                addHomePowerPage(for: service)
                            } label: {
                                Label("Add Switch Page", systemImage: "plus.circle.fill")
                            }
                            .buttonStyle(.bordered)
                            .disabled(profile.pages.count >= 8)
                        }
                    }
                }
                if homeManager.powerServices.isEmpty {
                    Label("No power accessories found in Home", systemImage: "house")
                        .foregroundStyle(.secondary)
                }
            } else if homeManager.authorizationStatus.contains(.restricted) {
                Button {
                    UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                } label: {
                    Label("Allow Home Access in Settings", systemImage: "gear")
                }
            } else {
                ProgressView("Requesting Home access…")
            }

            if let homeStatus {
                Text(homeStatus)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Accessories from Home")
        } footer: {
            Text("These controls use Apple Home through the connected iPhone. The iPhone must be connected to M5Paper over Bluetooth when the control is pressed.")
        }
    }

    private var networkDevicesSection: some View {
        Section {
            Button {
                setUpMatterAccessory()
            } label: {
                Label(
                    isSettingUpMatter ? "Opening Matter Setup…" : "Set Up with Apple Home",
                    systemImage: "homekit"
                )
            }
            .disabled(isSettingUpMatter)

            Button {
                networkDeviceStatus = nil
                networkDeviceDiscovery.start()
            } label: {
                Label(
                    networkDeviceDiscovery.state == .searching
                        ? "Searching…"
                        : (networkDeviceDiscovery.devices.isEmpty ? "Search for Network Devices" : "Search Again"),
                    systemImage: "network"
                )
            }
            .disabled(networkDeviceDiscovery.state == .searching)

            if networkDeviceDiscovery.state == .searching {
                ProgressView()
            }

            ForEach(networkDeviceDiscovery.devices) { device in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(
                            device.name,
                            systemImage: device.kind.isShelly || device.kind.isEWeLink
                                ? "powerplug.fill" : "network"
                        )
                        Spacer()
                        if hasNetworkControl(for: device) {
                            Label("Added", systemImage: "checkmark.circle.fill")
                                .font(.subheadline)
                                .foregroundStyle(.green)
                        }
                    }
                    Text("\(device.kind.rawValue) · \(device.actionHost)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    if device.kind.isEWeLink {
                        Label(
                            device.requiresDeviceKey
                                ? "Encrypted eWeLink LAN API"
                                : "eWeLink LAN API",
                            systemImage: device.requiresDeviceKey ? "lock.fill" : "checkmark.shield.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if device.requiresDeviceKey {
                            Text("Direct control requires an eWeLink LAN device key, which this model does not expose locally.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if !hasEWeLinkControl(for: device) {
                            Button {
                                addEWeLinkPage(for: device)
                            } label: {
                                Label("Add Switch Page", systemImage: "plus.circle.fill")
                            }
                            .buttonStyle(.bordered)
                            .disabled(profile.pages.count >= 8)
                        }
                    } else if !hasLocalHTTPControl(for: device) {
                        Button {
                            addLocalHTTPPage(for: device)
                        } label: {
                            Label(
                                device.kind.isShelly ? "Add Switch Page" : "Add HTTP Page",
                                systemImage: "plus.circle.fill"
                            )
                        }
                        .buttonStyle(.bordered)
                        .disabled(profile.pages.count >= 8)
                    }
                }
            }

            if networkDeviceDiscovery.state == .ready && networkDeviceDiscovery.devices.isEmpty {
                Label("No HTTP devices found", systemImage: "network.slash")
                    .foregroundStyle(.secondary)
            }

            if case .failed(let message) = networkDeviceDiscovery.state {
                Text(message)
                    .foregroundStyle(.secondary)
            }

            if let networkDeviceStatus {
                Text(networkDeviceStatus)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup("Add by Address") {
                TextField("Hostname or private IP address", text: $manualNetworkAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .onSubmit(addManualNetworkDevice)

                Button(action: addManualNetworkDevice) {
                    Label("Add HTTP Page", systemImage: "plus.circle.fill")
                }
                .disabled(
                    manualNetworkAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    profile.pages.count >= 8
                )
            }
        } header: {
            Text("Network Devices")
        } footer: {
            Text("Encrypted eWeLink LAN control requires a device key. The S41s does not expose that key through its local pairing mode.")
        }
    }

    private func setUpMatterAccessory(suggestedName: String? = nil) {
        isSettingUpMatter = true
        networkDeviceStatus = "Use the printed Matter code in the Apple Home setup sheet."
        let request = HMAccessorySetupRequest()
        request.suggestedAccessoryName = suggestedName
        matterSetupManager.performAccessorySetup(using: request) { _, error in
            Task { @MainActor in
                isSettingUpMatter = false
                networkDeviceStatus = error?.localizedDescription
                    ?? "Matter accessory added to Apple Home."
            }
        }
    }

    private var pagesSection: some View {
        Section("Pages") {
            ForEach(Array(profile.pages.enumerated()), id: \.element.id) { index, page in
                NavigationLink {
                    PaperGIFRemotePageEditor(
                        page: livePageBinding(page),
                        pages: profile.pages,
                        computers: profile.computers,
                        temperatureUnit: profile.temperatureUnit,
                        wledDiscovery: wledDiscovery
                    )
                } label: {
                    HStack(spacing: 14) {
                        PaperGIFRemotePageThumbnail(page: page)
                            .frame(width: 52, height: 92)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(page.name)
                                .font(.headline)
                            Text("Page \(index + 1) of \(profile.pages.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(page.controls.count) control\(page.controls.count == 1 ? "" : "s")")
                                .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .onDelete { offsets in
                var updatedProfile = profile
                updatedProfile.pages.remove(atOffsets: offsets)
                applyLiveProfile(updatedProfile)
            }
            .onMove { offsets, destination in
                var updatedProfile = profile
                updatedProfile.pages.move(fromOffsets: offsets, toOffset: destination)
                applyLiveProfile(updatedProfile)
            }

            Button {
                var updatedProfile = profile
                updatedProfile.pages.append(PaperGIFRemotePage(
                    name: "Page \(profile.pages.count + 1)",
                    controls: []
                ))
                applyLiveProfile(updatedProfile)
            } label: {
                Label("Add Page", systemImage: "plus")
            }
            .disabled(profile.pages.count >= 8)
        }
    }

    private var modulesSection: some View {
        Section {
            if isLoadingModules && availableModules.isEmpty {
                HStack {
                    ProgressView()
                    Text("Loading module pages…")
                }
            }

            ForEach(availableModules) { module in
                ForEach(module.pages ?? []) { definition in
                    modulePageRow(module: module, definition: definition)
                }
            }

            if let moduleStatus {
                HStack {
                    Text(moduleStatus)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry") {
                        Task { await refreshModuleCatalog() }
                    }
                }
            }
        } header: {
            Text("Modules")
        } footer: {
            Text("Add published page layouts or configure which paired computer handles their commands and live data.")
        }
    }

    @ViewBuilder
    private func modulePageRow(
        module: PaperGIFModuleManifest,
        definition: PaperGIFModulePageDefinition
    ) -> some View {
        let installed = modulePageIndex(moduleID: module.id, pageID: definition.id) != nil
        HStack(spacing: 12) {
            PaperGIFRemotePageThumbnail(page: definition.page)
                .frame(width: 38, height: 68)

            VStack(alignment: .leading, spacing: 3) {
                Text(definition.page.name)
                    .font(.headline)
                Text(module.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(definition.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if PaperGIFModuleCatalog.requiresComputer(definition.page),
               !profile.computers.isEmpty {
                Menu {
                    ForEach(profile.computers) { computer in
                        Button(computer.name) {
                            installModulePage(
                                module: module,
                                definition: definition,
                                computerID: computer.id
                            )
                        }
                    }
                } label: {
                    Image(systemName: installed ? "gearshape" : "plus.circle")
                }
                .accessibilityLabel(installed
                    ? "Configure \(definition.page.name)"
                    : "Add \(definition.page.name)")
                .disabled(!installed && profile.pages.count >= 8)
            } else if installed {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Added")
            } else {
                Button {
                    installModulePage(
                        module: module,
                        definition: definition,
                        computerID: nil
                    )
                } label: {
                    Image(systemName: "plus.circle")
                }
                .accessibilityLabel("Add \(definition.page.name)")
                .disabled(profile.pages.count >= 8)
            }
        }
    }

    private func modulePageIndex(moduleID: String, pageID: String) -> Int? {
        profile.pages.firstIndex {
            $0.moduleID == moduleID && $0.modulePageID == pageID
        }
    }

    @MainActor
    private func refreshModuleCatalog() async {
        guard !isLoadingModules else { return }
        isLoadingModules = true
        moduleStatus = nil
        defer { isLoadingModules = false }

        do {
            availableModules = try await PaperGIFModuleCatalog.downloadModules()
        } catch {
            if availableModules.isEmpty {
                moduleStatus = "Couldn’t load module pages: \(error.localizedDescription)"
            } else {
                moduleStatus = "Showing built-in module pages while offline."
            }
        }
    }

    private func installModulePage(
        module: PaperGIFModuleManifest,
        definition: PaperGIFModulePageDefinition,
        computerID: UUID?
    ) {
        var updatedProfile = profile
        if let index = modulePageIndex(moduleID: module.id, pageID: definition.id) {
            updatedProfile.pages[index] = PaperGIFModuleCatalog.configure(
                updatedProfile.pages[index],
                for: computerID
            )
            moduleStatus = "Configured \(definition.page.name)."
        } else {
            guard updatedProfile.pages.count < 8 else { return }
            let page = PaperGIFModuleCatalog.configure(
                PaperGIFModuleCatalog.clonePage(definition, moduleID: module.id),
                for: computerID
            )
            updatedProfile.pages.append(page)
            moduleStatus = "Added \(definition.page.name)."
        }
        applyLiveProfile(updatedProfile)
    }

    private var saveSection: some View {
        Section {
            if let liveSyncStatus {
                Label(liveSyncStatus, systemImage: liveSyncStatus == "Live on M5Paper"
                    ? "checkmark.circle.fill"
                    : "arrow.triangle.2.circlepath")
                    .foregroundStyle(liveSyncStatus == "Live on M5Paper"
                        ? Color.green
                        : Color.secondary)
            }

            Button {
                save()
            } label: {
                Label("Save Remote", systemImage: "square.and.arrow.down")
            }
            .disabled(profile.pages.isEmpty)

            Button {
                guard save() else { return }
                bluetoothManager.syncRemoteProfile(profile)
            } label: {
                Label("Save & Sync to M5Paper", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(
                profile.pages.isEmpty ||
                bluetoothManager.connectionState != .connected ||
                bluetoothManager.isTransferring
            )

            if let status = bluetoothManager.remoteSyncStatus {
                Text(status)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Layout changes save automatically and sync over Bluetooth after you pause editing.")
        }
    }

    private var screensaverDelayBinding: Binding<Int> {
        Binding(
            get: { profile.screensaverDelaySeconds },
            set: { delay in
                var updatedProfile = profile
                updatedProfile.screensaverDelaySeconds = delay
                applyLiveProfile(updatedProfile)
            }
        )
    }

    private func livePageBinding(_ fallbackPage: PaperGIFRemotePage) -> Binding<PaperGIFRemotePage> {
        Binding(
            get: {
                profile.pages.first(where: { $0.id == fallbackPage.id }) ?? fallbackPage
            },
            set: { updatedPage in
                var updatedProfile = profile
                guard let index = updatedProfile.pages.firstIndex(where: {
                    $0.id == updatedPage.id
                }), updatedProfile.pages[index] != updatedPage else { return }
                let updatesSliderValueOnly = isSliderValueOnlyChange(
                    from: updatedProfile.pages[index],
                    to: updatedPage
                )
                updatedProfile.pages[index] = updatedPage
                applyLiveProfile(updatedProfile, immediately: updatesSliderValueOnly)
            }
        )
    }

    private func applyLiveProfile(
        _ updatedProfile: PaperGIFRemoteProfile,
        immediately: Bool = false
    ) {
        var updatedProfile = updatedProfile
        updatedProfile.markUpdated()
        profile = updatedProfile
        if immediately {
            liveSyncTask?.cancel()
            guard save(updatedProfile) else { return }
            guard bluetoothManager.connectionState == .connected else {
                liveSyncStatus = "Saved; connect M5Paper to sync"
                return
            }
            liveSyncStatus = "Syncing changes…"
            bluetoothManager.syncRemoteProfile(updatedProfile)
        } else {
            scheduleLiveSync(updatedProfile)
        }
    }

    private func isSliderValueOnlyChange(
        from previousPage: PaperGIFRemotePage,
        to updatedPage: PaperGIFRemotePage
    ) -> Bool {
        guard previousPage.id == updatedPage.id,
              previousPage.name == updatedPage.name,
              previousPage.controls.count == updatedPage.controls.count else { return false }
        var changedSliderValue = false
        for (previousControl, updatedControl) in zip(previousPage.controls, updatedPage.controls) {
            if previousControl == updatedControl {
                continue
            }
            var normalizedControl = updatedControl
            normalizedControl.action.value = previousControl.action.value
            guard previousControl == normalizedControl,
                  updatedControl.kind == .slider else { return false }
            changedSliderValue = true
        }
        return changedSliderValue
    }

    private func scheduleLiveSync(_ profileSnapshot: PaperGIFRemoteProfile) {
        liveSyncTask?.cancel()
        liveSyncStatus = "Saving changes…"
        liveSyncTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, save(profileSnapshot) else { return }

            guard bluetoothManager.connectionState == .connected else {
                liveSyncStatus = "Saved; connect M5Paper to sync"
                return
            }

            liveSyncStatus = "Syncing changes…"
            bluetoothManager.syncRemoteProfile(profileSnapshot)
        }
    }

    @discardableResult
    private func save() -> Bool {
        profile.markUpdated()
        return save(profile)
    }

    @discardableResult
    private func save(_ profile: PaperGIFRemoteProfile) -> Bool {
        do {
            try PaperGIFStorage.saveRemoteProfile(profile)
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    private func useCurrentWiFi() {
        isReadingWiFi = true
        wifiStatus = nil
        NEHotspotNetwork.fetchCurrent { network in
            let ssid = network?.ssid
            Task { @MainActor in
                isReadingWiFi = false
                if let ssid, !ssid.isEmpty {
                    profile.wifiSSID = ssid
                    wifiStatus = "Using \(ssid)"
                } else {
                    wifiStatus = "Couldn’t read this network. Enter its name manually."
                }
            }
        }
    }

    private func connectComputer() {
        let name = computerDraftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = computerDraftHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !host.isEmpty else { return }
        let isPairing = computerDraftToken.isEmpty

        isConnectingComputer = true
        computerStatus = isPairing ? "Approve the request on \(name)." : "Testing \(name)…"
        Task {
            defer { isConnectingComputer = false }
            var components = URLComponents()
            components.scheme = "http"
            components.host = host
            components.port = computerDraftPort
            components.path = isPairing ? "/pair" : "/status"
            guard let url = components.url else {
                computerStatus = "That computer address isn’t valid."
                return
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = isPairing ? 45 : 5
            if isPairing {
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try? JSONEncoder().encode(PaperGIFPairingRequest(
                    deviceName: UIDevice.current.name
                ))
            } else {
                request.setValue("Bearer \(computerDraftToken)", forHTTPHeaderField: "Authorization")
            }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let response = response as? HTTPURLResponse else {
                    computerStatus = "\(name) returned an invalid response."
                    return
                }
                if response.statusCode == 403 {
                    computerStatus = "Pairing was declined on \(name)."
                    return
                }
                guard response.statusCode == 200 else {
                    computerStatus = response.statusCode == 401
                        ? "This pairing is no longer valid. Request pairing again."
                        : "Couldn’t connect to \(name)."
                    if response.statusCode == 401 {
                        computerDraftToken = ""
                    }
                    return
                }
                let pairedToken: String
                if isPairing {
                    guard let pairing = try? JSONDecoder().decode(PaperGIFPairingResponse.self, from: data),
                          !pairing.token.isEmpty else {
                        computerStatus = "\(name) didn’t return pairing credentials."
                        return
                    }
                    pairedToken = pairing.token
                    computerDraftToken = pairedToken
                } else {
                    pairedToken = computerDraftToken
                }
                let computer = PaperGIFRemoteComputer(
                    id: selectedComputerID ?? UUID(),
                    name: name,
                    host: host,
                    port: computerDraftPort,
                    token: pairedToken
                )
                if let index = profile.computers.firstIndex(where: { $0.id == computer.id }) {
                    profile.computers[index] = computer
                } else {
                    guard profile.computers.count < 8 else {
                        computerStatus = "The eight-computer limit has been reached."
                        return
                    }
                    profile.computers.append(computer)
                }
                selectedComputerID = computer.id
                syncDefaultComputer()
                guard save() else { return }
                await refreshNetHomeUnits()
                if isPairing, bluetoothManager.connectionState == .connected {
                    computerStatus = "Paired with \(computer.name); syncing M5Paper…"
                    bluetoothManager.syncRemoteProfile(profile)
                } else {
                    computerStatus = isPairing
                        ? "Paired with \(computer.name). Connect M5Paper to sync."
                        : "Connected to \(computer.name)."
                }
            } catch {
                computerStatus = "Couldn’t reach \(name). Make sure paperGIF Mac is running."
            }
        }
    }

    private func prepareComputerDraft() {
        guard computerDraftHost.isEmpty else { return }
        if let computer = profile.computers.first {
            selectPairedComputer(computer)
        } else if !profile.macHost.isEmpty {
            computerDraftName = "Default Computer"
            computerDraftHost = profile.macHost
            computerDraftPort = profile.macPort
            computerDraftToken = profile.macToken
        }
    }

    private func selectPairedComputer(_ computer: PaperGIFRemoteComputer) {
        selectedComputerID = computer.id
        computerDraftName = computer.name
        computerDraftHost = computer.host
        computerDraftPort = computer.port
        computerDraftToken = computer.token
        computerStatus = "Editing \(computer.name)"
    }

    private func selectDiscoveredComputer(_ computer: PaperGIFComputerDiscovery.Computer) {
        if var paired = pairedComputer(for: computer) {
            if paired.host != computer.host,
               let index = profile.computers.firstIndex(where: { $0.id == paired.id }) {
                paired.host = computer.host
                profile.computers[index] = paired
                syncDefaultComputer()
                if save(), bluetoothManager.connectionState == .connected {
                    bluetoothManager.syncRemoteProfile(profile)
                }
            }
            selectPairedComputer(paired)
            return
        }
        selectedComputerID = nil
        computerDraftName = computer.name
        computerDraftHost = computer.host
        computerDraftPort = computer.port
        computerDraftToken = ""
        computerStatus = "Ready to request pairing from \(computer.name)."
    }

    private func pairedComputer(
        for discovered: PaperGIFComputerDiscovery.Computer
    ) -> PaperGIFRemoteComputer? {
        profile.computers.first {
            $0.port == discovered.port &&
                ($0.host.caseInsensitiveCompare(discovered.host) == .orderedSame ||
                 $0.name.caseInsensitiveCompare(discovered.name) == .orderedSame)
        }
    }

    private func syncDefaultComputer() {
        guard let computer = profile.computers.first else {
            profile.macHost = ""
            profile.macPort = 43_821
            profile.macToken = ""
            return
        }
        profile.macHost = computer.host
        profile.macPort = computer.port
        profile.macToken = computer.token
    }

    private func hasWLEDControls(for device: PaperGIFWLEDDiscovery.Device) -> Bool {
        let deviceHost = normalizedWLEDHost(device.actionHost)
        return profile.pages.contains { page in
            page.controls.contains { control in
                normalizedWLEDHost(control.action.host) == deviceHost &&
                [.wledPower, .wledBrightness, .wledPreset].contains(control.action.type)
            }
        }
    }

    private func addWLEDControls(for device: PaperGIFWLEDDiscovery.Device) {
        guard profile.pages.count < 8 else {
            wledStatus = "Delete a page before adding another WLED device."
            return
        }
        guard !hasWLEDControls(for: device) else {
            wledStatus = "Controls for \(device.name) are already in the remote."
            return
        }
        let actionHost = device.actionHost
        let controls = [
            PaperGIFRemoteControl.button(
                title: "Power",
                symbol: "power",
                tintHex: "F2C14E",
                action: .init(type: .wledPower, host: actionHost, text: "toggle")
            ),
            PaperGIFRemoteControl(
                title: "Brightness",
                symbol: "sun.max.fill",
                tintHex: "F2C14E",
                kind: .slider,
                action: .init(type: .wledBrightness, host: actionHost)
            ),
            PaperGIFRemoteControl.button(
                title: "Preset 1",
                symbol: "sparkles",
                tintHex: "F2C14E",
                action: .init(type: .wledPreset, host: actionHost, value: 1)
            ),
        ]
        var updatedProfile = profile
        updatedProfile.pages.append(PaperGIFRemotePage(name: device.name, controls: controls))
        applyLiveProfile(updatedProfile)
        wledStatus = "Added \(device.name). Open Layout to arrange its controls."
    }

    private func connectManualWLED() {
        guard !isConnectingWLED else { return }
        isConnectingWLED = true
        wledStatus = "Connecting to WLED…"
        let address = manualWLEDAddress
        Task {
            defer { isConnectingWLED = false }
            do {
                let device = try await wledDiscovery.device(at: address)
                manualWLEDAddress = device.actionHost
                addWLEDControls(for: device)
            } catch {
                wledStatus = error.localizedDescription
            }
        }
    }

    private func hasLocalHTTPControl(
        for device: PaperGIFNetworkDeviceDiscovery.Device
    ) -> Bool {
        let deviceHost = normalizedNetworkHost(device.actionHost)
        return profile.pages.contains { page in
            page.controls.contains { control in
                control.action.type == .localHTTP &&
                normalizedNetworkHost(control.action.host) == deviceHost
            }
        }
    }

    private func hasEWeLinkControl(
        for device: PaperGIFNetworkDeviceDiscovery.Device
    ) -> Bool {
        let deviceHost = normalizedNetworkHost(device.actionHost)
        return profile.pages.contains { page in
            page.controls.contains { control in
                control.action.type == .eWeLinkPower &&
                normalizedNetworkHost(control.action.host) == deviceHost &&
                control.action.deviceID == device.deviceID
            }
        }
    }

    private func hasNetworkControl(
        for device: PaperGIFNetworkDeviceDiscovery.Device
    ) -> Bool {
        device.kind.isEWeLink
            ? hasEWeLinkControl(for: device)
            : hasLocalHTTPControl(for: device)
    }

    private func addEWeLinkPage(for device: PaperGIFNetworkDeviceDiscovery.Device) {
        guard profile.pages.count < 8 else {
            networkDeviceStatus = "Delete a page before adding another network device."
            return
        }
        guard let deviceID = device.deviceID, !deviceID.isEmpty else {
            networkDeviceStatus = "The eWeLink device did not publish its device ID."
            return
        }
        guard !hasEWeLinkControl(for: device) else {
            networkDeviceStatus = "A control for \(device.name) is already in the remote."
            return
        }
        var control = PaperGIFRemoteControl.button(
            title: "Power",
            symbol: "power",
            tintHex: "34C759",
            action: .init(
                type: .eWeLinkPower,
                host: device.actionHost,
                text: "toggle",
                deviceID: deviceID
            )
        )
        control.isToggle = true
        var updatedProfile = profile
        updatedProfile.pages.append(
            PaperGIFRemotePage(name: device.name, controls: [control])
        )
        applyLiveProfile(updatedProfile)
        networkDeviceStatus = "Added \(device.name)."
    }

    private func hasHomePowerControl(for service: PaperGIFHomePowerService) -> Bool {
        profile.pages.contains { page in
            page.controls.contains { control in
                control.action.type == .iPhoneHomePower &&
                control.action.deviceID == service.accessoryID &&
                control.action.host == service.serviceID
            }
        }
    }

    private func addHomePowerPage(for service: PaperGIFHomePowerService) {
        guard profile.pages.count < 8, !hasHomePowerControl(for: service) else { return }
        var control = PaperGIFRemoteControl.button(
            title: "Power",
            symbol: "power",
            tintHex: "34C759",
            action: .init(
                type: .iPhoneHomePower,
                host: service.serviceID,
                text: "toggle",
                deviceID: service.accessoryID
            )
        )
        control.isToggle = true
        var updatedProfile = profile
        updatedProfile.pages.append(
            PaperGIFRemotePage(name: service.accessoryName, controls: [control])
        )
        applyLiveProfile(updatedProfile)
        homeStatus = "Added \(service.displayName)."
    }

    private func addLocalHTTPPage(for device: PaperGIFNetworkDeviceDiscovery.Device) {
        guard profile.pages.count < 8 else {
            networkDeviceStatus = "Delete a page before adding another network device."
            return
        }
        guard !hasLocalHTTPControl(for: device) else {
            networkDeviceStatus = "A control for \(device.name) is already in the remote."
            return
        }
        let title = device.kind.isShelly ? "Toggle" : "Request"
        var control = PaperGIFRemoteControl.button(
            title: title,
            symbol: device.kind.isShelly ? "power" : "network",
            tintHex: device.kind.isShelly ? "34C759" : "4A90E2",
            action: .init(
                type: .localHTTP,
                host: device.actionHost,
                text: device.togglePath,
                httpMethod: "GET"
            )
        )
        control.isToggle = device.kind.isShelly ? true : nil
        var updatedProfile = profile
        updatedProfile.pages.append(
            PaperGIFRemotePage(name: device.name, controls: [control])
        )
        applyLiveProfile(updatedProfile)
        networkDeviceStatus = "Added \(device.name). Open Layout to edit its request."
    }

    private func addManualNetworkDevice() {
        var address = manualNetworkAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.lowercased().hasPrefix("http://") {
            address.removeFirst("http://".count)
        }
        while address.hasSuffix("/") {
            address.removeLast()
        }
        guard !address.isEmpty,
              !address.lowercased().hasPrefix("https://"),
              !address.contains("/"),
              !address.contains("@") else {
            networkDeviceStatus = "Enter a local hostname or private IP address, with an optional port."
            return
        }
        let device = PaperGIFNetworkDeviceDiscovery.Device(
            serviceName: address,
            name: address,
            host: address,
            port: 80,
            kind: .http
        )
        addLocalHTTPPage(for: device)
        if hasLocalHTTPControl(for: device) {
            manualNetworkAddress = address
        }
    }

    private func normalizedNetworkHost(_ host: String) -> String {
        var normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("http://") {
            normalized.removeFirst("http://".count)
        }
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    private func normalizedWLEDHost(_ host: String) -> String {
        var normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("http://") {
            normalized.removeFirst("http://".count)
        } else if normalized.hasPrefix("https://") {
            normalized.removeFirst("https://".count)
        }
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    /// Computers can't read Apple Home, so the iPhone sends its power accessories for their editors' pickers.
    private func shareHomeAccessories() async {
        guard homeManager.authorizationStatus.contains(.authorized), !homeManager.isRefreshing else { return }
        struct Payload: Encodable { let accessories: [PaperGIFHomePowerService] }
        guard let body = try? JSONEncoder().encode(Payload(accessories: Array(homeManager.powerServices.prefix(128)))) else {
            return
        }
        for computer in profile.computers {
            var components = URLComponents()
            components.scheme = "http"
            components.host = computer.host
            components.port = computer.port
            components.path = "/home-accessories"
            guard let url = components.url else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 8
            request.setValue("Bearer \(computer.token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            _ = try? await URLSession.shared.upload(for: request, from: body)
        }
    }

    private func refreshNetHomeUnits() async {
        guard !profile.computers.isEmpty else {
            netHomeUnits = []
            netHomeStatus = "Pair a Mac to load NetHome Plus units."
            return
        }
        isLoadingNetHomeUnits = true
        netHomeStatus = nil
        defer { isLoadingNetHomeUnits = false }
        var discovered: [PaperGIFConnectedNetHomeUnit] = []
        var failures: [String] = []
        for computer in profile.computers {
            var components = URLComponents()
            components.scheme = "http"
            components.host = computer.host
            components.port = computer.port
            components.path = "/nethome-units"
            guard let url = components.url else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("Bearer \(computer.token)", forHTTPHeaderField: "Authorization")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                    failures.append(computer.name)
                    continue
                }
                let units = try JSONDecoder().decode([PaperGIFNetHomeUnit].self, from: data)
                discovered.append(contentsOf: units.map {
                    PaperGIFConnectedNetHomeUnit(unit: $0, computer: computer)
                })
            } catch {
                failures.append(computer.name)
            }
        }
        netHomeUnits = discovered
        if discovered.isEmpty {
            netHomeStatus = failures.isEmpty
                ? "No NetHome Plus air conditioners were found."
                : "Couldn’t load AC units from \(failures.joined(separator: ", "))."
        }
    }

    private func hasNetHomeControls(for connection: PaperGIFConnectedNetHomeUnit) -> Bool {
        profile.pages.flatMap(\.controls).contains {
            $0.action.host.caseInsensitiveCompare(connection.unit.name) == .orderedSame &&
                $0.action.computerID == connection.computer.id.uuidString &&
                [.netHomePower, .netHomeTemperature, .netHomeMode, .netHomeFan, .netHomeAuto]
                    .contains($0.action.type)
        }
    }

    private func addNetHomePage(for connection: PaperGIFConnectedNetHomeUnit) {
        guard profile.pages.count < 8, !hasNetHomeControls(for: connection) else { return }
        let unit = connection.unit.name
        let computerID = connection.computer.id.uuidString
        var updatedProfile = profile
        updatedProfile.pages.append(.netHomeThermostat(unit: unit, computerID: computerID))
        applyLiveProfile(updatedProfile)
        netHomeStatus = "Added \(unit). Open Layout to arrange its thermostat controls."
    }

}

private struct PaperGIFRemotePageEditor: View {
    @Binding var page: PaperGIFRemotePage
    let pages: [PaperGIFRemotePage]
    let computers: [PaperGIFRemoteComputer]
    let temperatureUnit: PaperGIFTemperatureUnit
    @ObservedObject var wledDiscovery: PaperGIFWLEDDiscovery
    @State private var selectedControlID: UUID?

    var body: some View {
        List {
            Section("Preview") {
                PaperGIFRemotePagePreview(
                    page: $page,
                    pageIndex: pages.firstIndex { $0.id == page.id } ?? 0,
                    pageNames: pages.map(\.name),
                    temperatureUnit: temperatureUnit,
                    onEditControl: { selectedControlID = $0 }
                )
                .aspectRatio(540.0 / 960.0, contentMode: .fit)
                .frame(maxWidth: 280)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section("Page") {
                TextField("Name", text: $page.name)
                Stepper("Grid columns: \(page.gridColumns)", value: $page.gridColumns, in: 1...12)
                Stepper("Grid rows: \(page.gridRows)", value: $page.gridRows, in: 1...16)
            }

            Section("Controls") {
                ForEach($page.controls) { $control in
                    NavigationLink {
                        PaperGIFRemoteControlEditor(
                            control: $control,
                            pages: pages,
                            computers: computers,
                            temperatureUnit: temperatureUnit,
                            gridColumns: page.gridColumns,
                            gridRows: page.gridRows,
                            wledDiscovery: wledDiscovery
                        )
                    } label: {
                        Label(control.title, systemImage: control.symbol.isEmpty ? "square" : control.symbol)
                    }
                }
                .onDelete { page.controls.remove(atOffsets: $0) }
                .onMove { page.controls.move(fromOffsets: $0, toOffset: $1) }

                Menu {
                    Button("Button", systemImage: "rectangle") {
                        page.controls.append(.button(
                            title: "New Button",
                            symbol: "circle.fill",
                            action: .playPause
                        ))
                    }
                    .disabled(layoutUnitsUsed + 2 > layoutCapacity)

                    Button("Slider", systemImage: "slider.horizontal.3") {
                        page.controls.append(PaperGIFRemoteControl(
                            title: "New Slider",
                            symbol: "slider.horizontal.3",
                            tintHex: "202020",
                            kind: .slider,
                            action: .init(type: .wledBrightness)
                        ))
                    }
                    .disabled(layoutUnitsUsed + 1 > layoutCapacity)

                    Button("Text Box", systemImage: "text.rectangle") {
                        let control = PaperGIFRemoteControl(
                            title: "Text Box",
                            symbol: "",
                            tintHex: "202020",
                            kind: .textBox,
                            action: .playPause,
                            textBox: PaperGIFRemoteTextBox()
                        )
                        page.controls.append(control)
                    }
                    .disabled(layoutUnitsUsed + 2 > layoutCapacity)
                } label: {
                    Label("Add Control", systemImage: "plus")
                }
                .disabled(page.controls.count >= PaperGIFRemoteProfile.maximumControlsPerPage || layoutUnitsUsed >= layoutCapacity)
            }
        }
        .navigationTitle(page.name)
        .toolbar { EditButton() }
        .navigationDestination(item: $selectedControlID) { controlID in
            if let index = page.controls.firstIndex(where: { $0.id == controlID }) {
                PaperGIFRemoteControlEditor(
                    control: $page.controls[index],
                    pages: pages,
                    computers: computers,
                    temperatureUnit: temperatureUnit,
                    gridColumns: page.gridColumns,
                    gridRows: page.gridRows,
                    wledDiscovery: wledDiscovery
                )
            }
        }
    }

    private var layoutUnitsUsed: Int {
        page.controls.reduce(0) {
            let span = $1.gridSpan(columns: page.gridColumns, rows: page.gridRows)
            return $0 + span.width * span.height
        }
    }

    private var layoutCapacity: Int {
        page.gridColumns * page.gridRows
    }
}

private struct PaperGIFRemotePageThumbnail: View {
    let page: PaperGIFRemotePage

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Rectangle()
                    .frame(width: 18, height: 2)
                Spacer()
                Image(systemName: "gearshape")
                    .font(.system(size: 6))
            }
            .padding(.horizontal, 4)
            .frame(height: 10)

            GeometryReader { geometry in
                let placements = PaperGIFRemoteGrid.placements(
                    for: page.controls,
                    columns: page.gridColumns,
                    rows: page.gridRows,
                    reserved: PaperGIFRemoteGrid.reservedCells(for: page)
                )
                ZStack(alignment: .topLeading) {
                    ForEach(Array(page.controls.enumerated()), id: \.element.id) { index, _ in
                        if let placement = placements[index] {
                            let row = placement.slot / page.gridColumns
                            let column = placement.slot % page.gridColumns
                            Rectangle()
                                .fill(Color.primary.opacity(0.14))
                                .overlay {
                                    Rectangle().stroke(Color.primary, lineWidth: 0.5)
                                }
                                .frame(
                                    width: CGFloat(placement.span.width) * geometry.size.width /
                                        CGFloat(page.gridColumns) - 1,
                                    height: CGFloat(placement.span.height) * geometry.size.height /
                                        CGFloat(page.gridRows) - 1
                                )
                                .offset(
                                    x: CGFloat(column) * geometry.size.width / CGFloat(page.gridColumns),
                                    y: CGFloat(row) * geometry.size.height / CGFloat(page.gridRows)
                                )
                        }
                    }
                }
            }
            .padding(.horizontal, 3)

            Spacer(minLength: 1)
            Text("\(page.controls.count)")
                .font(.system(size: 6, weight: .semibold))
                .padding(.bottom, 2)
        }
        .foregroundStyle(.primary)
        .background(Color(uiColor: .systemBackground))
        .overlay {
            Rectangle().stroke(Color.primary, lineWidth: 1)
        }
        .accessibilityLabel("\(page.name), \(page.controls.count) controls")
    }
}

private struct PaperGIFRemotePagePreview: View {
    @Binding var page: PaperGIFRemotePage
    let pageIndex: Int
    let pageNames: [String]
    let temperatureUnit: PaperGIFTemperatureUnit
    let onEditControl: (UUID) -> Void
    @State private var draggedControlID: UUID?
    @State private var dragLocation: CGPoint?
    @State private var settingsDragLocation: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            let scale = geometry.size.width / 540
            let frames = controlFrames(scale: scale)

            ZStack(alignment: .topLeading) {
                Color.white

                Text(page.name)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(.black)
                    .frame(width: 290 * scale, alignment: .leading)
                    .position(x: 169 * scale, y: 58 * scale)

                Image(systemName: "wifi")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.black)
                    .position(x: 440 * scale, y: 57 * scale)

                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.black)
                    .position(x: 486 * scale, y: 57 * scale)

                Rectangle()
                    .fill(.black)
                    .frame(width: 492 * scale, height: max(1, scale))
                    .position(x: 270 * scale, y: 106 * scale)

                if page.layout == .openBuildsController {
                    if let settings = PaperGIFRemoteGrid.openBuildsSettingsPlacement(for: page) {
                        let frame = CGRect(
                            x: (24 + CGFloat(settings.slot % page.gridColumns) * 504 / CGFloat(page.gridColumns)) * scale,
                            y: (142 + CGFloat(settings.slot / page.gridColumns) * 712 / CGFloat(page.gridRows)) * scale,
                            width: 152 * scale,
                            height: 430 * scale
                        )
                        PaperGIFOpenBuildsSettingsPreview(controller: page.openBuildsController, scale: scale)
                            .contentShape(Rectangle())
                            .position(settingsDragLocation ?? center(of: frame))
                            .zIndex(settingsDragLocation == nil ? 0 : 1)
                            .simultaneousGesture(settingsGesture(frame: frame, scale: scale))
                    }
                    ForEach(Array(page.controls.prefix(PaperGIFRemoteProfile.maximumControlsPerPage).enumerated()), id: \.element.id) { index, control in
                        previewControl(control, frame: frames[index], scale: scale, controllerCompact: true)
                            .contentShape(Rectangle())
                            .position(
                                draggedControlID == control.id
                                    ? dragLocation ?? center(of: frames[index])
                                    : center(of: frames[index])
                            )
                            .zIndex(draggedControlID == control.id ? 1 : 0)
                            .onTapGesture { onEditControl(control.id) }
                            .simultaneousGesture(reorderGesture(
                                for: control.id,
                                frame: frames[index],
                                scale: scale
                            ))
                    }
                } else {
                    ForEach(Array(page.controls.prefix(PaperGIFRemoteProfile.maximumControlsPerPage).enumerated()), id: \.element.id) { index, control in
                        previewControl(control, frame: frames[index], scale: scale)
                            .contentShape(Rectangle())
                            .position(
                                draggedControlID == control.id
                                    ? dragLocation ?? center(of: frames[index])
                                    : center(of: frames[index])
                            )
                            .zIndex(draggedControlID == control.id ? 1 : 0)
                            .onTapGesture { onEditControl(control.id) }
                            .simultaneousGesture(reorderGesture(
                                for: control.id,
                                frame: frames[index],
                                scale: scale
                            ))
                    }
                }

                PaperGIFRemoteTabsPreview(
                    pageNames: pageNames,
                    selectedPageIndex: pageIndex,
                    scale: scale
                )
                    .position(x: 270 * scale, y: 884 * scale)
            }
            .overlay {
                Rectangle().stroke(Color.black, lineWidth: 1)
            }
            .clipShape(Rectangle())
            .coordinateSpace(name: "remotePreview")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview of \(page.name)")
    }


private struct PaperGIFRemoteTabsPreview: View {
    let pageNames: [String]
    let selectedPageIndex: Int
    let scale: CGFloat

    var body: some View {
        let visibleNames = Array(pageNames.prefix(8))
        let frames = PaperGIFRemoteTabLayout.frames(
            pageCount: visibleNames.count,
            selectedIndex: selectedPageIndex
        )

        ZStack(alignment: .topLeading) {
            Color.white
            ForEach(frames.indices, id: \.self) { index in
                let frame = frames[index]
                let selected = index == selectedPageIndex
                let width = CGFloat(frame.width) * scale
                let height = CGFloat(frame.height) * scale

                RoundedRectangle(cornerRadius: 7 * scale)
                    .fill(selected ? Color.black : Color.white)
                    .overlay {
                        Text(visibleNames[index])
                            .font(.system(size: max(5, 12 * scale), weight: .bold))
                            .lineLimit(2)
                            .minimumScaleFactor(0.45)
                            .allowsTightening(false)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(selected ? Color.white : Color.black)
                            .frame(
                                width: max(1, CGFloat(frame.width - 8) * scale),
                                height: max(1, CGFloat(frame.height - 4) * scale)
                            )
                            .clipped()
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 7 * scale)
                            .strokeBorder(Color.black, lineWidth: max(1, scale))
                    }
                    .frame(width: width, height: height)
                    .position(
                        x: CGFloat(frame.x - PaperGIFRemoteTabLayout.left) * scale + width / 2,
                        y: CGFloat(frame.y - PaperGIFRemoteTabLayout.top) * scale + height / 2
                    )
            }
        }
        .frame(
            width: CGFloat(PaperGIFRemoteTabLayout.width) * scale,
            height: CGFloat(PaperGIFRemoteTabLayout.height) * scale
        )
        .clipped()
    }
}
    private func previewControl(
        _ control: PaperGIFRemoteControl,
        frame: CGRect,
        scale: CGFloat,
        controllerCompact: Bool = false
    ) -> some View {
        let progress = CGFloat(min(max(control.action.value, 0), 255)) / 255

        return ZStack {
            if control.kind == .slider {
                RoundedRectangle(cornerRadius: 10 * scale)
                    .fill(.white)
                GeometryReader { geometry in
                    RoundedRectangle(cornerRadius: 7 * scale)
                        .fill(.black)
                        .frame(width: geometry.size.width * progress)
                }
                .padding((control.sliderOutlineInsetPixels == nil ? 3 : 1) * scale)
                if let inset = control.sliderOutlineInsetPixels {
                    RoundedRectangle(cornerRadius: max(2, 10 * scale - CGFloat(inset) * scale / 2))
                        .fill(Color.white)
                        .padding(CGFloat(inset) * scale)
                }
                RoundedRectangle(cornerRadius: 10 * scale)
                    .stroke(Color.black, lineWidth: max(1, scale))
            } else if control.kind != .textBox {
                RoundedRectangle(cornerRadius: 10 * scale)
                    .stroke(Color.black, lineWidth: 1)
            }

            if control.kind == .textBox {
                if control.textBox?.source == .openBuildsPosition {
                    VStack(spacing: 4 * scale) {
                        Text(openBuildsAxis(for: control))
                            .font(.system(size: 10 * scale, weight: .bold))
                        Text("-123.456 \(openBuildsUnits(for: control))")
                            .font(.system(size: 18 * scale, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.55)
                    }
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                } else {
                    Text(textBoxPreview(for: control))
                        .font(.system(size: textBoxPreviewSize(for: control), weight: .semibold))
                        .multilineTextAlignment(textBoxTextAlignment(for: control))
                        .foregroundStyle(.black)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: textBoxFrameAlignment(for: control)
                        )
                        .padding(8 * scale)
                        .clipped()
                }
                RoundedRectangle(cornerRadius: 10 * scale)
                    .stroke(Color.black, lineWidth: max(1, scale))
            } else if control.kind == .slider {
                if control.action.type == .macMedia && control.action.text == "seek" {
                    Text(textBoxPreview(for: control))
                        .font(.system(size: textBoxPreviewSize(for: control), weight: .semibold))
                        .multilineTextAlignment(textBoxTextAlignment(for: control))
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: textBoxFrameAlignment(for: control)
                        )
                        .padding(8 * scale)
                        .clipped()
                        .foregroundStyle(control.sliderOutlineInsetPixels == nil && progress >= 0.5
                            ? Color.white : Color.black)
                } else {
                    HStack(spacing: 8 * scale) {
                        PaperGIFRemoteBitmapIcon(symbol: control.symbol, bitmap: control.iconBitmap)
                            .frame(width: 28, height: 28)
                        Text(control.title)
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(control.sliderOutlineInsetPixels == nil && progress >= 0.5
                        ? Color.white : Color.black)
                }
            } else if controllerCompact && control.kind == .button {
                VStack(spacing: 5 * scale) {
                    PaperGIFRemoteBitmapIcon(symbol: control.symbol, bitmap: control.iconBitmap)
                        .frame(width: 30 * scale, height: 30 * scale)
                    Text(control.title)
                        .font(.system(size: 10 * scale, weight: .semibold))
                }
                .foregroundStyle(.black)
            } else if control.buttonGridHeight == 1 {
                HStack(spacing: 8 * scale) {
                    PaperGIFRemoteBitmapIcon(symbol: control.symbol, bitmap: control.iconBitmap)
                        .frame(width: 28, height: 28)
                    Text(control.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 10 * scale)
            } else {
                VStack(spacing: 10 * scale) {
                    PaperGIFRemoteBitmapIcon(symbol: control.symbol, bitmap: control.iconBitmap)
                        .frame(width: 64, height: 64)
                    Text(control.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.65)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 8)
            }
        }
        .frame(width: frame.width, height: frame.height)
    }

    private func textBoxPreview(for control: PaperGIFRemoteControl) -> String {
        guard let textBox = control.textBox else { return control.title }
        switch textBox.source {
        case .staticText: return textBox.sourceText
        case .dateTime: return "Sep 2, 18:54"
        case .macScript, .macShortcut: return textBox.placeholder == "Unavailable" ? "Command output" : textBox.placeholder
        case .controlValue:
            if control.action.type == .netHomeTemperature {
                return "\(temperatureUnit.displayValue(celsiusTenths: control.action.valueTenths ?? control.action.value * 10)) \(temperatureUnit.symbol)"
            }
            if control.action.type == .netHomeFan {
                return "\(control.action.value)%"
            }
            return "128"
        case .nowPlaying: return "Song Title - Artist"
        case .openBuildsPosition: return "0.000 \(openBuildsUnits(for: control))"
        }
    }

    private func openBuildsComponents(for control: PaperGIFRemoteControl) -> [Substring] {
        control.textBox?.sourceText.split(separator: "|", omittingEmptySubsequences: false) ?? []
    }

    private func openBuildsAxis(for control: PaperGIFRemoteControl) -> String {
        let components = openBuildsComponents(for: control)
        return components.indices.contains(1) ? components[1].uppercased() : "X"
    }

    private func openBuildsUnits(for control: PaperGIFRemoteControl) -> String {
        let components = openBuildsComponents(for: control)
        return components.indices.contains(2) ? components[2].lowercased() : "mm"
    }

    private func textBoxPreviewSize(for control: PaperGIFRemoteControl) -> CGFloat {
        switch control.textBox?.textSize ?? .autoFit {
        case .small: 9
        case .medium: 12
        case .large: 18
        case .extraLarge, .autoFit: 24
        }
    }

    private func textBoxTextAlignment(for control: PaperGIFRemoteControl) -> TextAlignment {
        switch control.textBox?.horizontalAlignment ?? .leading {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func textBoxFrameAlignment(for control: PaperGIFRemoteControl) -> Alignment {
        let horizontal: HorizontalAlignment = switch control.textBox?.horizontalAlignment ?? .leading {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
        let vertical: VerticalAlignment = switch control.textBox?.verticalAlignment ?? .top {
        case .top: .top
        case .center: .center
        case .bottom: .bottom
        }
        return Alignment(horizontal: horizontal, vertical: vertical)
    }

    private func reorderGesture(
        for controlID: UUID,
        frame: CGRect,
        scale: CGFloat
    ) -> some Gesture {
        LongPressGesture(minimumDuration: 0.25)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("remotePreview")))
            .onChanged { value in
                guard case let .second(true, drag?) = value else { return }
                draggedControlID = controlID
                dragLocation = CGPoint(
                    x: frame.midX + drag.translation.width,
                    y: frame.midY + drag.translation.height
                )
            }
            .onEnded { value in
                if case let .second(true, drag?) = value,
                   let destinationSlot = translatedSlot(
                       from: frame,
                       translation: drag.translation,
                       scale: scale
                   ) {
                    moveControl(controlID, to: destinationSlot)
                }
                draggedControlID = nil
                dragLocation = nil
            }
    }

    private func settingsGesture(frame: CGRect, scale: CGFloat) -> some Gesture {
        LongPressGesture(minimumDuration: 0.25)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("remotePreview")))
            .onChanged { value in
                guard case let .second(true, drag?) = value else { return }
                settingsDragLocation = CGPoint(
                    x: frame.midX + drag.translation.width,
                    y: frame.midY + drag.translation.height
                )
            }
            .onEnded { value in
                if case let .second(true, drag?) = value,
                   let destinationSlot = translatedSlot(
                       from: frame,
                       translation: drag.translation,
                       scale: scale
                   ) {
                    moveSettings(to: destinationSlot)
                }
                settingsDragLocation = nil
            }
    }

    private func moveSettings(to requestedSlot: Int) {
        let controls = Array(page.controls.prefix(PaperGIFRemoteProfile.maximumControlsPerPage))
        guard let slot = PaperGIFRemoteGrid.movedOpenBuildsSettings(
            on: page, controls: controls, to: requestedSlot
        ) else { return }
        let pinned = PaperGIFRemoteGrid.placements(
            for: controls, columns: page.gridColumns, rows: page.gridRows,
            reserved: PaperGIFRemoteGrid.reservedCells(for: page)
        )
        var updated = page
        for index in pinned.indices {
            updated.controls[index].layoutSlot = pinned[index]?.slot
        }
        var controller = updated.openBuildsController ?? PaperGIFOpenBuildsController()
        controller.settingsSlot = slot
        updated.openBuildsController = controller
        page = updated
    }

    private func center(of frame: CGRect) -> CGPoint {
        CGPoint(x: frame.midX, y: frame.midY)
    }

    private func translatedSlot(
        from frame: CGRect,
        translation: CGSize,
        scale: CGFloat
    ) -> Int? {
        let sourceSlot = slot(for: frame, scale: scale)
        let columnOffset = Int((translation.width * CGFloat(page.gridColumns) /
            (504 * scale)).rounded())
        let rowOffset = Int((translation.height * CGFloat(page.gridRows) /
            (712 * scale)).rounded())
        return PaperGIFRemoteGrid.translatedSlot(
            from: sourceSlot,
            columnOffset: columnOffset,
            rowOffset: rowOffset,
            columns: page.gridColumns,
            rows: page.gridRows
        )
    }

    private func moveControl(_ controlID: UUID, to requestedSlot: Int) {
        let controls = Array(page.controls.prefix(PaperGIFRemoteProfile.maximumControlsPerPage))
        guard let sourceIndex = controls.firstIndex(where: { $0.id == controlID }),
              let slots = PaperGIFRemoteGrid.rearranged(
                  controls,
                  moving: sourceIndex,
                  to: requestedSlot,
                  columns: page.gridColumns,
                  rows: page.gridRows,
                  reserved: PaperGIFRemoteGrid.reservedCells(for: page)
              ) else { return }
        var updated = page.controls
        for index in slots.indices {
            updated[index].layoutSlot = slots[index]
        }
        page.controls = updated
    }

    private func slot(for frame: CGRect, scale: CGFloat = 1) -> Int {
        let column = Int(((frame.minX / scale - 24) * CGFloat(page.gridColumns) / 504).rounded())
        let row = Int(((frame.minY / scale - 142) * CGFloat(page.gridRows) / 712).rounded())
        return row * page.gridColumns + column
    }

    private func controlFrames(scale: CGFloat) -> [CGRect] {
        let controls = Array(page.controls.prefix(PaperGIFRemoteProfile.maximumControlsPerPage))
        return PaperGIFRemoteGrid.placements(
            for: controls, columns: page.gridColumns, rows: page.gridRows,
            reserved: PaperGIFRemoteGrid.reservedCells(for: page)
        ).map { placement in
            guard let placement else { return .zero }
            let row = placement.slot / page.gridColumns
            let column = placement.slot % page.gridColumns
            return CGRect(
                x: (24 + CGFloat(column) * 504 / CGFloat(page.gridColumns)) * scale,
                y: (142 + CGFloat(row) * 712 / CGFloat(page.gridRows)) * scale,
                width: (CGFloat(placement.span.width) * 504 / CGFloat(page.gridColumns) - 12) * scale,
                height: (CGFloat(placement.span.height) * 712 / CGFloat(page.gridRows) - 12) * scale
            )
        }
    }
}

private struct PaperGIFOpenBuildsSettingsPreview: View {
    let controller: PaperGIFOpenBuildsController?
    let scale: CGFloat

    var body: some View {
        let settings = controller ?? PaperGIFOpenBuildsController()
        VStack(alignment: .leading, spacing: 0) {
            Text("UNITS")
                .font(.system(size: 9 * scale, weight: .bold))
            HStack(spacing: 8 * scale) {
                chip("MM", selected: settings.units == .millimeters)
                chip("IN", selected: settings.units == .inches)
            }
            .padding(.top, 8 * scale)

            HStack {
                Text("JOG SPEED")
                Spacer()
                Text("\(settings.jogSpeed) \(settings.units.rawValue)/min")
            }
            .font(.system(size: 9 * scale, weight: .bold))
            .padding(.top, 10 * scale)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 7 * scale).stroke(.black, lineWidth: max(1, scale))
                RoundedRectangle(cornerRadius: 5 * scale)
                    .fill(.black)
                    .padding(4 * scale)
                    .frame(width: max(8 * scale, 152 * scale * speedProgress(settings)))
            }
            .frame(height: 38 * scale)
            .padding(.top, 8 * scale)

            Text("JOG MODE")
                .font(.system(size: 9 * scale, weight: .bold))
                .padding(.top, 10 * scale)
            HStack(spacing: 8 * scale) {
                chip("STEP", selected: settings.jogMode == .incremental)
                chip("HOLD", selected: settings.jogMode == .continuous)
            }
            .padding(.top, 8 * scale)

            Text(settings.jogMode == .continuous ? "RELEASE TO STOP" : "STEP DISTANCE")
                .font(.system(size: 9 * scale, weight: .bold))
                .padding(.top, 10 * scale)
            if settings.jogMode == .continuous {
                Text("Motion stops\nwhen released.")
                    .font(.system(size: 12 * scale))
                    .padding(.top, 12 * scale)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(72 * scale)), count: 2), spacing: 12 * scale) {
                    ForEach(distances(settings), id: \.0) { value, label in
                        chip(label, selected: settings.jogDistanceThousandths == value)
                    }
                }
                .padding(.top, 8 * scale)
            }
        }
        .foregroundStyle(.black)
        .frame(width: 152 * scale, height: 430 * scale, alignment: .topLeading)
        .background(Color.white)
    }

    private func chip(_ title: String, selected: Bool) -> some View {
        Text(title)
            .font(.system(size: 9 * scale, weight: .bold))
            .foregroundStyle(selected ? .white : .black)
            .frame(width: 72 * scale, height: 42 * scale)
            .background(selected ? Color.black : Color.white)
            .overlay(RoundedRectangle(cornerRadius: 7 * scale).stroke(.black, lineWidth: max(1, scale)))
            .clipShape(RoundedRectangle(cornerRadius: 7 * scale))
    }

    private func speedProgress(_ settings: PaperGIFOpenBuildsController) -> CGFloat {
        let range = settings.units == .inches ? 4...400 : 100...10_000
        return CGFloat(settings.jogSpeed - range.lowerBound) /
            CGFloat(range.upperBound - range.lowerBound)
    }

    private func distances(_ settings: PaperGIFOpenBuildsController) -> [(Int, String)] {
        settings.units == .inches
            ? [(1, ".001"), (10, ".01"), (100, ".1"), (1_000, "1")]
            : [(100, "0.1"), (1_000, "1"), (10_000, "10"), (100_000, "100")]
    }
}

private struct PaperGIFRemoteControlEditor: View {
    @Binding var control: PaperGIFRemoteControl
    let pages: [PaperGIFRemotePage]
    let computers: [PaperGIFRemoteComputer]
    let temperatureUnit: PaperGIFTemperatureUnit
    let gridColumns: Int
    let gridRows: Int
    @ObservedObject var wledDiscovery: PaperGIFWLEDDiscovery
    @StateObject private var applicationCatalog = PaperGIFMacApplicationCatalog()
    @StateObject private var homeManager = PaperGIFHomeManager()

    private let mediaCommands = ["playPause", "previous", "next", "seek", "volumeUp", "volumeDown", "volume", "mute"]
    private let modifierNames = ["command", "option", "control", "shift"]

    var body: some View {
        Form {
            Section("Appearance") {
                TextField("Label", text: $control.title)
                if control.kind != .textBox {
                    NavigationLink {
                    PaperGIFRemoteIconPicker(selection: symbolBinding)
                    } label: {
                        HStack(spacing: 8) {
                            Text("Icon")
                            Spacer(minLength: 12)
                            PaperGIFRemoteBitmapIcon(
                                symbol: control.symbol.isEmpty ? "square.dashed" : control.symbol,
                                bitmap: control.iconBitmap
                            )
                            .frame(width: 24)
                            Text(selectedIconTitle)
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                        }
                    }
                    TextField("Color hex", text: $control.tintHex)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }
                Picker("Control", selection: controlKindBinding) {
                    ForEach(PaperGIFRemoteControlKind.allCases) { kind in
                        Text(controlKindTitle(kind)).tag(kind)
                            .disabled(kind == .button && !canUseButtonLayout)
                    }
                }
                Stepper(
                    "Width: \(control.gridSpan(columns: gridColumns, rows: gridRows).width) column(s)",
                    value: controlGridWidthBinding,
                    in: 1...gridColumns
                )
                Stepper(
                    "Height: \(control.gridSpan(columns: gridColumns, rows: gridRows).height) row(s)",
                    value: controlGridHeightBinding,
                    in: 1...gridRows
                )
                Toggle("Toggle button", isOn: toggleButtonBinding)
                    .disabled(control.kind != .button)
                if control.kind == .slider {
                    Toggle("Outline", isOn: sliderOutlineEnabledBinding)
                    if control.sliderOutlineInsetPixels != nil {
                        Stepper(
                            "Outline inset: \(sliderOutlineInsetBinding.wrappedValue) pixels",
                            value: sliderOutlineInsetBinding,
                            in: 1...32
                        )
                    }
                }
            }

            if control.kind == .textBox {
                textBoxSections
            }

            if control.kind != .textBox || control.textBox?.tapBehavior == .action {
                Section(control.kind == .textBox ? "Tap Action" : "Action") {
                Picker("Type", selection: $control.action.type) {
                    ForEach(PaperGIFRemoteActionType.allCases) { type in
                        Text(type.title).tag(type)
                    }
                }
                actionFields
                }
            }
        }
        .navigationTitle(control.title)
        .onChange(of: control.action.type) { previousType, _ in
            control.applyEditorActionDefaults(previousType: previousType)
            selectOnlyWLEDDeviceIfNeeded()
            loadSelectedWLEDPresetsIfNeeded()
        }
        .onChange(of: wledDiscovery.devices) {
            selectOnlyWLEDDeviceIfNeeded()
            refreshSelectedWLEDAddress()
            loadSelectedWLEDPresetsIfNeeded()
        }
        .onAppear {
            selectOnlyWLEDDeviceIfNeeded()
            refreshSelectedWLEDAddress()
            loadSelectedWLEDPresetsIfNeeded()
            prepareSchedules()
        }
    }

    @ViewBuilder
    private var textBoxSections: some View {
        Section("Text") {
            Picker("Source", selection: textBoxBinding(\.source)) {
                Text("Static text").tag(PaperGIFRemoteTextSource.staticText)
                Text("Date and time").tag(PaperGIFRemoteTextSource.dateTime)
                Text("Mac script output").tag(PaperGIFRemoteTextSource.macScript)
                Text("Shortcut output").tag(PaperGIFRemoteTextSource.macShortcut)
                Text("Control value").tag(PaperGIFRemoteTextSource.controlValue)
                Text("Now playing").tag(PaperGIFRemoteTextSource.nowPlaying)
                Text("OpenBuilds position").tag(PaperGIFRemoteTextSource.openBuildsPosition)
            }

            switch control.textBox?.source ?? .staticText {
            case .staticText:
                TextField("Text", text: textBoxBinding(\.sourceText), axis: .vertical)
                    .lineLimit(2...8)
            case .dateTime:
                TextField("Date format", text: textBoxBinding(\.dateFormat))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            case .macScript:
                macTextSourceComputerPicker
                TextField("Approved shell command", text: textBoxBinding(\.sourceText), axis: .vertical)
                    .lineLimit(2...6)
            case .macShortcut:
                macTextSourceComputerPicker
                TextField("Shortcut name", text: textBoxBinding(\.sourceText))
            case .controlValue:
                Picker("Control", selection: referencedControlBinding) {
                    Text("Choose Control").tag("")
                    ForEach(referenceableControls) { candidate in
                        Text(referenceableControlTitle(candidate)).tag(candidate.id.uuidString)
                    }
                }
            case .nowPlaying:
                Picker("Player", selection: referencedControlBinding) {
                    Text("Automatic").tag("")
                    ForEach(iPhoneMediaControls) { candidate in
                        Text("iPhone - \(candidate.title)").tag(candidate.id.uuidString)
                    }
                }
                if control.textBox?.referencedControlID == nil {
                    macTextSourceComputerPicker
                }
            case .openBuildsPosition:
                macTextSourceComputerPicker
                TextField("127.0.0.1|x|mm", text: textBoxBinding(\.sourceText))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            if control.textBox?.source != .staticText {
                TextField("Unavailable text", text: textBoxBinding(\.placeholder))
            }
        }

        Section("Text Layout") {
            Picker("Text size", selection: textBoxBinding(\.textSize)) {
                Text("Small").tag(PaperGIFRemoteTextSize.small)
                Text("Medium").tag(PaperGIFRemoteTextSize.medium)
                Text("Large").tag(PaperGIFRemoteTextSize.large)
                Text("Extra Large").tag(PaperGIFRemoteTextSize.extraLarge)
                Text("Auto Fit").tag(PaperGIFRemoteTextSize.autoFit)
            }
            Picker("Horizontal", selection: textBoxBinding(\.horizontalAlignment)) {
                Text("Leading").tag(PaperGIFRemoteTextHorizontalAlignment.leading)
                Text("Center").tag(PaperGIFRemoteTextHorizontalAlignment.center)
                Text("Trailing").tag(PaperGIFRemoteTextHorizontalAlignment.trailing)
            }
            .pickerStyle(.segmented)
            Picker("Vertical", selection: textBoxBinding(\.verticalAlignment)) {
                Text("Top").tag(PaperGIFRemoteTextVerticalAlignment.top)
                Text("Center").tag(PaperGIFRemoteTextVerticalAlignment.center)
                Text("Bottom").tag(PaperGIFRemoteTextVerticalAlignment.bottom)
            }
            .pickerStyle(.segmented)
        }

        Section("Updates") {
            if control.textBox?.source == .nowPlaying {
                LabeledContent("Automatic refresh", value: "When song changes")
            } else {
                Toggle("Automatic refresh", isOn: automaticRefreshBinding)
                    .disabled(!supportsAutomaticRefresh)
                if control.textBox?.refreshIntervalSeconds != nil && supportsAutomaticRefresh {
                    Stepper(
                        "Every \(control.textBox?.refreshIntervalSeconds ?? 5) seconds",
                        value: refreshIntervalBinding,
                        in: 5...3600,
                        step: 5
                    )
                }
            }
            Picker("When tapped", selection: textBoxBinding(\.tapBehavior)) {
                Text("Do nothing").tag(PaperGIFRemoteTextTapBehavior.displayOnly)
                Text("Refresh").tag(PaperGIFRemoteTextTapBehavior.refresh)
                Text("Run action").tag(PaperGIFRemoteTextTapBehavior.action)
            }
        }
    }

    @ViewBuilder
    private var macTextSourceComputerPicker: some View {
        Picker("Computer", selection: textSourceComputerBinding) {
            Text("Default Computer").tag("")
            ForEach(computers) { computer in
                Text(computer.name).tag(computer.id.uuidString)
            }
        }
    }

    @ViewBuilder
    private var actionFields: some View {
        if isMacAction {
            Picker("Computer", selection: computerIDBinding) {
                Text("Default Computer").tag("")
                ForEach(computers) { computer in
                    Text(computer.name).tag(computer.id.uuidString)
                }
            }
        }

        switch control.action.type {
        case .iPhoneMedia, .macMedia:
            Picker("Command", selection: mediaCommandBinding) {
                ForEach(mediaCommands, id: \.self) { Text(mediaTitle($0)).tag($0) }
            }
            if control.action.text == "volume" {
                LabeledContent("Volume", value: "\(volumePercentage)%")
                Slider(value: volumePercentageBinding, in: 0...100, step: 1)
            }
        case .iPhoneHomePower:
            Picker("Home accessory", selection: homePowerServiceBinding) {
                Text("Choose Accessory").tag("")
                ForEach(homeManager.powerServices) { service in
                    Text("\(service.homeName) · \(service.displayName)").tag(service.id)
                }
            }
            Button {
                homeManager.refreshAccessories()
            } label: {
                Label(
                    homeManager.isRefreshing ? "Refreshing Home…" : "Refresh Home Accessories",
                    systemImage: "arrow.clockwise"
                )
            }
            .disabled(homeManager.isRefreshing)
            Picker("Power", selection: $control.action.text) {
                Text("Toggle").tag("toggle")
                Text("On").tag("on")
                Text("Off").tag("off")
            }
            Text("Runs through Apple Home on the connected iPhone.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .macKey:
            TextField("Key", text: $control.action.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            ForEach(modifierNames, id: \.self) { modifier in
                Toggle(modifier.capitalized, isOn: modifierBinding(modifier))
            }
        case .macOpen:
            Picker("Application", selection: applicationSelectionBinding) {
                Text("Choose Application").tag("")
                if !control.action.text.isEmpty &&
                    !applicationCatalog.applications.contains(where: { $0.path == control.action.text }) {
                    Text("Custom Target").tag(control.action.text)
                }
                ForEach(applicationCatalog.applications) { application in
                    Text(application.name).tag(application.path)
                }
            }
            .task(id: selectedApplicationComputerKey) {
                await applicationCatalog.load(from: selectedApplicationComputer)
                let loadedIcon = applicationCatalog.applications
                    .first(where: { $0.path == control.action.text })?.iconBitmap
                if control.iconBitmap != loadedIcon {
                    control.iconBitmap = loadedIcon
                }
            }
            if applicationCatalog.isLoading {
                HStack {
                    ProgressView()
                    Text("Loading applications…")
                        .foregroundStyle(.secondary)
                }
            } else if let message = applicationCatalog.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField("App path, bundle ID, or URL", text: applicationTargetBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        case .macShortcut:
            TextField("Shortcut name", text: $control.action.text)
        case .macScript:
            TextField("Shell command", text: $control.action.text, axis: .vertical)
                .lineLimit(3...8)
        case .openBuilds:
            TextField("CONTROL address", text: $control.action.host)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Picker("Command", selection: $control.action.text) {
                Text("Jog X -").tag("jogXNegative")
                Text("Jog X +").tag("jogXPositive")
                Text("Jog Y -").tag("jogYNegative")
                Text("Jog Y +").tag("jogYPositive")
                Text("Jog Z -").tag("jogZNegative")
                Text("Jog Z +").tag("jogZPositive")
                Text("Zero X").tag("zeroX")
                Text("Zero Y").tag("zeroY")
                Text("Zero Z").tag("zeroZ")
                Text("Jog X-/Y-").tag("jogXNegativeYNegative")
                Text("Jog X-/Y+").tag("jogXNegativeYPositive")
                Text("Jog X+/Y-").tag("jogXPositiveYNegative")
                Text("Jog X+/Y+").tag("jogXPositiveYPositive")
                Text("Pause job").tag("pause")
                Text("Resume job").tag("resume")
                Text("Stop job").tag("stop")
                Text("Abort / reset").tag("abort")
                Text("Unlock alarm").tag("unlock")
                Text("Home machine").tag("home")
            }
            if control.action.text.hasPrefix("jog") {
                Stepper("Distance: \(control.action.value) mm", value: $control.action.value, in: 1...100)
            }
        case .wledPower:
            wledDevicePicker
            Picker("Power", selection: $control.action.text) {
                Text("Toggle").tag("toggle")
                Text("On").tag("on")
                Text("Off").tag("off")
            }
        case .wledPreset:
            wledDevicePicker
            wledPresetPicker
        case .wledBrightness:
            wledDevicePicker
            LabeledContent("Brightness", value: "\(control.action.value)")
            Slider(value: brightnessBinding, in: 0...255, step: 1)
        case .eWeLinkPower:
            TextField("Device address", text: $control.action.host)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            TextField("Device ID", text: optionalActionStringBinding(\.deviceID))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("eWeLink LAN device key", text: optionalActionStringBinding(\.deviceKey))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Picker("Power", selection: $control.action.text) {
                Text("Toggle").tag("toggle")
                Text("On").tag("on")
                Text("Off").tag("off")
            }
              Text("Only encrypted eWeLink LAN control needs this key. A Matter pairing code is not a device key.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .localHTTP:
            TextField("Device address", text: $control.action.host)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Picker("Method", selection: localHTTPMethodBinding) {
                Text("GET").tag("GET")
                Text("POST").tag("POST")
            }
            .pickerStyle(.segmented)
            TextField("Path, such as /relay/0?turn=toggle", text: $control.action.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if localHTTPMethodBinding.wrappedValue == "POST" {
                TextField("JSON body", text: localHTTPBodyBinding, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(2...6)
            }
            Text("Only local HTTP addresses are accepted. HTTPS and internet hosts are not sent by M5Paper.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .netHomePower:
            netHomeDeviceField
            Picker("Power", selection: $control.action.text) {
                Text("Toggle").tag("toggle")
                Text("On").tag("on")
                Text("Off").tag("off")
            }
        case .netHomeTemperature:
            netHomeDeviceField
            Stepper(
                "Setpoint: \(temperatureUnit.displayValue(celsiusTenths: control.action.valueTenths ?? control.action.value * 10)) \(temperatureUnit.symbol)",
                value: temperatureDisplayBinding,
                in: temperatureDisplayRange
            )
        case .netHomeTemperatureStep:
            netHomeDeviceField
            Text(control.action.value < 0 ? "Decrease the thermostat setpoint" : "Increase the thermostat setpoint")
                .foregroundStyle(.secondary)
        case .netHomeMode:
            netHomeDeviceField
            Picker("Mode", selection: $control.action.text) {
                Text("Auto").tag("auto")
                Text("Cool").tag("cool")
                Text("Heat").tag("heat")
                Text("Dry").tag("dry")
                Text("Fan").tag("fan")
            }
        case .netHomeFan:
            netHomeDeviceField
            Stepper("Fan: \(control.action.value)%", value: $control.action.value, in: 20...100, step: 20)
        case .netHomeAuto:
            netHomeDeviceField
            Text("Uses the thermostat page setpoint.")
                .foregroundStyle(.secondary)
            Picker("Control", selection: $control.action.text) {
                Text("Cooling").tag("cool")
                Text("Heating").tag("heat")
            }
            Stepper(
                "Deadband: \(deadbandDisplayText)",
                value: optionalActionValueBinding(\.deadbandTenths, default: 10),
                in: 5...30,
                step: 5
            )
            Stepper(
                "Humidity assist: \(control.action.humidityThreshold ?? 65)%",
                value: optionalActionValueBinding(\.humidityThreshold, default: 65),
                in: 40...80,
                step: 5
            )
            Stepper(
                "Adjustment interval: \(control.action.minimumCycleMinutes ?? 10) min",
                value: optionalActionValueBinding(\.minimumCycleMinutes, default: 10),
                in: 1...30,
                step: 1
            )
            Text("Humidity assist only extends cooling. The minimum cycle protects the compressor.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .module:
            LabeledContent("Module", value: control.action.host)
            LabeledContent("Command", value: control.action.text)
        case .page:
            Picker("Page", selection: $control.action.text) {
                Text("Choose Page").tag("")
                ForEach(pages) { page in
                    Text(page.name).tag(page.id.uuidString)
                }
            }
        }

        if supportsSchedule {
            Toggle("Run on a schedule", isOn: scheduleEnabledBinding)
            if control.action.scheduleEnabled == true {
                scheduleFields
            }
        }
    }

    @ViewBuilder
    private var netHomeDeviceField: some View {
        TextField("NetHome unit name", text: $control.action.host)
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
    }

    @ViewBuilder
    private var wledDevicePicker: some View {
        Picker("Device", selection: wledDeviceIDBinding) {
            Text("Choose Device").tag("")
            ForEach(wledDiscovery.devices) { device in
                Text(device.name).tag(device.id)
            }
            if !control.action.host.isEmpty && selectedWLEDDevice == nil {
                Text("Unavailable (\(control.action.host))").tag("saved-device")
            }
        }

        if wledDiscovery.devices.isEmpty {
            Button {
                wledDiscovery.start()
            } label: {
                Label(
                    wledDiscovery.state == .searching ? "Scanning…" : "Scan for WLED Devices",
                    systemImage: "dot.radiowaves.left.and.right"
                )
            }
            .disabled(wledDiscovery.state == .searching)
        } else if let selectedWLEDDevice {
            Text(selectedWLEDDevice.actionHost)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var wledPresetPicker: some View {
        if let selectedWLEDDevice {
            let presets = wledDiscovery.presets(for: selectedWLEDDevice)
            Picker("Preset", selection: $control.action.value) {
                if control.action.value == 0 {
                    Text("Choose Preset").tag(0)
                } else if !presets.contains(where: { $0.id == control.action.value }) {
                    Text("Preset \(control.action.value)").tag(control.action.value)
                }
                ForEach(presets) { preset in
                    Text(preset.name).tag(preset.id)
                }
            }
            .disabled(wledDiscovery.isLoadingPresets(for: selectedWLEDDevice))
            .onChange(of: control.action.value) {
                guard let preset = presets.first(where: { $0.id == control.action.value }) else { return }
                control.title = preset.name
            }

            if wledDiscovery.isLoadingPresets(for: selectedWLEDDevice) {
                HStack {
                    ProgressView()
                    Text("Loading presets…")
                }
                .foregroundStyle(.secondary)
            } else if let error = wledDiscovery.presetError(for: selectedWLEDDevice) {
                LabeledContent {
                    Button("Retry") {
                        Task { await wledDiscovery.loadPresets(for: selectedWLEDDevice, force: true) }
                    }
                } label: {
                    Text(error)
                        .foregroundStyle(.secondary)
                }
            } else if presets.isEmpty {
                Text("No saved presets on this device.")
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Choose a WLED device to load its presets.")
                .foregroundStyle(.secondary)
        }
    }

    private var wledDeviceIDBinding: Binding<String> {
        Binding(
            get: {
                if let selectedWLEDDevice {
                    return selectedWLEDDevice.id
                }
                return control.action.host.isEmpty ? "" : "saved-device"
            },
            set: { deviceID in
                guard let device = wledDiscovery.devices.first(where: { $0.id == deviceID }) else {
                    if deviceID.isEmpty {
                        control.action.host = ""
                    }
                    return
                }
                control.action.host = device.actionHost
                loadSelectedWLEDPresetsIfNeeded()
            }
        )
    }

    private var selectedWLEDDevice: PaperGIFWLEDDiscovery.Device? {
        let selectedHost = normalizedWLEDHost(control.action.host)
        return wledDiscovery.devices.first { device in
            selectedHost == normalizedWLEDHost(device.actionHost) ||
            selectedHost == normalizedWLEDHost("\(device.serviceName).local")
        }
    }

    private func selectOnlyWLEDDeviceIfNeeded() {
        guard isWLEDAction, control.action.host.isEmpty,
              wledDiscovery.devices.count == 1,
              let device = wledDiscovery.devices.first else { return }
        control.action.host = device.actionHost
    }

    private func refreshSelectedWLEDAddress() {
        guard isWLEDAction, let selectedWLEDDevice,
              control.action.host != selectedWLEDDevice.actionHost else { return }
        control.action.host = selectedWLEDDevice.actionHost
    }

    private func loadSelectedWLEDPresetsIfNeeded() {
        guard control.action.type == .wledPreset,
              let selectedWLEDDevice else { return }
        Task {
            await wledDiscovery.loadPresets(for: selectedWLEDDevice)
        }
    }

    private func normalizedWLEDHost(_ host: String) -> String {
        var normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("http://") {
            normalized.removeFirst("http://".count)
        } else if normalized.hasPrefix("https://") {
            normalized.removeFirst("https://".count)
        }
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    private var supportsSchedule: Bool {
        (control.kind == .button || control.action.type == .netHomeTemperature) &&
            control.action.type != .page && control.action.type != .openBuilds
    }

    private var scheduleEnabledBinding: Binding<Bool> {
        Binding(
            get: { control.action.scheduleEnabled == true },
            set: { enabled in
                control.action.scheduleEnabled = enabled
                if enabled {
                    prepareSchedules()
                }
            }
        )
    }

    @ViewBuilder private var scheduleFields: some View {
        ForEach(Array((control.action.schedules ?? []).enumerated()), id: \.element.id) { index, entry in
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Schedule \(index + 1)").font(.headline)
                    Spacer()
                    Button(role: .destructive) { removeSchedule(entry.id) } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Delete schedule")
                }
                DatePicker("Time", selection: scheduleTimeBinding(entry.id), displayedComponents: .hourAndMinute)
                Text("Days").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                    ForEach(Array(Calendar.current.veryShortWeekdaySymbols.enumerated()), id: \.offset) { dayIndex, symbol in
                        let weekday = dayIndex + 1
                        Button { toggleWeekday(weekday, in: entry.id) } label: {
                            Text(symbol).frame(maxWidth: .infinity, minHeight: 28)
                        }
                        .buttonStyle(.bordered)
                        .tint(entry.weekdays.contains(weekday) ? .accentColor : .secondary)
                        .accessibilityLabel(Calendar.current.weekdaySymbols[dayIndex])
                        .accessibilityValue(entry.weekdays.contains(weekday) ? "Selected" : "Not selected")
                    }
                }
                scheduleFunctionFields(entry)
            }
            .padding(.vertical, 4)
        }
        Button { addSchedule() } label: {
            Label("Add Time", systemImage: "plus")
        }
        .disabled((control.action.schedules?.count ?? 0) >= 8)
    }

    @ViewBuilder private func scheduleFunctionFields(_ entry: PaperGIFRemoteScheduleEntry) -> some View {
        switch control.action.type {
        case .iPhoneMedia, .macMedia:
            Picker("Command", selection: scheduleTextBinding(entry.id)) {
                ForEach(mediaCommands, id: \.self) { Text(mediaTitle($0)).tag($0) }
            }
            if (entry.text ?? control.action.text) == "volume" {
                Stepper("Volume: \(scheduleVolume(entry))%", value: scheduleVolumeBinding(entry.id), in: 0...100)
            }
        case .iPhoneHomePower, .wledPower, .netHomePower:
            Picker("Power", selection: scheduleTextBinding(entry.id)) {
                Text("Toggle").tag("toggle")
                Text("On").tag("on")
                Text("Off").tag("off")
            }
        case .wledPreset:
            Stepper("Preset: \(entry.value ?? control.action.value)", value: scheduleValueBinding(entry.id), in: 1...250)
        case .wledBrightness:
            Stepper("Brightness: \(entry.value ?? control.action.value)", value: scheduleValueBinding(entry.id), in: 0...255)
        case .netHomeTemperature:
            Stepper(
                "Setpoint: \(scheduleTemperature(entry)) \(temperatureUnit.symbol)",
                value: scheduleTemperatureBinding(entry.id),
                in: temperatureDisplayRange
            )
        case .netHomeTemperatureStep:
            Picker("Adjustment", selection: scheduleValueBinding(entry.id)) {
                Text("Decrease").tag(-1)
                Text("Increase").tag(1)
            }
        case .netHomeMode:
            Picker("Mode", selection: scheduleTextBinding(entry.id)) {
                Text("Auto").tag("auto")
                Text("Cool").tag("cool")
                Text("Heat").tag("heat")
                Text("Dry").tag("dry")
                Text("Fan").tag("fan")
            }
        case .netHomeFan:
            Stepper("Fan: \(entry.value ?? control.action.value)%", value: scheduleValueBinding(entry.id), in: 20...100, step: 20)
        case .netHomeAuto:
            Picker("Control", selection: scheduleTextBinding(entry.id)) {
                Text("Cooling").tag("cool")
                Text("Heating").tag("heat")
            }
        default:
            EmptyView()
        }
    }

    private func prepareSchedules() {
        guard control.action.scheduleEnabled == true,
              control.action.schedules?.isEmpty != false else { return }
        control.action.schedules = [makeScheduleEntry(
            hour: control.action.scheduleHour ?? 8,
            minute: control.action.scheduleMinute ?? 0
        )]
        syncLegacySchedule()
    }

    private func makeScheduleEntry(hour: Int = 8, minute: Int = 0) -> PaperGIFRemoteScheduleEntry {
        PaperGIFRemoteScheduleEntry(
            hour: hour,
            minute: minute,
            text: scheduleUsesText ? control.action.text : nil,
            value: scheduleUsesValue ? control.action.value : nil,
            valueTenths: control.action.type == .netHomeTemperature
                ? (control.action.valueTenths ?? control.action.value * 10) : nil
        )
    }

    private var scheduleUsesText: Bool {
        [.macMedia, .wledPower, .netHomePower, .netHomeMode, .netHomeAuto].contains(control.action.type)
    }

    private var scheduleUsesValue: Bool {
        [.macMedia, .wledPreset, .wledBrightness, .netHomeTemperature,
         .netHomeTemperatureStep, .netHomeFan].contains(control.action.type)
    }

    private func addSchedule() {
        prepareSchedules()
        guard var schedules = control.action.schedules, schedules.count < 8 else { return }
        let previous = schedules.last
        schedules.append(makeScheduleEntry(hour: previous?.hour ?? 8, minute: previous?.minute ?? 0))
        control.action.schedules = schedules
    }

    private func removeSchedule(_ id: UUID) {
        control.action.schedules?.removeAll { $0.id == id }
        if control.action.schedules?.isEmpty != false {
            control.action.scheduleEnabled = false
        }
        syncLegacySchedule()
    }

    private func updateSchedule(_ id: UUID, _ update: (inout PaperGIFRemoteScheduleEntry) -> Void) {
        guard let index = control.action.schedules?.firstIndex(where: { $0.id == id }) else { return }
        update(&control.action.schedules![index])
        syncLegacySchedule()
    }

    private func syncLegacySchedule() {
        control.action.scheduleHour = control.action.schedules?.first?.hour
        control.action.scheduleMinute = control.action.schedules?.first?.minute
    }

    private func toggleWeekday(_ weekday: Int, in id: UUID) {
        updateSchedule(id) { entry in
            if let index = entry.weekdays.firstIndex(of: weekday) {
                entry.weekdays.remove(at: index)
            } else {
                entry.weekdays.append(weekday)
                entry.weekdays.sort()
            }
        }
    }

    private func scheduleTimeBinding(_ id: UUID) -> Binding<Date> {
        Binding(
            get: {
                let entry = control.action.schedules?.first(where: { $0.id == id })
                return Calendar.current.date(
                    bySettingHour: entry?.hour ?? 8,
                    minute: entry?.minute ?? 0,
                    second: 0,
                    of: Date()
                ) ?? Date()
            },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                updateSchedule(id) {
                    $0.hour = components.hour ?? 8
                    $0.minute = components.minute ?? 0
                }
            }
        )
    }

    private func scheduleTextBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { control.action.schedules?.first(where: { $0.id == id })?.text ?? control.action.text },
            set: { value in updateSchedule(id) { $0.text = value } }
        )
    }

    private func scheduleValueBinding(_ id: UUID) -> Binding<Int> {
        Binding(
            get: { control.action.schedules?.first(where: { $0.id == id })?.value ?? control.action.value },
            set: { value in updateSchedule(id) { $0.value = value } }
        )
    }

    private func scheduleVolume(_ entry: PaperGIFRemoteScheduleEntry) -> Int {
        min(max(Int((Double(entry.value ?? control.action.value) / 255 * 100).rounded()), 0), 100)
    }

    private func scheduleVolumeBinding(_ id: UUID) -> Binding<Int> {
        Binding(
            get: {
                let value = control.action.schedules?.first(where: { $0.id == id })?.value ?? control.action.value
                return min(max(Int((Double(value) / 255 * 100).rounded()), 0), 100)
            },
            set: { percentage in
                updateSchedule(id) { $0.value = Int((Double(percentage) / 100 * 255).rounded()) }
            }
        )
    }

    private func scheduleTemperature(_ entry: PaperGIFRemoteScheduleEntry) -> Int {
        temperatureUnit.displayValue(celsiusTenths: entry.valueTenths ?? control.action.valueTenths ?? control.action.value * 10)
    }

    private func scheduleTemperatureBinding(_ id: UUID) -> Binding<Int> {
        Binding(
            get: {
                let entry = control.action.schedules?.first(where: { $0.id == id })
                return temperatureUnit.displayValue(
                    celsiusTenths: entry?.valueTenths ?? control.action.valueTenths ?? control.action.value * 10
                )
            },
            set: { displayValue in
                let tenths = min(max(temperatureUnit.celsiusTenthsValue(displayValue: displayValue), 160), 300)
                updateSchedule(id) {
                    $0.valueTenths = tenths
                    $0.value = Int((Double(tenths) / 10).rounded())
                }
            }
        )
    }

    private func textBoxBinding<Value>(
        _ keyPath: WritableKeyPath<PaperGIFRemoteTextBox, Value>
    ) -> Binding<Value> {
        Binding(
            get: { (control.textBox ?? PaperGIFRemoteTextBox())[keyPath: keyPath] },
            set: { value in
                var textBox = control.textBox ?? PaperGIFRemoteTextBox()
                textBox[keyPath: keyPath] = value
                control.textBox = textBox
            }
        )
    }

    private var referenceableControls: [PaperGIFRemoteControl] {
        pages.flatMap(\.controls).filter {
            ($0.id != control.id || $0.action.type == .netHomeTemperature) &&
                ($0.kind == .slider || $0.isToggle == true ||
                    $0.action.type == .netHomeTemperature)
        }
    }

    private var iPhoneMediaControls: [PaperGIFRemoteControl] {
        pages.flatMap(\.controls).filter { $0.action.type == .iPhoneMedia }
    }

    private func referenceableControlTitle(_ candidate: PaperGIFRemoteControl) -> String {
        let isNetHomeControl = switch candidate.action.type {
        case .netHomePower, .netHomeTemperature, .netHomeTemperatureStep,
             .netHomeMode, .netHomeFan, .netHomeAuto:
            true
        default:
            false
        }
        if isNetHomeControl && !candidate.action.host.isEmpty {
            return "\(candidate.action.host) \(candidate.title)"
        }
        return candidate.title
    }

    private var referencedControlBinding: Binding<String> {
        Binding(
            get: { control.textBox?.referencedControlID?.uuidString ?? "" },
            set: { identifier in
                var textBox = control.textBox ?? PaperGIFRemoteTextBox()
                textBox.referencedControlID = UUID(uuidString: identifier)
                control.textBox = textBox
            }
        )
    }

    private var textSourceComputerBinding: Binding<String> {
        Binding(
            get: { control.textBox?.computerID?.uuidString ?? "" },
            set: { identifier in
                var textBox = control.textBox ?? PaperGIFRemoteTextBox()
                textBox.computerID = UUID(uuidString: identifier)
                control.textBox = textBox
                if [.macMedia, .macScript, .macShortcut, .openBuilds].contains(control.action.type) {
                    control.action.computerID = identifier.isEmpty ? nil : identifier
                }
            }
        )
    }

    private var supportsAutomaticRefresh: Bool {
        switch control.textBox?.source ?? .staticText {
        case .dateTime, .macScript, .macShortcut, .nowPlaying, .openBuildsPosition:
            true
        case .staticText, .controlValue:
            false
        }
    }

    private var automaticRefreshBinding: Binding<Bool> {
        Binding(
            get: { control.textBox?.refreshIntervalSeconds != nil },
            set: { enabled in
                var textBox = control.textBox ?? PaperGIFRemoteTextBox()
                textBox.refreshIntervalSeconds = enabled ? max(textBox.refreshIntervalSeconds ?? 5, 5) : nil
                control.textBox = textBox
            }
        )
    }

    private var refreshIntervalBinding: Binding<Int> {
        Binding(
            get: { max(control.textBox?.refreshIntervalSeconds ?? 5, 5) },
            set: { interval in
                var textBox = control.textBox ?? PaperGIFRemoteTextBox()
                textBox.refreshIntervalSeconds = max(interval, 5)
                control.textBox = textBox
            }
        )
    }

    private func controlKindTitle(_ kind: PaperGIFRemoteControlKind) -> String {
        switch kind {
        case .button: "Button"
        case .slider: "Slider"
        case .textBox: "Text Box"
        }
    }

    private var brightnessBinding: Binding<Double> {
        Binding(
            get: { Double(control.action.value) },
            set: { control.action.value = Int($0.rounded()) }
        )
    }

    private var sliderOutlineEnabledBinding: Binding<Bool> {
        Binding(
            get: { control.sliderOutlineInsetPixels != nil },
            set: { control.sliderOutlineInsetPixels = $0 ? 3 : nil }
        )
    }

    private var sliderOutlineInsetBinding: Binding<Int> {
        Binding(
            get: { control.sliderOutlineInsetPixels ?? 3 },
            set: { control.sliderOutlineInsetPixels = min(max($0, 1), 32) }
        )
    }

    private var temperatureDisplayRange: ClosedRange<Int> {
        temperatureUnit.displayValue(celsius: 16)...temperatureUnit.displayValue(celsius: 30)
    }

    private var temperatureDisplayBinding: Binding<Int> {
        Binding(
            get: {
                temperatureUnit.displayValue(
                    celsiusTenths: control.action.valueTenths ?? control.action.value * 10
                )
            },
            set: {
                let tenths = min(max(temperatureUnit.celsiusTenthsValue(displayValue: $0), 160), 300)
                control.action.valueTenths = tenths
                control.action.value = Int((Double(tenths) / 10).rounded())
            }
        )
    }

    private var deadbandDisplayText: String {
        let celsius = Double(control.action.deadbandTenths ?? 10) / 10
        let value = temperatureUnit == .celsius ? celsius : celsius * 9 / 5
        return String(format: "%.1f %@", value, temperatureUnit.symbol)
    }

    private func optionalActionValueBinding(
        _ keyPath: WritableKeyPath<PaperGIFRemoteAction, Int?>,
        default defaultValue: Int
    ) -> Binding<Int> {
        Binding(
            get: { control.action[keyPath: keyPath] ?? defaultValue },
            set: { control.action[keyPath: keyPath] = $0 }
        )
    }

    private var volumePercentageBinding: Binding<Double> {
        Binding(
            get: { Double(volumePercentage) },
            set: { control.action.value = Int(($0 / 100 * 255).rounded()) }
        )
    }

    private var volumePercentage: Int {
        min(max(Int((Double(control.action.value) / 255 * 100).rounded()), 0), 100)
    }

    private var selectedIconTitle: String {
        if control.iconBitmap != nil {
            return "Application Icon"
        }
        return PaperGIFRemoteIcon.all.first(where: { $0.id == control.symbol })?.title ?? "None"
    }

    private var canUseButtonLayout: Bool {
        guard control.kind != .button,
              let page = pages.first(where: { page in
                  page.controls.contains(where: { $0.id == control.id })
              }) else { return true }
        let unitsUsed = page.controls.reduce(0) {
            $0 + $1.gridSpan.width * $1.gridSpan.height
        }
        return unitsUsed - control.gridSpan.width * control.gridSpan.height + 2 <= 16
    }

    private var controlKindBinding: Binding<PaperGIFRemoteControlKind> {
        Binding(
            get: { control.kind },
            set: { kind in
                control.kind = kind
                if kind == .textBox && control.textBox == nil {
                    control.textBox = PaperGIFRemoteTextBox()
                }
                if kind != .button {
                    control.isToggle = nil
                }
            }
        )
    }

    private var buttonHeightBinding: Binding<Int> {
        Binding(
            get: { control.buttonGridHeight },
            set: { control.buttonHeight = $0 }
        )
    }

    private var controlGridWidthBinding: Binding<Int> {
        Binding(
            get: { control.gridSpan(columns: gridColumns, rows: gridRows).width },
            set: { control.gridWidth = $0 }
        )
    }

    private var controlGridHeightBinding: Binding<Int> {
        Binding(
            get: { control.gridSpan(columns: gridColumns, rows: gridRows).height },
            set: { control.gridHeight = $0 }
        )
    }

    private var toggleButtonBinding: Binding<Bool> {
        Binding(
            get: { control.isToggle == true },
            set: { control.isToggle = $0 ? true : nil }
        )
    }

    private var isMacAction: Bool {
        switch control.action.type {
        case .macMedia, .macKey, .macOpen, .macShortcut, .macScript, .openBuilds,
               .netHomePower, .netHomeTemperature, .netHomeTemperatureStep,
             .netHomeMode, .netHomeFan, .netHomeAuto, .module:
            true
        default:
            false
        }
    }

    private var mediaCommandBinding: Binding<String> {
        Binding(
            get: { control.action.text },
            set: { control.setEditorMediaCommand($0) }
        )
    }

    private var localHTTPMethodBinding: Binding<String> {
        Binding(
            get: { control.action.httpMethod == "POST" ? "POST" : "GET" },
            set: { method in
                control.action.httpMethod = method
                if method == "GET" {
                    control.action.httpBody = nil
                }
            }
        )
    }

    private var homePowerServiceBinding: Binding<String> {
        Binding(
            get: {
                guard let accessoryID = control.action.deviceID,
                      !accessoryID.isEmpty, !control.action.host.isEmpty else { return "" }
                return "\(accessoryID):\(control.action.host)"
            },
            set: { selection in
                guard let service = homeManager.powerServices.first(where: { $0.id == selection }) else {
                    control.action.deviceID = nil
                    control.action.host = ""
                    return
                }
                control.action.deviceID = service.accessoryID
                control.action.host = service.serviceID
            }
        )
    }

    private func optionalActionStringBinding(
        _ keyPath: WritableKeyPath<PaperGIFRemoteAction, String?>
    ) -> Binding<String> {
        Binding(
            get: { control.action[keyPath: keyPath] ?? "" },
            set: { control.action[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    private var localHTTPBodyBinding: Binding<String> {
        Binding(
            get: { control.action.httpBody ?? "" },
            set: { control.action.httpBody = $0.isEmpty ? nil : $0 }
        )
    }

    private var isWLEDAction: Bool {
        switch control.action.type {
        case .wledPower, .wledPreset, .wledBrightness:
            true
        default:
            false
        }
    }

    private var computerIDBinding: Binding<String> {
        Binding(
            get: { control.action.computerID ?? "" },
            set: {
                control.action.computerID = $0.isEmpty ? nil : $0
                if let source = control.textBox?.source,
                   [.macScript, .macShortcut, .nowPlaying, .openBuildsPosition].contains(source) {
                    control.textBox?.computerID = UUID(uuidString: $0)
                }
                control.iconBitmap = nil
            }
        )
    }

    private var applicationSelectionBinding: Binding<String> {
        Binding(
            get: { control.action.text },
            set: { path in
                control.action.text = path
                control.iconBitmap = applicationCatalog.applications
                    .first(where: { $0.path == path })?.iconBitmap
            }
        )
    }

    private var applicationTargetBinding: Binding<String> {
        Binding(
            get: { control.action.text },
            set: { target in
                control.action.text = target
                guard applicationCatalog.applications.first(where: { $0.path == target })?.iconBitmap == control.iconBitmap else {
                    control.iconBitmap = nil
                    return
                }
            }
        )
    }

    private var symbolBinding: Binding<String> {
        Binding(
            get: { control.symbol },
            set: { symbol in
                control.symbol = symbol
                control.iconBitmap = nil
            }
        )
    }

    private var selectedApplicationComputer: PaperGIFRemoteComputer? {
        if let computerID = control.action.computerID,
           let computer = computers.first(where: { $0.id.uuidString == computerID }) {
            return computer
        }
        return computers.first
    }

    private var selectedApplicationComputerKey: String? {
        selectedApplicationComputer.map {
            "\($0.id.uuidString)|\($0.host)|\($0.port)|\($0.token)"
        }
    }

    private func modifierBinding(_ modifier: String) -> Binding<Bool> {
        Binding(
            get: { control.action.modifiers.contains(modifier) },
            set: { enabled in
                if enabled {
                    if !control.action.modifiers.contains(modifier) {
                        control.action.modifiers.append(modifier)
                    }
                } else {
                    control.action.modifiers.removeAll { $0 == modifier }
                }
            }
        )
    }

    private func mediaTitle(_ command: String) -> String {
        switch command {
        case "playPause": "Play/Pause"
        case "volumeUp": "Volume Up"
        case "volumeDown": "Volume Down"
        case "volume": "Volume"
        default: command.capitalized
        }
    }
}

private struct PaperGIFMacApplication: Decodable, Identifiable {
    let name: String
    let path: String
    let iconBitmap: String?

    var id: String { path }
}

private struct PaperGIFRemoteBitmapIcon: View {
    let symbol: String
    let bitmap: String?

    @ViewBuilder
    var body: some View {
        if let image = remoteBitmapMaskImage(bitmap) {
            Image(decorative: image, scale: 1)
                .renderingMode(.template)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
        } else if !symbol.isEmpty {
            Image(systemName: symbol)
                .resizable()
                .scaledToFit()
        }
    }
}

private func remoteBitmapMaskImage(_ hex: String?) -> CGImage? {
    guard let hex else { return nil }
    let characters = Array(hex.utf8)
    let dimension = characters.count == 256 ? 32 : characters.count == 1024 ? 64 : 0
    guard dimension > 0 else { return nil }

    func nibble(_ character: UInt8) -> UInt8? {
        switch character {
        case 48...57: character - 48
        case 65...70: character - 55
        case 97...102: character - 87
        default: nil
        }
    }

    var packed = [UInt8](repeating: 0, count: dimension * dimension / 8)
    for index in packed.indices {
        guard let high = nibble(characters[index * 2]),
              let low = nibble(characters[index * 2 + 1]) else { return nil }
        packed[index] = high << 4 | low
    }
    var pixels = [UInt8](repeating: 0, count: dimension * dimension * 4)
    for y in 0..<dimension {
        for x in 0..<dimension where packed[y * (dimension / 8) + x / 8] & (0x80 >> (x % 8)) != 0 {
            pixels[(y * dimension + x) * 4 + 3] = 255
        }
    }
    guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
    return CGImage(
        width: dimension,
        height: dimension,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: dimension * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )
}

@MainActor
private final class PaperGIFMacApplicationCatalog: ObservableObject {
    @Published private(set) var applications: [PaperGIFMacApplication] = []
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?

    private var loadedConfigurationKey: String?

    func load(from computer: PaperGIFRemoteComputer?) async {
        guard let computer else {
            applications = []
            message = "Pair a Mac to load its applications."
            loadedConfigurationKey = nil
            return
        }
        let configurationKey = "\(computer.id.uuidString)|\(computer.host)|\(computer.port)|\(computer.token)"
        guard loadedConfigurationKey != configurationKey else { return }
        loadedConfigurationKey = configurationKey

        isLoading = true
        message = nil
        defer { isLoading = false }

        var components = URLComponents()
        components.scheme = "http"
        components.host = computer.host
        components.port = computer.port
        components.path = "/applications"
        guard let url = components.url else {
            message = "This computer address isn’t valid."
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("Bearer \(computer.token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                message = "Couldn’t load applications from \(computer.name)."
                return
            }
            applications = try JSONDecoder().decode([PaperGIFMacApplication].self, from: data)
            if applications.isEmpty {
                message = "No applications were found on \(computer.name)."
            }
        } catch {
            message = "Couldn’t reach \(computer.name). Make sure paperGIF Mac is running."
        }
    }
}

private struct PaperGIFRemoteIconPicker: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                iconButton(id: "", title: "None", image: "square.dashed")
                ForEach(filteredIcons) { icon in
                    iconButton(id: icon.id, title: icon.title, image: icon.id)
                }
            }
            .padding()
        }
        .navigationTitle("Choose Icon")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search icons")
    }

    private var filteredIcons: [PaperGIFRemoteIcon] {
        guard !searchText.isEmpty else { return PaperGIFRemoteIcon.all }
        return PaperGIFRemoteIcon.all.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.id.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func iconButton(id: String, title: String, image: String) -> some View {
        Button {
            selection = id
            dismiss()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: image)
                    .font(.title2)
                    .frame(height: 28)
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, minHeight: 76)
            .foregroundStyle(selection == id ? Color.white : Color.primary)
            .background(selection == id ? Color.accentColor : Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selection == id ? .isSelected : [])
    }
}