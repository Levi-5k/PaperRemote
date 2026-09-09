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
    @StateObject private var moduleCatalog = ModuleCatalog()
    @State private var inspectorTab = InspectorTab.catalog

    private enum InspectorTab: String, CaseIterable, Identifiable {
        case catalog = "Add Controls"
        case control = "Control"
        case modules = "Modules"
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
                if let gridColumnsBinding, let gridRowsBinding {
                    Stepper("\(gridColumnsBinding.wrappedValue) cols", value: gridColumnsBinding, in: 1...12)
                        .fixedSize()
                    Stepper("\(gridRowsBinding.wrappedValue) rows", value: gridRowsBinding, in: 1...16)
                        .fixedSize()
                }
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
                    temperatureUnit: store.profile.temperatureUnit,
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
            } else if inspectorTab == .modules {
                ModulesPanel(store: store, catalog: moduleCatalog)
            } else if inspectorTab == .control, let binding = selectedControlBinding {
                ControlInspector(
                    control: binding,
                    pages: store.profile.pages,
                    computers: store.profile.computers,
                    temperatureUnit: store.profile.temperatureUnit,
                    discovery: discovery,
                    canUseButtonLayout: store.canChangeSelectedControl(to: .button),
                    canUseTextBoxLayout: store.canChangeSelectedControl(to: .textBox),
                    gridColumns: selectedPage?.gridColumns ?? 2,
                    gridRows: selectedPage?.gridRows ?? 8,
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
                ControlCatalogPanel(store: store, moduleTemplates: moduleCatalog.installedTemplates)
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

    private var gridColumnsBinding: Binding<Int>? {
        guard let index = store.selectedPageIndex else { return nil }
        return Binding(
            get: { store.profile.pages[index].gridColumns },
            set: { store.profile.pages[index].gridColumns = $0 }
        )
    }

    private var gridRowsBinding: Binding<Int>? {
        guard let index = store.selectedPageIndex else { return nil }
        return Binding(
            get: { store.profile.pages[index].gridRows },
            set: { store.profile.pages[index].gridRows = $0 }
        )
    }
}

private struct ControlCatalogPanel: View {
    @ObservedObject var store: RemoteEditorStore
    let moduleTemplates: [RemoteControlTemplate]
    @State private var search = ""

    var body: some View {
        let templates = RemoteControlTemplate.all + moduleTemplates
        let categories = templates.reduce(into: [String]()) { result, template in
            if !result.contains(template.category) { result.append(template.category) }
        }
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
                    ForEach(categories, id: \.self) { category in
                        let templates = templates.filter {
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

private struct ModulesPanel: View {
    @ObservedObject var store: RemoteEditorStore
    @ObservedObject var catalog: ModuleCatalog
    @State private var status = "Browse controls published in the paperGIF GitHub catalog."
    @State private var installingID: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("GitHub modules")
                        .font(.headline)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh module catalog")
                .disabled(catalog.isLoading)
            }
            .padding(12)

            Divider()

            if catalog.isLoading && catalog.availableModules.isEmpty {
                Spacer()
                ProgressView("Loading modules...")
                    .controlSize(.small)
                Spacer()
            } else if catalog.availableModules.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "shippingbox")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("No Modules Available")
                        .font(.headline)
                    Text("Refresh when you are connected to GitHub.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(catalog.availableModules) { module in
                            moduleCard(module)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private func moduleCard(_ module: PaperModuleListing) -> some View {
        let installed = catalog.isInstalled(module)
        let hasOlderVersion = catalog.hasUpdate(module)
        let pageTemplates = installed ? catalog.installedModule(id: module.id)?.pages ?? [] : []
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(module.name).font(.headline)
                    Text("v\(module.version) · \(module.author)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if installed {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            Text(module.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                Task { await install(module) }
            } label: {
                if installingID == module.id {
                    ProgressView().controlSize(.small)
                } else {
                    Label(
                        installed ? "Installed" : hasOlderVersion ? "Update" : "Install",
                        systemImage: installed ? "checkmark.circle" : "arrow.down.circle"
                    )
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(installingID != nil || installed)

            ForEach(pageTemplates, id: \.id) { definition in
                Button {
                    store.addPage(ModuleCatalog.clonePage(definition, moduleID: module.id))
                    status = "Added \(definition.page.name)."
                } label: {
                    Label("Add \(definition.page.name) Page", systemImage: "plus.rectangle.on.rectangle")
                }
                .buttonStyle(.bordered)
                .disabled(store.profile.pages.count >= 8)
                .help(definition.detail)
            }
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }

    private func refresh() async {
        status = "Loading the module catalog..."
        do {
            try await catalog.refresh()
            var updatedModuleCount = 0
            var updatedPageCount = 0
            for listing in catalog.availableModules where catalog.hasUpdate(listing) {
                installingID = listing.id
                let module = try await catalog.install(listing)
                updatedPageCount += store.updateModulePages(from: module)
                updatedModuleCount += 1
            }
            installingID = nil
            status = updatedModuleCount == 0
                ? "\(catalog.availableModules.count) module(s) available"
                : "Updated \(updatedModuleCount) module(s) and \(updatedPageCount) linked page(s)."
        } catch {
            installingID = nil
            status = "Catalog unavailable: \(error.localizedDescription)"
        }
    }

    private func install(_ listing: PaperModuleListing) async {
        installingID = listing.id
        defer { installingID = nil }
        do {
            let module = try await catalog.install(listing)
            let updatedPageCount = store.updateModulePages(from: module)
            if updatedPageCount > 0 {
                status = "Updated \(updatedPageCount) \(updatedPageCount == 1 ? "page" : "pages") from \(module.name)."
            } else {
                status = module.pages?.isEmpty == false
                    ? "Installed \(module.name). Add its page here or use individual controls."
                    : "Installed \(module.name). Its controls are now in Add Controls."
            }
        } catch {
            status = "Install failed: \(error.localizedDescription)"
        }
    }
}

private struct ControlInspector: View {
    @Binding var control: RemoteControl
    let pages: [RemotePage]
    let computers: [RemoteComputer]
    let temperatureUnit: RemoteTemperatureUnit
    @ObservedObject var discovery: WLEDDiscovery
    let canUseButtonLayout: Bool
    let canUseTextBoxLayout: Bool
    let gridColumns: Int
    let gridRows: Int
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
                    Stepper(value: controlGridWidthBinding, in: 1...gridColumns) {
                        Text("Width: \(control.gridSpan(columns: gridColumns, rows: gridRows).width) column(s)")
                    }
                    Stepper(value: controlGridHeightBinding, in: 1...gridRows) {
                        Text("Height: \(control.gridSpan(columns: gridColumns, rows: gridRows).height) row(s)")
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
        .onAppear {
            prepareWLEDSelection()
            prepareSchedules()
        }
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
                    Text("OpenBuilds position").tag(RemoteTextSource.openBuildsPosition)
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
                            Text(referenceableControlTitle(candidate)).tag(candidate.id.uuidString)
                        }
                    }
                    .labelsHidden()
                }
            case .nowPlaying:
                textSourceComputerPicker
            case .openBuildsPosition:
                textSourceComputerPicker
                LabeledContent("Target") {
                    TextField("127.0.0.1|x|mm", text: textBoxBinding(\.sourceText))
                }
            }

            if control.textBox?.source != .staticText {
                LabeledContent("Unavailable") {
                    TextField("Unavailable", text: textBoxBinding(\.placeholder))
                }
            }
        }

        section("TEXT LAYOUT") {
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
                Picker("", selection: mediaCommandBinding) {
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
        case .openBuilds:
            LabeledContent("CONTROL address") {
                TextField("127.0.0.1 or private IP", text: $control.action.host)
            }
            LabeledContent("Command") {
                Picker("", selection: $control.action.text) {
                    Text("Jog X -").tag("jogXNegative")
                    Text("Jog X +").tag("jogXPositive")
                    Text("Jog Y -").tag("jogYNegative")
                    Text("Jog Y +").tag("jogYPositive")
                    Text("Jog Z -").tag("jogZNegative")
                    Text("Jog Z +").tag("jogZPositive")
                    Text("Zero X").tag("zeroX")
                    Text("Zero Y").tag("zeroY")
                    Text("Zero Z").tag("zeroZ")
                    Text("Jog X-/Y-").tag("jogXNegativeYNegative")
                    Text("Jog X-/Y+").tag("jogXNegativeYPositive")
                    Text("Jog X+/Y-").tag("jogXPositiveYNegative")
                    Text("Jog X+/Y+").tag("jogXPositiveYPositive")
                    Text("Pause job").tag("pause")
                    Text("Resume job").tag("resume")
                    Text("Stop job").tag("stop")
                    Text("Abort / reset").tag("abort")
                    Text("Unlock alarm").tag("unlock")
                    Text("Home machine").tag("home")
                }
                .labelsHidden()
            }
            if control.action.text.hasPrefix("jog") {
                Stepper("Distance: \(control.action.value) mm", value: $control.action.value, in: 1...100)
            }
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
        case .netHomePower:
            netHomeDeviceField
            LabeledContent("Power") {
                Picker("", selection: $control.action.text) {
                    Text("Toggle").tag("toggle")
                    Text("On").tag("on")
                    Text("Off").tag("off")
                }
                .labelsHidden()
            }
        case .netHomeTemperature:
            netHomeDeviceField
            Stepper(
                "Setpoint: \(temperatureUnit.displayValue(celsiusTenths: control.action.valueTenths ?? control.action.value * 10)) \(temperatureUnit.symbol)",
                value: temperatureDisplayBinding,
                in: temperatureDisplayRange
            )
        case .netHomeTemperatureStep:
            netHomeDeviceField
            Text(control.action.value < 0 ? "Decrease the thermostat setpoint" : "Increase the thermostat setpoint")
                .foregroundStyle(.secondary)
        case .netHomeMode:
            netHomeDeviceField
            LabeledContent("Mode") {
                Picker("", selection: $control.action.text) {
                    Text("Auto").tag("auto")
                    Text("Cool").tag("cool")
                    Text("Heat").tag("heat")
                    Text("Dry").tag("dry")
                    Text("Fan").tag("fan")
                }
                .labelsHidden()
            }
        case .netHomeFan:
            netHomeDeviceField
            Stepper("Fan: \(control.action.value)%", value: $control.action.value, in: 20...100, step: 20)
        case .netHomeAuto:
            netHomeDeviceField
            Text("Uses the thermostat page setpoint.")
                .foregroundStyle(.secondary)
            LabeledContent("Control") {
                Picker("", selection: $control.action.text) {
                    Text("Cooling").tag("cool")
                    Text("Heating").tag("heat")
                }
                .labelsHidden()
            }
            Stepper(
                "Deadband: \(deadbandDisplayText)",
                value: optionalActionValueBinding(\.deadbandTenths, default: 10),
                in: 5...30,
                step: 5
            )
            Stepper(
                "Humidity assist: \(control.action.humidityThreshold ?? 65)%",
                value: optionalActionValueBinding(\.humidityThreshold, default: 65),
                in: 40...80,
                step: 5
            )
            Stepper(
                "Adjustment interval: \(control.action.minimumCycleMinutes ?? 10) min",
                value: optionalActionValueBinding(\.minimumCycleMinutes, default: 10),
                in: 1...30,
                step: 1
            )
            Text("Humidity assist only extends cooling. The minimum cycle protects the compressor.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .page:
            LabeledContent("Page") {
                Picker("", selection: $control.action.text) {
                    Text("Choose a page").tag("")
                    ForEach(pages) { page in Text(page.name).tag(page.id.uuidString) }
                }
                .labelsHidden()
            }
        }

        if supportsSchedule {
            Toggle("Run on a schedule", isOn: scheduleEnabledBinding)
            if control.action.scheduleEnabled == true {
                scheduleFields
            }
        }
    }

    @ViewBuilder private var netHomeDeviceField: some View {
        LabeledContent("NetHome unit") {
            TextField("Room or East bedroom", text: $control.action.host)
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
        [.macMedia, .macKey, .macOpen, .macShortcut, .macScript,
         .openBuilds,
         .netHomePower, .netHomeTemperature, .netHomeTemperatureStep,
         .netHomeMode, .netHomeFan, .netHomeAuto]
            .contains(control.action.type)
    }

    private var isWLEDAction: Bool {
        [.wledPower, .wledPreset, .wledBrightness].contains(control.action.type)
    }

    private var supportsSchedule: Bool {
        (control.kind == .button || control.action.type == .netHomeTemperature) &&
            control.action.type != .page && control.action.type != .openBuilds
    }

    private var scheduleEnabledBinding: Binding<Bool> {
        Binding(
            get: { control.action.scheduleEnabled == true },
            set: { enabled in
                control.action.scheduleEnabled = enabled
                if enabled {
                    prepareSchedules()
                }
            }
        )
    }

    @ViewBuilder private var scheduleFields: some View {
        ForEach(Array((control.action.schedules ?? []).enumerated()), id: \.element.id) { index, entry in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Schedule \(index + 1)").font(.headline)
                    Spacer()
                    Button(role: .destructive) { removeSchedule(entry.id) } label: {
                        Image(systemName: "trash")
                    }
                    .help("Delete schedule")
                }
                DatePicker("Time", selection: scheduleTimeBinding(entry.id), displayedComponents: .hourAndMinute)
                Text("Days").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                    ForEach(Array(Calendar.current.veryShortWeekdaySymbols.enumerated()), id: \.offset) { dayIndex, symbol in
                        let weekday = dayIndex + 1
                        Button { toggleWeekday(weekday, in: entry.id) } label: {
                            Text(symbol).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(entry.weekdays.contains(weekday) ? .accentColor : .secondary)
                        .accessibilityLabel(Calendar.current.weekdaySymbols[dayIndex])
                        .accessibilityValue(entry.weekdays.contains(weekday) ? "Selected" : "Not selected")
                    }
                }
                scheduleFunctionFields(entry)
            }
            .padding(10)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
        Button { addSchedule() } label: {
            Label("Add Time", systemImage: "plus")
        }
        .disabled((control.action.schedules?.count ?? 0) >= 8)
    }

    @ViewBuilder private func scheduleFunctionFields(_ entry: RemoteScheduleEntry) -> some View {
        switch control.action.type {
        case .macMedia:
            LabeledContent("Command") {
                Picker("", selection: scheduleTextBinding(entry.id)) {
                    ForEach(mediaCommands, id: \.0) { command in Text(command.1).tag(command.0) }
                }
                .labelsHidden()
            }
            if (entry.text ?? control.action.text) == "volume" {
                Stepper("Volume: \(scheduleVolume(entry))%", value: scheduleVolumeBinding(entry.id), in: 0...100)
            }
        case .wledPower, .netHomePower:
            LabeledContent("Power") {
                Picker("", selection: scheduleTextBinding(entry.id)) {
                    Text("Toggle").tag("toggle")
                    Text("On").tag("on")
                    Text("Off").tag("off")
                }
                .labelsHidden()
            }
        case .wledPreset:
            Stepper("Preset: \(entry.value ?? control.action.value)", value: scheduleValueBinding(entry.id), in: 1...250)
        case .wledBrightness:
            Stepper("Brightness: \(entry.value ?? control.action.value)", value: scheduleValueBinding(entry.id), in: 0...255)
        case .netHomeTemperature:
            Stepper(
                "Setpoint: \(scheduleTemperature(entry)) \(temperatureUnit.symbol)",
                value: scheduleTemperatureBinding(entry.id),
                in: temperatureDisplayRange
            )
        case .netHomeTemperatureStep:
            Picker("Adjustment", selection: scheduleValueBinding(entry.id)) {
                Text("Decrease").tag(-1)
                Text("Increase").tag(1)
            }
        case .netHomeMode:
            Picker("Mode", selection: scheduleTextBinding(entry.id)) {
                Text("Auto").tag("auto")
                Text("Cool").tag("cool")
                Text("Heat").tag("heat")
                Text("Dry").tag("dry")
                Text("Fan").tag("fan")
            }
        case .netHomeFan:
            Stepper("Fan: \(entry.value ?? control.action.value)%", value: scheduleValueBinding(entry.id), in: 20...100, step: 20)
        case .netHomeAuto:
            Picker("Control", selection: scheduleTextBinding(entry.id)) {
                Text("Cooling").tag("cool")
                Text("Heating").tag("heat")
            }
        default:
            EmptyView()
        }
    }

    private func prepareSchedules() {
        guard control.action.scheduleEnabled == true,
              control.action.schedules?.isEmpty != false else { return }
        control.action.schedules = [makeScheduleEntry(
            hour: control.action.scheduleHour ?? 8,
            minute: control.action.scheduleMinute ?? 0
        )]
        syncLegacySchedule()
    }

    private func makeScheduleEntry(hour: Int = 8, minute: Int = 0) -> RemoteScheduleEntry {
        RemoteScheduleEntry(
            hour: hour,
            minute: minute,
            text: scheduleUsesText ? control.action.text : nil,
            value: scheduleUsesValue ? control.action.value : nil,
            valueTenths: control.action.type == .netHomeTemperature
                ? (control.action.valueTenths ?? control.action.value * 10) : nil
        )
    }

    private var scheduleUsesText: Bool {
        [.macMedia, .wledPower, .netHomePower, .netHomeMode, .netHomeAuto].contains(control.action.type)
    }

    private var scheduleUsesValue: Bool {
        [.macMedia, .wledPreset, .wledBrightness, .netHomeTemperature,
         .netHomeTemperatureStep, .netHomeFan].contains(control.action.type)
    }

    private func addSchedule() {
        prepareSchedules()
        guard var schedules = control.action.schedules, schedules.count < 8 else { return }
        let previous = schedules.last
        schedules.append(makeScheduleEntry(hour: previous?.hour ?? 8, minute: previous?.minute ?? 0))
        control.action.schedules = schedules
    }

    private func removeSchedule(_ id: UUID) {
        control.action.schedules?.removeAll { $0.id == id }
        if control.action.schedules?.isEmpty != false {
            control.action.scheduleEnabled = false
        }
        syncLegacySchedule()
    }

    private func updateSchedule(_ id: UUID, _ update: (inout RemoteScheduleEntry) -> Void) {
        guard let index = control.action.schedules?.firstIndex(where: { $0.id == id }) else { return }
        update(&control.action.schedules![index])
        syncLegacySchedule()
    }

    private func syncLegacySchedule() {
        control.action.scheduleHour = control.action.schedules?.first?.hour
        control.action.scheduleMinute = control.action.schedules?.first?.minute
    }

    private func toggleWeekday(_ weekday: Int, in id: UUID) {
        updateSchedule(id) { entry in
            if let index = entry.weekdays.firstIndex(of: weekday) {
                entry.weekdays.remove(at: index)
            } else {
                entry.weekdays.append(weekday)
                entry.weekdays.sort()
            }
        }
    }

    private func scheduleTimeBinding(_ id: UUID) -> Binding<Date> {
        Binding(
            get: {
                let entry = control.action.schedules?.first(where: { $0.id == id })
                return Calendar.current.date(
                    bySettingHour: entry?.hour ?? 8,
                    minute: entry?.minute ?? 0,
                    second: 0,
                    of: Date()
                ) ?? Date()
            },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                updateSchedule(id) {
                    $0.hour = components.hour ?? 8
                    $0.minute = components.minute ?? 0
                }
            }
        )
    }

    private func scheduleTextBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { control.action.schedules?.first(where: { $0.id == id })?.text ?? control.action.text },
            set: { value in updateSchedule(id) { $0.text = value } }
        )
    }

    private func scheduleValueBinding(_ id: UUID) -> Binding<Int> {
        Binding(
            get: { control.action.schedules?.first(where: { $0.id == id })?.value ?? control.action.value },
            set: { value in updateSchedule(id) { $0.value = value } }
        )
    }

    private func scheduleVolume(_ entry: RemoteScheduleEntry) -> Int {
        Int((Double(entry.value ?? control.action.value) / 255 * 100).rounded()).clamped(to: 0...100)
    }

    private func scheduleVolumeBinding(_ id: UUID) -> Binding<Int> {
        Binding(
            get: {
                let value = control.action.schedules?.first(where: { $0.id == id })?.value ?? control.action.value
                return Int((Double(value) / 255 * 100).rounded()).clamped(to: 0...100)
            },
            set: { percentage in
                updateSchedule(id) { $0.value = Int((Double(percentage) / 100 * 255).rounded()) }
            }
        )
    }

    private func scheduleTemperature(_ entry: RemoteScheduleEntry) -> Int {
        temperatureUnit.displayValue(celsiusTenths: entry.valueTenths ?? control.action.valueTenths ?? control.action.value * 10)
    }

    private func scheduleTemperatureBinding(_ id: UUID) -> Binding<Int> {
        Binding(
            get: {
                let entry = control.action.schedules?.first(where: { $0.id == id })
                return temperatureUnit.displayValue(
                    celsiusTenths: entry?.valueTenths ?? control.action.valueTenths ?? control.action.value * 10
                )
            },
            set: { displayValue in
                let tenths = min(max(temperatureUnit.celsiusTenthsValue(displayValue: displayValue), 160), 300)
                updateSchedule(id) {
                    $0.valueTenths = tenths
                    $0.value = Int((Double(tenths) / 10).rounded())
                }
            }
        )
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
            ($0.id != control.id || $0.action.type == .netHomeTemperature) &&
                ($0.kind == .slider || $0.isToggle == true ||
                    $0.action.type == .netHomeTemperature)
        }
    }

    private func referenceableControlTitle(_ candidate: RemoteControl) -> String {
        let isNetHomeControl = switch candidate.action.type {
        case .netHomePower, .netHomeTemperature, .netHomeTemperatureStep,
             .netHomeMode, .netHomeFan, .netHomeAuto:
            true
        default:
            false
        }
        if isNetHomeControl && !candidate.action.host.isEmpty {
            return "\(candidate.action.host) \(candidate.title)"
        }
        return candidate.title
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
        case .dateTime, .macScript, .macShortcut, .nowPlaying, .openBuildsPosition: true
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

    private var mediaCommandBinding: Binding<String> {
        Binding(
            get: { control.action.text },
            set: { command in
                control.action.text = command
                guard command == "playPause" else { return }
                control.title = "Play / Pause"
                control.symbol = "playpause.fill"
                control.iconBitmap = nil
                control.isToggle = nil
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

    private var temperatureDisplayRange: ClosedRange<Int> {
        temperatureUnit.displayValue(celsius: 16)...temperatureUnit.displayValue(celsius: 30)
    }

    private var temperatureDisplayBinding: Binding<Int> {
        Binding(
            get: {
                temperatureUnit.displayValue(
                    celsiusTenths: control.action.valueTenths ?? control.action.value * 10
                )
            },
            set: {
                let tenths = min(max(temperatureUnit.celsiusTenthsValue(displayValue: $0), 160), 300)
                control.action.valueTenths = tenths
                control.action.value = Int((Double(tenths) / 10).rounded())
            }
        )
    }

    private var deadbandDisplayText: String {
        let celsius = Double(control.action.deadbandTenths ?? 10) / 10
        let value = temperatureUnit == .celsius ? celsius : celsius * 9 / 5
        return String(format: "%.1f %@", value, temperatureUnit.symbol)
    }

    private func optionalActionValueBinding(
        _ keyPath: WritableKeyPath<RemoteAction, Int?>,
        default defaultValue: Int
    ) -> Binding<Int> {
        Binding(
            get: { control.action[keyPath: keyPath] ?? defaultValue },
            set: { control.action[keyPath: keyPath] = $0 }
        )
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
                    control.title = "Play / Pause"
                    control.symbol = "playpause.fill"
                    control.isToggle = nil
                case .macKey:
                    control.action = RemoteAction(type: type, text: "space", computerID: computerID)
                case .macOpen:
                    control.action = RemoteAction(type: type, text: "https://", computerID: computerID)
                case .macShortcut, .macScript:
                    control.action = RemoteAction(type: type, computerID: computerID)
                case .openBuilds:
                    control.action = RemoteAction(
                        type: type,
                        host: "127.0.0.1",
                        text: "jogXPositive",
                        value: 1,
                        computerID: computerID
                    )
                case .wledPower:
                    control.action = RemoteAction(type: type, host: host, text: "toggle")
                case .wledPreset:
                    control.action = RemoteAction(type: type, host: host, value: 1)
                case .wledBrightness:
                    control.action = RemoteAction(type: type, host: host, value: 128)
                case .netHomePower:
                    control.action = RemoteAction(type: type, host: host, text: "toggle", computerID: computerID)
                case .netHomeTemperature:
                    control.action = RemoteAction(
                        type: type,
                        host: host,
                        value: 22,
                        valueTenths: 220,
                        computerID: computerID
                    )
                case .netHomeTemperatureStep:
                    control.action = RemoteAction(type: type, host: host, value: 1, computerID: computerID)
                case .netHomeMode:
                    control.action = RemoteAction(type: type, host: host, text: "auto", computerID: computerID)
                case .netHomeFan:
                    control.action = RemoteAction(type: type, host: host, value: 40, computerID: computerID)
                case .netHomeAuto:
                    control.action = RemoteAction(
                        type: type,
                        host: host,
                        text: "cool",
                        value: 22,
                        computerID: computerID,
                        deadbandTenths: 10,
                        humidityThreshold: 65,
                        minimumCycleMinutes: 10
                    )
                case .page:
                    control.action = RemoteAction(type: type)
                }
                if control.kind != .textBox {
                    control.kind = (type == .wledBrightness || type == .netHomeTemperature || type == .netHomeFan)
                        ? .slider : .button
                    if control.kind == .slider {
                        control.isToggle = nil
                    } else if type == .netHomeAuto {
                        control.isToggle = true
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

    private var controlGridWidthBinding: Binding<Int> {
        Binding(
            get: { control.gridSpan(columns: gridColumns, rows: gridRows).width },
            set: { control.gridWidth = $0 }
        )
    }

    private var controlGridHeightBinding: Binding<Int> {
        Binding(
            get: { control.gridSpan(columns: gridColumns, rows: gridRows).height },
            set: { control.gridHeight = $0 }
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
    let temperatureUnit: RemoteTemperatureUnit
    let selectedControlID: UUID?
    let onSelect: (UUID) -> Void
    let onMove: (UUID, Int) -> Void

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / 540, geometry.size.height / 960)
            let width = 540 * scale
            let height = 960 * scale
            let origin = CGPoint(x: (geometry.size.width - width) / 2, y: (geometry.size.height - height) / 2)
            let frames = RemoteLayout.frames(for: page)

            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color(red: 0.97, green: 0.965, blue: 0.93))
                VStack(spacing: 4 * scale) {
                    Text(page.name.uppercased())
                        .font(.system(size: 27 * scale, weight: .bold, design: .rounded))
                    Rectangle().fill(.black).frame(height: max(1, scale))
                }
                .padding(.horizontal, 24 * scale)
                .padding(.top, 55 * scale)

                if page.layout == .openBuildsController {
                    OpenBuildsSettingsPreview(controller: page.openBuildsController, scale: scale)
                    ForEach(Array(page.controls.prefix(RemoteProfile.maximumControlsPerPage).enumerated()), id: \.element.id) { index, control in
                        let frame = frames[index]
                        PreviewControl(
                            control: control,
                            temperatureUnit: temperatureUnit,
                            selected: selectedControlID == control.id,
                            scale: scale,
                            controllerCompact: control.kind == .button
                        )
                        .frame(width: frame.width * scale, height: frame.height * scale)
                        .position(x: frame.midX * scale, y: frame.midY * scale)
                        .onTapGesture { onSelect(control.id) }
                    }
                } else {
                    ForEach(Array(page.controls.prefix(RemoteProfile.maximumControlsPerPage).enumerated()), id: \.element.id) { index, control in
                        let frame = frames[index]
                        PreviewControl(
                            control: control,
                            temperatureUnit: temperatureUnit,
                            selected: selectedControlID == control.id,
                            scale: scale
                        )
                            .frame(width: frame.width * scale, height: frame.height * scale)
                            .position(x: frame.midX * scale, y: frame.midY * scale)
                            .onTapGesture { onSelect(control.id) }
                            .gesture(DragGesture(minimumDistance: 8).onEnded { drag in
                                let point = CGPoint(
                                    x: frame.midX + drag.translation.width / scale,
                                    y: frame.midY + drag.translation.height / scale
                                )
                                guard let slot = RemoteLayout.slot(at: point, page: page) else { return }
                                onMove(control.id, slot)
                            })
                    }
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

private struct OpenBuildsSettingsPreview: View {
    let controller: RemoteOpenBuildsController?
    let scale: CGFloat

    var body: some View {
        let settings = controller ?? RemoteOpenBuildsController()
        VStack(alignment: .leading, spacing: 0) {
            Text("UNITS")
                .font(.system(size: 9 * scale, weight: .bold))
            HStack(spacing: 8 * scale) {
                modeChip("MM", selected: settings.units == .millimeters)
                modeChip("IN", selected: settings.units == .inches)
            }
            .padding(.top, 8 * scale)

            HStack {
                Text("JOG SPEED")
                Spacer()
                Text("\(settings.jogSpeed) \(settings.units.rawValue)/min")
            }
            .font(.system(size: 9 * scale, weight: .bold))
            .padding(.top, 10 * scale)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 7 * scale).stroke(.black, lineWidth: max(1, scale))
                RoundedRectangle(cornerRadius: 5 * scale)
                    .fill(.black)
                    .padding(4 * scale)
                    .frame(width: max(8 * scale, 152 * scale * speedProgress(settings)))
            }
            .frame(height: 38 * scale)
            .padding(.top, 8 * scale)

            Text("JOG MODE")
                .font(.system(size: 9 * scale, weight: .bold))
                .padding(.top, 10 * scale)
            HStack(spacing: 8 * scale) {
                modeChip("STEP", selected: settings.jogMode == .incremental)
                modeChip("HOLD", selected: settings.jogMode == .continuous)
            }
            .padding(.top, 8 * scale)

            Text(settings.jogMode == .continuous ? "RELEASE TO STOP" : "STEP DISTANCE")
                .font(.system(size: 9 * scale, weight: .bold))
                .padding(.top, 10 * scale)
            if settings.jogMode == .continuous {
                Text("Motion stops\nwhen released.")
                    .font(.system(size: 12 * scale))
                    .padding(.top, 12 * scale)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(72 * scale)), count: 2), spacing: 12 * scale) {
                    ForEach(distances(settings), id: \.0) { value, label in
                        modeChip(label, selected: settings.jogDistanceThousandths == value)
                    }
                }
                .padding(.top, 8 * scale)
            }
        }
        .foregroundStyle(.black)
        .frame(width: 152 * scale, alignment: .topLeading)
        .position(x: 440 * scale, y: 507 * scale)
    }

    private func modeChip(_ title: String, selected: Bool) -> some View {
        Text(title)
            .font(.system(size: 9 * scale, weight: .bold))
            .foregroundStyle(selected ? .white : .black)
            .frame(width: 72 * scale, height: 42 * scale)
            .background(selected ? Color.black : Color.white)
            .overlay(RoundedRectangle(cornerRadius: 7 * scale).stroke(.black, lineWidth: max(1, scale)))
            .clipShape(RoundedRectangle(cornerRadius: 7 * scale))
    }

    private func speedProgress(_ settings: RemoteOpenBuildsController) -> CGFloat {
        let range = settings.units == .inches ? 4...400 : 100...10_000
        return CGFloat(settings.jogSpeed - range.lowerBound) /
            CGFloat(range.upperBound - range.lowerBound)
    }

    private func distances(_ settings: RemoteOpenBuildsController) -> [(Int, String)] {
        settings.units == .inches
            ? [(1, ".001"), (10, ".01"), (100, ".1"), (1_000, "1")]
            : [(100, "0.1"), (1_000, "1"), (10_000, "10"), (100_000, "100")]
    }
}

private struct PreviewControl: View {
    let control: RemoteControl
    let temperatureUnit: RemoteTemperatureUnit
    let selected: Bool
    let scale: CGFloat
    var controllerCompact = false

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
                if control.textBox?.source == .openBuildsPosition {
                    VStack(spacing: 4 * scale) {
                        Text(openBuildsAxis)
                            .font(.system(size: 10 * scale, weight: .bold))
                        Text("0.000 \(openBuildsUnits)")
                            .font(.system(size: 18 * scale, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                } else {
                    Text(textBoxPreview)
                        .font(.system(size: textBoxSize * scale, weight: .semibold))
                        .multilineTextAlignment(textBoxTextAlignment)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: textBoxFrameAlignment)
                        .padding(8 * scale)
                        .clipped()
                }
                RoundedRectangle(cornerRadius: 9 * scale).stroke(.black, lineWidth: max(1, scale))
            } else if control.kind == .slider {
                HStack(spacing: 8 * scale) {
                    RemoteBitmapIcon(symbol: control.symbol, bitmap: control.iconBitmap)
                        .frame(width: 28 * scale, height: 28 * scale)
                    Text(control.title).lineLimit(1)
                }
                .font(.system(size: 15 * scale, weight: .semibold))
            } else if controllerCompact {
                VStack(spacing: 5 * scale) {
                    RemoteBitmapIcon(symbol: control.symbol, bitmap: control.iconBitmap)
                        .frame(width: 30 * scale, height: 30 * scale)
                    Text(control.title)
                        .font(.system(size: 10 * scale, weight: .semibold))
                }
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
        case .controlValue:
            if control.action.type == .netHomeTemperature {
                "\(temperatureUnit.displayValue(celsiusTenths: control.action.valueTenths ?? control.action.value * 10)) \(temperatureUnit.symbol)"
            } else if control.action.type == .netHomeFan {
                "\(control.action.value)%"
            } else {
                "128"
            }
        case .nowPlaying: "Song Title\nArtist"
        case .openBuildsPosition: "0.000 \(openBuildsUnits)"
        }
    }

    private var openBuildsComponents: [Substring] {
        control.textBox?.sourceText.split(separator: "|", omittingEmptySubsequences: false) ?? []
    }

    private var openBuildsAxis: String {
        openBuildsComponents.indices.contains(1) ? openBuildsComponents[1].uppercased() : "X"
    }

    private var openBuildsUnits: String {
        openBuildsComponents.indices.contains(2) ? openBuildsComponents[2].lowercased() : "mm"
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
    static func frames(for page: RemotePage) -> [CGRect] {
        let controls = Array(page.controls.prefix(RemoteProfile.maximumControlsPerPage))
        var occupied: Set<Int> = []
        var frames = Array(repeating: CGRect.zero, count: controls.count)
        var placed = Array(repeating: false, count: controls.count)

        func place(_ index: Int, slot: Int) -> Bool {
            guard let placement = RemoteGrid.placement(
                for: controls[index], at: slot,
                columns: page.gridColumns, rows: page.gridRows
            ) else { return false }
            let cells = RemoteGrid.cells(for: placement, columns: page.gridColumns)
            guard occupied.isDisjoint(with: cells) else { return false }
            occupied.formUnion(cells)
            let row = placement.slot / page.gridColumns
            let column = placement.slot % page.gridColumns
            frames[index] = CGRect(
                x: 24 + CGFloat(column) * 504 / CGFloat(page.gridColumns),
                y: 142 + CGFloat(row) * 712 / CGFloat(page.gridRows),
                width: CGFloat(placement.span.width) * 504 / CGFloat(page.gridColumns) - 12,
                height: CGFloat(placement.span.height) * 712 / CGFloat(page.gridRows) - 12
            )
            placed[index] = true
            return true
        }

        for index in controls.indices {
                if let slot = controls[index].layoutSlot,
                    (0..<(page.gridColumns * page.gridRows)).contains(slot) {
                _ = place(index, slot: slot)
            }
        }
        for index in controls.indices where !placed[index] {
            for slot in 0..<(page.gridColumns * page.gridRows) where !placed[index] {
                _ = place(index, slot: slot)
            }
        }
        return frames
    }

    static func slot(at point: CGPoint, page: RemotePage) -> Int? {
        let column = Int((point.x - 24) * CGFloat(page.gridColumns) / 504)
        let row = Int((point.y - 142) * CGFloat(page.gridRows) / 712)
        guard (0..<page.gridColumns).contains(column),
              (0..<page.gridRows).contains(row) else { return nil }
        return row * page.gridColumns + column
    }
}

private extension RemoteEditorStore {
    var selectedPage: RemotePage? {
        guard let index = selectedPageIndex else { return nil }
        return profile.pages[index]
    }
}