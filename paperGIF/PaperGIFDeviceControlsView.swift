import PaperDeviceKit
import SwiftUI

/// Sections generated from the selected device's descriptor `controls`.
/// Embedded in the Device tab's form; it shows nothing for devices without controls.
struct PaperGIFDeviceControlsView: View {
    let descriptor: DeviceDescriptor
    @ObservedObject var bluetoothManager: PaperGIFBluetoothManager
    @ObservedObject var session: DeviceSession
    @StateObject private var model = DeviceControlsModel()
    @State private var lastRefresh: Date?

    private struct ConfigurationKey: Equatable {
        let deviceID: String
        let controls: [DeviceControl]
        let routes: PaperGIFDeviceControlRoutes
    }

    private var controls: [DeviceControl] { descriptor.controls }
    private var routes: PaperGIFDeviceControlRoutes { bluetoothManager.deviceControlRoutes(for: descriptor) }

    var body: some View {
        Section {
            statusRow
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Device controls error: \(error)")
            }
            if routes.isEmpty, let status = bluetoothManager.descriptorStatus {
                Text(status).font(.footnote).foregroundStyle(.secondary)
            }
            Button {
                if routes.isEmpty {
                    bluetoothManager.connectSavedDevice(deviceID: descriptor.deviceID)
                } else {
                    Task { await refresh() }
                }
            } label: {
                Label("Refresh Controls", systemImage: "arrow.clockwise")
            }
            .disabled(model.isLoading)
            .accessibilityHint("Reads the current values from \(descriptor.name)")
            if let lastRefresh {
                LabeledContent("Last Updated", value: lastRefresh.formatted(date: .omitted, time: .standard))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Device Controls")
        } footer: {
            if routes.isEmpty {
                Text("Refresh Controls reconnects to \(descriptor.name) over Bluetooth when it is not already reachable. Keep the controller powered on and nearby.")
            }
        }
        .task(id: ConfigurationKey(deviceID: descriptor.deviceID, controls: controls, routes: routes)) {
            let routes = routes
            model.configure(controls: controls, transports: bluetoothManager.deviceControlTransports(for: routes))
            guard !routes.isEmpty else { return }
            await refresh()
        }
        .onChange(of: bluetoothManager.pushedControlSnapshot) {
            guard let pushed = bluetoothManager.pushedControlSnapshot, routes.bluetooth else { return }
            model.receive(pushed.snapshot, via: "Bluetooth")
        }

        // Dial settings live in the knob's own editor on the Remote page.
        ForEach(model.groups.filter { !DeviceDialView.isSupported(by: controls) || $0.name != "Dial" }, id: \.name) { group in
            Section(group.name) {
                ForEach(group.controls) { control in
                    PaperGIFDeviceControlRow(
                        control: control,
                        model: model,
                        isReachable: !routes.isEmpty
                    )
                }
            }
        }
    }

    private func refresh() async {
        await model.refresh()
        if !Task.isCancelled, model.error == nil, model.activeTransport != nil { lastRefresh = Date() }
    }

    @ViewBuilder
    private var statusRow: some View {
        LabeledContent {
            HStack(spacing: 6) {
                if model.isLoading { ProgressView() }
                Text(connectionText).foregroundStyle(.secondary)
            }
        } label: {
            Label("Connection", systemImage: connectionIcon)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Device controls connection")
        .accessibilityValue(model.isLoading ? "Loading, \(connectionText)" : connectionText)
    }

    private var connectionText: String {
        if let transport = model.activeTransport { return "Via \(transport)" }
        if model.isLoading { return "Loading…" }
        if routes.isEmpty {
            switch bluetoothManager.connectionState {
            case .connecting: return "Connecting over Bluetooth…"
            case .searching: return "Looking for the selected controller…"
            case .bluetoothUnavailable: return "Bluetooth unavailable"
            case .connected: return "Not reachable"
            }
        }
        return routes.httpAddress != nil ? "Wi-Fi available" : "Bluetooth available"
    }

    private var connectionIcon: String {
        switch model.activeTransport {
        case "Wi-Fi": "wifi"
        case "Bluetooth": "antenna.radiowaves.left.and.right"
        default: routes.isEmpty ? "wifi.slash" : "dot.radiowaves.left.and.right"
        }
    }
}

/// Live dial position, end stops and precision settings, shown only in the knob's own input
/// editor. Uses the same Wi-Fi/Bluetooth routes as Device Controls.
struct PaperGIFDialSettingsSection: View {
    let descriptor: DeviceDescriptor
    @ObservedObject var bluetoothManager: PaperGIFBluetoothManager
    @StateObject private var model = DeviceControlsModel()

    static func isAvailable(for descriptor: DeviceDescriptor) -> Bool {
        DeviceDialView.isSupported(by: descriptor.controls)
    }

    private var routes: PaperGIFDeviceControlRoutes { bluetoothManager.deviceControlRoutes(for: descriptor) }

