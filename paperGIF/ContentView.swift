import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    private enum LibraryLocation: String, CaseIterable, Identifiable {
        case phone = "Phone"
        case device = "Device"

        var id: Self { self }
    }

    @StateObject private var bluetoothManager = PaperGIFBluetoothManager()

    @AppStorage(PaperGIFSettingKey.monochromeMode) private var monochromeMode = PaperGIFMonochromeMode.threshold
    @AppStorage(PaperGIFSettingKey.threshold) private var threshold = 128.0
    @AppStorage(PaperGIFSettingKey.monochromeLevels) private var monochromeLevels = 16
    @AppStorage(PaperGIFSettingKey.halftoneDotSpacing) private var halftoneDotSpacing = 8
    @AppStorage(PaperGIFSettingKey.halftoneAngle) private var halftoneAngle = 45
    @AppStorage(PaperGIFSettingKey.halftoneDotGain) private var halftoneDotGain = 0
    @AppStorage(PaperGIFSettingKey.maximumFramesPerSecond) private var maximumFramesPerSecond = 10.0
    @AppStorage(PaperGIFSettingKey.scanRateHz) private var scanRateHz = 60
    @AppStorage(PaperGIFSettingKey.transitionScans) private var transitionScans = 1
    @AppStorage(PaperGIFSettingKey.cleanRefreshInterval) private var cleanRefreshInterval = 120
    @AppStorage(PaperGIFSettingKey.adaptiveCleaning) private var adaptiveCleaning = true

    @State private var animation: PaperGIFAnimation?
    @State private var exportDocument: PaperGIFDocument?
    @State private var sourceName = "Media"
    @State private var savedMedia: [PaperGIFStorage.SavedMedia] = []
    @State private var selectedSavedMediaID: UUID?
    @State private var libraryLocation = LibraryLocation.phone
    @State private var pendingMedia: PendingMedia?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isImporting = false
    @State private var isExporting = false
    @State private var isConverting = false
    @State private var conversionProgress = 0.0
    @State private var conversionStatus = "Converting frames…"
    @State private var errorMessage: String?
    @State private var remoteProfileSaveError: String?
    @State private var remoteProfile = PaperGIFStorage.loadRemoteProfile()

    var body: some View {
        TabView {
            PaperGIFRemoteView(
                profile: $remoteProfile,
                bluetoothManager: bluetoothManager
            )
            .tabItem {
                Label("Remote", systemImage: "rectangle.grid.2x2")
            }

            conversionView
                .tabItem {
                    Label("Convert", systemImage: "rectangle.stack.badge.play")
                }

            libraryView
                .tabItem {
                    Label("Library", systemImage: "photo.stack")
                }

            PaperGIFSettingsView(
                monochromeMode: $monochromeMode,
                threshold: $threshold,
                monochromeLevels: $monochromeLevels,
                halftoneDotSpacing: $halftoneDotSpacing,
                halftoneAngle: $halftoneAngle,
                halftoneDotGain: $halftoneDotGain,
                maximumFramesPerSecond: $maximumFramesPerSecond,
                scanRateHz: $scanRateHz,
                transitionScans: $transitionScans,
                cleanRefreshInterval: $cleanRefreshInterval,
                adaptiveCleaning: $adaptiveCleaning
            )
            .tabItem {
                Label("Settings", systemImage: "slider.horizontal.3")
            }

            PaperGIFDeviceView(
                bluetoothManager: bluetoothManager,
                animation: animation,
                sourceName: sourceName
            )
            .tabItem {
                Label("Device", systemImage: "antenna.radiowaves.left.and.right")
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.image]) { result in
            importMedia(result)
        }
        .onChange(of: selectedPhoto) {
            guard let selectedPhoto else { return }
            importPhoto(selectedPhoto)
        }
        .onChange(of: bluetoothManager.remoteProfileFromDevice) {
            guard let deviceProfile = bluetoothManager.remoteProfileFromDevice,
                  deviceProfile != remoteProfile else { return }
            do {
                try PaperGIFStorage.saveRemoteProfile(deviceProfile)
                remoteProfile = deviceProfile
            } catch {
                remoteProfileSaveError = error.localizedDescription
            }
        }
        .task {
            restoreLibrary()
        }
        .task {
            await bluetoothManager.monitorWiFiConnection()
        }
        .sheet(item: $pendingMedia) { media in
            PaperGIFMediaEditorView(
                name: media.name,
                sourcePreview: media.preview,
                isAnimated: media.isAnimated,
                initialRecipe: media.recipe,
                isNew: media.savedMediaID == nil,
                startsAtAdjustment: media.startsAtAdjustment
            ) { recipe in
                pendingMedia = nil
                convert(media, recipe: recipe)
            } onCancel: {
                pendingMedia = nil
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .paperGIF,
            defaultFilename: "\(sourceName).pgif"
        ) { result in
            if case .failure(let error) = result {
                errorMessage = error.localizedDescription
            }
        }
        .alert("Couldn’t Convert Media", isPresented: errorIsPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
        .alert("Couldn’t Save Remote", isPresented: Binding(
            get: { remoteProfileSaveError != nil },
            set: { if !$0 { remoteProfileSaveError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(remoteProfileSaveError ?? "Unknown error")
        }
    }

    private var conversionView: some View {
        NavigationStack {
            GeometryReader { proxy in
                if savedMedia.isEmpty && !isConverting {
                    ContentUnavailableView(
                        "No Media",
                        systemImage: "photo.on.rectangle",
                        description: Text("Add a picture or GIF to begin.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    let rowHeight = min(176, max(112, (proxy.size.height - 48) / 3))
                    List {
                        ForEach(savedMedia) { saved in
                            PaperGIFMediaCard(
                                savedMedia: saved,
                                isSelected: selectedSavedMediaID == saved.id,
                                bluetoothManager: bluetoothManager,
                                onChangeCrop: { edit(saved, startsAtAdjustment: false) },
                                onEditConversion: { edit(saved, startsAtAdjustment: true) },
                                onExport: { export(saved) },
                                onDelete: { delete([saved]) }
                            )
                            .frame(height: rowHeight)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                select(saved)
                            }
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .overlay(alignment: .top) {
                        if isConverting {
                        HStack(spacing: 10) {
                            ProgressView(value: conversionProgress)
                                .frame(width: 72)
                            Text(conversionStatus)
                                .monospacedDigit()
                        }
                        .font(.footnote)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.regularMaterial, in: Capsule())
                            .padding(.top, 8)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                importControls
            }
            .navigationTitle("Convert")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var importControls: some View {
        HStack(spacing: 10) {
            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Label("Photos", systemImage: "photo.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isConverting)

            Button {
                isImporting = true
            } label: {
                Label("Files", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isConverting)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var libraryView: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Library", selection: $libraryLocation) {
                    ForEach(LibraryLocation.allCases) { location in
                        Text(location.rawValue).tag(location)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 10)

                if libraryLocation == .phone {
                    phoneLibraryContent
                } else {
                    deviceLibraryContent
                }
            }
            .navigationTitle("Library")
            .toolbar {
                if libraryLocation == .phone && !savedMedia.isEmpty {
                    EditButton()
                } else if libraryLocation == .device && bluetoothManager.canAccessDeviceLibrary {
                    Button {
                        bluetoothManager.refreshDeviceLibrary()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(bluetoothManager.isLoadingDeviceLibrary || bluetoothManager.isTransferring)
                }
            }
            .onChange(of: libraryLocation) {
                if libraryLocation == .device {
                    bluetoothManager.refreshDeviceLibrary()
                }
            }
        }
    }

    @ViewBuilder
    private var phoneLibraryContent: some View {
        if savedMedia.isEmpty {
            ContentUnavailableView(
                "No Saved Media",
                systemImage: "photo.stack",
                description: Text("Converted pictures and GIFs appear here.")
            )
        } else {
            List {
                ForEach(savedMedia) { saved in
                    Button {
                        select(saved)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "photo")
                                .font(.title2)
                                .frame(width: 32)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(saved.name)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text(saved.savedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if selectedSavedMediaID == saved.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .onDelete(perform: deleteSavedMedia)
            }
        }
    }

    @ViewBuilder
    private var deviceLibraryContent: some View {
        if !bluetoothManager.canAccessDeviceLibrary && bluetoothManager.deviceMedia.isEmpty {
            ContentUnavailableView(
                "Device Unavailable",
                systemImage: "antenna.radiowaves.left.and.right.slash",
                description: Text("Connect to the M5Paper to manage its library.")
            )
        } else if bluetoothManager.isLoadingDeviceLibrary && bluetoothManager.deviceMedia.isEmpty {
            ProgressView("Loading device library")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = bluetoothManager.deviceLibraryError {
            ContentUnavailableView {
                Label("Couldn’t Load Device", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") {
                    bluetoothManager.refreshDeviceLibrary()
                }
                .buttonStyle(.borderedProminent)
            }
        } else if bluetoothManager.deviceMedia.isEmpty {
            ContentUnavailableView(
                "No Device Media",
                systemImage: "display",
                description: Text("Media sent to the M5Paper appears here.")
            )
        } else {
            List(bluetoothManager.deviceMedia) { media in
                Button {
                    bluetoothManager.selectDeviceMedia(media)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: media.frameCount == 1 ? "photo" : "photo.stack")
                            .font(.title2)
                            .frame(width: 32)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(media.name)
                                .font(.headline)
                            Text("\(media.frameCount) frame\(media.frameCount == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if bluetoothManager.deletingDeviceMediaIndex == media.index {
                            ProgressView()
                        } else if media.isActive {
                            Image(systemName: "display")
                                .foregroundStyle(.tint)
                                .accessibilityLabel("Currently displayed")
                        }
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .disabled(
                    !bluetoothManager.canAccessDeviceLibrary ||
                    bluetoothManager.isLoadingDeviceLibrary ||
                    bluetoothManager.deletingDeviceMediaIndex != nil
                )
                .swipeActions {
                    Button("Delete", role: .destructive) {
                        bluetoothManager.deleteDeviceMedia(media)
                    }
                    .disabled(
                        bluetoothManager.connectionState != .connected ||
                        bluetoothManager.deletingDeviceMediaIndex != nil
                    )
                }
            }
        }
    }

    private var playbackConfiguration: PaperGIFPlaybackConfiguration {
        PaperGIFPlaybackConfiguration(
            scanRateHz: UInt16(clamping: scanRateHz),
            transitionScans: UInt8(clamping: transitionScans),
            cleanRefreshInterval: UInt16(clamping: cleanRefreshInterval),
            adaptiveCleaning: adaptiveCleaning
        )
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func importMedia(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let hasSecurityAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let data = try Data(contentsOf: url)
            pendingMedia = PendingMedia(
                name: url.deletingPathExtension().lastPathComponent,
                data: data,
                preview: try PaperGIFEncoder.previewImage(from: data),
                isAnimated: isAnimated(data),
                recipe: defaultRecipe
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importPhoto(_ item: PhotosPickerItem) {
        Task {
            defer { selectedPhoto = nil }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw PaperGIFError.invalidMedia
                }
                pendingMedia = PendingMedia(
                    name: "Photo",
                    data: data,
                    preview: try PaperGIFEncoder.previewImage(from: data),
                    isAnimated: isAnimated(data),
                    recipe: defaultRecipe
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func convert(_ media: PendingMedia, recipe: PaperGIFConversionRecipe) {
        isConverting = true
        conversionProgress = 0
        conversionStatus = "Converting 0%"
        applyAsDefaults(recipe)

        Task {
            do {
                let conversion = try await Task.detached(priority: .userInitiated) {
                    let result = try PaperGIFEncoder.encode(
                        mediaData: media.data,
                        monochromeMode: recipe.monochromeMode,
                        threshold: UInt8(clamping: Int(recipe.threshold.rounded())),
                        monochromeLevels: recipe.monochromeLevels,
                        halftoneDotSpacing: recipe.halftoneDotSpacing,
                        halftoneAngle: recipe.halftoneAngle,
                        halftoneDotGain: recipe.halftoneDotGain,
                        maximumFramesPerSecond: recipe.maximumFramesPerSecond,
                        cropRect: recipe.cropRect,
                        rotationQuarterTurns: recipe.rotationQuarterTurns,
                        playbackConfiguration: recipe.playbackConfiguration,
                        progress: { progress in
                            Task { @MainActor in
                                conversionProgress = progress
                                conversionStatus = "Converting \(Int((progress * 100).rounded()))%"
                            }
                        }
                    )
                    return (result, result.encoded)
                }.value
                let result = conversion.0
                let encoded = conversion.1
                conversionProgress = 1
                conversionStatus = "Saving"
                let saved = try await Task.detached(priority: .utility) {
                    try PaperGIFStorage.save(
                        id: media.savedMediaID,
                        name: media.name,
                        data: encoded,
                        sourceData: media.data,
                        recipe: recipe
                    )
                }.value
                savedMedia.removeAll { $0.id == saved.id }
                savedMedia.insert(saved, at: 0)
                animation = result
                sourceName = saved.name
                selectedSavedMediaID = saved.id
                exportDocument = PaperGIFDocument(data: encoded)
            } catch {
                errorMessage = error.localizedDescription
            }
            isConverting = false
        }
    }

    private func restoreLibrary() {
        Task {
            do {
                let storedItems = try await Task.detached(priority: .utility) {
                    try PaperGIFStorage.loadAll()
                }.value
                savedMedia = storedItems
                if let latest = savedMedia.first {
                    select(latest)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func select(_ saved: PaperGIFStorage.SavedMedia) {
        Task {
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try PaperGIFStorage.loadData(saved)
                }.value
                let restoredAnimation = try await Task.detached(priority: .userInitiated) {
                    try PaperGIFAnimation(encoded: data)
                }.value
                sourceName = saved.name
                animation = restoredAnimation
                exportDocument = PaperGIFDocument(data: data)
                selectedSavedMediaID = saved.id
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func deleteSavedMedia(at offsets: IndexSet) {
        delete(offsets.map { savedMedia[$0] })
    }

    private func delete(_ deletedItems: [PaperGIFStorage.SavedMedia]) {
        let deletedIDs = Set(deletedItems.map(\.id))
        savedMedia.removeAll { deletedIDs.contains($0.id) }
        if deletedItems.contains(where: { $0.id == selectedSavedMediaID }) {
            if let next = savedMedia.first {
                select(next)
            } else {
                animation = nil
                exportDocument = nil
                selectedSavedMediaID = nil
            }
        }

        Task {
            do {
                try await Task.detached(priority: .utility) {
                    for item in deletedItems {
                        try PaperGIFStorage.delete(item)
                    }
                }.value
            } catch {
                errorMessage = error.localizedDescription
                restoreLibrary()
            }
        }
    }

    private var defaultRecipe: PaperGIFConversionRecipe {
        PaperGIFConversionRecipe(
            cropRect: nil,
            rotationQuarterTurns: 0,
            monochromeMode: monochromeMode,
            threshold: threshold,
            monochromeLevels: monochromeLevels,
            halftoneDotSpacing: halftoneDotSpacing,
            halftoneAngle: halftoneAngle,
            halftoneDotGain: halftoneDotGain,
            maximumFramesPerSecond: maximumFramesPerSecond,
            scanRateHz: scanRateHz,
            transitionScans: transitionScans,
            cleanRefreshInterval: cleanRefreshInterval,
            adaptiveCleaning: adaptiveCleaning
        )
    }

    private func edit(_ saved: PaperGIFStorage.SavedMedia, startsAtAdjustment: Bool) {
        guard saved.isEditable else { return }
        Task {
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try PaperGIFStorage.load(saved)
                }.value
                guard let sourceData = loaded.sourceData, let recipe = loaded.recipe else { return }
                let preview = try await Task.detached(priority: .userInitiated) {
                    try PaperGIFEncoder.previewImage(from: sourceData)
                }.value
                pendingMedia = PendingMedia(
                    savedMediaID: saved.id,
                    name: saved.name,
                    data: sourceData,
                    preview: preview,
                    isAnimated: isAnimated(sourceData),
                    recipe: recipe,
                    startsAtAdjustment: startsAtAdjustment
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func export(_ saved: PaperGIFStorage.SavedMedia) {
        Task {
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try PaperGIFStorage.loadData(saved)
                }.value
                exportDocument = PaperGIFDocument(data: data)
                isExporting = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func isAnimated(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 1
    }

    private func applyAsDefaults(_ recipe: PaperGIFConversionRecipe) {
        monochromeMode = recipe.monochromeMode
        threshold = recipe.threshold
        monochromeLevels = recipe.monochromeLevels
        halftoneDotSpacing = recipe.halftoneDotSpacing
        halftoneAngle = recipe.halftoneAngle
        halftoneDotGain = recipe.halftoneDotGain
        maximumFramesPerSecond = recipe.maximumFramesPerSecond
        scanRateHz = recipe.scanRateHz
        transitionScans = recipe.transitionScans
        cleanRefreshInterval = recipe.cleanRefreshInterval
        adaptiveCleaning = recipe.adaptiveCleaning
    }
}

private struct PendingMedia: Identifiable {
    let id = UUID()
    var savedMediaID: UUID?
    let name: String
    let data: Data
    let preview: CGImage
    let isAnimated: Bool
    let recipe: PaperGIFConversionRecipe
    var startsAtAdjustment = false
}

private struct PaperGIFDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.paperGIF]

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private extension UTType {
    static let paperGIF = UTType(exportedAs: "app.papergif.animation", conformingTo: .data)
}

#Preview {
    ContentView()
}
