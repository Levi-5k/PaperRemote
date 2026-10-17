import PaperDeviceKit
import Security
import SwiftUI
import UniformTypeIdentifiers

enum PaperGIFDeviceCredentials {
    static func token(for id: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "PaperRemote.controller",
            kSecAttrAccount as String: id,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func save(_ token: String, for id: String) throws {
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "PaperRemote.controller",
            kSecAttrAccount as String: id
        ]
        SecItemDelete(key as CFDictionary)
        guard !token.isEmpty else { return }
        var item = key
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

struct PaperGIFDeviceSetupView: View {
    @ObservedObject var session: DeviceSession
    @ObservedObject var bluetooth: PaperGIFBluetoothManager
    @Binding var profile: PaperGIFRemoteProfile
    @State private var address = ""
    @State private var token = ""
    @State private var problem: String?
    @State private var connectionTask: Task<Void, Never>?
    @State private var importingLayout = false
    @State private var layoutJSON = ""
    @State private var showingLayoutEditor = false
    @State private var layoutDeviceID: String?

    var body: some View {
        Form {
            Section("Controllers") {
                ForEach(session.records) { record in
                    Button {
                        connectionTask?.cancel()
                        session.select(id: record.id)
                        token = PaperGIFDeviceCredentials.token(for: record.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(record.descriptor.name)
                                Text(record.id).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if session.selectedID == record.id { Image(systemName: "checkmark.circle.fill") }
                        }
                    }
                }
                Text("Profiles and layout overrides are saved separately for each stable device ID.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Add or Verify Network Device") {
                TextField("http://device-address", text: $address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField("Device authorization token (if required)", text: $token)
                Button(session.isLoading ? "Connecting…" : "Read Device Capabilities") { connect() }
                    .disabled(session.isLoading || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("Native PaperRemote descriptors and the recognized legacy M5Paper protocol are supported. Other devices require a compatible protocol adapter; adding an address does not make an arbitrary controller compatible.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let message = session.message { Text(message).font(.footnote) }
            }
            if let descriptor = session.descriptor {
                Section("Selected Device") {
                    LabeledContent("Protocol", value: session.adapter == .legacyM5Paper ? "Legacy M5Paper (v6)" : "Native PaperRemote")
                    LabeledContent("Board", value: descriptor.boardID)
                    LabeledContent("Hardware", value: descriptor.hardwareRevision)
                    LabeledContent("Firmware", value: descriptor.firmwareVersion)
                    LabeledContent("Display", value: descriptor.display.map {
                        "\($0.width) × \($0.height), \($0.pixelFormat), rotation \($0.rotation)°"
                    } ?? "No display — physical inputs only")
                    LabeledContent("Profile versions", value: descriptor.capabilities.profileVersions.map(String.init).joined(separator: ", "))
                    Button("Save Authorization Token") {
                        do { try PaperGIFDeviceCredentials.save(token, for: descriptor.deviceID) }
                        catch { problem = error.localizedDescription }
                    }
                    Button("Load Profile from Device") { loadProfile() }
                        .disabled(!session.isVerified || session.address.isEmpty || session.isLoading)
                    Button("Send Saved Profile") { bluetooth.syncRemoteProfile(profile) }
                        .disabled(!bluetooth.canSyncSelectedProfile)
                    if let status = bluetooth.remoteSyncStatus { Text(status).font(.footnote) }
                }
                if !descriptor.isM5Paper {
                    Section("Native Network Configuration") {
                        TextField("Wi-Fi SSID", text: $profile.wifiSSID)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Wi-Fi password", text: $profile.wifiPassword)
                        if descriptor.boardID == "paperremote.esp32-screenless-reference" {
                            SecureField("Device enrollment token", text: $profile.macToken)
                            Button("Generate Enrollment Token") {
                                profile.macToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                            }
                            .disabled(!profile.computers.isEmpty || !profile.macHost.isEmpty)
                            if !profile.computers.isEmpty || !profile.macHost.isEmpty {
                                Text("A paired computer's token already provides enrollment. Generating a replacement would invalidate that computer's credentials.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            Text("First enrollment must be sent while connected to the reference board's own Wi-Fi access point. A nonempty enrollment or paired-computer token is required. The app retains the accepted token in Keychain for future edits.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Button("Save Network Configuration Locally") {
                            do {
                                profile.markUpdated()
                                try PaperGIFStorage.saveRemoteProfile(profile, deviceID: descriptor.deviceID)
                                try session.saveProfile(JSONEncoder().encode(profile))
                                problem = nil
                            } catch { problem = error.localizedDescription }
                        }
                        Text("Send the saved profile to apply Wi-Fi credentials. This does not invent BLE Wi-Fi setup support for other boards.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("Board Layout") {
                    Text("Layouts change appearance only, never capabilities or input IDs.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Import Layout JSON") {
                        layoutDeviceID = session.selectedID
                        importingLayout = true
                    }
                    Button("Edit Layout Geometry") {
                        if let data = try? JSONEncoder().encode(session.layout ?? descriptor.layout) {
                            layoutDeviceID = session.selectedID
                            layoutJSON = String(decoding: data, as: UTF8.self)
                            showingLayoutEditor = true
                        }
                    }
                }
            }
            Section("Bluetooth Discovery") {
                LabeledContent("Status", value: bluetooth.connectionState.description)
                if let status = bluetooth.descriptorStatus { Text(status).font(.footnote) }
                if let descriptor = bluetooth.bluetoothDescriptor {
                    Button("Select Discovered \(descriptor.name)") {
                        connectionTask?.cancel()
                        if let id = session.selectedID {
                            do { try PaperGIFStorage.saveRemoteProfile(profile, deviceID: id) }
                            catch { problem = error.localizedDescription; return }
                        }
                        connectionTask = Task {
                            do {
                                let savedAddress = session.records.first { $0.id == descriptor.deviceID }?.address ?? ""
                                try await session.applyDescriptor(descriptor, address: savedAddress)
                            } catch { problem = error.localizedDescription }
                        }
                    }
                }
                Text("Discovery is limited to the PaperRemote BLE service. Native custom boards use HTTP for profile sync; legacy BLE commands are enabled only for recognized M5Paper hardware.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let problem { Section("Problem") { Text(problem).foregroundStyle(.orange) } }
        }
        .navigationTitle("Device Setup")
        .onAppear {
            address = session.address
            if let id = session.selectedID { token = PaperGIFDeviceCredentials.token(for: id) }
        }
        .onChange(of: session.selectedID) {
            if let id = session.selectedID {
                token = PaperGIFDeviceCredentials.token(for: id)
                address = session.address
            }
        }
        .fileImporter(isPresented: $importingLayout, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 65_536 else { throw DeviceContractError.invalid("layout file exceeds 64 KiB") }
                try applyLayout(Data(contentsOf: url))
            } catch { problem = error.localizedDescription }
        }
        .sheet(isPresented: $showingLayoutEditor) {
            NavigationStack {
                TextEditor(text: $layoutJSON).font(.system(.body, design: .monospaced)).padding()
                    .navigationTitle("Layout JSON")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingLayoutEditor = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Apply") {
                                do {
                                    try applyLayout(Data(layoutJSON.utf8))
                                    showingLayoutEditor = false
                                } catch { problem = error.localizedDescription }
                            }
                        }
                    }
            }
        }
    }

    private func applyLayout(_ data: Data) throws {
        guard layoutDeviceID == session.selectedID else { throw CancellationError() }
        guard data.count <= 65_536 else { throw DeviceContractError.invalid("layout exceeds 64 KiB") }
        try session.setLayoutOverride(JSONDecoder().decode(DeviceLayout.self, from: data))
        problem = nil
    }

    private func connect() {
        connectionTask?.cancel()
        if let id = session.selectedID {
            do { try PaperGIFStorage.saveRemoteProfile(profile, deviceID: id) }
            catch { problem = error.localizedDescription; return }
        }
        let requestedAddress = address
        let requestedToken = token
        problem = nil
        connectionTask = Task {
            do {
                try await session.connect(address: requestedAddress)
                guard !Task.isCancelled, session.address == requestedAddress,
                      let id = session.selectedID else { return }
                try PaperGIFDeviceCredentials.save(requestedToken, for: id)
            } catch is CancellationError {
            } catch { problem = error.localizedDescription }
        }
    }

    private func loadProfile() {
        connectionTask?.cancel()
        connectionTask = Task {
            do {
                guard let descriptor = session.descriptor else { return }
                let data = try await session.loadProfile(token: PaperGIFDeviceCredentials.token(for: descriptor.deviceID))
                let loaded = try JSONDecoder().decode(PaperGIFRemoteProfile.self, from: data)
                _ = try loaded.negotiatedPayload(for: descriptor)
                try PaperGIFStorage.saveRemoteProfile(loaded, deviceID: descriptor.deviceID)
                try session.saveProfile(data)
                profile = loaded
                problem = nil
            } catch is CancellationError {
            } catch { problem = error.localizedDescription }
        }
    }
}
