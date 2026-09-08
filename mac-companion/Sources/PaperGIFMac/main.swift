import AppKit
import ApplicationServices
import CoreAudio
import CoreGraphics
import Darwin
import Foundation
import IOKit.hidsystem
import Network

private struct RemoteRequest: Decodable {
    let type: String
    let host: String?
    let text: String
    let value: Int
    let valueTenths: Int?
    let modifiers: [String]
}

private typealias RemoteActionResult = (succeeded: Bool, changed: Bool)

private struct PairingRequest: Decodable {
    let deviceName: String
}

private struct TextSourceBatchRequest: Decodable {
    let items: [TextSourceRequest]
}

private struct TextSourceRequest: Decodable {
    let id: String
    let source: String
    let sourceText: String
    let placeholder: String
}

private struct TextSourceBatchResponse: Encodable {
    let items: [TextSourceResponse]
}

private struct TextSourceResponse: Encodable {
    let id: String
    let text: String
    let available: Bool
    let value: Int?

    init(id: String, text: String, available: Bool, value: Int? = nil) {
        self.id = id
        self.text = text
        self.available = available
        self.value = value
    }
}

private struct InstalledApplication: Encodable {
    let name: String
    let path: String
    let iconBitmap: String?
}

private struct CompanionConfiguration: Codable {
    var token: String
    var port: UInt16
    var allowedScripts: [String]
    var pairedDevices: [String]? = nil

    static let initial = CompanionConfiguration(
        token: UUID().uuidString,
        port: 43_821,
        allowedScripts: []
    )
}

private final class CompanionServer {
    private static let maximumConnections = 16
    private static let requestDeadline: TimeInterval = 10

    private let port: UInt16
    private let token: String
    private let pairingHandler: (PairingRequest) -> Bool
    private let actionHandler: (RemoteRequest) -> RemoteActionResult
    private let netHomeUnitsHandler: () -> [NetHomeUnit]?
    private let textSourceHandler: (TextSourceBatchRequest, String?) -> TextSourceBatchResponse
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var respondingConnections: Set<ObjectIdentifier> = []
    private let queue = DispatchQueue(label: "paperGIF.companion.server")
    private let workQueue = DispatchQueue(label: "paperGIF.companion.actions", qos: .utility)

    init(
        port: UInt16,
        token: String,
        pairingHandler: @escaping (PairingRequest) -> Bool,
        actionHandler: @escaping (RemoteRequest) -> RemoteActionResult,
        netHomeUnitsHandler: @escaping () -> [NetHomeUnit]?,
        textSourceHandler: @escaping (TextSourceBatchRequest, String?) -> TextSourceBatchResponse
    ) {
        self.port = port
        self.token = token
        self.pairingHandler = pairingHandler
        self.actionHandler = actionHandler
        self.netHomeUnitsHandler = netHomeUnitsHandler
        self.textSourceHandler = textSourceHandler
    }

