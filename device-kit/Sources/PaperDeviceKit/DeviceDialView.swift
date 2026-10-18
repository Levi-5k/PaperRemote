import SwiftUI

/// Live dial telemetry and soft limits, using the standard device-controls channel.
public struct DeviceDialView: View {
    @ObservedObject private var model: DeviceControlsModel
    @State private var draggedStart: Double?
    @State private var draggedSweep: Double?
    @State private var draggedTurns: Double?

    public init(model: DeviceControlsModel) { self.model = model }

    public static func isSupported(by controls: [DeviceControl]) -> Bool {
        Set(controls.map(\.id)).isSuperset(of: [
            "dialPresent", "dialPosition", "dialMode", "dialStart", "dialSweep",
            "dialTurns", "dialStep", "dialJitter", "dialZero"
        ])
    }

    /// Signed travel from `start` to a dragged end-stop angle. Positive is clockwise.
    /// The side follows the drag continuously, so dragging the end stop past the start
    /// flips the dial to counterclockwise; crossing the far side pins it at a full turn.
    public static func signedTravel(dragAngle: Double, start: Double, previous: Double) -> Double {
        var clockwise = (dragAngle - start).truncatingRemainder(dividingBy: 360)
        if clockwise < 0 { clockwise += 360 }
        let candidates = [clockwise, clockwise - 360]
        let nearest = candidates.min { abs($0 - previous) < abs($1 - previous) }!
        guard abs(nearest - previous) <= 180 else { return previous < 0 ? -360 : 360 }
        if abs(nearest) < 1 { return nearest < 0 || (nearest == 0 && previous < 0) ? -1 : 1 }
        return nearest
    }

