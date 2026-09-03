import SwiftUI

struct PaperGIFDeviceView: View {
    @ObservedObject var bluetoothManager: PaperGIFBluetoothManager
    let animation: PaperGIFAnimation?
    let sourceName: String

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