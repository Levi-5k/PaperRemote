import PaperDeviceKit
import SwiftUI

struct PaperGIFPhysicalInputsSection: View {
    @Binding var profile: PaperGIFRemoteProfile
    let descriptor: DeviceDescriptor
    let layout: DeviceLayout
    @ObservedObject var wledDiscovery: PaperGIFWLEDDiscovery
    @ObservedObject var bluetoothManager: PaperGIFBluetoothManager
    @State private var selectedInputID: String?
    @StateObject private var liveControls = DeviceControlsModel()
    @State private var unwrappedAngle: Double?
    @State private var lastDialStreamAt = Date.distantPast

    private var dialInputID: String? {
        PaperGIFDialSettingsSection.isAvailable(for: descriptor) ? descriptor.inputs.first { $0.kind == "dial" }?.id : nil
    }
    private var liveAngles: [String: Double] {
        guard let dialInputID, let unwrappedAngle else { return [:] }
        return [dialInputID: unwrappedAngle]
    }
    private var routes: PaperGIFDeviceControlRoutes { bluetoothManager.deviceControlRoutes(for: descriptor) }

    var body: some View {
        Section("Physical Board") {
            if !descriptor.isM5Paper || !descriptor.inputs.isEmpty {
                DeviceBoardPreview(
                    layout: layout, inputs: descriptor.inputs,
                    selectedInputID: selectedInputID, inputAngles: liveAngles,
                    angleSmoothing: isStreamingDial ? 1.0 / 30 : 0.1,
                    onSelect: { selectedInputID = $0 }
                )
                // A fixed height avoids the Form row first laying the preview out at its tiny ideal size.
                .frame(maxWidth: .infinity)
                .frame(height: min(360, max(180, 320 * layout.height / max(layout.width, 1))))
            }
            if descriptor.display == nil {
                Text("Screenless controller — assign actions to the physical inputs below.")
                    .foregroundStyle(.secondary)
            }
            if !descriptor.inputs.isEmpty, !descriptor.capabilities.profileVersions.contains(7) {
                Text("This firmware reports physical inputs but cannot receive bindings. Profile version 7 is required.")
                    .foregroundStyle(.orange)
            }
            ForEach(descriptor.inputs) { input in
                NavigationLink {
                    PaperGIFPhysicalInputEditor(
                        profile: $profile, descriptor: descriptor, input: input,
                        wledDiscovery: wledDiscovery, bluetoothManager: bluetoothManager
                    )
                } label: {
                    LabeledContent(input.name, value: input.kind)
                }
                .disabled(!descriptor.capabilities.profileVersions.contains(7))
            }
            if let selectedInputID,
               let input = descriptor.inputs.first(where: { $0.id == selectedInputID }),
               descriptor.capabilities.profileVersions.contains(7) {
                NavigationLink("Configure \(input.name)") {
                    PaperGIFPhysicalInputEditor(
                        profile: $profile, descriptor: descriptor, input: input,
                        wledDiscovery: wledDiscovery, bluetoothManager: bluetoothManager
                    )
                }
            }
        }
        .task(id: dialInputID == nil ? nil : routes) {
            // Only the knob artwork moves here; dial settings live in the knob's own editor.
            guard dialInputID != nil else { return }
            let routes = routes
            liveControls.configure(controls: descriptor.controls,
                                   transports: bluetoothManager.deviceControlTransports(for: routes))
            guard !routes.isEmpty else { return }
            await liveControls.refresh()
            await liveControls.monitorDial()
        }
        .onChange(of: liveControls.values["dialAngle"]?.numberValue) { _, angle in
            // Snapshots lag the low-latency stream; use them only once it has stopped.
            guard !isStreamingDial else { return }
            follow(angle)
        }
        .onChange(of: bluetoothManager.liveDial) { _, dial in
            guard dialInputID != nil, routes.bluetooth, let dial else { return }
            lastDialStreamAt = Date()
            follow(dial.angle)
        }
        .onChange(of: bluetoothManager.pushedControlSnapshot) {
            guard dialInputID != nil, let pushed = bluetoothManager.pushedControlSnapshot, routes.bluetooth else { return }
            liveControls.receive(pushed.snapshot, via: "Bluetooth")
        }
    }
}

