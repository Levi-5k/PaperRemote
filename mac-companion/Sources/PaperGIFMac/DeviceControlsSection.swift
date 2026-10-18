import PaperDeviceKit
import SwiftUI

/// Control surface generated from the controls a device declares in its descriptor.
struct DeviceControlsSection: View {
    let descriptor: DeviceDescriptor
    let address: String
    let token: String
    @ObservedObject var relay: DeviceBluetoothRelay
    @StateObject private var model = DeviceControlsModel()
    @State private var confirming: DeviceControl?

    private var configurationKey: String {
        "\(descriptor.deviceID)|\(address)|\(relay.controlTransport != nil)|\(relay.lanReachable)"
            + "|\(descriptor.controls.map(\.id).joined(separator: ","))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Device controls").font(.headline)
                Spacer()
                if model.isLoading {
                    ProgressView().controlSize(.small)
                } else if let transport = model.activeTransport {
                    Label(transport, systemImage: transport == "Bluetooth" ? "dot.radiowaves.left.and.right" : "wifi")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("Controls are reaching the device over \(transport)")
                }
                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Read current values from the device")
                .accessibilityLabel("Refresh device controls")
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if DeviceDialView.isSupported(by: descriptor.controls) {
                DeviceDialView(model: model)
            }
            ForEach(model.groups.filter { !DeviceDialView.isSupported(by: descriptor.controls) || $0.name != "Dial" }, id: \.name) { group in
                Text(group.name).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(group.controls) { control in
                    row(for: control)
                        .disabled(model.pendingIDs.contains(control.id))
                }
            }
        }
        .task(id: configurationKey) {
            configure()
            await model.refresh()
            await model.monitorDial()
        }
        .confirmationDialog(
            confirming.map { "Run “\($0.name)” on \(descriptor.name)?" } ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
        ) {
            if let control = confirming {
                Button(control.name, role: .destructive) { model.set(control, to: nil) }
            }
        }
    }

    private func configure() {
        var transports: [any DeviceControlTransport] = []
        let http = address.isEmpty ? nil : HTTPDeviceControlTransport(address: address, token: token)
        let bluetooth = relay.controlTransport
        // Over a lost LAN each HTTP attempt would wait for its timeout before falling back.
        if relay.lanReachable {
            if let http { transports.append(http) }
            if let bluetooth { transports.append(bluetooth) }
        } else {
            if let bluetooth { transports.append(bluetooth) }
            if let http { transports.append(http) }
        }
        model.configure(controls: descriptor.controls, transports: transports)
        relay.channel.onSnapshot = { [weak model] snapshot in
            model?.receive(snapshot, via: "Bluetooth")
        }
    }

    @ViewBuilder private func row(for control: DeviceControl) -> some View {
        let value = model.values[control.id]
        if control.isReadOnly {
            LabeledContent(control.name) {
                Text(Self.format(value, control: control)).monospacedDigit().textSelection(.enabled)
            }
        } else {
            switch control.kind {
            case .toggle:
                Toggle(control.name, isOn: Binding(
                    get: { value?.boolValue ?? false },
                    set: { model.set(control, to: .bool($0)) }
                ))
            case .range:
                DeviceRangeRow(control: control, value: value?.numberValue) { model.set(control, to: .number($0)) }
            case .select:
                Picker(control.name, selection: Binding(
                    get: { value?.stringValue ?? "" },
                    set: { model.set(control, to: .string($0)) }
                )) {
                    if value == nil { Text("Unknown").tag("") }
                    ForEach(control.options ?? [], id: \.value) { Text($0.name).tag($0.value) }
                }
            case .action:
                Button(control.name) {
                    if control.requiresConfirmation { confirming = control } else { model.set(control, to: nil) }
                }
            }
        }
    }

    static func format(_ value: DeviceControlValue?, control: DeviceControl) -> String {
        let text: String
        switch value {
        case .bool(let flag): text = flag ? "On" : "Off"
        case .number(let number):
            text = number.rounded() == number ? String(Int64(number)) : String(format: "%.2f", number)
        case .string(let string):
            text = control.options?.first(where: { $0.value == string })?.name ?? string
        case nil: return "—"
        }
        guard let unit = control.unit, !unit.isEmpty, value?.numberValue != nil else { return text }
        return "\(text) \(unit)"
    }
}

private struct DeviceRangeRow: View {
    let control: DeviceControl
    let value: Double?
    let send: (Double) -> Void
    @State private var draft: Double?

    var body: some View {
        let minimum = control.minimum ?? 0
        let maximum = max(control.maximum ?? 1, minimum)
        let current = draft ?? value ?? minimum
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(control.name)
                Spacer()
                Text(DeviceControlsSection.format(value == nil && draft == nil ? nil : .number(current), control: control))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(get: { current }, set: { draft = $0 }),
                in: minimum...maximum,
                step: control.step ?? 1
            ) { editing in
                guard !editing, let draft else { return }
                send(draft)
                self.draft = nil
            }
            .accessibilityLabel(control.name)
            .accessibilityValue(DeviceControlsSection.format(.number(current), control: control))
        }
    }
}

struct BluetoothRelayStatus: View {
    @ObservedObject var relay: DeviceBluetoothRelay

    var body: some View {
        switch relay.state {
        case .idle:
            EmptyView()
        case .searching:
            Label("Wi-Fi unreachable — looking for the device over Bluetooth", systemImage: "dot.radiowaves.left.and.right")
                .font(.caption).foregroundStyle(.orange)
        case .connected(let name):
            Label("Wi-Fi unreachable — actions and controls use Bluetooth via \(name)", systemImage: "dot.radiowaves.left.and.right")
                .font(.caption).foregroundStyle(.secondary)
        case .unavailable(let reason):
            Label("Wi-Fi unreachable — \(reason)", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.red)
        }
    }
}
