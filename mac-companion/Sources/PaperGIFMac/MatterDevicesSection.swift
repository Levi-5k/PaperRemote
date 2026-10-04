import SwiftUI

struct MatterDevicesSection: View {
    @ObservedObject var manager: MatterDeviceManager
    @State private var showingSetup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    showingSetup = true
                } label: {
                    Label("Set Up a Device…", systemImage: "plus.circle")
                }
                .disabled(manager.isBusy)
                Button {
                    Task { await manager.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(manager.isBusy)
                if manager.isBusy && !manager.isAdding { ProgressView().controlSize(.small) }
            }

            if manager.devices.isEmpty {
                Text("No devices added to this Mac yet. Devices in Apple Home don't appear here automatically; use Set Up a Device to add each one.")
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
        }
        .task { await manager.refresh() }
        .sheet(isPresented: $showingSetup) {
            MatterSetupSheet(manager: manager)
        }
    }
}

private struct MatterSetupSheet: View {
    private enum Step {
        case pairingMode, enterCode, adding, finished
    }

    @ObservedObject var manager: MatterDeviceManager
    @Environment(\.dismiss) private var dismiss
    @State private var step = Step.pairingMode
    @State private var name = ""
    @State private var pairingCode = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "powerplug.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set Up a Matter Device").font(.headline)
                    Text(stepCaption).font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            Divider()
            buttons
        }
        .padding(20)
        .frame(width: 460, height: 380)
        .interactiveDismissDisabled(step == .adding)
    }

    private var stepCaption: String {
        switch step {
        case .pairingMode: "Step 1 of 3 · Get a pairing code"
        case .enterCode: "Step 2 of 3 · Enter the code"
        case .adding: "Step 3 of 3 · Adding to this Mac"
        case .finished: manager.lastAddSucceeded ? "Done" : "Setup didn't finish"
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .pairingMode:
            VStack(alignment: .leading, spacing: 10) {
                Text("Your device can stay in Apple Home. Apple Home creates a one-time code that lets this Mac control it too.")
                    .fixedSize(horizontal: false, vertical: true)
                instruction(1, "On your iPhone, open the **Home** app.")
                instruction(2, "Touch and hold the device, then tap the **settings** button (or scroll to the bottom).")
                instruction(3, "Tap **Turn On Pairing Mode**, then copy the **Setup Code** it shows.")
                Text("The code only works for a few minutes, so continue right away.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .enterCode:
            VStack(alignment: .leading, spacing: 10) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. Desk Lamp", text: $name)
                Text("Setup code").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. 1234-567-8901", text: $pairingCode)
                    .font(.body.monospaced())
                if !pairingCode.isEmpty && !MatterDeviceManager.isPlausiblePairingCode(pairingCode) {
                    Text("Setup codes have 11 digits, like 1234-567-8901.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        case .adding:
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Adding \(displayName)…")
                }
                Text("Keep the device powered and nearby, and leave pairing mode on. This can take up to 2 minutes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .finished:
            if manager.lastAddSucceeded {
                VStack(alignment: .leading, spacing: 10) {
                    Label("\(displayName) was added to this Mac.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Next, open **Add Controls**, find **Matter Switch**, and add the Switch, On, or Off button to a page.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label(manager.status ?? "The device couldn't be added.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Things to check:").font(.caption.weight(.semibold))
                    Text("• Pairing mode may have expired. Turn it on again in the Home app for a new code.")
                    Text("• The code must be typed exactly as shown.")
                    Text("• The device and this Mac must be on the same home network.")
                }
                .font(.caption)
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack {
            if step != .adding && step != .finished {
                Button("Cancel") { dismiss() }
            }
            Spacer()
            switch step {
            case .pairingMode:
                Button("I Have the Code") { step = .enterCode }
                    .keyboardShortcut(.defaultAction)
            case .enterCode:
                Button("Back") { step = .pairingMode }
                Button("Add Device") { startAdding() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!MatterDeviceManager.isPlausiblePairingCode(pairingCode))
            case .adding:
                EmptyView()
            case .finished:
                if !manager.lastAddSucceeded {
                    Button("Try Again") {
                        pairingCode = ""
                        step = .pairingMode
                    }
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "the device" : trimmed
    }

    private func instruction(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor.opacity(0.18)))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func startAdding() {
        step = .adding
        Task {
            await manager.add(pairingCode: pairingCode, name: name)
            step = .finished
        }
    }
}