extension PaperGIFPhysicalInputsSection {
    private var isStreamingDial: Bool { Date().timeIntervalSince(lastDialStreamAt) < 1 }

    /// Takes the shortest way round so crossing 0° doesn't animate a full reverse turn.
    private func follow(_ angle: Double?) {
        guard let angle else { unwrappedAngle = nil; return }
        guard let previous = unwrappedAngle else { unwrappedAngle = angle; return }
        let delta = (angle - previous).truncatingRemainder(dividingBy: 360)
        unwrappedAngle = previous + (delta > 180 ? delta - 360 : delta < -180 ? delta + 360 : delta)
    }
}

private struct PaperGIFPhysicalInputEditor: View {
    @Binding var profile: PaperGIFRemoteProfile
    let descriptor: DeviceDescriptor
    let input: DeviceInput
    @ObservedObject var wledDiscovery: PaperGIFWLEDDiscovery
    @ObservedObject var bluetoothManager: PaperGIFBluetoothManager
    @State private var event = ""
    @State private var direction = "both"

    private var selectedEvent: String { event.isEmpty ? input.events.first ?? "" : event }
    private var bindingIndex: Int? {
        profile.hardwareBindings.firstIndex {
            $0.pageID == nil && $0.inputID == input.id && $0.event == selectedEvent &&
                $0.direction == (selectedEvent == "rotate" && direction != "both" ? direction : nil)
        }
    }

