import SwiftUI

struct MatterDevicesSection: View {
    @ObservedObject var manager: MatterDeviceManager
    @State private var name = ""
    @State private var pairingCode = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    Task { await manager.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(manager.isBusy)
                if manager.isBusy && !manager.isAdding { ProgressView().controlSize(.small) }
            }

            if manager.devices.isEmpty {
                Text("No devices added to this Mac yet. Devices in Apple Home don't appear here automatically; add each one below with a pairing code from the Home app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(manager.devices) { device in
                HStack {
                    Label(device.name, systemImage: "powerplug")
                    Spacer()
                    // The module's buttons don't name a device, so they control the newest one.
                    if device == manager.devices.last {
                        Text("Controlled by Matter buttons")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            GroupBox("Add Device") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Already in Apple Home? Open the device's settings in the Home app, tap **Turn On Pairing Mode**, and enter the code here within a few minutes. It stays in Apple Home.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("Name, e.g. Desk Lamp", text: $name)
                    TextField("Pairing code, e.g. 1234-567-8901", text: $pairingCode)
                        .font(.body.monospaced())
                    HStack {
                        Button {
                            Task {
                                await manager.add(pairingCode: pairingCode, name: name)
                                if manager.lastAddSucceeded {
                                    name = ""
                                    pairingCode = ""
                                }
                            }
                        } label: {
                            Label(manager.isAdding ? "Adding…" : "Add Device", systemImage: "plus.circle")
                        }
                        .disabled(manager.isBusy || !MatterDeviceManager.isPlausiblePairingCode(pairingCode))
                        if manager.isAdding { ProgressView().controlSize(.small) }
                    }
                }
                .padding(.top, 4)
            }

            if let status = manager.status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await manager.refresh() }
    }
}
