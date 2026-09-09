import Combine
import Foundation

struct PaperModuleListing: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let summary: String
    let version: String
    let author: String
    let manifest: String
}

struct PaperModuleIndex: Codable, Sendable {
    let schemaVersion: Int
    let modules: [PaperModuleListing]
}

struct PaperModuleControl: Codable, Sendable {
    let id: String
    let category: String
    let detail: String
    let control: RemoteControl
}

struct PaperModulePage: Codable, Sendable {
    let id: String
    let detail: String
    let page: RemotePage
}

struct PaperModuleManifest: Codable, Identifiable, Sendable {
    let schemaVersion: Int
    let id: String
    let name: String
    let summary: String
    let version: String
    let author: String
    let controls: [PaperModuleControl]
    let pages: [PaperModulePage]?
}

@MainActor
final class ModuleCatalog: ObservableObject {
    static let defaultIndexURL = URL(
        string: "https://raw.githubusercontent.com/Levi-5k/PaperRemote/main/modules/index.json"
    )!

    @Published private(set) var availableModules: [PaperModuleListing] = []
    @Published private(set) var isLoading = false
    @Published private var installedByID: [String: PaperModuleManifest] = [:]
    private let indexURL: URL
    private let installedDirectory: URL
    private let maximumDownloadBytes = 512 * 1024

    init(
        indexURL: URL? = nil,
        installedDirectory: URL? = nil
    ) {
        self.indexURL = indexURL ?? Self.defaultIndexURL
        self.installedDirectory = installedDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("paperGIF Mac/modules", isDirectory: true)
        loadInstalled()
    }