    var body: some View {
        Form {
            if input.kind == "dial", PaperGIFDialSettingsSection.isAvailable(for: descriptor) {
                PaperGIFDialSettingsSection(descriptor: descriptor, bluetoothManager: bluetoothManager)
            }
            Section("Input") {
                LabeledContent("Stable ID", value: input.id)
                LabeledContent("Kind", value: input.kind)
                Picker("Event", selection: Binding(get: { selectedEvent }, set: { event = $0 })) {
                    ForEach(input.events, id: \.self) { Text($0.capitalized).tag($0) }
                }
                if selectedEvent == "rotate" {
                    Picker("Rotation action direction", selection: $direction) {
                        Text("Both / signed adjustment").tag("both")
                        Text("Counterclockwise (negative)").tag("negative")
                        Text("Clockwise (positive)").tag("positive")
                    }
                }
            }
            if let index = bindingIndex {
                bindingFields(index)
            } else {
                Section {
                    Button("Assign Action to \(selectedEvent.capitalized)") {
                        var binding = PaperGIFHardwareBinding(
                            inputID: input.id, event: selectedEvent,
                            action: .init(type: .computerMedia, text: "playPause")
                        )
                        binding.direction = selectedEvent == "rotate" && direction != "both" ? direction : nil
                        profile.hardwareBindings.append(binding)
                    }
                }
            }
            Section {
                Text("Only device-reported events are assignable. Encoder rotation is signed; relative mode applies delta × step. Absolute mode normalizes the input range, rounds to step, then clamps to the configured bounds.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(input.name)
    }

    @ViewBuilder
    private func bindingFields(_ index: Int) -> some View {
        Section("Binding") {
            Picker("Mode", selection: $profile.hardwareBindings[index].mode) {
                Text("Action").tag("action")
                if input.kind == "encoder", selectedEvent == "rotate", direction == "both" {
                    Text("Relative adjustment").tag("relative")
                }
                if ["dial", "slider"].contains(input.kind), selectedEvent == "change" {
                    Text("Absolute adjustment").tag("absolute")
                }
            }
            NavigationLink("Configure \(profile.hardwareBindings[index].action.type.title)") {
                PaperGIFRemoteControlEditor(
                    control: actionProxy(index), pages: profile.pages, computers: profile.computers,
                    temperatureUnit: profile.temperatureUnit, gridColumns: 2, gridRows: 8,
                    wledDiscovery: wledDiscovery, hardwareOnly: true
                )
            }
            if profile.hardwareBindings[index].mode != "action" {
                LabeledContent("Minimum") {
                    TextField("Minimum", value: $profile.hardwareBindings[index].minimum, format: .number)
                        .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                }
                LabeledContent("Maximum") {
                    TextField("Maximum", value: $profile.hardwareBindings[index].maximum, format: .number)
                        .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                }
                LabeledContent("Step") {
                    TextField("Step", value: $profile.hardwareBindings[index].step, format: .number)
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                }
                Text("Adjustments support computer volume, WLED brightness, and NetHome temperature. Other combinations are rejected, never silently converted.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let error = validationError(index) { Text(error).foregroundStyle(.orange) }
            Button("Remove Binding", role: .destructive) {
                profile.hardwareBindings.remove(at: index)
            }
        }
    }

    private func actionProxy(_ index: Int) -> Binding<PaperGIFRemoteControl> {
        let id = profile.hardwareBindings[index].id
        return Binding(
            get: {
                let action = profile.hardwareBindings.first { $0.id == id }?.action ?? .playPause
                return .button(title: input.name, symbol: "", action: action)
            },
            set: { control in
                guard let current = profile.hardwareBindings.firstIndex(where: { $0.id == id }) else { return }
                profile.hardwareBindings[current].action = control.action
            }
        )
    }

    private func validationError(_ index: Int) -> String? {
        do {
            try profile.hardwareBindings[index].validate(for: descriptor)
            _ = try profile.negotiatedPayload(for: descriptor)
            return nil
        }
        catch { return error.localizedDescription }
    }
}

struct PaperGIFPageInputsSection: View {
    let page: PaperGIFRemotePage
    let descriptor: DeviceDescriptor
    @Binding var bindings: [PaperGIFHardwareBinding]

    var body: some View {
        Section("Page Inputs") {
            ForEach(descriptor.inputs) { input in
                ForEach(input.events, id: \.self) { event in
                    Picker("\(input.name) \(event.capitalized)", selection: target(input, event: event)) {
                        Text(bindings.contains { $0.pageID == nil && $0.inputID == input.id && $0.event == event }
                             ? "Default action" : "Unassigned").tag(UUID?.none)
                        ForEach(page.controls.filter { control in
                            event == "change" || event == "rotate" ? control.kind == .slider : control.kind == .button
                        }) { control in
                            Text(control.title).tag(Optional(control.id))
                        }
                    }
                }
            }
        }
    }

    private func target(_ input: DeviceInput, event: String) -> Binding<UUID?> {
        Binding(
            get: { bindings.first { $0.pageID == page.id && $0.inputID == input.id && $0.event == event }?.controlID },
            set: { controlID in
                bindings.removeAll { $0.pageID == page.id && $0.inputID == input.id && $0.event == event }
                guard let control = page.controls.first(where: { $0.id == controlID }) else { return }
                bindings.append(Self.tileBinding(pageID: page.id, control: control, input: input, event: event))
            }
        )
    }

    static func tileBinding(pageID: UUID, control: PaperGIFRemoteControl,
                            input: DeviceInput, event: String) -> PaperGIFHardwareBinding {
        let adjusting = event == "change" || event == "rotate"
        return PaperGIFHardwareBinding(
            inputID: input.id, event: event, pageID: pageID, controlID: control.id,
            mode: adjusting ? (event == "rotate" ? "relative" : "absolute") : "action",
            action: control.action,
            minimum: control.action.type == .netHomeTemperature ? 16 : 0,
            maximum: control.action.type == .netHomeTemperature ? 30 : control.action.type == .wledBrightness ? 255 : 100,
            step: control.action.type == .netHomeTemperature ? 0.5 : 1
        )
    }
}

enum PaperGIFAdaptiveGridGeometry {
    static func cellSize(in size: CGSize, columns: Int, rows: Int) -> CGSize {
        CGSize(width: size.width * 0.92 / Double(max(1, columns)),
               height: size.height * 0.92 / Double(max(1, rows)))
    }

    static func frame(_ placement: PaperGIFRemoteGridPlacement, in size: CGSize,
                      columns: Int, rows: Int) -> CGRect {
        let cell = cellSize(in: size, columns: columns, rows: rows)
        return CGRect(
            x: size.width * 0.04 + Double(placement.slot % max(1, columns)) * cell.width,
            y: size.height * 0.04 + Double(placement.slot / max(1, columns)) * cell.height,
            width: max(1, cell.width * Double(placement.span.width) - 2),
            height: max(1, cell.height * Double(placement.span.height) - 2)
        )
    }
}

struct PaperGIFAdaptivePagePreview: View {
    @Binding var page: PaperGIFRemotePage
    let display: DeviceDisplay
    let onEdit: (UUID) -> Void

    private var isQuarterTurn: Bool { display.rotation == 90 || display.rotation == 270 }
    private var width: Double { Double(isQuarterTurn ? display.height : display.width) }
    private var height: Double { Double(isQuarterTurn ? display.width : display.height) }

    var body: some View {
        GeometryReader { geometry in
            let columns = max(1, page.gridColumns)
            let rows = max(1, page.gridRows)
            let placements = PaperGIFRemoteGrid.placements(for: page.controls, columns: columns, rows: rows)
            let headerHeight = geometry.size.height * 28 / height
            let contentSize = CGSize(width: geometry.size.width, height: geometry.size.height - headerHeight)
            let cell = PaperGIFAdaptiveGridGeometry.cellSize(in: contentSize, columns: columns, rows: rows)
            let cellWidth = cell.width
            let cellHeight = cell.height
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.black)
                Text(page.name)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .frame(width: geometry.size.width, height: headerHeight)
                ForEach(Array(page.controls.enumerated()), id: \.element.id) { index, control in
                    if let placement = placements[index] {
                        let frame = PaperGIFAdaptiveGridGeometry.frame(
                            placement, in: contentSize, columns: columns, rows: rows
                        )
                        Button { onEdit(control.id) } label: {
                            VStack(spacing: 4) {
                                if control.kind == .textBox {
                                    Text(control.textBox?.sourceText ?? control.title)
                                        .font(.caption).lineLimit(4).minimumScaleFactor(0.4)
                                } else {
                                    RemoteIconGlyphView(name: control.symbol.isEmpty ? "square" : control.symbol)
                                        .frame(width: min(24, frame.width * 0.25), height: min(24, frame.height * 0.25))
                                    Text(control.title).font(.caption.weight(.medium))
                                        .lineLimit(2).minimumScaleFactor(0.4)
                                    if control.kind == .slider {
                                        GeometryReader { track in
                                            ZStack(alignment: .leading) {
                                                Capsule().fill(Color.white.opacity(0.2))
                                                Capsule().fill(Color.white)
                                                    .frame(width: track.size.width * sliderFraction(control))
                                            }
                                        }
                                        .frame(height: 4)
                                        .padding(.horizontal, 8)
                                    }
                                }
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(white: 0.094))
                            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color(white: 0.467), lineWidth: 1) }
                        }
                        .buttonStyle(.plain)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY + headerHeight)
                        .accessibilityLabel("Edit \(control.title)")
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 16).onEnded { drag in
                                let columnOffset = Int((drag.translation.width / cellWidth).rounded())
                                let rowOffset = Int((drag.translation.height / cellHeight).rounded())
                                guard let slot = PaperGIFRemoteGrid.translatedSlot(
                                    from: placement.slot, columnOffset: columnOffset,
                                    rowOffset: rowOffset, columns: columns, rows: rows
                                ), let slots = PaperGIFRemoteGrid.rearranged(
                                    page.controls, moving: index, to: slot, columns: columns, rows: rows
                                ) else { return }
                                for index in page.controls.indices { page.controls[index].layoutSlot = slots[index] }
                            }
                        )
                    }
                }
            }
            .border(Color.secondary)
        }
        .aspectRatio(width / height, contentMode: .fit)
        .accessibilityLabel("\(display.width) by \(display.height) display preview")
    }

    private func sliderFraction(_ control: PaperGIFRemoteControl) -> Double {
        let value = Double(control.action.value)
        switch control.action.type {
        case .netHomeTemperature: return min(1, max(0, (value - 16) / 14))
        case .netHomeFan: return min(1, max(0, value / 100))
        default: return min(1, max(0, value / 255))
        }
    }
}
