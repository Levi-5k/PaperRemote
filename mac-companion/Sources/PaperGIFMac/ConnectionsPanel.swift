import CoreWLAN
import SwiftUI

private struct PairingRequest: Encodable {
    let deviceName: String
}

private struct PairingResponse: Decodable {
    let token: String
}

struct ConnectionsPanel: View {
    @ObservedObject var store: RemoteEditorStore
    @ObservedObject var computers: ComputerDiscovery
    @ObservedObject var wled: WLEDDiscovery

    @State private var selectedComputerID: UUID?
    @State private var computerName = ""
    @State private var computerHost = ""
    @State private var computerPort = 43_821
    @State private var computerToken = ""
    @State private var computerStatus: String?
    @State private var isConnectingComputer = false
    @State private var manualWLEDAddress = ""
    @State private var wledStatus: String?
    @State private var isConnectingWLED = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                section("DEVICE WI-FI", systemImage: "wifi") {
                    HStack {
                        Button {
                            Task { await store.scanWiFiNetworks() }
                        } label: {
                            Label(store.isScanningWiFi ? "Scanning..." : "Scan for Networks", systemImage: "wifi")
                        }
                        .disabled(store.isScanningWiFi)
                        if store.isScanningWiFi { ProgressView().controlSize(.small) }
                    }

                    ForEach(store.wifiNetworks) { network in
                        Button {
                            store.profile.wifiSSID = network.ssid
                            if !network.secure { store.profile.wifiPassword = "" }
                        } label: {
                            HStack {
                                Label(network.ssid, systemImage: network.secure ? "lock.fill" : "wifi")
                                Spacer()
                                Text("\(network.rssi) dBm")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                if store.profile.wifiSSID == network.ssid {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    if let error = store.wifiScanError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    LabeledContent("Network") {
                        TextField("Wi-Fi name", text: $store.profile.wifiSSID)
                    }
                    LabeledContent("Password") {
                        SecureField("Wi-Fi password", text: $store.profile.wifiPassword)
                    }
                    HStack {
                        Button(action: useCurrentWiFi) {
                            Label("Use This Mac's Wi-Fi", systemImage: "wifi")
                        }
                        Spacer()
                        Button {
                            Task { await store.send() }
                        } label: {
                            Label("Send Settings", systemImage: "paperplane")
                        }
                        .disabled(store.profile.wifiSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Text("The M5Paper, computers, and WLED devices must use the same home network.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                section("COMPUTERS", systemImage: "desktopcomputer") {
                    ForEach(store.profile.computers) { computer in
                        HStack(spacing: 8) {
                            Button {
                                select(computer)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(computer.name).foregroundStyle(.primary)
                                    Text("\(computer.host):\(computer.port)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            if selectedComputerID == computer.id {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                            Button {
                                Task { await test(computer) }
                            } label: {
                                Image(systemName: "network")
                            }
                            .help("Test connection")
                            Button(role: .destructive) {
                                store.deleteComputer(computer.id)
                                if selectedComputerID == computer.id { clearComputerDraft() }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .help("Remove computer")
                        }
                    }

                    if !store.profile.computers.contains(where: { $0.host == store.localComputer.host }) {
                        Button {
                            store.addLocalComputer()
                        } label: {
                            Label("Add This Mac", systemImage: "plus.circle")
                        }
                        .disabled(store.profile.computers.count >= 8)
                    }

                    HStack {
                        Button { computers.start() } label: {
                            Label(computers.state == .searching ? "Searching..." : "Find Computers", systemImage: "magnifyingglass")
                        }
                        .disabled(computers.state == .searching)
                        if computers.state == .searching { ProgressView().controlSize(.small) }
                        Spacer()
                        Text("\(store.profile.computers.count) / 8")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    ForEach(computers.computers) { computer in
                        let paired = store.profile.computers.first {
                            $0.host == computer.host && $0.port == computer.port
                        }
                        Button {
                            if let paired {
                                select(paired)
                            } else {
                                selectedComputerID = nil
                                computerName = computer.name
                                computerHost = computer.host
                                computerPort = computer.port
                                computerToken = ""
                                computerStatus = "Ready to request pairing from \(computer.name)."
                            }
                        } label: {
                            HStack {
                                Label(computer.name, systemImage: "desktopcomputer")
                                Spacer()
                                Image(systemName: paired == nil ? "plus.circle" : "checkmark.circle.fill")
                                    .foregroundStyle(paired == nil ? Color.accentColor : Color.green)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    if case .failed(let message) = computers.state {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    GroupBox(selectedComputerID == nil ? "Add Computer" : "Edit Computer") {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Computer name", text: $computerName)
                            TextField("Host", text: $computerHost)
                            Stepper("Port: \(computerPort)", value: $computerPort, in: 1...65_535)
                            HStack {
                                Button {
                                    Task { await connectComputer() }
                                } label: {
                                    Label(
                                        isConnectingComputer
                                            ? "Connecting..."
                                            : (computerToken.isEmpty ? "Request Pairing" : "Save & Test"),
                                        systemImage: computerToken.isEmpty ? "link.badge.plus" : "network"
                                    )
                                }
                                .disabled(
                                    isConnectingComputer || computerName.trimmingCharacters(in: .whitespaces).isEmpty ||
                                    computerHost.trimmingCharacters(in: .whitespaces).isEmpty ||
                                    (selectedComputerID == nil && store.profile.computers.count >= 8)
                                )
                                Button("New") { clearComputerDraft() }
                            }
                        }
                        .padding(.top, 4)
                    }

                    if let computerStatus {
                        Text(computerStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Divider()

                section("WLED DEVICES", systemImage: "lightbulb.fill") {
                    HStack {
                        Button { wled.start() } label: {
                            Label(wled.isSearching ? "Scanning..." : "Scan Again", systemImage: "dot.radiowaves.left.and.right")
                        }
                        .disabled(wled.isSearching)
                        if wled.isSearching { ProgressView().controlSize(.small) }
                    }

                    ForEach(wled.devices) { device in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                Text(device.actionHost)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if store.hasWLEDControls(host: device.actionHost) {
                                Label("Added", systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            } else {
                                Button {
                                    store.addWLEDPage(name: device.name, host: device.actionHost)
                                } label: {
                                    Label("Add Page", systemImage: "plus.circle")
                                }
                                .disabled(store.profile.pages.count >= 8)
                            }
                        }
                    }

                    if let error = wled.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        TextField("Hostname or IP address", text: $manualWLEDAddress)
                        Button {
                            Task { await addManualWLED() }
                        } label: {
                            Label(isConnectingWLED ? "Connecting..." : "Connect & Add", systemImage: "link")
                        }
                        .disabled(
                            isConnectingWLED || manualWLEDAddress.trimmingCharacters(in: .whitespaces).isEmpty ||
                            store.profile.pages.count >= 8
                        )
                    }
                    if let wledStatus {
                        Text(wledStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
        }
    }

    private func section<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func useCurrentWiFi() {
        if let ssid = CWWiFiClient.shared().interface()?.ssid(), !ssid.isEmpty {
            store.profile.wifiSSID = ssid
        } else {
            computerStatus = "Could not read this Mac's network. Enter its name manually."
        }
    }

    private func select(_ computer: RemoteComputer) {
        selectedComputerID = computer.id
        computerName = computer.name
        computerHost = computer.host
        computerPort = computer.port
        computerToken = computer.token
        computerStatus = "Editing \(computer.name)."
    }

    private func clearComputerDraft() {
        selectedComputerID = nil
        computerName = ""
        computerHost = ""
        computerPort = 43_821
        computerToken = ""
        computerStatus = nil
    }

    private func connectComputer() async {
        let name = computerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = computerHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !host.isEmpty else { return }
        let isPairing = computerToken.isEmpty
        isConnectingComputer = true
        computerStatus = isPairing ? "Approve the request on \(name)." : "Testing \(name)..."
        defer { isConnectingComputer = false }

        guard let url = computerURL(host: host, port: computerPort, path: isPairing ? "/pair" : "/status") else {
            computerStatus = "That computer address is invalid."
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = isPairing ? 45 : 5
        if isPairing {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(PairingRequest(
                deviceName: Host.current().localizedName ?? "paperGIF Mac"
            ))
        } else {
            request.setValue("Bearer \(computerToken)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                computerStatus = "\(name) returned an invalid response."
                return
            }
            guard response.statusCode == 200 else {
                if response.statusCode == 401 { computerToken = "" }
                computerStatus = response.statusCode == 403
                    ? "Pairing was declined on \(name)."
                    : "Could not connect to \(name)."
                return
            }
            if isPairing {
                guard let pairing = try? JSONDecoder().decode(PairingResponse.self, from: data),
                      !pairing.token.isEmpty else {
                    computerStatus = "\(name) did not return pairing credentials."
                    return
                }
                computerToken = pairing.token
            }
            let computer = RemoteComputer(
                id: selectedComputerID ?? UUID(),
                name: name,
                host: host,
                port: computerPort,
                token: computerToken
            )
            store.upsertComputer(computer)
            selectedComputerID = computer.id
            computerStatus = isPairing ? "Paired with \(name)." : "Connected to \(name)."
        } catch {
            computerStatus = "Could not reach \(name). Make sure paperGIF Mac is running."
        }
    }

    private func test(_ computer: RemoteComputer) async {
        guard let url = computerURL(host: computer.host, port: computer.port, path: "/status") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("Bearer \(computer.token)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            computerStatus = (response as? HTTPURLResponse)?.statusCode == 200
                ? "Connected to \(computer.name)."
                : "\(computer.name) rejected the saved pairing."
        } catch {
            computerStatus = "Could not reach \(computer.name)."
        }
    }

    private func addManualWLED() async {
        isConnectingWLED = true
        wledStatus = "Connecting..."
        defer { isConnectingWLED = false }
        do {
            let device = try await wled.device(at: manualWLEDAddress)
            manualWLEDAddress = device.actionHost
            store.addWLEDPage(name: device.name, host: device.actionHost)
            wledStatus = "Added \(device.name)."
        } catch {
            wledStatus = error.localizedDescription
        }
    }

    private func computerURL(host: String, port: Int, path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = path
        return components.url
    }
}