    private func number(_ id: String, default fallback: Double = 0) -> Double {
        model.values[id]?.numberValue ?? fallback
    }
    private var mode: String { model.values["dialMode"]?.stringValue ?? "single" }
    private var start: Double { draggedStart ?? number("dialStart") }
    private var sweep: Double { draggedSweep ?? number("dialSweep", default: 360) }
    private var turns: Double { draggedTurns ?? number("dialTurns", default: 3) }
    private var counterclockwise: Bool { (mode == "single" ? sweep : turns) < 0 }
    private var direction: Double { counterclockwise ? -1 : 1 }
    private var position: Double { number("dialPosition") }
    private var span: Double { mode == "single" ? abs(sweep) : abs(turns) * 360 }
    private var available: Bool { model.values["dialPresent"]?.boolValue == true }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Live dial").font(.headline)
            if !available {
                Label("Dial sensor unavailable. Check power, magnet and I2C wiring.",
                      systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            GeometryReader { geometry in
                let size = min(geometry.size.width, geometry.size.height)
                let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                let radius = size * 0.38
                ZStack {
                    Circle().stroke(.secondary.opacity(0.25), lineWidth: 12)
                        .frame(width: radius * 2, height: radius * 2)
                        .position(center)
                    if mode == "single" {
                        Path { path in
                            path.addArc(center: center, radius: radius,
                                        startAngle: .degrees(start - 90),
                                        endAngle: .degrees(start + sweep - 90),
                                        clockwise: counterclockwise)
                        }
                        .stroke(.blue.opacity(0.5), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    }
                    Path { path in
                        path.move(to: center)
                        path.addLine(to: point(angle: number("dialAngle", default: start + direction * position),
                                               center: center, radius: radius - 12))
                    }
                    .stroke(available ? Color.primary : Color.secondary, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    Circle().fill(.primary).frame(width: 10, height: 10).position(center)
                    if mode == "single" {
                        stopHandle("Start", angle: start, center: center, radius: radius - 10, isStart: true)
                        stopHandle("End", angle: start + sweep, center: center, radius: radius + 10, isStart: false)
                    } else {
                        stopMarker("Start", angle: start, color: .green, center: center, radius: radius - 10)
                        if mode == "multi" {
                            stopMarker("End \(abs(turns).formatted(.number.precision(.fractionLength(0...1)))) rev",
                                       angle: start + turns * 360, color: .orange, center: center, radius: radius + 10)
                        }
                    }
                }
                .coordinateSpace(name: "dial")
            }
            .frame(height: 200)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Dial position")
            .accessibilityValue(available ? "\(position.formatted()) degrees, \(mode)" : "Sensor unavailable")
            HStack {
                Text(available ? "\(position.formatted(.number.precision(.fractionLength(2)))) deg" : "--")
                Spacer()
                Text("\((position / 360).formatted(.number.precision(.fractionLength(2)))) rev")
            }.monospacedDigit()
            if let angle = model.values["dialAngle"]?.numberValue {
                Text("Shaft angle: \(angle.formatted(.number.precision(.fractionLength(2)))) deg")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if let output = model.values["dialOutput"]?.numberValue {
                Text("Output travel: \(output.formatted(.number.precision(.fractionLength(2))))%")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if mode != "continuous" {
                ProgressView(value: min(span, max(0, position)), total: span)
                HStack {
                    Text("Start: 0 deg")
                    Spacer()
                    Text("End: \(span.formatted()) deg \(counterclockwise ? "counterclockwise" : "clockwise")")
                }.font(.caption).foregroundStyle(.secondary)
            }
            if let control = model.controls.first(where: { $0.id == "dialMode" }) {
                Picker("Rotation mode", selection: Binding(
                    get: { mode }, set: { model.set(control, to: .string($0)) }
                )) {
                    ForEach(control.options ?? [], id: \.value) { Text($0.name).tag($0.value) }
                }.disabled(model.values["dialMode"] == nil || model.pendingIDs.contains("dialMode"))
            }
            setting("dialStart")
            if mode == "single" { setting("dialSweep") }
            else {
                setting("dialTurns")
                if let control = model.controls.first(where: { $0.id == "dialTurns" }) {
                    Slider(value: Binding(
                        get: { draggedTurns ?? number("dialTurns", default: 3) },
                        set: { draggedTurns = $0 }
                    ), in: -100...100, step: 0.1) { editing in
                        if !editing, let draggedTurns {
                            let previous = number("dialTurns", default: 3)
                            let value = abs(draggedTurns) < 0.1 ? (previous < 0 ? -0.1 : 0.1) : draggedTurns
                            model.set(control, to: .number(value))
                            self.draggedTurns = nil
                        }
                    }
                    .accessibilityLabel(mode == "multi" ? "Multi-turn end stop in revolutions" : "Revolutions per output range")
                    Text("\(abs(turns).formatted(.number.precision(.fractionLength(1)))) rev \(counterclockwise ? "counterclockwise (left of 0)" : "clockwise (right of 0)")")
                        .font(.caption).foregroundStyle(.secondary)
                    .disabled(model.values["dialTurns"] == nil || model.pendingIDs.contains("dialTurns"))
                }
            }
            setting("dialStep")
            setting("dialJitter")
            if let control = model.controls.first(where: { $0.id == "dialLowLatency" }) {
                Toggle(control.name, isOn: Binding(
                    get: { model.values[control.id]?.boolValue ?? false },
                    set: { model.set(control, to: .bool($0)) }
                ))
                .disabled(model.values[control.id] == nil || model.pendingIDs.contains(control.id))
                if model.values[control.id]?.boolValue == true { setting("dialRate") }
            }
            if let control = model.controls.first(where: { $0.id == "dialZero" }) {
                Button(control.name) { model.set(control, to: nil) }
                    .disabled(!available || model.pendingIDs.contains(control.id))
            }
            Text("Soft stops limit output, not physical rotation. Drag the single-turn Start/End handles or enter exact values; drag End past Start (or enter a negative end stop) to make the dial count counterclockwise. Multi-turn starts at zero after reboot; use Set current position to start to re-zero. Continuous mode has no stops; revolutions set sensitivity. Output resolution is a percentage of the assigned range; the binding's Step sets its final output units. Low latency mode streams only changes to computers over Wi-Fi (UDP) and to the phone over Bluetooth, up to the set rate per second.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func setting(_ id: String) -> some View {
        if let control = model.controls.first(where: { $0.id == id }) {
            DialNumberField(control: control, model: model)
        }
    }

    private func point(angle: Double, center: CGPoint, radius: Double) -> CGPoint {
        let radians = (angle - 90) * .pi / 180
        return CGPoint(x: center.x + cos(radians) * radius, y: center.y + sin(radians) * radius)
    }

    private func stopMarker(_ name: String, angle: Double, color: Color, center: CGPoint, radius: Double) -> some View {
        VStack(spacing: 2) {
            Circle().fill(color).frame(width: 12, height: 12)
            Text(name).font(.caption2)
        }
        .position(point(angle: angle, center: center, radius: radius))
        .accessibilityHidden(true)
    }

    private func stopHandle(_ name: String, angle: Double, center: CGPoint, radius: Double, isStart: Bool) -> some View {
        VStack(spacing: 2) {
            Circle().fill(isStart ? Color.green : Color.orange).frame(width: 18, height: 18)
            Text(name).font(.caption2)
        }
        .position(point(angle: angle, center: center, radius: radius))
        .gesture(DragGesture(coordinateSpace: .named("dial")).onChanged { drag in
            var degrees = atan2(drag.location.x - center.x, center.y - drag.location.y) * 180 / .pi
            if degrees < 0 { degrees += 360 }
            if isStart { draggedStart = min(359.9, degrees) }
            else { draggedSweep = Self.signedTravel(dragAngle: degrees, start: start, previous: sweep) }
        }.onEnded { _ in
            let id = isStart ? "dialStart" : "dialSweep"
            let value = isStart ? draggedStart : draggedSweep
            if let value, let control = model.controls.first(where: { $0.id == id }) {
                model.set(control, to: .number(value))
            }
            draggedStart = nil
            draggedSweep = nil
        })
        .accessibilityLabel("\(name) soft stop; use the numeric field for exact adjustment")
    }
}

private struct DialNumberField: View {
    let control: DeviceControl
    @ObservedObject var model: DeviceControlsModel
    // Edit raw text: a number-formatted field reparses each keystroke, so "0." became
    // "0" mid-typing, and live dial refreshes re-applied the formatting.
    @State private var draft: String?
    @FocusState private var focused: Bool

    private var current: Double { model.values[control.id]?.numberValue ?? control.minimum ?? 0 }
    private var parsed: Double? {
        draft.flatMap { Double($0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) }
    }

    var body: some View {
        HStack {
            Text(control.name)
            Spacer()
            TextField(control.name, text: Binding(
                get: { draft ?? Self.format(current) },
                set: { draft = $0 }
            ))
            .focused($focused)
            #if os(iOS)
            .keyboardType(.numbersAndPunctuation)
            #endif
            .multilineTextAlignment(.trailing)
            .frame(width: 85)
            .onSubmit { commit() }
            if let unit = control.unit { Text(unit).foregroundStyle(.secondary) }
            Button("Apply") { commit() }.disabled(parsed == nil)
        }
        .disabled(model.values[control.id] == nil || model.pendingIDs.contains(control.id))
    }

    static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...6)).grouping(.never))
    }

    private func commit() {
        guard let value = parsed else { draft = nil; return }
        model.set(control, to: .number(value))
        draft = nil
        focused = false
    }
}
