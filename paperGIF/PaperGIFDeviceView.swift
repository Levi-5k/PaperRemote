import SwiftUI

struct PaperGIFDeviceView: View {
    @ObservedObject var bluetoothManager: PaperGIFBluetoothManager
    let animation: PaperGIFAnimation?
    let sourceName: String
    @StateObject private var firmware = PaperGIFFirmwareUpdater()

    var body: some View {
        NavigationStack {
            Form {
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
                        bluetoothManager.isTransferring
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

                firmwareSection

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
            }
            .navigationTitle("Device")
            .task(id: bluetoothManager.deviceHTTPEndpoint) {
                await firmware.refresh(endpoint: bluetoothManager.deviceHTTPEndpoint)
            }
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
            } else if let endpoint = bluetoothManager.deviceHTTPEndpoint,
                      firmware.updateAvailable, !firmware.needsUSB {
                Button {
                    Task { await firmware.install(endpoint: endpoint) }
                } label: {
                    Label("Update M5Paper to \(firmware.release?.version ?? "")", systemImage: "arrow.down.circle.fill")
                }
                .disabled(bluetoothManager.isTransferring)
            } else {
                Button {
                    Task { await firmware.refresh(endpoint: bluetoothManager.deviceHTTPEndpoint) }
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
            } else if bluetoothManager.deviceHTTPEndpoint == nil {
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