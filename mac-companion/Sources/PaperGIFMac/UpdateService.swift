import AppKit
import CryptoKit
import Foundation
import Security
import UserNotifications

struct ReleaseManifest: Decodable, Equatable {
    struct Asset: Decodable, Equatable {
        let name: String
        let sha256: String
        let size: Int
    }

    let version: String
    let mac: Asset?
    let windows: Asset?
    let firmware: Asset?
}

struct AvailableRelease: Equatable {
    let version: String
    let notes: String
    let pageURL: URL?
    let manifest: ReleaseManifest
    let downloads: [String: URL]
}

enum UpdateError: LocalizedError {
    case noReleases
    case invalidRelease(String)
    case downloadFailed(String)
    case checksumMismatch(String)
    case notInstallable(String)
    case signatureMismatch
    case deviceUnreachable
    case deviceRejected(String)
    case deviceDidNotRestart

    var errorDescription: String? {
        switch self {
        case .noReleases: "No paperGIF releases have been published yet."
        case .invalidRelease(let detail): "The latest release is incomplete: \(detail)"
        case .downloadFailed(let name): "Could not download \(name)."
        case .checksumMismatch(let name): "\(name) failed its checksum and was discarded."
        case .notInstallable(let detail): detail
        case .signatureMismatch: "The downloaded app is not signed by the same developer as this copy, so it was not installed."
        case .deviceUnreachable: "Could not reach the M5Paper. Wake it and make sure it is on this Mac's network."
        case .deviceRejected(let detail): "The M5Paper rejected the firmware: \(detail)"
        case .deviceDidNotRestart: "The firmware was sent, but the M5Paper did not come back with the new version."
        }
    }
}

enum SoftwareVersion {
    static func components(_ version: String) -> [Int] {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let unprefixed = trimmed.hasPrefix("v") || trimmed.hasPrefix("V") ? String(trimmed.dropFirst()) : trimmed
        return unprefixed.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        var lhs = components(candidate)
        var rhs = components(current)
        let count = max(lhs.count, rhs.count)
        lhs += Array(repeating: 0, count: count - lhs.count)
        rhs += Array(repeating: 0, count: count - rhs.count)
        return rhs.lexicographicallyPrecedes(lhs)
    }
}