    func start() throws {
        guard let networkPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "PaperGIFMac", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Invalid port",
            ])
        }
        let listener = try NWListener(using: .tcp, on: networkPort)
        listener.service = NWListener.Service(
            name: Host.current().localizedName ?? "paperGIF Mac",
            type: "_papergif._tcp",
            txtRecord: NWTXTRecord([
                "host": ProcessInfo.processInfo.hostName,
                "port": String(port),
            ])
        )
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        respondingConnections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < Self.maximumConnections else {
            connection.start(queue: queue)
            respond(connection, status: 503, body: "{\"ok\":false}")
            return
        }
        let identifier = ObjectIdentifier(connection)
        connections[identifier] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .failed, .cancelled:
                let identifier = ObjectIdentifier(connection)
                self.connections.removeValue(forKey: identifier)
                self.respondingConnections.remove(identifier)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(connection, buffer: Data())
        queue.asyncAfter(deadline: .now() + Self.requestDeadline) { [weak self, weak connection] in
            guard let self, let connection,
                  self.connections[ObjectIdentifier(connection)] != nil else { return }
            self.respond(connection, status: 408, body: "{\"ok\":false}")
        }
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var requestData = buffer
            if let data {
                requestData.append(data)
            }
            switch HTTPRequestParser.parse(requestData) {
            case let .complete(request):
                self.handle(request, connection: connection)
            case .invalid:
                self.respond(connection, status: 400, body: "{\"ok\":false}")
            case .incomplete:
                if error != nil || isComplete {
                    self.respond(connection, status: 400, body: "{\"ok\":false}")
                } else {
                    self.receive(connection, buffer: requestData)
                }
            }
        }
    }

    private func handle(_ data: Data, connection: NWConnection) {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = data.range(of: separator),
              let header = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else {
            respond(connection, status: 400, body: "{\"ok\":false}")
            return
        }

        if header.hasPrefix("POST /pair ") {
            guard let request = try? JSONDecoder().decode(PairingRequest.self, from: data[headerEnd.upperBound...]) else {
                respond(connection, status: 400, body: "{\"ok\":false}")
                return
            }
            var approved = false
            DispatchQueue.main.sync {
                approved = pairingHandler(request)
            }
            guard approved else {
                respond(connection, status: 403, body: "{\"ok\":false,\"error\":\"Pairing declined\"}")
                return
            }
            let body = try? JSONSerialization.data(withJSONObject: ["ok": true, "token": token])
            respond(connection, status: 200, body: body.flatMap { String(data: $0, encoding: .utf8) } ?? "{\"ok\":false}")
            return
        }

        guard HTTPRequestParser.hasBearerToken(token, in: data) else {
            respond(connection, status: 401, body: "{\"ok\":false}")
            return
        }

        if header.hasPrefix("GET /status ") {
            respond(connection, status: 200, body: "{\"ok\":true}")
            return
        }

        if header.hasPrefix("GET /applications ") {
            workQueue.async { [weak self, weak connection] in
                guard let self, let connection else { return }
                let applications = Self.installedApplications()
                let data = try? JSONEncoder().encode(applications)
                self.queue.async {
                    self.respond(
                        connection,
                        status: 200,
                        body: data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                    )
                }
            }
            return
        }

        if header.hasPrefix("GET /nethome-units ") {
            workQueue.async { [weak self, weak connection] in
                guard let self, let connection else { return }
                let units = self.netHomeUnitsHandler()
                let data = units.flatMap { try? JSONEncoder().encode($0) }
                self.queue.async {
                    self.respond(
                        connection,
                        status: data == nil ? 400 : 200,
                        body: data.flatMap { String(data: $0, encoding: .utf8) } ?? "{\"ok\":false}"
                    )
                }
            }
            return
        }

        if header.hasPrefix("POST /text-source ") {
            guard let request = try? JSONDecoder().decode(
                TextSourceBatchRequest.self,
                from: data[headerEnd.upperBound...]
            ), request.items.count <= 16 else {
                respond(connection, status: 400, body: "{\"ok\":false}")
                return
            }
            let subscriberHost = Self.host(from: connection.endpoint)
            workQueue.async { [weak self, weak connection] in
                guard let self, let connection else { return }
                let response = self.textSourceHandler(request, subscriberHost)
                let encoded = try? JSONEncoder().encode(response)
                self.queue.async {
                    self.respond(
                        connection,
                        status: encoded == nil ? 400 : 200,
                        body: encoded.flatMap { String(data: $0, encoding: .utf8) } ?? "{\"ok\":false}"
                    )
                }
            }
            return
        }

        guard header.hasPrefix("POST /action "),
              let request = try? JSONDecoder().decode(RemoteRequest.self, from: data[headerEnd.upperBound...]) else {
            respond(connection, status: 400, body: "{\"ok\":false}")
            return
        }

        workQueue.async { [weak self, weak connection] in
            guard let self, let connection else { return }
            let result = self.actionHandler(request)
            let responseBody = result.succeeded
                ? "{\"ok\":true,\"changed\":\(result.changed ? "true" : "false")}"
                : "{\"ok\":false}"
            self.queue.async {
                self.respond(
                    connection,
                    status: result.succeeded ? 200 : 400,
                    body: responseBody
                )
            }
        }
    }

    private static func host(from endpoint: NWEndpoint) -> String? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        return String(describing: host)
    }

    private static func installedApplications() -> [InstalledApplication] {
        let fileManager = FileManager.default
        var roots = Set(fileManager.urls(
            for: .applicationDirectory,
            in: [.userDomainMask, .localDomainMask, .networkDomainMask, .systemDomainMask]
        ).map(\.standardizedFileURL))
        roots.insert(URL(fileURLWithPath: "/System/Library/CoreServices", isDirectory: true))

        for volume in fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeIsLocalKey],
            options: [.skipHiddenVolumes]
        ) ?? [] {
            guard volume.path != "/" else { continue }
            roots.insert(volume.appendingPathComponent("Applications", isDirectory: true))
        }

        var applicationsByIdentifier: [String: InstalledApplication] = [:]
        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
                enumerator.skipDescendants()
                let bundle = Bundle(url: url)
                let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? url.deletingPathExtension().lastPathComponent
                let identifier = bundle?.bundleIdentifier ?? url.standardizedFileURL.path
                applicationsByIdentifier[identifier] = InstalledApplication(
                    name: name,
                    path: url.standardizedFileURL.path,
                    iconBitmap: monochromeIconBitmap(at: url)
                )
            }
        }
        return applicationsByIdentifier.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func monochromeIconBitmap(at applicationURL: URL) -> String? {
        let dimension = 64
        let bytesPerRow = dimension
        var pixels = [UInt8](repeating: 255, count: dimension * dimension)
        guard let context = CGContext(
            data: &pixels,
            width: dimension,
            height: dimension,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        let icon = NSWorkspace.shared.icon(forFile: applicationURL.path)
        var proposedRect = NSRect(x: 0, y: 0, width: dimension, height: dimension)
        guard let image = icon.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return nil
        }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: dimension, height: dimension))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: dimension, height: dimension))

        let thresholds: [UInt8] = [
            8, 136, 40, 168,
            200, 72, 232, 104,
            56, 184, 24, 152,
            248, 120, 216, 88,
        ]
        var bitmap = [UInt8](repeating: 0, count: dimension * dimension / 8)
        for y in 0..<dimension {
            for x in 0..<dimension where pixels[y * bytesPerRow + x] < thresholds[(y % 4) * 4 + x % 4] {
                bitmap[y * dimension / 8 + x / 8] |= UInt8(0x80 >> (x % 8))
            }
        }
        return bitmap.map { String(format: "%02X", $0) }.joined()
    }

    private func respond(_ connection: NWConnection, status: Int, body: String) {
        let identifier = ObjectIdentifier(connection)
        guard respondingConnections.insert(identifier).inserted else { return }
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 408: reason = "Request Timeout"
        case 503: reason = "Service Unavailable"
        default: reason = "Bad Request"
        }
        let response = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var pairedDevicesMenuItem: NSMenuItem!
    private var recentActionMenuItem: NSMenuItem!
    private var netHomeMenuItem: NSMenuItem!
    private var server: CompanionServer?
    private let netHomeService = NetHomeService()
    private let openBuildsService = OpenBuildsControlService()
    private var configuration = CompanionConfiguration.initial
    private var editorStore: RemoteEditorStore?
    private var editorWindowController: RemoteEditorWindowController?
    private var nowPlayingSubscriptions: [String: Set<String>] = [:]
    private var playbackStateSubscriptions: [String: Set<String>] = [:]
    private var outputVolumeSubscriptions: [String: Set<String>] = [:]
    private var nowPlayingNotificationObservers: [NSObjectProtocol] = []
    private var distributedNowPlayingObservers: [NSObjectProtocol] = []
    private var mediaRemoteRegistrationHandle: UnsafeMutableRawPointer?
    private var nowPlayingUpdateGeneration = 0
    private var lastPushedNowPlayingText: String?
    private var lastPushedPlaybackState: Bool?
    private var hasPushedPlaybackState = false
    private var defaultOutputDeviceListener: AudioObjectPropertyListenerBlock?
    private var outputVolumeListener: AudioObjectPropertyListenerBlock?
    private var observedOutputDevice = AudioObjectID(kAudioObjectUnknown)
    private var outputVolumeUpdateGeneration = 0
    private var lastPushedOutputVolume: Int?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configuration = loadConfiguration()
        configureMenu()
        startNowPlayingObservation()
        startOutputVolumeObservation()
        restartServer()
        let store = controlsEditorStore()
        if netHomeService.isSignedIn {
            Task { await store.refreshNetHomeUnits() }
        } else {
            DispatchQueue.main.async { [weak self] in self?.showNetHomeLogin() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopNowPlayingObservation()
        stopOutputVolumeObservation()
    }

    private var token: String {
        configuration.token
    }

    private var port: UInt16 {
        configuration.port
    }

    private var allowedScripts: Set<String> {
        Set(configuration.allowedScripts)
    }

    private var configurationURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("paperGIF Mac", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    private func loadConfiguration() -> CompanionConfiguration {
        guard let data = try? Data(contentsOf: configurationURL),
              let saved = try? JSONDecoder().decode(CompanionConfiguration.self, from: data),
              !saved.token.isEmpty else {
            let initial = CompanionConfiguration.initial
            saveConfiguration(initial)
            return initial
        }
        return saved
    }

    private func saveConfiguration(_ configuration: CompanionConfiguration) {
        do {
            try FileManager.default.createDirectory(
                at: configurationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(configuration).write(to: configurationURL, options: .atomic)
        } catch {
            statusMenuItem?.title = "Could not save settings"
        }
    }

    private func configureMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.grid.2x2", accessibilityDescription: "paperGIF")
        let menu = NSMenu()
        statusMenuItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        pairedDevicesMenuItem = NSMenuItem(title: "No paired devices", action: nil, keyEquivalent: "")
        pairedDevicesMenuItem.isEnabled = false
        menu.addItem(pairedDevicesMenuItem)
        recentActionMenuItem = NSMenuItem(title: "No actions received", action: nil, keyEquivalent: "")
        recentActionMenuItem.isEnabled = false
        menu.addItem(recentActionMenuItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Controls Editor…", action: #selector(showControlsEditor), keyEquivalent: "e"))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","))
        netHomeMenuItem = NSMenuItem(title: "NetHome Plus…", action: #selector(showNetHomeAccount), keyEquivalent: "")
        menu.addItem(netHomeMenuItem)
        menu.addItem(NSMenuItem(title: "Accessibility Settings…", action: #selector(openAccessibilitySettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Forget Paired Devices…", action: #selector(forgetPairedDevices), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit paperGIF Mac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        updatePairedDevicesMenuItem()
        updateNetHomeMenuItem()
    }

    private func restartServer() {
        server?.stop()
        server = CompanionServer(
            port: port,
            token: token,
            pairingHandler: { [weak self] request in
                self?.approvePairing(request) ?? false
            },
            actionHandler: { [weak self] request in
                self?.perform(request) ?? (false, false)
            },
            netHomeUnitsHandler: { [weak self] in
                guard let self else { return nil }
                return try? self.netHomeService.listUnits()
            },
            textSourceHandler: { [weak self] request, subscriberHost in
                self?.resolveTextSources(request, subscriberHost: subscriberHost)
                    ?? TextSourceBatchResponse(items: [])
            }
        )
        do {
            try server?.start()
            statusMenuItem.title = "Ready on \(ProcessInfo.processInfo.hostName):\(port)"
        } catch {
            statusMenuItem.title = "Server failed: \(error.localizedDescription)"
        }
    }

    private func updatePairedDevicesMenuItem() {
        let count = configuration.pairedDevices?.count ?? 0
        pairedDevicesMenuItem?.title = count == 0
            ? "No paired devices"
            : "\(count) paired device\(count == 1 ? "" : "s")"
    }

    private func updateNetHomeMenuItem() {
        netHomeMenuItem?.title = netHomeService.isSignedIn
            ? "NetHome Plus: Connected…"
            : "Connect NetHome Plus…"
    }

    @MainActor @objc private func showNetHomeAccount() {
        guard netHomeService.isSignedIn else {
            showNetHomeLogin()
            return
        }
        let alert = NSAlert()
        alert.messageText = "NetHome Plus Connected"
        alert.informativeText = "Signed in as \(netHomeService.account ?? "NetHome user"). Credentials are stored in macOS Keychain."
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Sign Out")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            netHomeService.signOut()
            updateNetHomeMenuItem()
            showNetHomeLogin()
        }
    }

    @MainActor private func showNetHomeLogin() {
        let alert = NSAlert()
        alert.messageText = "Connect NetHome Plus"
        alert.informativeText = "Sign in with the email and password used by the NetHome Plus app. Your password is stored only in macOS Keychain."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Not Now")

        let accountField = NSTextField(string: netHomeService.account ?? "")
        accountField.placeholderString = "Email"
        let passwordField = NSSecureTextField(string: "")
        passwordField.placeholderString = "Password"
        let stack = NSStackView(views: [
            labeled("Account", accountField),
            labeled("Password", passwordField),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.frame = NSRect(x: 0, y: 0, width: 390, height: 95)
        accountField.widthAnchor.constraint(equalToConstant: 390).isActive = true
        passwordField.widthAnchor.constraint(equalToConstant: 390).isActive = true
        alert.accessoryView = stack
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            let devices = try netHomeService.signIn(
                account: accountField.stringValue,
                password: passwordField.stringValue
            )
            updateNetHomeMenuItem()
            Task { await controlsEditorStore().refreshNetHomeUnits() }
            let confirmation = NSAlert()
            confirmation.messageText = "NetHome Plus Connected"
            confirmation.informativeText = "Found \(devices.joined(separator: ", "))."
            confirmation.runModal()
        } catch {
            let failure = NSAlert(error: error)
            failure.messageText = "Could Not Connect NetHome Plus"
            failure.runModal()
        }
    }

    @objc private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    @MainActor @objc private func showControlsEditor() {
        if editorWindowController == nil {
            editorWindowController = RemoteEditorWindowController(store: controlsEditorStore())
        }
        editorWindowController?.showWindow(nil)
        editorWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        editorWindowController?.loadFromDevice()
    }

    @MainActor private func controlsEditorStore() -> RemoteEditorStore {
        if let editorStore {
            return editorStore
        }
        let store = RemoteEditorStore(
            computerName: Host.current().localizedName ?? "This Mac",
            host: ProcessInfo.processInfo.hostName,
            port: Int(port),
            token: token,
            netHomeService: netHomeService
        )
        editorStore = store
        return store
    }

    @objc private func forgetPairedDevices() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Forget all paired devices?"
        alert.informativeText = "Existing paperGIF remotes will stop controlling this Mac until they pair again."
        alert.addButton(withTitle: "Forget Devices")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        configuration.token = UUID().uuidString
        configuration.pairedDevices = []
        saveConfiguration(configuration)
        updatePairedDevicesMenuItem()
        recentActionMenuItem.title = "Pairings cleared"
        restartServer()
    }

    private func approvePairing(_ request: PairingRequest) -> Bool {
        let requester = request.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Pair with \(requester.isEmpty ? "an iPhone" : requester)?"
        alert.informativeText = "Approve only if you initiated pairing in paperGIF. This device will be able to run configured remote actions on this Mac."
        alert.addButton(withTitle: "Pair")
        alert.addButton(withTitle: "Decline")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            recentActionMenuItem.title = "Pairing declined"
            return false
        }
        if !requester.isEmpty,
           !(configuration.pairedDevices ?? []).contains(requester) {
            configuration.pairedDevices = (configuration.pairedDevices ?? []) + [requester]
            saveConfiguration(configuration)
            updatePairedDevicesMenuItem()
        }
        recentActionMenuItem.title = "Paired \(requester.isEmpty ? "iPhone" : requester)"
        return true
    }

    @MainActor @objc private func showSettings() {
        let alert = NSAlert()
        alert.messageText = "paperGIF Mac Settings"
        alert.informativeText = "Host: \(ProcessInfo.processInfo.hostName)\nPair from the iPhone Remote tab and approve the request here. Only exact script lines listed below may run."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "NetHome Account…")

        let portField = NSTextField(string: String(port))
        portField.placeholderString = "Port"
        let scriptsField = NSTextField(string: configuration.allowedScripts.joined(separator: "\n"))
        scriptsField.placeholderString = "Allowed shell commands, one per line"
        scriptsField.maximumNumberOfLines = 8
        scriptsField.lineBreakMode = .byWordWrapping

        let stack = NSStackView(views: [
            labeled("Port", portField),
            labeled("Allowed scripts", scriptsField),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.frame = NSRect(x: 0, y: 0, width: 430, height: 170)
        portField.widthAnchor.constraint(equalToConstant: 430).isActive = true
        scriptsField.widthAnchor.constraint(equalToConstant: 430).isActive = true
        alert.accessoryView = stack

        let response = alert.runModal()
        if response == .alertThirdButtonReturn {
            showNetHomeAccount()
            return
        }
        guard response == .alertFirstButtonReturn,
              let newPort = UInt16(portField.stringValue) else { return }
        configuration = CompanionConfiguration(
            token: token,
            port: newPort,
            allowedScripts: scriptsField.stringValue
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            pairedDevices: configuration.pairedDevices
        )
        saveConfiguration(configuration)
        restartServer()
    }

    private func labeled(_ title: String, _ field: NSTextField) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        let stack = NSStackView(views: [label, field])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        return stack
    }

    private func perform(_ request: RemoteRequest) -> RemoteActionResult {
        let result: RemoteActionResult
        switch request.type {
        case "macMedia":
            let succeeded = request.text == "volume"
                ? setOutputVolume(request.value)
                : sendMediaCommand(request.text)
            result = (succeeded, succeeded)
        case "macKey":
            let succeeded = sendKey(request.text, modifiers: request.modifiers)
            result = (succeeded, succeeded)
        case "macOpen":
            let succeeded = open(request.text)
            result = (succeeded, succeeded)
        case "macShortcut":
            let succeeded = launch("/usr/bin/shortcuts", arguments: ["run", request.text])
            result = (succeeded, succeeded)
        case "macScript":
            var scriptAllowed = false
            DispatchQueue.main.sync {
                scriptAllowed = allowedScripts.contains(request.text)
            }
            let succeeded = scriptAllowed &&
                launch("/bin/zsh", arguments: ["-lc", request.text])
            result = (succeeded, succeeded)
        case "openBuilds":
            let succeeded = openBuildsService.perform(
                host: request.host,
                command: request.text,
                value: request.value,
                valueTenths: request.valueTenths,
                modifiers: request.modifiers
            )
            result = (succeeded, succeeded)
        case "netHomePower", "netHomeTemperature", "netHomeMode", "netHomeFan", "netHomeClimate":
            result = netHomeService.perform(
                type: request.type,
                unit: request.host ?? "",
                text: request.text,
                value: request.value,
                valueTenths: request.valueTenths
            )
        default:
            result = (false, false)
        }
        let actionName = request.text.isEmpty ? request.type : request.text
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            recentActionMenuItem.title = "\(result.succeeded ? (result.changed ? "Ran" : "Already set") : "Failed"): \(actionName)"
            statusItem.button?.image = NSImage(
                systemSymbolName: result.succeeded ? "checkmark.rectangle" : "exclamationmark.rectangle",
                accessibilityDescription: result.succeeded ? "Last action succeeded" : "Last action failed"
            )
            if result.succeeded && request.type == "macMedia" && request.text == "playPause" {
                refreshPlaybackStateAfterCommand()
            }
        }
        return result
    }

    private func refreshPlaybackStateAfterCommand() {
        for delay in [0.2, 0.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.pushPlaybackStateIfChanged()
            }
        }
    }

    private func resolveTextSources(
        _ request: TextSourceBatchRequest,
        subscriberHost: String?
    ) -> TextSourceBatchResponse {
        let nowPlayingControlIDs = Set(request.items.lazy
            .filter { $0.source == "nowPlaying" }
            .map { String($0.id.prefix(40)) })
        let playbackStateControlIDs = Set(request.items.lazy
            .filter { $0.source == "playbackState" }
            .map { String($0.id.prefix(40)) })
        let outputVolumeControlIDs = Set(request.items.lazy
            .filter { $0.source == "outputVolume" }
            .map { String($0.id.prefix(40)) })
        var permittedScripts: Set<String> = []
        DispatchQueue.main.sync {
            if let subscriberHost, !nowPlayingControlIDs.isEmpty {
                nowPlayingSubscriptions[subscriberHost] = nowPlayingControlIDs
            }
            if let subscriberHost, !playbackStateControlIDs.isEmpty {
                playbackStateSubscriptions[subscriberHost] = playbackStateControlIDs
            }
            if let subscriberHost, !outputVolumeControlIDs.isEmpty {
                outputVolumeSubscriptions[subscriberHost] = outputVolumeControlIDs
            }
            permittedScripts = allowedScripts
        }
        let positionHosts = Set(request.items.compactMap { item -> String? in
            guard item.source == "openBuildsPosition" else { return nil }
            return item.sourceText.split(separator: "|", maxSplits: 1).first.map(String.init)
        })
        let openBuildsPositions = Dictionary(uniqueKeysWithValues: positionHosts.compactMap { host in
            openBuildsService.position(host: host).map { (host, $0) }
        })
        let items = request.items.map { item -> TextSourceResponse in
            if item.source == "playbackState" {
                let isPlaying = playbackIsPlaying()
                return TextSourceResponse(
                    id: String(item.id.prefix(40)),
                    text: "",
                    available: isPlaying != nil,
                    value: isPlaying.map { $0 ? 1 : 0 }
                )
            }
            if item.source == "outputVolume" {
                let value = outputVolumeValue()
                return TextSourceResponse(
                    id: String(item.id.prefix(40)),
                    text: "",
                    available: value != nil,
                    value: value
                )
            }
            let output: String?
            switch item.source {
            case "macScript":
                output = permittedScripts.contains(item.sourceText)
                    ? commandOutput("/bin/zsh", arguments: ["-lc", item.sourceText])
                    : nil
            case "macShortcut":
                output = commandOutput("/usr/bin/shortcuts", arguments: ["run", item.sourceText])
            case "nowPlaying":
                output = nowPlayingText()
            case "openBuildsPosition":
                let components = item.sourceText.split(separator: "|", maxSplits: 1).map(String.init)
                guard components.count == 2,
                      let position = openBuildsPositions[components[0]] else {
                    output = nil
                    break
                }
                let axis = components[1].lowercased()
                let value = axis == "x" ? position.x : axis == "y" ? position.y : axis == "z" ? position.z : nil
                output = value.map { String(format: "%@ %.3f", axis.uppercased(), $0) }
            default:
                output = nil
            }
            let normalized = output?.trimmingCharacters(in: .whitespacesAndNewlines)
            let available = normalized?.isEmpty == false
            return TextSourceResponse(
                id: String(item.id.prefix(40)),
                text: boundedUTF8(available ? normalized! : item.placeholder, maximumBytes: 192),
                available: available
            )
        }
        return TextSourceBatchResponse(items: items)
    }

    private func startNowPlayingObservation() {
        let distributedCenter = DistributedNotificationCenter.default()
        for name in ["com.apple.Music.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
            let observer = distributedCenter.addObserver(
                forName: Notification.Name(name),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleNowPlayingPush()
            }
            distributedNowPlayingObservers.append(observer)
        }

        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(path, RTLD_LAZY),
              let registerSymbol = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications") else {
            return
        }
        mediaRemoteRegistrationHandle = handle
        let observer = NotificationCenter.default.addObserver(
            forName: Notification.Name("kMRMediaRemoteNowPlayingInfoDidChangeNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleNowPlayingPush()
        }
        nowPlayingNotificationObservers.append(observer)
        typealias RegisterForNotifications = @convention(c) (DispatchQueue) -> Void
        unsafeBitCast(registerSymbol, to: RegisterForNotifications.self)(DispatchQueue.main)
    }

    private func stopNowPlayingObservation() {
        distributedNowPlayingObservers.forEach {
            DistributedNotificationCenter.default().removeObserver($0)
        }
        distributedNowPlayingObservers.removeAll()
        nowPlayingNotificationObservers.forEach(NotificationCenter.default.removeObserver)
        nowPlayingNotificationObservers.removeAll()
        guard let handle = mediaRemoteRegistrationHandle else { return }
        if let unregisterSymbol = dlsym(handle, "MRMediaRemoteUnregisterForNowPlayingNotifications") {
            typealias UnregisterForNotifications = @convention(c) () -> Void
            unsafeBitCast(unregisterSymbol, to: UnregisterForNotifications.self)()
        }
        dlclose(handle)
        mediaRemoteRegistrationHandle = nil
    }

    private func scheduleNowPlayingPush() {
        nowPlayingUpdateGeneration += 1
        let generation = nowPlayingUpdateGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, generation == self.nowPlayingUpdateGeneration else { return }
            self.pushNowPlayingIfChanged()
            self.pushPlaybackStateIfChanged()
        }
    }

    private func pushNowPlayingIfChanged() {
        let normalized = nowPlayingText()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = normalized?.isEmpty == false ? boundedUTF8(normalized!, maximumBytes: 192) : nil
        guard text != lastPushedNowPlayingText else { return }
        lastPushedNowPlayingText = text

        for (host, controlIDs) in nowPlayingSubscriptions where !controlIDs.isEmpty {
            var components = URLComponents()
            components.scheme = "http"
            components.host = host
            components.port = 80
            components.path = "/text-source/update"
            guard let url = components.url else { continue }
            let body = TextSourceBatchResponse(items: controlIDs.map {
                TextSourceResponse(id: $0, text: text ?? "", available: text != nil)
            })
            guard let payload = try? JSONEncoder().encode(body) else { continue }
            var request = URLRequest(url: url, timeoutInterval: 3)
            request.httpMethod = "POST"
            request.httpBody = payload
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            URLSession.shared.dataTask(with: request).resume()
        }
    }

    private func pushPlaybackStateIfChanged() {
        let playbackState = playbackIsPlaying()
        guard !hasPushedPlaybackState || playbackState != lastPushedPlaybackState else { return }
        hasPushedPlaybackState = true
        lastPushedPlaybackState = playbackState
        for (host, controlIDs) in playbackStateSubscriptions where !controlIDs.isEmpty {
            var components = URLComponents()
            components.scheme = "http"
            components.host = host
            components.port = 80
            components.path = "/text-source/update"
            guard let url = components.url else { continue }
            let body = TextSourceBatchResponse(items: controlIDs.map {
                TextSourceResponse(
                    id: $0,
                    text: "",
                    available: playbackState != nil,
                    value: playbackState.map { $0 ? 1 : 0 }
                )
            })
            guard let payload = try? JSONEncoder().encode(body) else { continue }
            var request = URLRequest(url: url, timeoutInterval: 3)
            request.httpMethod = "POST"
            request.httpBody = payload
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            URLSession.shared.dataTask(with: request).resume()
        }
    }

    private func startOutputVolumeObservation() {
        let defaultDeviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.observeCurrentOutputDevice()
                self?.scheduleOutputVolumePush()
            }
        }
        var defaultDeviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultDeviceAddress,
            .main,
            defaultDeviceListener
        ) == noErr else { return }
        defaultOutputDeviceListener = defaultDeviceListener
        observeCurrentOutputDevice()
    }

    private func stopOutputVolumeObservation() {
        if let listener = outputVolumeListener,
           observedOutputDevice != AudioObjectID(kAudioObjectUnknown) {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertySelectorWildcard,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementWildcard
            )
            AudioObjectRemovePropertyListenerBlock(observedOutputDevice, &address, .main, listener)
        }
        outputVolumeListener = nil
        observedOutputDevice = AudioObjectID(kAudioObjectUnknown)
        if let listener = defaultOutputDeviceListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                .main,
                listener
            )
        }
        defaultOutputDeviceListener = nil
    }

    private func observeCurrentOutputDevice() {
        let outputDevice = defaultOutputDevice()
        guard outputDevice != observedOutputDevice else { return }
        if let listener = outputVolumeListener,
           observedOutputDevice != AudioObjectID(kAudioObjectUnknown) {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertySelectorWildcard,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementWildcard
            )
            AudioObjectRemovePropertyListenerBlock(observedOutputDevice, &address, .main, listener)
        }
        outputVolumeListener = nil
        observedOutputDevice = outputDevice
        guard outputDevice != AudioObjectID(kAudioObjectUnknown) else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.scheduleOutputVolumePush() }
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertySelectorWildcard,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementWildcard
        )
        guard AudioObjectAddPropertyListenerBlock(outputDevice, &address, .main, listener) == noErr else {
            return
        }
        outputVolumeListener = listener
    }

    private func scheduleOutputVolumePush() {
        outputVolumeUpdateGeneration += 1
        let generation = outputVolumeUpdateGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, generation == self.outputVolumeUpdateGeneration else { return }
            self.pushOutputVolumeIfChanged()
        }
    }

    private func pushOutputVolumeIfChanged() {
        guard let value = outputVolumeValue(), value != lastPushedOutputVolume else { return }
        lastPushedOutputVolume = value
        for (host, controlIDs) in outputVolumeSubscriptions where !controlIDs.isEmpty {
            var components = URLComponents()
            components.scheme = "http"
            components.host = host
            components.port = 80
            components.path = "/text-source/update"
            guard let url = components.url else { continue }
            let body = TextSourceBatchResponse(items: controlIDs.map {
                TextSourceResponse(id: $0, text: "", available: true, value: value)
            })
            guard let payload = try? JSONEncoder().encode(body) else { continue }
            var request = URLRequest(url: url, timeoutInterval: 3)
            request.httpMethod = "POST"
            request.httpBody = payload
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            URLSession.shared.dataTask(with: request).resume()
        }
    }

    private func defaultOutputDevice() -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout.size(ofValue: device))
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &device
        ) == noErr else { return AudioObjectID(kAudioObjectUnknown) }
        return device
    }

    private func outputVolumeValue() -> Int? {
        let device = defaultOutputDevice()
        guard device != AudioObjectID(kAudioObjectUnknown) else { return nil }
        for element in [AudioObjectPropertyElement(kAudioObjectPropertyElementMain), 1, 2] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element
            )
            var scalar = Float32.zero
            var size = UInt32(MemoryLayout.size(ofValue: scalar))
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &scalar) == noErr {
                return Int((Double(min(max(scalar, 0), 1)) * 255).rounded())
            }
        }
        return nil
    }

    private func nowPlayingText() -> String? {
        let applications = [
            (name: "Music", bundleID: "com.apple.Music"),
            (name: "Spotify", bundleID: "com.spotify.client"),
        ]
        for application in applications where
            !NSRunningApplication.runningApplications(withBundleIdentifier: application.bundleID).isEmpty {
            guard requestAutomationPermission(for: application.bundleID) else {
                recentActionMenuItem.title = "Allow Music access in System Settings"
                statusItem.button?.image = NSImage(
                    systemSymbolName: "exclamationmark.rectangle",
                    accessibilityDescription: "Music access is required"
                )
                continue
            }
            let script = """
            if application "\(application.name)" is running then
                tell application "\(application.name)"
                    set currentState to player state
                    if currentState is playing or currentState is paused then
                        return (name of current track) & " - " & (artist of current track)
                    end if
                end tell
            end if
            """
            if let output = appleScriptOutput(script),
               !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return output
            }
        }
        return mediaRemoteNowPlayingText()
    }

    private func playbackIsPlaying() -> Bool? {
        let applications = [
            (name: "Music", bundleID: "com.apple.Music"),
            (name: "Spotify", bundleID: "com.spotify.client"),
        ]
        for application in applications where
            !NSRunningApplication.runningApplications(withBundleIdentifier: application.bundleID).isEmpty {
            guard requestAutomationPermission(for: application.bundleID) else { continue }
            let script = """
            if application "\(application.name)" is running then
                tell application "\(application.name)"
                    if player state is playing then return "playing"
                    if player state is paused then return "paused"
                    return "unavailable"
                end tell
            end if
            """
            if let output = appleScriptOutput(script)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                if output == "playing" { return true }
                if output == "paused" { return false }
            }
        }
        return mediaRemotePlaybackIsPlaying()
    }

    private func requestAutomationPermission(for bundleIdentifier: String) -> Bool {
        var target = AEAddressDesc()
        let bytes = Array(bundleIdentifier.utf8)
        let createStatus = bytes.withUnsafeBytes {
            AECreateDesc(typeApplicationBundleID, $0.baseAddress, $0.count, &target)
        }
        guard createStatus == noErr else { return false }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(
            &target,
            typeWildCard,
            typeWildCard,
            true
        ) == noErr
    }

    private func mediaRemoteNowPlayingText() -> String? {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(path, RTLD_LAZY),
              let symbol = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") else {
            return nil
        }
        defer { dlclose(handle) }

        typealias Callback = @convention(block) (CFDictionary?) -> Void
        typealias GetNowPlayingInfo = @convention(c) (DispatchQueue, Callback) -> Void
        let getNowPlayingInfo = unsafeBitCast(symbol, to: GetNowPlayingInfo.self)
        let semaphore = DispatchSemaphore(value: 0)
        var result: String?
        let callback: Callback = { information in
            defer { semaphore.signal() }
            guard let values = information as? [String: Any],
                  let title = values["kMRMediaRemoteNowPlayingInfoTitle"] as? String,
                  !title.isEmpty else { return }
            let artist = values["kMRMediaRemoteNowPlayingInfoArtist"] as? String
            result = artist?.isEmpty == false ? "\(title) - \(artist!)" : title
        }
        getNowPlayingInfo(DispatchQueue.global(qos: .utility), callback)
        guard semaphore.wait(timeout: .now() + 1) == .success else { return nil }
        return result
    }

    private func mediaRemotePlaybackIsPlaying() -> Bool? {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(path, RTLD_LAZY),
              let symbol = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") else {
            return nil
        }
        defer { dlclose(handle) }

        typealias Callback = @convention(block) (CFDictionary?) -> Void
        typealias GetNowPlayingInfo = @convention(c) (DispatchQueue, Callback) -> Void
        let getNowPlayingInfo = unsafeBitCast(symbol, to: GetNowPlayingInfo.self)
        let semaphore = DispatchSemaphore(value: 0)
        var result: Bool?
        let callback: Callback = { information in
            defer { semaphore.signal() }
            guard let values = information as? [String: Any],
                  values["kMRMediaRemoteNowPlayingInfoTitle"] != nil,
                  let playbackRate = values["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber else {
                return
            }
            result = playbackRate.doubleValue > 0
        }
        getNowPlayingInfo(DispatchQueue.global(qos: .utility), callback)
        guard semaphore.wait(timeout: .now() + 1) == .success else { return nil }
        return result
    }

    private func appleScriptOutput(_ source: String) -> String? {
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error) else {
            if let error {
                NSLog("Now-playing AppleScript failed: %@", error)
            }
            return nil
        }
        return result.stringValue
    }

    private func commandOutput(_ executable: String, arguments: [String]) -> String? {
        do {
            let result = try BoundedProcessRunner.run(
                executableURL: URL(fileURLWithPath: executable),
                arguments: arguments,
                timeout: 5,
                maximumOutputBytes: 4096
            )
            guard result.status == 0, !result.timedOut else { return nil }
            return String(data: result.output, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func boundedUTF8(_ value: String, maximumBytes: Int) -> String {
        var bytes = Array(value.utf8.prefix(maximumBytes))
        while String(bytes: bytes, encoding: .utf8) == nil && !bytes.isEmpty {
            bytes.removeLast()
        }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    private func sendMediaCommand(_ command: String) -> Bool {
        let keyType: Int32
        switch command {
        case "playPause": keyType = NX_KEYTYPE_PLAY
        case "previous": keyType = NX_KEYTYPE_PREVIOUS
        case "next": keyType = NX_KEYTYPE_NEXT
        case "volumeUp": keyType = NX_KEYTYPE_SOUND_UP
        case "volumeDown": keyType = NX_KEYTYPE_SOUND_DOWN
        case "mute": keyType = NX_KEYTYPE_MUTE
        default: return false
        }
        for (flags, state) in [(0xA00, 0xA), (0xB00, 0xB)] {
            let data = Int((keyType << 16) | Int32(flags))
            NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data,
                data2: -1
            )?.cgEvent?.post(tap: .cghidEventTap)
        }
        return true
    }

    private func setOutputVolume(_ value: Int) -> Bool {
        let percentage = Int((Double(value.clamped(to: 0...255)) / 255 * 100).rounded())
        do {
            let result = try BoundedProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: ["-e", "set volume output volume \(percentage)"],
                captureOutput: false,
                timeout: 5
            )
            return result.status == 0 && !result.timedOut
        } catch {
            return false
        }
    }

    private func sendKey(_ key: String, modifiers: [String]) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { return false }
        var flags: CGEventFlags = []
        for modifier in modifiers {
            switch modifier {
            case "command": flags.insert(.maskCommand)
            case "option": flags.insert(.maskAlternate)
            case "control": flags.insert(.maskControl)
            case "shift": flags.insert(.maskShift)
            default: break
            }
        }
        let namedKeys: [String: CGKeyCode] = [
            "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53,
            "f17": 64, "f18": 79, "f19": 80, "f20": 90,
            "f5": 96, "f6": 97, "f7": 98, "f3": 99, "f8": 100,
            "f9": 101, "f11": 103, "f13": 105, "f16": 106, "f14": 107,
            "f10": 109, "f12": 111, "f15": 113, "home": 115, "pageup": 116,
            "forwarddelete": 117, "f4": 118, "end": 119, "f2": 120,
            "pagedown": 121, "f1": 122,
            "left": 123, "right": 124, "down": 125, "up": 126,
        ]
        let characterKeys: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
            "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
            "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
            "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
            "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37,
            "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
            "n": 45, "m": 46, ".": 47, "`": 50,
        ]
        let normalized = key.lowercased()
        guard let keyCode = namedKeys[normalized] ?? characterKeys[normalized] else {
            return false
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            return false
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func open(_ target: String) -> Bool {
        if let url = URL(string: target), url.scheme != nil {
            return NSWorkspace.shared.open(url)
        }
        let fileURL = URL(fileURLWithPath: target)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return NSWorkspace.shared.open(fileURL)
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target) else {
            return false
        }
        NSWorkspace.shared.openApplication(at: appURL, configuration: .init())
        return true
    }

    private func launch(_ executable: String, arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }
}

let application = NSApplication.shared
private let appDelegate = AppDelegate()
application.delegate = appDelegate
application.run()

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
