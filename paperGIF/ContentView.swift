import ImageIO
import PhotosUI
import PaperDeviceKit
import SwiftUI
import UniformTypeIdentifiers

enum PaperGIFAppTab: Hashable {
    case remote
    case edit
    case media
    case settings
    case device
}

struct ContentView: View {
    private enum LibraryLocation: String, CaseIterable, Identifiable {
        case phone = "Phone"
        case device = "Device"

        var id: Self { self }
    }

    @StateObject private var bluetoothManager = PaperGIFBluetoothManager()
    @StateObject private var deviceSession = DeviceSession()
    @State private var profileDeviceID: String?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(PaperGIFPhoneRemoteBackground.storageKey) private var phoneBackgroundRaw = PaperGIFPhoneRemoteBackground.off.rawValue

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
    @State private var pendingDeletionID: UUID?
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
    @State private var isLoadingConnectedProfile = false
    @State private var selectedTab = PaperGIFAppTab.remote
    @State private var remotePageID: UUID?
    @State private var remoteTabBarMinimizeRequests = 0

    var body: some View {
        root
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            PaperGIFPhoneRemoteView(
                profile: remoteProfile,
                isVisible: selectedTab == .remote,
                selectedPageID: $remotePageID,
                minimizeTabBarRequests: remoteTabBarMinimizeRequests
            )
                .environment(\.paperGIFEffectTab, .remote)
                .tag(PaperGIFAppTab.remote)
                .tabItem {
                    Label("Remote", systemImage: "av.remote")
                }

            PaperGIFRemoteView(
                profile: $remoteProfile,
                bluetoothManager: bluetoothManager,
                deviceSession: deviceSession,
                locksLayout: (deviceSession.isLoading && deviceSession.descriptor == nil) || isLoadingConnectedProfile
            )
            .environment(\.paperGIFEffectTab, .edit)
            .id(deviceSession.selectedID ?? "offline")
            .tag(PaperGIFAppTab.edit)
            .tabItem {
                Label("Edit", systemImage: "square.and.pencil")
            }

            Group {
                if let descriptor = deviceSession.descriptor, !supportsMedia {
                    PaperGIFEmptyScreen(isVisible: selectedTab == .media) {
                        ContentUnavailableView(
                            "Media Unavailable", systemImage: "photo.badge.exclamationmark",
                            description: Text(descriptor.display == nil
                                ? "This controller has no screen."
                                : "This panel has no compatible media encoder. M5Paper image data is never sent to a different panel.")
                        )
                    }
                } else {
                    mediaView
                }
            }
            .environment(\.paperGIFEffectTab, .media)
            .tag(PaperGIFAppTab.media)
            .tabItem {
                Label("Media", systemImage: "photo.stack")
            }

            PaperGIFSettingsView(
                profile: $remoteProfile,
                bluetoothManager: bluetoothManager,
                deviceSession: deviceSession,
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
                adaptiveCleaning: $adaptiveCleaning,
                effectsLive: selectedTab == .settings
            )
            .environment(\.paperGIFEffectTab, .settings)
            .tag(PaperGIFAppTab.settings)
            .tabItem {
                Label("Settings", systemImage: "slider.horizontal.3")
            }

            PaperGIFDeviceView(
                bluetoothManager: bluetoothManager,
                animation: animation,
                sourceName: sourceName,
                session: deviceSession,
                profile: $remoteProfile,
                effectsLive: selectedTab == .device
            )
            .environment(\.paperGIFEffectTab, .device)
            .tag(PaperGIFAppTab.device)
            .tabItem {
                Label("Device", systemImage: "antenna.radiowaves.left.and.right")
            }
        }
    }

    private var remoteShaderCoversChrome: Bool {
        selectedTab == .remote && (PaperGIFPhoneRemoteBackground(rawValue: phoneBackgroundRaw) ?? .off) != .off
    }

    private var root: some View {
        mediaChrome
    }

    private var profileChrome: some View {
        tabs
        .toolbarBackground(remoteShaderCoversChrome ? .hidden : .visible, for: .tabBar)
        .toolbarColorScheme(selectedTab == .remote ? .dark : colorScheme, for: .tabBar)
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory(isEnabled: selectedTab == .remote && !remoteProfile.pages.isEmpty) {
            PaperGIFRemotePageAccessory(pages: remoteProfile.pages, selectedPageID: $remotePageID) {
                remoteTabBarMinimizeRequests += 1
            }
        }
        .onAppear {
            PaperGIFEffectVisibility.publish(tab: selectedTab, sceneIsActive: scenePhase == .active)
            connectSelectedController()
        }
        .onChange(of: selectedTab) { _, tab in
            PaperGIFEffectVisibility.publish(tab: tab, sceneIsActive: scenePhase == .active)
        }
        .onChange(of: scenePhase) { _, phase in
            PaperGIFEffectVisibility.publish(tab: selectedTab, sceneIsActive: phase == .active)
        }
        .onChange(of: deviceSession.selectedID) {
            selectProfileForDevice()
        }
        .onChange(of: remoteProfile) {
            bluetoothManager.updateRelayProfile(remoteProfile)
        }
        .task(id: deviceSession.isVerified ? profileDeviceID : nil) {
            await loadConnectedAMOLEDProfile()
        }
        .task(id: bluetoothManager.bluetoothDescriptor) {
            await applyConnectedDescriptor()
        }
        .onChange(of: bluetoothManager.remoteProfileFromDevice) {
            applyRemoteProfileFromDevice()
        }
        .task {
            restoreLibrary()
        }
        .task {
            bluetoothManager.startBrowsingNearby()
            defer { bluetoothManager.stopBrowsingNearby() }
            await bluetoothManager.monitorWiFiConnection()
        }
    }

    private var mediaChrome: some View {
        profileChrome
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.image]) { result in
            importMedia(result)
        }
        .onChange(of: selectedPhoto) {
            guard let selectedPhoto else { return }
            importPhoto(selectedPhoto)
        }
        .sheet(item: $pendingMedia) { media in
            mediaEditor(for: media)
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: exportDocument?.isColorImage == true ? .data : .paperGIF,
            defaultFilename: "\(sourceName).\(exportDocument?.isColorImage == true ? "pimg" : "pgif")"
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

    private func connectSelectedController() {
        bluetoothManager.deviceSession = deviceSession
        bluetoothManager.updateRelayProfile(remoteProfile)
        guard !UserDefaults.standard.bool(forKey: PaperGIFSettingKey.editingPhone) else { return }
        if deviceSession.selectedID == nil,
           let id = UserDefaults.standard.string(forKey: "devices.selectedControllerID"),
           deviceSession.records.contains(where: { $0.id == id }) {
            deviceSession.select(id: id)
        }
    }

    private func applyConnectedDescriptor() async {
        guard !UserDefaults.standard.bool(forKey: PaperGIFSettingKey.editingPhone) else { return }
        guard let descriptor = bluetoothManager.bluetoothDescriptor,
              deviceSession.selectedID == nil || deviceSession.selectedID == descriptor.deviceID else { return }
        let address = deviceSession.records.first { $0.id == descriptor.deviceID }?.address ?? ""
        do {
            try await deviceSession.applyDescriptor(descriptor, address: address)
            bluetoothManager.requestDeviceWiFiStatus()
        }
        catch { remoteProfileSaveError = error.localizedDescription }
    }

    private func applyRemoteProfileFromDevice() {
        guard bluetoothManager.legacyBLEPermitted, !bluetoothManager.isEditingPhoneProfile else { return }
        guard let deviceProfile = bluetoothManager.remoteProfileFromDevice,
              deviceProfile != remoteProfile else { return }
        if remoteProfile.updatedAtMilliseconds > deviceProfile.updatedAtMilliseconds {
            bluetoothManager.syncRemoteProfile(remoteProfile)
            return
        }
        if deviceProfile.usesStarterLayout && !remoteProfile.usesStarterLayout {
            var recoveredProfile = remoteProfile
            recoveredProfile.markUpdated()
            do {
                try PaperGIFStorage.saveRemoteProfile(recoveredProfile, deviceID: profileDeviceID)
                remoteProfile = recoveredProfile
                bluetoothManager.syncRemoteProfile(recoveredProfile)
            } catch {
                remoteProfileSaveError = error.localizedDescription
            }
            return
        }
        if deviceProfile.updatedAtMilliseconds == remoteProfile.updatedAtMilliseconds,
           deviceProfile.updatedAtMilliseconds > 0 {
            return
        }
        var reconciledProfile = deviceProfile
        let repairedComputerHosts = reconciledProfile.preserveNumericComputerHosts(from: remoteProfile)
        do {
            if repairedComputerHosts {
                reconciledProfile.markUpdated()
            }
            try PaperGIFStorage.saveRemoteProfile(reconciledProfile, deviceID: profileDeviceID)
            remoteProfile = reconciledProfile
            if repairedComputerHosts, bluetoothManager.connectionState == .connected {
                bluetoothManager.syncRemoteProfile(reconciledProfile)
            }
        } catch {
            remoteProfileSaveError = error.localizedDescription
        }
    }

    private func mediaEditor(for media: PendingMedia) -> some View {
        PaperGIFMediaEditorView(
            name: media.name,
            sourcePreview: media.preview,
            isAnimated: media.isAnimated && colorDisplay == nil,
            initialRecipe: media.recipe,
            isNew: media.savedMediaID == nil,
            startsAtAdjustment: media.startsAtAdjustment,
            colorDisplay: colorDisplay
        ) { recipe in
            pendingMedia = nil
            convert(media, recipe: recipe)
        } onCancel: {
            pendingMedia = nil
        }
    }

    private func selectProfileForDevice() {
        do {
            if let previousID = profileDeviceID {
                try PaperGIFStorage.saveRemoteProfile(remoteProfile, deviceID: previousID)
            } else {
                try PaperGIFStorage.saveRemoteProfile(remoteProfile)
            }
            bluetoothManager.selectedDeviceChanged()
            profileDeviceID = deviceSession.selectedID
            guard let id = profileDeviceID, let descriptor = deviceSession.descriptor else {
                remoteProfile = PaperGIFStorage.loadRemoteProfile()
                return
            }
            UserDefaults.standard.set(id, forKey: "devices.selectedControllerID")
            if let data = deviceSession.profileData,
               let saved = try? JSONDecoder().decode(PaperGIFRemoteProfile.self, from: data) {
                remoteProfile = saved
            } else {
                let migrationKey = "devices.migratedLegacyProfile"
                if descriptor.isM5Paper, !UserDefaults.standard.bool(forKey: migrationKey) {
                    remoteProfile = PaperGIFStorage.loadRemoteProfile()
                    try PaperGIFStorage.saveRemoteProfile(remoteProfile, deviceID: id)
                    UserDefaults.standard.set(true, forKey: migrationKey)
                } else {
                    remoteProfile = PaperGIFStorage.loadRemoteProfile(deviceID: id)
                }
                if descriptor.display == nil, remoteProfile.usesStarterLayout {
                    remoteProfile.pages = []
                }
            }
            if descriptor.capabilities.profileVersions.contains(7) { remoteProfile.version = 7 }
            if remoteProfile.prepareBluetoothEnrollment(for: descriptor,
                savedToken: PaperGIFDeviceCredentials.token(for: id)) {
                try PaperGIFStorage.saveRemoteProfile(remoteProfile, deviceID: id)
                try deviceSession.saveProfile(JSONEncoder().encode(remoteProfile))
            }
            pendingMedia = nil
            selectedPhoto = nil
        } catch { remoteProfileSaveError = error.localizedDescription }
    }

    private func loadConnectedAMOLEDProfile() async {
        guard deviceSession.isVerified, let descriptor = deviceSession.descriptor,
              descriptor.boardID == "paperremote.waveshare-amoled-18-v2",
              profileDeviceID == descriptor.deviceID else { return }
          isLoadingConnectedProfile = true
          defer { isLoadingConnectedProfile = false }
        let snapshot = remoteProfile
        do {
            let data = try await deviceSession.loadProfile(token: PaperGIFDeviceCredentials.token(for: descriptor.deviceID))
            try Task.checkCancellation()
            guard profileDeviceID == descriptor.deviceID else { return }
            let loaded = try PaperGIFRemoteProfile.profileFromDeviceRefresh(data, descriptor: descriptor,
                previousLocalProfile: snapshot, currentLocalProfile: remoteProfile)
            try PaperGIFStorage.saveRemoteProfile(loaded, deviceID: descriptor.deviceID)
            try deviceSession.saveProfile(data)
            bluetoothManager.confirmLoadedRemoteProfile(loaded)
            remoteProfile = loaded
        } catch is CancellationError {
        } catch {
            remoteProfileSaveError = "Could not load the device profile. Your saved profile was not sent: \(error.localizedDescription)"
        }
    }

    private var supportsMedia: Bool {
        deviceSession.descriptor.map { $0.canUseLegacyMedia || $0.canUseColorImages } ?? true
    }

    private var colorDisplay: DeviceDisplay? {
        deviceSession.descriptor?.canUseColorImages == true ? deviceSession.descriptor?.display : nil
    }

    private var mediaView: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Media", selection: $libraryLocation) {
                    ForEach(LibraryLocation.allCases) { location in
                        Text(location.rawValue).tag(location)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 10)

                if libraryLocation == .phone {
                    phoneMediaContent
                } else {
                    deviceLibraryContent
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if libraryLocation == .phone {
                    importControls
                }
            }
            .navigationTitle("Media")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if libraryLocation == .device && bluetoothManager.canAccessDeviceLibrary {
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

    private var phoneMediaContent: some View {
        GeometryReader { proxy in
            if savedMedia.isEmpty && !isConverting {
                PaperGIFEmptyScreen(isVisible: selectedTab == .media) {
                    ContentUnavailableView(
                        "No Media",
                        systemImage: "photo.on.rectangle",
                        description: Text("Add a picture or GIF to begin.")
                    )
                }
            } else {
                let rowHeight = min(176, max(112, (proxy.size.height - 48) / 3))
                List {
                    ForEach(savedMedia) { saved in
                        PaperGIFMediaCard(
                            savedMedia: saved,
                            isSelected: selectedSavedMediaID == saved.id,
                            bluetoothManager: bluetoothManager,
                            descriptor: deviceSession.descriptor,
                            effectsLive: selectedTab == .media,
                            onChangeCrop: { edit(saved, startsAtAdjustment: false) },
                            onEditConversion: { edit(saved, startsAtAdjustment: true) },
                            onExport: { export(saved) },
                            isConfirmingDeletion: Binding(
                                get: { pendingDeletionID == saved.id },
                                set: { pendingDeletionID = $0 ? saved.id : nil }
                            ),
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
                            if selectedTab == .media {
                                PaperGIFTransferBar(fraction: conversionProgress, label: conversionStatus)
                                    .frame(width: 120)
                            } else {
                                ProgressView(value: conversionProgress)
                                    .frame(width: 72)
                            }
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

    @ViewBuilder
    private var deviceLibraryContent: some View {
        if !bluetoothManager.canAccessDeviceLibrary && bluetoothManager.deviceMedia.isEmpty {
            PaperGIFEmptyScreen(isVisible: selectedTab == .media) {
                ContentUnavailableView(
                    "Device Unavailable",
                    systemImage: "antenna.radiowaves.left.and.right.slash",
                    description: Text("Connect to the selected device to manage its library.")
                )
            }
        } else if bluetoothManager.isLoadingDeviceLibrary && bluetoothManager.deviceMedia.isEmpty {
            PaperGIFActivityWait(label: "Loading device library", isLive: selectedTab == .media)
        } else if let error = bluetoothManager.deviceLibraryError {
            PaperGIFEmptyScreen(isVisible: selectedTab == .media) {
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
            }
        } else if bluetoothManager.deviceMedia.isEmpty {
            PaperGIFEmptyScreen(isVisible: selectedTab == .media) {
                ContentUnavailableView(
                    "No Device Media",
                    systemImage: "display",
                    description: Text("Media sent to this device appears here.")
                )
            }
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
        guard supportsMedia else { return }
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
        guard supportsMedia else { return }
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
        guard supportsMedia else { return }
        let colorDisplay = colorDisplay
        isConverting = true
        conversionProgress = 0
        conversionStatus = "Converting 0%"
        applyAsDefaults(recipe)

        Task {
            do {
                let encoded = try await Task.detached(priority: .userInitiated) {
                    try PaperGIFStorage.LoadedMedia(data: Data(), sourceData: media.data, recipe: recipe).convertedData(
                        for: colorDisplay,
                        progress: { progress in
                            Task { @MainActor in
                                conversionProgress = progress
                                conversionStatus = "Converting \(Int((progress * 100).rounded()))%"
                            }
                        }
                    )
                }.value
                let result = colorDisplay == nil ? try PaperGIFAnimation(encoded: encoded) : nil
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
                    saved.isColorImage ? nil : try PaperGIFAnimation(encoded: data)
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
                sourceName = saved.name
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
    static let readableContentTypes: [UTType] = [.paperGIF, .data]

    let data: Data
    var isColorImage: Bool { data.starts(with: Data("PIMG".utf8)) }

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
