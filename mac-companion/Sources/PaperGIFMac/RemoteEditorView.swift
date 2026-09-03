import AppKit
import SwiftUI

@MainActor
final class RemoteEditorWindowController: NSWindowController {
    private let store: RemoteEditorStore

    init(store: RemoteEditorStore) {
        self.store = store
        let content = RemoteEditorView(store: store)
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = "paperGIF Controls"
        window.setContentSize(NSSize(width: 1_180, height: 780))
        window.minSize = NSSize(width: 980, height: 680)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.tabbingMode = .disallowed
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func loadFromDevice() {
        Task { await store.loadFromDevice() }
    }
}

private struct RemoteEditorView: View {
    @ObservedObject var store: RemoteEditorStore
    @StateObject private var discovery = WLEDDiscovery()
    @StateObject private var computerDiscovery = ComputerDiscovery()
    @StateObject private var deviceDiscovery = DeviceDiscovery()
    @State private var inspectorTab = InspectorTab.catalog

    private enum InspectorTab: String, CaseIterable, Identifiable {
        case catalog = "Add Controls"
        case control = "Control"
        case connections = "Connections"

        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            sendBar
            Divider()
            HSplitView {
                pageSidebar
                    .frame(minWidth: 170, idealWidth: 190, maxWidth: 220)
                previewPanel
                    .frame(minWidth: 380, idealWidth: 500, maxWidth: .infinity)
                inspector
                    .frame(minWidth: 320, idealWidth: 360, maxWidth: 420)
            }
        }
        .frame(minWidth: 980, minHeight: 680)
        .onAppear {
            discovery.start()
            computerDiscovery.start()
            deviceDiscovery.start()
        }
        .onDisappear {
            discovery.stop()
            computerDiscovery.stop()
            deviceDiscovery.stop()
            store.saveImmediately()
        }
        .onChange(of: deviceDiscovery.devices) { devices in
            guard let device = devices.first else { return }
            store.deviceAddress = device.address
            Task { await store.loadFromDevice() }
        }
        .onChange(of: store.selectedPageID) { _ in
            store.selectedControlID = nil
            if inspectorTab == .control { inspectorTab = .catalog }
        }
    }

