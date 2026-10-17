import SwiftUI
import PaperDeviceKit

struct PaperGIFDeviceView: View {
    @ObservedObject var bluetoothManager: PaperGIFBluetoothManager
    let animation: PaperGIFAnimation?
    let sourceName: String
    @ObservedObject var session: DeviceSession
    @Binding var profile: PaperGIFRemoteProfile
    @StateObject private var firmware = PaperGIFFirmwareUpdater()
    @State private var firmwareTask: Task<Void, Never>?

    private var firmwareEndpoint: PaperGIFDeviceEndpoint? {
        if session.isVerified, let descriptor = session.descriptor,
           descriptor.isM5Paper, !session.address.isEmpty,
           let url = try? DeviceHTTP.endpoint(session.address, path: "/") {
            let token = PaperGIFDeviceCredentials.token(for: descriptor.deviceID)
            return PaperGIFDeviceEndpoint(url: url, authorization: token.isEmpty ? nil : "Bearer \(token)")
        }
        return bluetoothManager.deviceHTTPEndpoint
    }

    /// The active device's descriptor when it declares device controls.
    private var controlsDescriptor: DeviceDescriptor? {
        let descriptor = session.descriptor ?? bluetoothManager.bluetoothDescriptor
        guard let descriptor, !descriptor.controls.isEmpty else { return nil }
        return descriptor
    }

    private var firmwareTargetID: String {
        "\(session.selectedID ?? "")|\(firmwareEndpoint?.url.absoluteString ?? "")|\(session.isVerified)"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        PaperGIFDeviceSetupView(session: session, bluetooth: bluetoothManager, profile: $profile)
                    } label: {
                        Label("Device Setup & Saved Controllers", systemImage: "rectangle.connected.to.line.below")
                    }
                    if let descriptor = session.descriptor {
                        LabeledContent("Selected", value: descriptor.name)
                    }
                }
                if let descriptor = controlsDescriptor {
                    PaperGIFDeviceControlsView(
                        descriptor: descriptor,
                        bluetoothManager: bluetoothManager,
                        session: session
                    )
                    .id(descriptor.deviceID)
                }
                if session.descriptor?.isM5Paper != false {
                Section("M5Paper") {
                    LabeledContent {
                        Text(bluetoothManager.connectionState.description)
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("Bluetooth", systemImage: connectionIcon)
                    }

                    Toggle(isOn: Binding(
                        get: { bluetoothManager.wifiEnabled },
                        set: { bluetoothManager.setDeviceWiFiEnabled($0) }
                    )) {
                        Label("Wi-Fi", systemImage: wifiConnectionIcon)
                    }
                    .disabled(
                        bluetoothManager.wifiConnectionState == .checking ||
                        bluetoothManager.wifiConnectionState == .connecting ||
                        bluetoothManager.isTransferring || !bluetoothManager.legacyBLEPermitted
                    )

                    LabeledContent("Wi-Fi status", value: bluetoothManager.wifiConnectionState.description)

                    if let wifiConnectionError = bluetoothManager.wifiConnectionError {
                        Text(wifiConnectionError)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if bluetoothManager.connectionState == .connected {
                        Button("Forget Device", role: .destructive) {
                            bluetoothManager.forgetDevice()
                        }
                    } else {
                        Text("Keep the M5Paper powered on. The app reconnects to a saved device or discovers a new one automatically.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                }

                if session.descriptor?.isM5Paper == true,
                   session.descriptor?.capabilities.firmwareUpdate == true {
                    firmwareSection
                } else {
                    Section("Firmware") {
                        Text("No compatible firmware update is available for this board. M5Paper firmware is never offered to unknown or custom boards.")
                    }
                }

                if session.descriptor?.canUseLegacyMedia != false {
                Section("Media") {
                    if let animation {
                        LabeledContent("Name", value: sourceName)
                        LabeledContent("Frames", value: "\(animation.frames.count)")

                        if bluetoothManager.isTransferring {
                            ProgressView(value: bluetoothManager.transferProgress)
                            Text(bluetoothManager.transferStatus ?? "Sending")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else if let transferStatus = bluetoothManager.transferStatus {
                            Text(transferStatus)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            bluetoothManager.send(animation.encoded, name: sourceName)
                        } label: {
                            Label("Send to M5Paper", systemImage: "antenna.radiowaves.left.and.right")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!bluetoothManager.canSend)
                    } else {
                        ContentUnavailableView(
                            "No Media",
                            systemImage: "photo.on.rectangle",
                            description: Text("Convert a picture or GIF before sending it to the display.")
                        )
                    }
                }
                } else {
                    Section("Media") {
                        Text("Media and button images are unavailable: this device has no supported M5Paper-compatible display encoder.")
                    }
                }
            }
            .navigationTitle("Device")
            .task(id: firmwareTargetID) {
                await firmware.refresh(endpoint: firmwareEndpoint, descriptor: session.descriptor)
            }
            .onChange(of: session.selectedID) {
                firmwareTask?.cancel()
                firmware.resetForDevice()
            }
            .onDisappear { firmwareTask?.cancel() }
        }
    }

    private var firmwareSection: some View {
        Section {
            LabeledContent("Installed", value: firmware.deviceFirmware ?? "Not reachable over Wi-Fi")
            LabeledContent("Latest release", value: firmware.release?.version ?? "Unknown")

            if let activity = firmware.activity {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(activity)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if let endpoint = firmwareEndpoint,
                      firmware.updateAvailable, !firmware.needsUSB {
                Button {
                    firmwareTask = Task { await firmware.install(endpoint: endpoint, descriptor: session.descriptor) }
                } label: {
                    Label("Update M5Paper to \(firmware.release?.version ?? "")", systemImage: "arrow.down.circle.fill")
                }
                .disabled(bluetoothManager.isTransferring || !session.isVerified)
            } else {
                Button {
                    Task { await firmware.refresh(endpoint: firmwareEndpoint, descriptor: session.descriptor) }
                } label: {
                    Label("Check for Updates", systemImage: "arrow.clockwise")
                }
            }

            if let problem = firmware.problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else if let notice = firmware.notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.green)
            }
        } header: {
            Text("Firmware")
        } footer: {
            if firmware.needsUSB {
                Text("This M5Paper's firmware is too old for Wi-Fi updates. Flash it over USB once; later updates install from here.")
            } else if firmwareEndpoint == nil {
                Text("Firmware updates install over Wi-Fi. Connect the M5Paper to Wi-Fi to check its version.")
            } else if firmware.deviceFirmware != nil, !firmware.updateAvailable, firmware.release != nil {
                Text("The M5Paper is up to date.")
            }
        }
    }

    private var connectionIcon: String {
        switch bluetoothManager.connectionState {
        case .bluetoothUnavailable:
            "antenna.radiowaves.left.and.right.slash"
        case .searching:
            "dot.radiowaves.left.and.right"
        case .connecting:
            "ellipsis"
        case .connected:
            "checkmark.circle.fill"
        }
    }

    private var wifiConnectionIcon: String {
        switch bluetoothManager.wifiConnectionState {
        case .checking:
            "ellipsis"
        case .connecting:
            "wifi"
        case .unavailable:
            "wifi.slash"
        case .connected:
            "wifi"
        }
    }
}