    var installedModules: [PaperModuleManifest] {
        installedByID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var installedTemplates: [RemoteControlTemplate] {
        installedModules.flatMap { module in
            module.controls.map { RemoteControlTemplate.module(module, control: $0) }
        }
    }

    func isInstalled(_ listing: PaperModuleListing) -> Bool {
        guard let installedVersion = installedByID[listing.id]?.version else { return false }
        return !Self.isVersion(listing.version, newerThan: installedVersion)
    }

    func hasUpdate(_ listing: PaperModuleListing) -> Bool {
        guard let installedVersion = installedByID[listing.id]?.version else { return false }
        return Self.isVersion(listing.version, newerThan: installedVersion)
    }

    func installedModule(id: String) -> PaperModuleManifest? {
        installedByID[id]
    }

    nonisolated static func clonePage(_ definition: PaperModulePage, moduleID: String) -> RemotePage {
        var page = definition.page
        page.id = UUID()
        page.controls = page.controls.map { control in
            var copy = control
            copy.id = UUID()
            return copy
        }
        page.moduleID = moduleID
        page.modulePageID = definition.id
        return page
    }

    nonisolated static func updatedPage(
        _ existing: RemotePage,
        from definition: PaperModulePage,
        moduleID: String
    ) -> RemotePage {
        var page = clonePage(definition, moduleID: moduleID)
        page.id = existing.id
        page.name = existing.name
        if let controller = existing.openBuildsController,
           page.openBuildsController != nil {
            page.openBuildsController = controller
        }

        let actionComputerID = existing.controls.lazy.compactMap(\.action.computerID).first
        let actionHost = existing.controls.lazy.map(\.action.host).first { !$0.isEmpty }
        let textComputerID = existing.controls.lazy.compactMap(\.textBox?.computerID).first
        let textHost = existing.controls.lazy.compactMap { control -> String? in
            guard control.textBox?.source == .openBuildsPosition,
                  let sourceText = control.textBox?.sourceText else { return nil }
            return sourceText.split(separator: "|", omittingEmptySubsequences: false).first.map(String.init)
        }.first

        for index in page.controls.indices {
            if let previous = existing.controls.first(where: {
                $0.kind == page.controls[index].kind && $0.title == page.controls[index].title
            }) {
                page.controls[index].id = previous.id
            }
            if page.controls[index].action.type == .openBuilds {
                page.controls[index].action.computerID = actionComputerID
                if let actionHost {
                    page.controls[index].action.host = actionHost
                }
            }
            if page.controls[index].textBox?.source == .openBuildsPosition {
                page.controls[index].textBox?.computerID = textComputerID
                if let textHost,
                   let sourceText = page.controls[index].textBox?.sourceText {
                    var components = sourceText.split(
                        separator: "|", omittingEmptySubsequences: false
                    ).map(String.init)
                    if !components.isEmpty {
                        components[0] = textHost
                        page.controls[index].textBox?.sourceText = components.joined(separator: "|")
                    }
                }
            }
        }
        return page
    }

    func refresh() async throws {
        isLoading = true
        defer { isLoading = false }
        let data = try await download(indexURL)
        let index = try JSONDecoder().decode(PaperModuleIndex.self, from: data)
        guard index.schemaVersion == 1 else {
            throw ModuleCatalogError.invalidCatalog
        }
        availableModules = index.modules
            .filter { Self.isValidIdentifier($0.id) && !$0.name.isEmpty && !$0.manifest.isEmpty }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func install(_ listing: PaperModuleListing) async throws -> PaperModuleManifest {
        guard let manifestURL = URL(string: listing.manifest, relativeTo: indexURL)?.absoluteURL,
              manifestURL.scheme?.lowercased() == "https" else {
            throw ModuleCatalogError.insecureManifest
        }
        let data = try await download(manifestURL)
        let manifest = try JSONDecoder().decode(PaperModuleManifest.self, from: data)
        try Self.validate(manifest, expectedID: listing.id, expectedVersion: listing.version)
        try FileManager.default.createDirectory(at: installedDirectory, withIntermediateDirectories: true)
        try data.write(
            to: installedDirectory.appendingPathComponent("\(manifest.id).json"),
            options: .atomic
        )
        installedByID[manifest.id] = manifest
        return manifest
    }

    private func download(_ url: URL) async throws -> Data {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = (components?.queryItems ?? []) + [
            URLQueryItem(name: "_", value: String(Int(Date().timeIntervalSince1970 * 1_000)))
        ]
        components?.queryItems = queryItems
        var request = URLRequest(url: components?.url ?? url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw ModuleCatalogError.downloadFailed
        }
        guard data.count <= maximumDownloadBytes else {
            throw ModuleCatalogError.downloadTooLarge
        }
        return data
    }

    private func loadInstalled() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: installedDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: file),
                  let manifest = try? JSONDecoder().decode(PaperModuleManifest.self, from: data),
                  (try? Self.validate(manifest, expectedID: manifest.id)) != nil else { continue }
            installedByID[manifest.id] = manifest
        }
    }

    private static func validate(
        _ manifest: PaperModuleManifest,
        expectedID: String,
        expectedVersion: String? = nil
    ) throws {
        guard manifest.schemaVersion == 1,
              manifest.id == expectedID,
              expectedVersion == nil || manifest.version == expectedVersion,
              isValidIdentifier(manifest.id),
              !manifest.name.isEmpty,
              !manifest.version.isEmpty,
              (1...RemoteProfile.maximumControlsPerPage).contains(manifest.controls.count),
              Set(manifest.controls.map(\.id)).count == manifest.controls.count,
              manifest.controls.allSatisfy({
                  isValidIdentifier($0.id) &&
                      !$0.category.isEmpty &&
                      !$0.detail.isEmpty &&
                      !$0.control.title.isEmpty
              }),
              (manifest.pages ?? []).count <= 8,
              Set((manifest.pages ?? []).map(\.id)).count == (manifest.pages ?? []).count,
              (manifest.pages ?? []).allSatisfy({
                  isValidIdentifier($0.id) &&
                      !$0.detail.isEmpty &&
                      !$0.page.name.isEmpty &&
                      $0.page.controls.count <= RemoteProfile.maximumControlsPerPage
              }) else {
            throw ModuleCatalogError.invalidManifest
        }
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        value.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil
    }

    nonisolated static func isVersion(_ candidate: String, newerThan installed: String) -> Bool {
        candidate.compare(installed, options: [.numeric, .caseInsensitive]) == .orderedDescending
    }
}

private enum ModuleCatalogError: LocalizedError {
    case invalidCatalog
    case invalidManifest
    case insecureManifest
    case downloadFailed
    case downloadTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidCatalog: "The module catalog format is not supported."
        case .invalidManifest: "The module manifest is invalid."
        case .insecureManifest: "Module manifests must use HTTPS."
        case .downloadFailed: "The module download failed."
        case .downloadTooLarge: "The module download is too large."
        }
    }
}