    var body: some View {
        Section {
            if routes.isEmpty {
                Text("Connect to \(descriptor.name) to see the live dial and change its end stops.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Connect Over Bluetooth") {
                    bluetoothManager.connectSavedDevice(deviceID: descriptor.deviceID)
                }
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            }
            DeviceDialView(model: model)
        } header: {
            Text("Dial Settings")
        }
        .task(id: routes) {
            let routes = routes
            model.configure(controls: descriptor.controls,
                            transports: bluetoothManager.deviceControlTransports(for: routes))
            guard !routes.isEmpty else { return }
            await model.refresh()
            await model.monitorDial()
        }
        .onChange(of: bluetoothManager.pushedControlSnapshot) {
            guard let pushed = bluetoothManager.pushedControlSnapshot, routes.bluetooth else { return }
            model.receive(pushed.snapshot, via: "Bluetooth")
        }
        .onChange(of: bluetoothManager.liveDial) { _, dial in
            // Low latency mode streams the dial between the slower full snapshots.
            guard let dial, routes.bluetooth, model.values["dialAngle"] != nil else { return }
            var values = model.values
            values["dialAngle"] = .number(dial.angle)
            values["dialPosition"] = .number(dial.position)
            model.receive(DeviceControlSnapshot(values: values), via: "Bluetooth")
        }
    }
}

struct PaperGIFDeviceControlRow: View {
    let control: DeviceControl
    @ObservedObject var model: DeviceControlsModel
    let isReachable: Bool
    @State private var draft: Double?
    @State private var lastLiveSend = Date.distantPast
    @State private var isConfirming = false

    private static let liveUpdateInterval: TimeInterval = 0.2
    private static let maximumStepperPositions = 20.0

    private var value: DeviceControlValue? { model.values[control.id] }
    private var isPending: Bool { model.pendingIDs.contains(control.id) }

    var body: some View {
        if control.isReadOnly {
            LabeledContent(control.name, value: displayValue(value))
                .accessibilityLabel(control.name)
                .accessibilityValue(displayValue(value))
        } else {
            switch control.kind {
            case .toggle: toggle
            case .range: range
            case .select: picker
            case .action: action
            }
        }
    }

    private var toggle: some View {
        Toggle(control.name, isOn: Binding(
            get: { value?.boolValue ?? false },
            set: { model.set(control, to: .bool($0)) }
        ))
        .disabled(isPending || value?.boolValue == nil)
        .accessibilityHint(value == nil ? "Value unavailable" : "")
    }

    @ViewBuilder
    private var range: some View {
        let minimum = control.minimum ?? 0
        let maximum = max(control.maximum ?? 100, minimum)
        let current = draft ?? value?.numberValue
        let disabled = isPending && draft == nil || value?.numberValue == nil
        if let step = control.step, step > 0, (maximum - minimum) / step <= Self.maximumStepperPositions {
            Stepper(value: Binding(
                get: { current ?? minimum },
                set: { model.set(control, to: .number($0)) }
            ), in: minimum...maximum, step: step) {
                LabeledContent(control.name, value: displayValue(current.map(DeviceControlValue.number)))
            }
            .disabled(disabled)
            .accessibilityLabel(control.name)
            .accessibilityValue(displayValue(current.map(DeviceControlValue.number)))
        } else {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent(control.name, value: displayValue(current.map(DeviceControlValue.number)))
                slider(minimum: minimum, maximum: maximum, current: current)
            }
            .disabled(disabled)
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private func slider(minimum: Double, maximum: Double, current: Double?) -> some View {
        let binding = Binding<Double>(
            get: { current ?? minimum },
            set: { newValue in
                draft = newValue
                let now = Date()
                if now.timeIntervalSince(lastLiveSend) >= Self.liveUpdateInterval {
                    lastLiveSend = now
                    model.set(control, to: .number(newValue))
                }
            }
        )
        let onEditingChanged: (Bool) -> Void = { editing in
            guard !editing, let final = draft else { return }
            model.set(control, to: .number(final))
            draft = nil
            lastLiveSend = .distantPast
        }
        Group {
            if let step = control.step, step > 0 {
                Slider(value: binding, in: minimum...maximum, step: step, onEditingChanged: onEditingChanged)
            } else {
                Slider(value: binding, in: minimum...maximum, onEditingChanged: onEditingChanged)
            }
        }
        .accessibilityLabel(control.name)
        .accessibilityValue(displayValue(current.map(DeviceControlValue.number)))
    }

    private var picker: some View {
        Picker(control.name, selection: Binding<String?>(
            get: { value?.stringValue },
            set: { if let choice = $0 { model.set(control, to: .string(choice)) } }
        )) {
            if value?.stringValue == nil {
                Text("Unknown").tag(String?.none)
            }
            ForEach(control.options ?? [], id: \.value) { option in
                Text(option.name).tag(Optional(option.value))
            }
        }
        .disabled(isPending || value?.stringValue == nil)
    }

    private var action: some View {
        Button {
            if control.requiresConfirmation {
                isConfirming = true
            } else {
                model.set(control, to: nil)
            }
        } label: {
            HStack {
                Text(control.name)
                if isPending {
                    Spacer()
                    ProgressView()
                }
            }
        }
        .disabled(isPending || !isReachable)
        .accessibilityLabel(control.name)
        .accessibilityHint(control.requiresConfirmation ? "Asks for confirmation before running" : "Runs on the device")
        .confirmationDialog(
            "\(control.name)?",
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button(control.name, role: .destructive) { model.set(control, to: nil) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func displayValue(_ value: DeviceControlValue?) -> String {
        Self.format(value, for: control)
    }

    static func format(_ value: DeviceControlValue?, for control: DeviceControl) -> String {
        switch value {
        case .bool(let flag): return flag ? "On" : "Off"
        case .string(let choice):
            return control.options?.first(where: { $0.value == choice })?.name ?? choice
        case .number(let number):
            let fractional = (control.step ?? 1).truncatingRemainder(dividingBy: 1) != 0
            let text = number.formatted(.number.precision(.fractionLength(fractional ? 0...2 : 0...0)))
            guard let unit = control.unit, !unit.isEmpty else { return text }
            return unit == "%" ? "\(text)%" : "\(text) \(unit)"
        case nil: return "—"
        }
    }
}