    private var sendBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.grid.2x2")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color(red: 0.08, green: 0.35, blue: 0.42))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text("paperGIF Controls")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text("Design and install your M5Paper remote")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            sendStatus
            TextField("M5Paper address", text: $store.deviceAddress)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .help("Connect to the paperGIF Wi-Fi, then use 192.168.4.1")
            Button {
                Task { await store.loadFromDevice() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Reload layouts and settings from M5Paper")
            .disabled(store.sendState == .loading || store.sendState == .sending)
            Button {
                Task { await store.send() }
            } label: {
                Label("Send to M5Paper", systemImage: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.validationMessage != nil || store.sendState == .sending || store.sendState == .loading)
        }
        .padding(.horizontal, 16)
        .frame(height: 58)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private var sendStatus: some View {
        switch store.sendState {
        case .idle:
            if let message = store.validationMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
        case .loading:
            ProgressView().controlSize(.small)
            Text("Loading from M5Paper...").font(.caption)
        case .sending:
            ProgressView().controlSize(.small)
            Text("Installing...").font(.caption)
        case .succeeded(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
                .lineLimit(2)
                .frame(maxWidth: 250, alignment: .trailing)
        }
    }

    private var pageSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("PAGES")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(store.profile.pages.count) / 8")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            List(selection: $store.selectedPageID) {
                ForEach(Array(store.profile.pages.enumerated()), id: \.element.id) { index, page in
                    HStack(spacing: 8) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(page.name).lineLimit(1)
                            Text("\(page.controls.count) control\(page.controls.count == 1 ? "" : "s")")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(page.id)
                    .contextMenu {
                        Button("Delete Page", role: .destructive) {
                            store.selectedPageID = page.id
                            store.deleteSelectedPage()
                        }
                        .disabled(store.profile.pages.count == 1)
                    }
                }
                .onMove(perform: store.movePages)
            }
            HStack(spacing: 6) {
                Button { store.addPage() } label: { Image(systemName: "plus") }
                    .help("Add page")
                    .disabled(store.profile.pages.count >= 8)
                Button { store.deleteSelectedPage() } label: { Image(systemName: "trash") }
                    .help("Delete selected page")
                    .disabled(store.profile.pages.count <= 1 || store.selectedPageIndex == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(10)
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                Text("DISPLAY")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Stepper(
                    "Start after \(store.profile.screensaverDelaySeconds) seconds",
                    value: $store.profile.screensaverDelaySeconds,
                    in: 10...3_600,
                    step: 10
                )
            }
            .font(.caption)
            .padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var previewPanel: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    if let pageNameBinding {
                        TextField("Page name", text: pageNameBinding)
                            .textFieldStyle(.plain)
                            .font(.headline)
                    }
                    Text("Click to edit. Drag controls to arrange them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let count = selectedPage?.controls.count {
                    Text("\(count) / 16")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)

            if let page = selectedPage {
                DevicePreview(
                    page: page,
                    pageIndex: store.selectedPageIndex ?? 0,
                    pageCount: store.profile.pages.count,
                    selectedControlID: store.selectedControlID,
                    onSelect: { id in
                        store.selectedControlID = id
                        inspectorTab = .control
                    },
                    onMove: store.moveControl
                )
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
            } else {
                Spacer()
                Text("Select a page")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            Picker("", selection: $inspectorTab) {
                ForEach(InspectorTab.allCases) { tab in Text(tab.rawValue).tag(tab) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
            Divider()
            if inspectorTab == .connections {
                ConnectionsPanel(store: store, computers: computerDiscovery, wled: discovery)
            } else if inspectorTab == .control, let binding = selectedControlBinding {
                ControlInspector(
                    control: binding,
                    pages: store.profile.pages,
                    computers: store.profile.computers,
                    discovery: discovery,
                    canUseButtonLayout: store.canChangeSelectedControl(to: .button),
                    canUseTextBoxLayout: store.canChangeSelectedControl(to: .textBox),
                    canMoveEarlier: (store.selectedControlLocation?.control ?? 0) > 0,
                    canMoveLater: store.selectedControlLocation.map {
                        $0.control < store.profile.pages[$0.page].controls.count - 1
                    } ?? false,
                    onMoveEarlier: { store.moveSelectedControl(by: -1) },
                    onMoveLater: { store.moveSelectedControl(by: 1) },
                    onDuplicate: store.duplicateSelectedControl,
                    onDelete: store.deleteSelectedControl
                )
            } else {
                ControlCatalogPanel(store: store)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var selectedPage: RemotePage? {
        guard let index = store.selectedPageIndex else { return nil }
        return store.profile.pages[index]
    }

    private var selectedControlBinding: Binding<RemoteControl>? {
        guard let location = store.selectedControlLocation else { return nil }
        return Binding(
            get: { store.profile.pages[location.page].controls[location.control] },
            set: { store.profile.pages[location.page].controls[location.control] = $0 }
        )
    }

    private var pageNameBinding: Binding<String>? {
        guard let index = store.selectedPageIndex else { return nil }
        return Binding(
            get: { store.profile.pages[index].name },
            set: { store.profile.pages[index].name = $0 }
        )
    }
}

private struct ControlCatalogPanel: View {
    @ObservedObject var store: RemoteEditorStore
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search controls", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(12)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(RemoteControlTemplate.categories, id: \.self) { category in
                        let templates = RemoteControlTemplate.all.filter {
                            $0.category == category && $0.matches(search)
                        }
                        if !templates.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(category.uppercased())
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 12)
                                ForEach(templates) { template in
                                    Button {
                                        store.addControl(template.control)
                                    } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: template.symbol)
                                                .frame(width: 24)
                                                .foregroundStyle(Color(red: 0.08, green: 0.35, blue: 0.42))
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(template.title).foregroundStyle(.primary)
                                                Text(template.detail)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            Image(systemName: "plus.circle")
                                                .foregroundStyle(.secondary)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 5)
                                    .disabled(!store.canAddControl(ofKind: template.kind))
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

private struct ControlInspector: View {
    @Binding var control: RemoteControl
    let pages: [RemotePage]
    let computers: [RemoteComputer]
    @ObservedObject var discovery: WLEDDiscovery
    let canUseButtonLayout: Bool
    let canUseTextBoxLayout: Bool
    let canMoveEarlier: Bool
    let canMoveLater: Bool
    let onMoveEarlier: () -> Void
    let onMoveLater: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    private let mediaCommands = [
        ("playPause", "Play / Pause"), ("previous", "Previous"), ("next", "Next"),
        ("volumeDown", "Volume Down"), ("volume", "Volume"),
        ("mute", "Mute"), ("volumeUp", "Volume Up"),
    ]
    private let keyOptions = [
        "return", "tab", "space", "delete", "forwardDelete", "escape",
        "left", "right", "up", "down", "home", "end", "pageUp", "pageDown",
    ] + (1...20).map { "f\($0)" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section("APPEARANCE") {
                    LabeledContent("Label") { TextField("Control", text: $control.title) }
                    if control.kind != .textBox {
                        LabeledContent("Icon") {
                            Picker("", selection: symbolBinding) {
                                ForEach(RemoteIcon.all) { icon in
                                    Label(icon.title, systemImage: icon.id).tag(icon.id)
                                }
                            }
                            .labelsHidden()
                        }
                        LabeledContent("Color hex") {
                            TextField("202020", text: $control.tintHex)
                                .frame(width: 90)
                        }
                    }
                    LabeledContent("Control") {
                        Picker("", selection: kindBinding) {
                            Text("Button").tag(RemoteControlKind.button)
                                .disabled(!canUseButtonLayout && control.kind != .button)
                            Text("Slider").tag(RemoteControlKind.slider)
                            Text("Text Box").tag(RemoteControlKind.textBox)
                                .disabled(!canUseTextBoxLayout && control.kind != .textBox)
                        }
                        .labelsHidden()
                    }
                    if control.kind == .button {
                        LabeledContent("Height") {
                            Picker("", selection: buttonHeightBinding) {
                                Text("1 Row").tag(1)
                                Text("2 Rows").tag(2)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                    }
                    Toggle("Toggle button", isOn: toggleButtonBinding)
                        .disabled(control.kind != .button)
                }

                if control.kind == .textBox {
                    textBoxSections
                }

                if control.kind != .textBox || control.textBox?.tapBehavior == .action {
                    section(control.kind == .textBox ? "TAP ACTION" : "ACTION") {
                    LabeledContent("Type") {
                        Picker("", selection: actionTypeBinding) {
                            ForEach(RemoteActionType.allCases) { type in
                                Label(type.title, systemImage: type.systemImage).tag(type)
                            }
                        }
                        .labelsHidden()
                    }
                    actionFields
                    }
                }

                HStack {
                    Button(action: onMoveEarlier) { Image(systemName: "arrow.up") }
                        .help("Move control earlier")
                        .disabled(!canMoveEarlier)
                    Button(action: onMoveLater) { Image(systemName: "arrow.down") }
                        .help("Move control later")
                        .disabled(!canMoveLater)
                    Button(action: onDuplicate) { Label("Duplicate", systemImage: "plus.square.on.square") }
                    Spacer()
                    Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
                }
            }
            .padding(14)
        }
        .onAppear { prepareWLEDSelection() }
        .onChange(of: discovery.devices) { _ in prepareWLEDSelection() }
    }

    @ViewBuilder private var textBoxSections: some View {
        section("TEXT") {
            LabeledContent("Source") {
                Picker("", selection: textBoxBinding(\.source)) {
                    Text("Static text").tag(RemoteTextSource.staticText)
                    Text("Date and time").tag(RemoteTextSource.dateTime)
                    Text("Mac script output").tag(RemoteTextSource.macScript)
                    Text("Shortcut output").tag(RemoteTextSource.macShortcut)
                    Text("Control value").tag(RemoteTextSource.controlValue)
                    Text("Mac now playing").tag(RemoteTextSource.nowPlaying)
                }
                .labelsHidden()
            }

            switch control.textBox?.source ?? .staticText {
            case .staticText:
                TextEditor(text: textBoxBinding(\.sourceText))
                    .frame(minHeight: 70)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            case .dateTime:
                LabeledContent("Format") { TextField("%b %e, %H:%M", text: textBoxBinding(\.dateFormat)) }
            case .macScript:
                textSourceComputerPicker
                TextEditor(text: textBoxBinding(\.sourceText))
                    .font(.body.monospaced())
                    .frame(minHeight: 70)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                Text("The command must exactly match an approved script in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .macShortcut:
                textSourceComputerPicker
                LabeledContent("Shortcut") { TextField("Shortcut name", text: textBoxBinding(\.sourceText)) }
            case .controlValue:
                LabeledContent("Control") {
                    Picker("", selection: referencedControlBinding) {
                        Text("Choose control").tag("")
                        ForEach(referenceableControls) { candidate in
                            Text(candidate.title).tag(candidate.id.uuidString)
                        }
                    }
                    .labelsHidden()
                }
            case .nowPlaying:
                textSourceComputerPicker
            }

            if control.textBox?.source != .staticText {
                LabeledContent("Unavailable") {
                    TextField("Unavailable", text: textBoxBinding(\.placeholder))
                }
            }
        }

        section("TEXT LAYOUT") {
            Stepper(value: textBoxBinding(\.gridWidth), in: 1...2) {
                Text("Width: \(control.textBox?.gridWidth ?? 2) column(s)")
            }
            Stepper(value: textBoxBinding(\.gridHeight), in: 1...8) {
                Text("Height: \(control.textBox?.gridHeight ?? 1) row(s)")
            }
            LabeledContent("Text size") {
                Picker("", selection: textBoxBinding(\.textSize)) {
                    Text("Small").tag(RemoteTextSize.small)
                    Text("Medium").tag(RemoteTextSize.medium)
                    Text("Large").tag(RemoteTextSize.large)
                    Text("Extra Large").tag(RemoteTextSize.extraLarge)
                    Text("Auto Fit").tag(RemoteTextSize.autoFit)
                }
                .labelsHidden()
            }
            LabeledContent("Horizontal") {
                Picker("", selection: textBoxBinding(\.horizontalAlignment)) {
                    Text("Leading").tag(RemoteTextHorizontalAlignment.leading)
                    Text("Center").tag(RemoteTextHorizontalAlignment.center)
                    Text("Trailing").tag(RemoteTextHorizontalAlignment.trailing)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            LabeledContent("Vertical") {
                Picker("", selection: textBoxBinding(\.verticalAlignment)) {
                    Text("Top").tag(RemoteTextVerticalAlignment.top)
                    Text("Center").tag(RemoteTextVerticalAlignment.center)
                    Text("Bottom").tag(RemoteTextVerticalAlignment.bottom)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }

        section("UPDATES") {
            if control.textBox?.source == .nowPlaying {
                LabeledContent("Automatic refresh", value: "When song changes")
            } else {
                Toggle("Automatic refresh", isOn: automaticRefreshBinding)
                    .disabled(!supportsAutomaticRefresh)
                if control.textBox?.refreshIntervalSeconds != nil && supportsAutomaticRefresh {
                    Stepper(value: refreshIntervalBinding, in: 5...3600, step: 5) {
                        Text("Every \(control.textBox?.refreshIntervalSeconds ?? 5) seconds")
                    }
                }
            }
            LabeledContent("When tapped") {
                Picker("", selection: textBoxBinding(\.tapBehavior)) {
                    Text("Do nothing").tag(RemoteTextTapBehavior.displayOnly)
                    Text("Refresh").tag(RemoteTextTapBehavior.refresh)
                    Text("Run action").tag(RemoteTextTapBehavior.action)
                }
                .labelsHidden()
            }
        }
    }

    @ViewBuilder private var textSourceComputerPicker: some View {
        LabeledContent("Computer") {
            Picker("", selection: textSourceComputerBinding) {
                Text("Default Mac").tag("")
                ForEach(computers) { computer in Text(computer.name).tag(computer.id.uuidString) }
            }
            .labelsHidden()
        }
    }

    @ViewBuilder private var actionFields: some View {
        if isMacAction {
            LabeledContent("Computer") {
                Picker("", selection: computerBinding) {
                    Text("Default Mac").tag("")
                    ForEach(computers) { computer in Text(computer.name).tag(computer.id.uuidString) }
                }
                .labelsHidden()
            }
        }

        switch control.action.type {
        case .macMedia:
            LabeledContent("Command") {
                Picker("", selection: $control.action.text) {
                    ForEach(mediaCommands, id: \.0) { command in Text(command.1).tag(command.0) }
                }
                .labelsHidden()
            }
            if control.action.text == "volume" {
                LabeledContent("Level") {
                    HStack {
                        Slider(value: volumePercentageBinding, in: 0...100, step: 1)
                        Text("\(volumePercentage)%").monospacedDigit().frame(width: 38)
                    }
                }
            }
        case .macKey:
            LabeledContent("Key") {
                ComboBoxField(value: $control.action.text, suggestions: keyOptions)
            }
            Text("Modifiers").font(.caption).foregroundStyle(.secondary)
            HStack {
                ForEach([("command", "Command"), ("option", "Option"), ("control", "Control"), ("shift", "Shift")], id: \.0) { modifier in
                    Toggle(modifier.1, isOn: modifierBinding(modifier.0))
                }
            }
            .toggleStyle(.checkbox)
        case .macOpen:
            LabeledContent("Target") { TextField("URL, app bundle ID, or path", text: openTargetBinding) }
        case .macShortcut:
            LabeledContent("Name") { TextField("Shortcut name", text: $control.action.text) }
        case .macScript:
            Text("Command").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $control.action.text)
                .font(.body.monospaced())
                .frame(minHeight: 70)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            Text("The command must exactly match a line allowed in the menu bar app's Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .wledPower:
            wledDeviceFields
            LabeledContent("Power") {
                Picker("", selection: $control.action.text) {
                    Text("Toggle").tag("toggle")
                    Text("On").tag("on")
                    Text("Off").tag("off")
                }
                .labelsHidden()
            }
        case .wledPreset:
            wledDeviceFields
            presetField
        case .wledBrightness:
            wledDeviceFields
            LabeledContent("Level") {
                HStack {
                    Slider(value: actionValueBinding, in: 0...255, step: 1)
                    Text("\(control.action.value)").monospacedDigit().frame(width: 28)
                }
            }
        case .page:
            LabeledContent("Page") {
                Picker("", selection: $control.action.text) {
                    Text("Choose a page").tag("")
                    ForEach(pages) { page in Text(page.name).tag(page.id.uuidString) }
                }
                .labelsHidden()
            }
        }
    }

    @ViewBuilder private var wledDeviceFields: some View {
        if !discovery.devices.isEmpty {
            LabeledContent("Device") {
                Picker("", selection: $control.action.host) {
                    Text("Manual address").tag("")
                    ForEach(discovery.devices) { device in Text(device.name).tag(device.actionHost) }
                }
                .labelsHidden()
                .onChange(of: control.action.host) { host in
                    guard let device = discovery.devices.first(where: { $0.actionHost == host }) else { return }
                    Task { await discovery.loadPresets(for: device) }
                }
            }
        }
        LabeledContent("Address") { TextField("wled.local or IP", text: $control.action.host) }
        HStack {
            Button { discovery.start() } label: {
                Label(discovery.isSearching ? "Searching..." : "Find WLED", systemImage: "dot.radiowaves.left.and.right")
            }
            if discovery.isSearching { ProgressView().controlSize(.small) }
        }
    }

    @ViewBuilder private var presetField: some View {
        let presets = discovery.presets(for: control.action.host)
        if presets.isEmpty {
            LabeledContent("Preset") {
                Stepper(value: $control.action.value, in: 1...250) {
                    Text("\(control.action.value)").monospacedDigit()
                }
            }
        } else {
            LabeledContent("Preset") {
                Picker("", selection: presetBinding(presets)) {
                    ForEach(presets) { preset in Text(preset.name).tag(preset.id) }
                }
                .labelsHidden()
            }
        }
    }

    private var isMacAction: Bool {
        [.macMedia, .macKey, .macOpen, .macShortcut, .macScript].contains(control.action.type)
    }

    private var isWLEDAction: Bool {
        [.wledPower, .wledPreset, .wledBrightness].contains(control.action.type)
    }

    private var selectedWLEDDevice: WLEDDiscovery.Device? {
        let selectedHost = normalizedWLEDHost(control.action.host)
        return discovery.devices.first {
            selectedHost == normalizedWLEDHost($0.actionHost) ||
                selectedHost == normalizedWLEDHost("\($0.serviceName).local")
        }
    }

    private func prepareWLEDSelection() {
        guard isWLEDAction else { return }
        if control.action.host.isEmpty, discovery.devices.count == 1, let device = discovery.devices.first {
            control.action.host = device.actionHost
        } else if let selectedWLEDDevice, control.action.host != selectedWLEDDevice.actionHost {
            control.action.host = selectedWLEDDevice.actionHost
        }
        guard control.action.type == .wledPreset, let selectedWLEDDevice else { return }
        Task { await discovery.loadPresets(for: selectedWLEDDevice) }
    }

    private func normalizedWLEDHost(_ host: String) -> String {
        var normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("http://") { normalized.removeFirst("http://".count) }
        if normalized.hasPrefix("https://") { normalized.removeFirst("https://".count) }
        while normalized.hasSuffix("/") { normalized.removeLast() }
        return normalized
    }

    private var computerBinding: Binding<String> {
        Binding(
            get: { control.action.computerID ?? "" },
            set: { control.action.computerID = $0.isEmpty ? nil : $0 }
        )
    }

    private func textBoxBinding<Value>(_ keyPath: WritableKeyPath<RemoteTextBox, Value>) -> Binding<Value> {
        Binding(
            get: { (control.textBox ?? RemoteTextBox())[keyPath: keyPath] },
            set: { value in
                var textBox = control.textBox ?? RemoteTextBox()
                textBox[keyPath: keyPath] = value
                control.textBox = textBox
            }
        )
    }

    private var referenceableControls: [RemoteControl] {
        pages.flatMap(\.controls).filter {
            $0.id != control.id && ($0.kind == .slider || $0.isToggle == true)
        }
    }

    private var referencedControlBinding: Binding<String> {
        Binding(
            get: { control.textBox?.referencedControlID?.uuidString ?? "" },
            set: { identifier in
                var textBox = control.textBox ?? RemoteTextBox()
                textBox.referencedControlID = UUID(uuidString: identifier)
                control.textBox = textBox
            }
        )
    }

    private var textSourceComputerBinding: Binding<String> {
        Binding(
            get: { control.textBox?.computerID?.uuidString ?? "" },
            set: { identifier in
                var textBox = control.textBox ?? RemoteTextBox()
                textBox.computerID = UUID(uuidString: identifier)
                control.textBox = textBox
            }
        )
    }

    private var supportsAutomaticRefresh: Bool {
        switch control.textBox?.source ?? .staticText {
        case .dateTime, .macScript, .macShortcut, .nowPlaying: true
        case .staticText, .controlValue: false
        }
    }

    private var automaticRefreshBinding: Binding<Bool> {
        Binding(
            get: { control.textBox?.refreshIntervalSeconds != nil },
            set: { enabled in
                var textBox = control.textBox ?? RemoteTextBox()
                textBox.refreshIntervalSeconds = enabled ? max(textBox.refreshIntervalSeconds ?? 5, 5) : nil
                control.textBox = textBox
            }
        )
    }

    private var refreshIntervalBinding: Binding<Int> {
        Binding(
            get: { max(control.textBox?.refreshIntervalSeconds ?? 5, 5) },
            set: { interval in
                var textBox = control.textBox ?? RemoteTextBox()
                textBox.refreshIntervalSeconds = max(interval, 5)
                control.textBox = textBox
            }
        )
    }

    private var symbolBinding: Binding<String> {
        Binding(
            get: { control.symbol },
            set: {
                control.symbol = $0
                control.iconBitmap = nil
            }
        )
    }

    private var openTargetBinding: Binding<String> {
        Binding(
            get: { control.action.text },
            set: {
                control.action.text = $0
                control.iconBitmap = nil
            }
        )
    }

    private var actionValueBinding: Binding<Double> {
        Binding(
            get: { Double(control.action.value) },
            set: { control.action.value = Int($0.rounded()) }
        )
    }

    private var volumePercentageBinding: Binding<Double> {
        Binding(
            get: { Double(volumePercentage) },
            set: { control.action.value = Int(($0 / 100 * 255).rounded()) }
        )
    }

    private var volumePercentage: Int {
        Int((Double(control.action.value) / 255 * 100).rounded()).clamped(to: 0...100)
    }

    private func presetBinding(_ presets: [WLEDDiscovery.Preset]) -> Binding<Int> {
        Binding(
            get: { control.action.value },
            set: { value in
                control.action.value = value
                if let preset = presets.first(where: { $0.id == value }) {
                    control.title = preset.name
                }
            }
        )
    }

    private var actionTypeBinding: Binding<RemoteActionType> {
        Binding(
            get: { control.action.type },
            set: { type in
                guard type != control.action.type else { return }
                control.iconBitmap = nil
                let host = control.action.host
                let computerID = control.action.computerID
                switch type {
                case .macMedia:
                    control.action = RemoteAction(type: type, text: "playPause", computerID: computerID)
                case .macKey:
                    control.action = RemoteAction(type: type, text: "space", computerID: computerID)
                case .macOpen:
                    control.action = RemoteAction(type: type, text: "https://", computerID: computerID)
                case .macShortcut, .macScript:
                    control.action = RemoteAction(type: type, computerID: computerID)
                case .wledPower:
                    control.action = RemoteAction(type: type, host: host, text: "toggle")
                case .wledPreset:
                    control.action = RemoteAction(type: type, host: host, value: 1)
                case .wledBrightness:
                    control.action = RemoteAction(type: type, host: host, value: 128)
                case .page:
                    control.action = RemoteAction(type: type)
                }
                if control.kind != .textBox {
                    control.kind = type == .wledBrightness ? .slider : .button
                    if control.kind == .slider {
                        control.isToggle = nil
                    }
                }
            }
        )
    }

    private var kindBinding: Binding<RemoteControlKind> {
        Binding(
            get: { control.kind },
            set: { kind in
                let canUseKind = kind == .slider ||
                    (kind == .button && canUseButtonLayout) ||
                    (kind == .textBox && canUseTextBoxLayout)
                if canUseKind {
                    control.kind = kind
                    if kind == .textBox && control.textBox == nil {
                        control.textBox = RemoteTextBox()
                    }
                    if kind != .button {
                        control.isToggle = nil
                    }
                }
            }
        )
    }

    private var buttonHeightBinding: Binding<Int> {
        Binding(
            get: { control.buttonGridHeight },
            set: { control.buttonHeight = $0 }
        )
    }

    private var toggleButtonBinding: Binding<Bool> {
        Binding(
            get: { control.isToggle == true },
            set: { control.isToggle = $0 ? true : nil }
        )
    }

    private func modifierBinding(_ modifier: String) -> Binding<Bool> {
        Binding(
            get: { control.action.modifiers.contains(modifier) },
            set: { enabled in
                control.action.modifiers.removeAll { $0 == modifier }
                if enabled { control.action.modifiers.append(modifier) }
            }
        )
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

private struct ComboBoxField: NSViewRepresentable {
    @Binding var value: String
    let suggestions: [String]

    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }

    func makeNSView(context: Context) -> NSComboBox {
        let field = NSComboBox()
        field.addItems(withObjectValues: suggestions)
        field.stringValue = value
        field.delegate = context.coordinator
        field.isEditable = true
        field.completes = true
        return field
    }

    func updateNSView(_ field: NSComboBox, context: Context) {
        if field.stringValue != value { field.stringValue = value }
    }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        @Binding var value: String
        init(value: Binding<String>) { _value = value }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSComboBox else { return }
            value = field.stringValue
        }
        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSComboBox else { return }
            value = field.stringValue
        }
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}

private struct DevicePreview: View {
    let page: RemotePage
    let pageIndex: Int
    let pageCount: Int
    let selectedControlID: UUID?
    let onSelect: (UUID) -> Void
    let onMove: (UUID, Int) -> Void

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / 540, geometry.size.height / 960)
            let width = 540 * scale
            let height = 960 * scale
            let origin = CGPoint(x: (geometry.size.width - width) / 2, y: (geometry.size.height - height) / 2)
            let frames = RemoteLayout.frames(for: page.controls)

            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color(red: 0.97, green: 0.965, blue: 0.93))
                VStack(spacing: 4 * scale) {
                    Text(page.name.uppercased())
                        .font(.system(size: 27 * scale, weight: .bold, design: .rounded))
                    Rectangle().fill(.black).frame(height: max(1, scale))
                }
                .padding(.horizontal, 24 * scale)
                .padding(.top, 55 * scale)

                ForEach(Array(page.controls.prefix(16).enumerated()), id: \.element.id) { index, control in
                    let frame = frames[index]
                    PreviewControl(control: control, selected: selectedControlID == control.id, scale: scale)
                        .frame(width: frame.width * scale, height: frame.height * scale)
                        .position(x: frame.midX * scale, y: frame.midY * scale)
                        .onTapGesture { onSelect(control.id) }
                        .gesture(DragGesture(minimumDistance: 8).onEnded { drag in
                            let point = CGPoint(
                                x: frame.midX + drag.translation.width / scale,
                                y: frame.midY + drag.translation.height / scale
                            )
                            guard let slot = RemoteLayout.slot(at: point) else { return }
                            onMove(control.id, slot)
                        })
                }

                Text("<  \(pageIndex + 1) / \(max(pageCount, 1))  >")
                    .font(.system(size: 14 * scale, weight: .semibold, design: .monospaced))
                    .position(x: 270 * scale, y: 902 * scale)
            }
            .frame(width: width, height: height)
            .overlay(Rectangle().stroke(.black, lineWidth: 1))
            .position(x: origin.x + width / 2, y: origin.y + height / 2)
            .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
        }
        .aspectRatio(540 / 960, contentMode: .fit)
    }
}

private struct PreviewControl: View {
    let control: RemoteControl
    let selected: Bool
    let scale: CGFloat

    var body: some View {
        ZStack {
            if control.kind == .slider {
                RoundedRectangle(cornerRadius: 9 * scale).fill(.white)
                GeometryReader { geometry in
                    RoundedRectangle(cornerRadius: 6 * scale)
                        .fill(.black)
                        .frame(width: geometry.size.width * CGFloat(min(max(control.action.value, 0), 255)) / 255)
                }
                .padding(3 * scale)
                RoundedRectangle(cornerRadius: 9 * scale).stroke(.black, lineWidth: max(1, scale))
            } else if control.kind != .textBox {
                RoundedRectangle(cornerRadius: 9 * scale).fill(.white.opacity(0.28))
                RoundedRectangle(cornerRadius: 9 * scale).stroke(.black, lineWidth: max(1, scale))
            }
            if control.kind == .textBox {
                Text(textBoxPreview)
                    .font(.system(size: textBoxSize * scale, weight: .semibold))
                    .multilineTextAlignment(textBoxTextAlignment)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: textBoxFrameAlignment)
                    .padding(8 * scale)
                    .clipped()
                RoundedRectangle(cornerRadius: 9 * scale).stroke(.black, lineWidth: max(1, scale))
            } else if control.kind == .slider {
                HStack(spacing: 8 * scale) {
                    RemoteBitmapIcon(symbol: control.symbol, bitmap: control.iconBitmap)
                        .frame(width: 28 * scale, height: 28 * scale)
                    Text(control.title).lineLimit(1)
                }
                .font(.system(size: 15 * scale, weight: .semibold))
            } else if control.buttonGridHeight == 1 {
                HStack(spacing: 8 * scale) {
                    RemoteBitmapIcon(symbol: control.symbol, bitmap: control.iconBitmap)
                        .frame(width: 28 * scale, height: 28 * scale)
                    Text(control.title)
                        .font(.system(size: 15 * scale, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
                .padding(.horizontal, 10 * scale)
            } else {
                VStack(spacing: 10 * scale) {
                    RemoteBitmapIcon(symbol: control.symbol, bitmap: control.iconBitmap)
                        .frame(width: 64 * scale, height: 64 * scale)
                    Text(control.title)
                        .font(.system(size: 16 * scale, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .padding(8 * scale)
            }
        }
        .foregroundStyle(.black)
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 9 * scale)
                    .stroke(Color(red: 0.05, green: 0.52, blue: 0.62), lineWidth: max(2, 3 * scale))
            }
        }
        .contentShape(Rectangle())
    }

    private var textBoxTextAlignment: TextAlignment {
        switch control.textBox?.horizontalAlignment ?? .leading {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private var textBoxFrameAlignment: Alignment {
        let horizontal: HorizontalAlignment = switch control.textBox?.horizontalAlignment ?? .leading {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
        let vertical: VerticalAlignment = switch control.textBox?.verticalAlignment ?? .top {
        case .top: .top
        case .center: .center
        case .bottom: .bottom
        }
        return Alignment(horizontal: horizontal, vertical: vertical)
    }

    private var textBoxPreview: String {
        guard let textBox = control.textBox else { return control.title }
        return switch textBox.source {
        case .staticText: textBox.sourceText
        case .dateTime: "Sep 2, 18:54"
        case .macScript, .macShortcut: "Command output"
        case .controlValue: "128"
        case .nowPlaying: "Song Title\nArtist"
        }
    }

    private var textBoxSize: CGFloat {
        switch control.textBox?.textSize ?? .autoFit {
        case .small: 9
        case .medium: 12
        case .large: 18
        case .extraLarge, .autoFit: 24
        }
    }
}

private struct RemoteBitmapIcon: View {
    let symbol: String
    let bitmap: String?

    @ViewBuilder
    var body: some View {
        if let image = remoteBitmapMaskImage(bitmap) {
            Image(decorative: image, scale: 1)
                .renderingMode(.template)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
        } else if !symbol.isEmpty {
            Image(systemName: symbol)
                .resizable()
                .scaledToFit()
        }
    }
}

private func remoteBitmapMaskImage(_ hex: String?) -> CGImage? {
    guard let hex else { return nil }
    let characters = Array(hex.utf8)
    let dimension = characters.count == 256 ? 32 : characters.count == 1024 ? 64 : 0
    guard dimension > 0 else { return nil }

    func nibble(_ character: UInt8) -> UInt8? {
        switch character {
        case 48...57: character - 48
        case 65...70: character - 55
        case 97...102: character - 87
        default: nil
        }
    }

    var packed = [UInt8](repeating: 0, count: dimension * dimension / 8)
    for index in packed.indices {
        guard let high = nibble(characters[index * 2]),
              let low = nibble(characters[index * 2 + 1]) else { return nil }
        packed[index] = high << 4 | low
    }
    var pixels = [UInt8](repeating: 0, count: dimension * dimension * 4)
    for y in 0..<dimension {
        for x in 0..<dimension where packed[y * (dimension / 8) + x / 8] & (0x80 >> (x % 8)) != 0 {
            pixels[(y * dimension + x) * 4 + 3] = 255
        }
    }
    guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
    return CGImage(
        width: dimension,
        height: dimension,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: dimension * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )
}

private enum RemoteLayout {
    static func frames(for controls: [RemoteControl]) -> [CGRect] {
        let controls = Array(controls.prefix(16))
        var occupied: Set<Int> = []
        var frames = Array(repeating: CGRect.zero, count: controls.count)
        var placed = Array(repeating: false, count: controls.count)

        func place(_ index: Int, slot: Int) -> Bool {
            guard let placement = RemoteGrid.placement(for: controls[index], at: slot) else { return false }
            let cells = RemoteGrid.cells(for: placement)
            guard occupied.isDisjoint(with: cells) else { return false }
            occupied.formUnion(cells)
            let row = placement.slot / 2
            let column = placement.slot % 2
            frames[index] = CGRect(
                x: 24 + CGFloat(column) * 252,
                y: 142 + CGFloat(row) * 89,
                width: CGFloat(240 * placement.span.width + 12 * (placement.span.width - 1)),
                height: CGFloat(77 * placement.span.height + 12 * (placement.span.height - 1))
            )
            placed[index] = true
            return true
        }

        for index in controls.indices {
            if let slot = controls[index].layoutSlot, (0..<16).contains(slot) {
                _ = place(index, slot: slot)
            }
        }
        for index in controls.indices where !placed[index] {
            for slot in 0..<16 where !placed[index] {
                _ = place(index, slot: slot)
            }
        }
        return frames
    }

    static func slot(at point: CGPoint) -> Int? {
        let column = Int((point.x - 24) / 252)
        let row = Int((point.y - 142) / 89)
        guard (0..<2).contains(column), (0..<8).contains(row) else { return nil }
        return row * 2 + column
    }
}

private extension RemoteEditorStore {
    var selectedPage: RemotePage? {
        guard let index = selectedPageIndex else { return nil }
        return profile.pages[index]
    }
}