enum ReleaseClient {
    static let repository = "Levi-5k/PaperRemote"
    static let manifestName = "papergif-release.json"

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let htmlURL: URL?
        let body: String?
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case body
            case assets
        }
    }

    static func latest(session: URLSession = .shared) async throws -> AvailableRelease {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw UpdateError.noReleases
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("paperGIF-Mac", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { throw UpdateError.noReleases }
        guard status == 200 else { throw UpdateError.downloadFailed("the release list (HTTP \(status))") }
        let (tag, notes, pageURL, downloads) = try parseRelease(data)
        guard let manifestURL = downloads[manifestName] else {
            throw UpdateError.invalidRelease("\(manifestName) is missing")
        }
        var manifestRequest = URLRequest(url: manifestURL)
        manifestRequest.timeoutInterval = 20
        let (manifestData, manifestResponse) = try await session.data(for: manifestRequest)
        guard (manifestResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.downloadFailed(manifestName)
        }
        let manifest = try decodeManifest(manifestData)
        guard SoftwareVersion.components(manifest.version) == SoftwareVersion.components(tag) else {
            throw UpdateError.invalidRelease("tag \(tag) does not match manifest version \(manifest.version)")
        }
        return AvailableRelease(
            version: manifest.version,
            notes: notes,
            pageURL: pageURL,
            manifest: manifest,
            downloads: downloads
        )
    }

    static func parseRelease(_ data: Data) throws -> (String, String, URL?, [String: URL]) {
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        var downloads: [String: URL] = [:]
        for asset in release.assets where isTrustedDownload(asset.browserDownloadURL) {
            downloads[asset.name] = asset.browserDownloadURL
        }
        return (release.tagName, release.body ?? "", release.htmlURL, downloads)
    }

    static func decodeManifest(_ data: Data) throws -> ReleaseManifest {
        let manifest = try JSONDecoder().decode(ReleaseManifest.self, from: data)
        for asset in [manifest.mac, manifest.windows, manifest.firmware].compactMap({ $0 }) {
            guard asset.sha256.count == 64, asset.sha256.allSatisfy(\.isHexDigit), asset.size > 0,
                  !asset.name.contains("/") else {
                throw UpdateError.invalidRelease("asset \(asset.name) has an invalid checksum or size")
            }
        }
        return manifest
    }

    static func isTrustedDownload(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "github.com"
    }

    /// Downloads an asset and verifies its manifest size and SHA-256 before returning the file.
    static func download(
        _ asset: ReleaseManifest.Asset,
        from release: AvailableRelease,
        session: URLSession = .shared
    ) async throws -> URL {
        guard let url = release.downloads[asset.name] else {
            throw UpdateError.invalidRelease("\(asset.name) is not attached to the release")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let (temporaryURL, response) = try await session.download(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw UpdateError.downloadFailed(asset.name)
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("paperGIF-\(UUID().uuidString)-\(asset.name)")
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        guard size == asset.size, try sha256Hex(of: destination) == asset.sha256.lowercased() else {
            try? FileManager.default.removeItem(at: destination)
            throw UpdateError.checksumMismatch(asset.name)
        }
        return destination
    }

    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum FirmwareInstaller {
    private struct DeviceStatus: Decodable {
        let device: String
        let firmware: String?
    }

    private struct DeviceError: Decodable {
        let error: String?
    }

    /// Firmware without version reporting predates the /firmware endpoint and can only be updated over USB.
    static let usbOnlyVersion = "0.0.0"

    /// Returns nil when the device is unreachable.
    static func installedVersion(at address: String) async -> String? {
        guard let url = try? RemoteEditorStore.deviceURL(from: address, path: "/status") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let status = try? JSONDecoder().decode(DeviceStatus.self, from: data),
              status.device == "paperGIF" else { return nil }
        return status.firmware ?? usbOnlyVersion
    }

    static func multipartBody(firmware: Data, boundary: String) -> Data {
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"firmware\"; filename=\"firmware.bin\"\r\n".utf8))
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(firmware)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    static func install(firmwareAt fileURL: URL, version: String, address: String, token: String) async throws {
        let firmware = try Data(contentsOf: fileURL)
        let md5 = Insecure.MD5.hash(data: firmware).map { String(format: "%02x", $0) }.joined()
        let boundary = "paperGIF-\(UUID().uuidString)"
        var request = URLRequest(url: try RemoteEditorStore.deviceURL(from: address, path: "/firmware"))
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(String(firmware.count), forHTTPHeaderField: "X-PGIF-Size")
        request.setValue(md5, forHTTPHeaderField: "X-PGIF-MD5")
        let body = multipartBody(firmware: firmware, boundary: boundary)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.upload(for: request, from: body)
        } catch {
            throw UpdateError.deviceUnreachable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let detail = (try? JSONDecoder().decode(DeviceError.self, from: data))?.error
            throw UpdateError.deviceRejected(status == 401 ? "this Mac is not paired with it" : detail ?? "HTTP \(status)")
        }
        let deadline = Date().addingTimeInterval(90)
        try await Task.sleep(for: .seconds(4))
        while Date() < deadline {
            if let installed = await installedVersion(at: address),
               !SoftwareVersion.isNewer(version, than: installed) {
                return
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw UpdateError.deviceDidNotRestart
    }
}

@MainActor
final class UpdateService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    struct FirmwareTarget {
        let address: String
        let token: String
    }

    enum Activity: Equatable {
        case checking
        case downloading(String)
        case installing(String)

        var title: String {
            switch self {
            case .checking: "Checking for Updates…"
            case .downloading(let item): "Downloading \(item)…"
            case .installing(let item): "Installing \(item)…"
            }
        }
    }

    @Published private(set) var release: AvailableRelease?
    /// nil when the M5Paper could not be reached.
    @Published private(set) var deviceFirmware: String?
    @Published private(set) var activity: Activity?
    @Published private(set) var problem: String?
    @Published private(set) var notice: String?

    var menuChanged: ((_ title: String, _ enabled: Bool) -> Void)?
    var firmwareTarget: (() -> FirmwareTarget?)?
    var deviceAddressFound: ((String) -> Void)?
    var openUpdates: (() -> Void)?

    private var timer: Timer?
    private static let notifiedVersionKey = "UpdateService.notifiedVersion"

    var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var appUpdate: AvailableRelease? {
        guard let release, release.manifest.mac != nil,
              SoftwareVersion.isNewer(release.version, than: currentAppVersion) else { return nil }
        return release
    }

    var firmwareUpdate: AvailableRelease? {
        guard let release, let deviceFirmware, release.manifest.firmware != nil,
              SoftwareVersion.isNewer(release.version, than: deviceFirmware) else { return nil }
        return release
    }

    var firmwareNeedsUSB: Bool {
        firmwareUpdate != nil && deviceFirmware == FirmwareInstaller.usbOnlyVersion
    }

    func startAutomaticChecks() {
        UNUserNotificationCenter.current().delegate = self
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            await self?.refresh(notify: true)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh(notify: true) }
        }
    }

    /// Checks GitHub and the M5Paper without interrupting; results show in the menu and editor.
    func refresh(notify: Bool = false) async {
        guard activity == nil else { return }
        setActivity(.checking)
        defer { setActivity(nil) }
        do {
            release = try await ReleaseClient.latest()
            problem = nil
        } catch {
            DiagnosticLog.error("Update check failed", error: error)
            if release == nil { problem = "Could not check for updates: \(error.localizedDescription)" }
        }
        await refreshDevice()
        if notify { notifyIfNeeded() }
    }

    func refreshDevice() async {
        guard let target = firmwareTarget?() else {
            deviceFirmware = nil
            return
        }
        if let version = await FirmwareInstaller.installedVersion(at: target.address) {
            deviceFirmware = version
            return
        }
        // The saved address goes stale when the M5Paper gets a new IP; find it again.
        for device in await DeviceDiscovery.probeNetwork(preferredAddress: target.address) {
            if let version = await FirmwareInstaller.installedVersion(at: device.address) {
                deviceAddressFound?(device.address)
                deviceFirmware = version
                return
            }
        }
        deviceFirmware = nil
    }

    func dismissMessages() {
        problem = nil
        notice = nil
    }

    /// Menu command: checks, then asks about each available update.
    func checkForUpdates(userInitiated: Bool) async {
        await refresh()
        guard let release else {
            if userInitiated, let problem { inform(title: "Could Not Check for Updates", message: problem) }
            return
        }
        if let appUpdate, confirm(
            title: "paperGIF Mac \(appUpdate.version) Is Available",
            message: "You have \(currentAppVersion). paperGIF Mac will download, verify, install, and relaunch.\n\n\(appUpdate.notes)",
            action: "Install and Relaunch"
        ) {
            await installAppUpdate()
            if let problem { inform(title: "Could Not Install the Update", message: problem) }
            return
        }
        if firmwareNeedsUSB {
            inform(
                title: "M5Paper Needs a One-Time USB Update",
                message: "This M5Paper's firmware is too old to update over Wi-Fi. Flash firmware \(release.version) over USB once; later updates install from here."
            )
        } else if let firmwareUpdate, let deviceFirmware, confirm(
            title: "M5Paper Firmware \(firmwareUpdate.version) Is Available",
            message: "The M5Paper has \(deviceFirmware). It shows its progress on screen and restarts when the update finishes.",
            action: "Update M5Paper"
        ) {
            await installFirmwareUpdate()
            if let problem {
                inform(title: "Could Not Update the M5Paper", message: problem)
            } else if let notice {
                inform(title: "M5Paper Updated", message: notice)
            }
        } else if userInitiated && appUpdate == nil && firmwareUpdate == nil {
            let firmwareLine = deviceFirmware.map { "M5Paper firmware \($0)" }
                ?? "M5Paper not found on the network, so its firmware was not checked"
            inform(
                title: "paperGIF Is Up to Date",
                message: "paperGIF Mac \(currentAppVersion)\n\(firmwareLine)\nLatest release: \(release.version)"
            )
        }
    }

    func installAppUpdate() async {
        guard activity == nil, let release = appUpdate, let asset = release.manifest.mac else { return }
        dismissMessages()
        setActivity(.downloading("paperGIF Mac \(release.version)"))
        defer { setActivity(nil) }
        do {
            try await installApp(asset, from: release)
        } catch {
            DiagnosticLog.error("App update failed", error: error)
            problem = error.localizedDescription
        }
    }

    func installFirmwareUpdate() async {
        guard activity == nil, let release = firmwareUpdate, !firmwareNeedsUSB,
              let asset = release.manifest.firmware, let target = firmwareTarget?() else { return }
        dismissMessages()
        defer { setActivity(nil) }
        do {
            setActivity(.downloading("M5Paper firmware \(release.version)"))
            let file = try await ReleaseClient.download(asset, from: release)
            defer { try? FileManager.default.removeItem(at: file) }
            setActivity(.installing("M5Paper firmware \(release.version)"))
            try await FirmwareInstaller.install(
                firmwareAt: file,
                version: release.version,
                address: target.address,
                token: target.token
            )
            DiagnosticLog.info("M5Paper firmware updated to \(release.version)")
            deviceFirmware = release.version
            notice = "The M5Paper restarted with firmware \(release.version)."
        } catch {
            DiagnosticLog.error("Firmware update failed", error: error)
            problem = error.localizedDescription
        }
    }

    private func setActivity(_ newActivity: Activity?) {
        activity = newActivity
        if let newActivity {
            menuChanged?(newActivity.title, false)
        } else if let version = (appUpdate ?? firmwareUpdate)?.version {
            menuChanged?("Install Update \(version)…", true)
        } else {
            menuChanged?("Check for Updates…", true)
        }
    }

    private func notifyIfNeeded() {
        guard let release = appUpdate ?? (firmwareNeedsUSB ? nil : firmwareUpdate),
              UserDefaults.standard.string(forKey: Self.notifiedVersionKey) != release.version else { return }
        UserDefaults.standard.set(release.version, forKey: Self.notifiedVersionKey)
        let center = UNUserNotificationCenter.current()
        let body = appUpdate != nil
            ? "paperGIF Mac \(release.version) is ready to install."
            : "M5Paper firmware \(release.version) is ready to install."
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "paperGIF Update Available"
            content.body = body
            center.add(UNNotificationRequest(identifier: "papergif-update", content: content, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in self.openUpdates?() }
        completionHandler()
    }

    private func installApp(_ asset: ReleaseManifest.Asset, from release: AvailableRelease) async throws {
        let appURL = Bundle.main.bundleURL
        guard appURL.pathExtension == "app" else {
            throw UpdateError.notInstallable("Updates can only be installed into the packaged paperGIF Mac.app.")
        }
        let parent = appURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError.notInstallable("paperGIF Mac cannot write to \(parent.path).")
        }
        let archive = try await ReleaseClient.download(asset, from: release)
        defer { try? FileManager.default.removeItem(at: archive) }
        setActivity(.installing("paperGIF Mac \(release.version)"))
        let staging = parent.appendingPathComponent(".paperGIF-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            let stagedApp = try await Self.extractApp(archive, into: staging)
            try Self.verifySignature(of: stagedApp, matches: appURL)
            let stagedVersion = Bundle(url: stagedApp)?
                .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            guard SoftwareVersion.components(stagedVersion) == SoftwareVersion.components(release.version) else {
                throw UpdateError.invalidRelease("the app inside reports version \(stagedVersion)")
            }
            try Self.launchReplacement(of: appURL, with: stagedApp, staging: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        DiagnosticLog.info("Installing paperGIF Mac \(release.version) and relaunching")
        NSApp.terminate(nil)
    }

    private static func extractApp(_ archive: URL, into staging: URL) async throws -> URL {
        let result = try await Task.detached {
            try BoundedProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: ["-x", "-k", archive.path, staging.path],
                timeout: 120
            )
        }.value
        guard result.status == 0, !result.timedOut else {
            throw UpdateError.invalidRelease("the app archive could not be extracted")
        }
        let apps = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "app" }
        guard apps.count == 1 else { throw UpdateError.invalidRelease("the archive must contain one app") }
        return apps[0]
    }

    nonisolated static func verifySignature(of candidate: URL, matches current: URL) throws {
        var currentCode: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(current as CFURL, [], &currentCode) == errSecSuccess,
              let currentCode,
              SecCodeCopyDesignatedRequirement(currentCode, [], &requirement) == errSecSuccess,
              let requirement else {
            throw UpdateError.notInstallable("This copy of paperGIF Mac is not signed, so updates cannot be verified.")
        }
        var candidateCode: SecStaticCode?
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard SecStaticCodeCreateWithPath(candidate as CFURL, [], &candidateCode) == errSecSuccess,
              let candidateCode,
              SecStaticCodeCheckValidity(candidateCode, flags, requirement) == errSecSuccess else {
            throw UpdateError.signatureMismatch
        }
    }

    private static func launchReplacement(of target: URL, with staged: URL, staging: URL) throws {
        // Paths are passed as positional arguments, never interpolated into the script.
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        backup="$2.previous"
        rm -rf "$backup"
        if mv "$2" "$backup"; then
            if mv "$3" "$2"; then rm -rf "$backup"; else mv "$backup" "$2"; fi
        fi
        rm -rf "$4"
        open "$2"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", script, "paperGIF-updater",
            String(ProcessInfo.processInfo.processIdentifier),
            target.path, staged.path, staging.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private func confirm(title: String, message: String, action: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Later")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func inform(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
