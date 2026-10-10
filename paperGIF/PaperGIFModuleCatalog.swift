import Foundation

struct PaperGIFModulePageDefinition: Decodable, Identifiable, Sendable {
    let id: String
    let detail: String
    let page: PaperGIFRemotePage
}

struct PaperGIFModuleListing: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let summary: String
    let version: String
    let author: String
    let manifest: String
}

struct PaperGIFModuleIndex: Decodable, Sendable {
    let schemaVersion: Int
    let modules: [PaperGIFModuleListing]
}

struct PaperGIFModuleManifest: Decodable, Identifiable, Sendable {
    let schemaVersion: Int
    let id: String
    let name: String
    let summary: String
    let version: String
    let author: String
    let pages: [PaperGIFModulePageDefinition]?
}

enum PaperGIFModuleCatalog {
    static let openBuildsModuleID = "openbuilds-control"
    static let motionControllerPageID = "motion-controller"
    static let defaultIndexURL = URL(
        string: "https://raw.githubusercontent.com/Levi-5k/PaperRemote/main/modules/index.json"
    )!
    private static let maximumDownloadBytes = 512 * 1024

    static func bundledModules(bundle: Bundle = .main) throws -> [PaperGIFModuleManifest] {
        guard let directoryURL = bundle.url(forResource: "modules", withExtension: nil) else {
            throw PaperGIFModuleCatalogError.bundledCatalogMissing
        }
        let indexData = try Data(contentsOf: directoryURL.appendingPathComponent("index.json"))
        let index = try decodeIndex(from: indexData)
        return try index.modules.map { listing in
            let data = try Data(contentsOf: directoryURL.appendingPathComponent(listing.manifest))
            return try decodeManifest(data, listing: listing)
        }.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func downloadMotionControllerPage() async throws -> PaperGIFRemotePage {
        let openBuildsManifestURL = URL(
            string: "openbuilds-control.json",
            relativeTo: defaultIndexURL
        )!.absoluteURL
        let data = try await download(openBuildsManifestURL)
        return try decodeMotionControllerPage(from: data)
    }

    static func downloadModules() async throws -> [PaperGIFModuleManifest] {
        let indexData = try await download(defaultIndexURL)
        let index = try decodeIndex(from: indexData)
        var modules: [PaperGIFModuleManifest] = []
        for listing in index.modules {
            guard let manifestURL = URL(
                string: listing.manifest,
                relativeTo: defaultIndexURL
            )?.absoluteURL, manifestURL.scheme == "https" else {
                throw PaperGIFModuleCatalogError.invalidManifest
            }
            let data = try await download(manifestURL)
            modules.append(try decodeManifest(data, listing: listing))
        }
        return modules.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func decodeIndex(from data: Data) throws -> PaperGIFModuleIndex {
        let index = try JSONDecoder().decode(PaperGIFModuleIndex.self, from: data)
        guard index.schemaVersion == 1 else {
            throw PaperGIFModuleCatalogError.invalidManifest
        }
        return index
    }

    private static func decodeManifest(
        _ data: Data,
        listing: PaperGIFModuleListing
    ) throws -> PaperGIFModuleManifest {
        let manifest = try JSONDecoder().decode(PaperGIFModuleManifest.self, from: data)
        try validate(manifest, expectedModuleID: listing.id)
        return manifest
    }

    private static func download(_ url: URL) async throws -> Data {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "_", value: String(Int(Date().timeIntervalSince1970 * 1_000)))
        ]
        var request = URLRequest(url: components?.url ?? url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw PaperGIFModuleCatalogError.downloadFailed
        }
        guard data.count <= maximumDownloadBytes else {
            throw PaperGIFModuleCatalogError.downloadTooLarge
        }
        return data
    }

    static func decodeMotionControllerPage(from data: Data) throws -> PaperGIFRemotePage {
        let manifest = try JSONDecoder().decode(PaperGIFModuleManifest.self, from: data)
        return try clonePage(
            from: manifest,
            expectedModuleID: openBuildsModuleID,
            pageID: motionControllerPageID
        )
    }

    static func decodePage(
        from data: Data,
        expectedModuleID: String,
        pageID: String
    ) throws -> PaperGIFRemotePage {
        let manifest = try JSONDecoder().decode(PaperGIFModuleManifest.self, from: data)
        return try clonePage(
            from: manifest,
            expectedModuleID: expectedModuleID,
            pageID: pageID
        )
    }

    static func clonePage(
        from manifest: PaperGIFModuleManifest,
        expectedModuleID: String,
        pageID: String
    ) throws -> PaperGIFRemotePage {
        guard manifest.schemaVersion == 1,
              manifest.id == expectedModuleID,
              let definition = manifest.pages?.first(where: { $0.id == pageID }),
              !definition.page.name.isEmpty,
              definition.page.controls.count <= PaperGIFRemoteProfile.maximumControlsPerPage else {
            throw PaperGIFModuleCatalogError.invalidManifest
        }

        return clonePage(definition, moduleID: manifest.id)
    }

    static func clonePage(
        _ definition: PaperGIFModulePageDefinition,
        moduleID: String
    ) -> PaperGIFRemotePage {
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

    static func configure(
        _ source: PaperGIFRemotePage,
        for computerID: UUID?
    ) -> PaperGIFRemotePage {
        var page = source
        let identifier = computerID?.uuidString
        for index in page.controls.indices {
            if requiresComputer(page.controls[index].action.type) {
                page.controls[index].action.computerID = identifier
            }
            if let source = page.controls[index].textBox?.source,
               requiresComputer(source) {
                page.controls[index].textBox?.computerID = computerID
            }
            if let type = page.controls[index].textBox?.tapAction?.type,
               requiresComputer(type) {
                page.controls[index].textBox?.tapAction?.computerID = identifier
            }
        }
        return page
    }

    static func requiresComputer(_ page: PaperGIFRemotePage) -> Bool {
        page.controls.contains {
            requiresComputer($0.action.type) ||
                ($0.textBox.map { requiresComputer($0.source) } ?? false)
        }
    }

    private static func requiresComputer(_ type: PaperGIFRemoteActionType) -> Bool {
        switch type {
        case .computerMedia, .computerKey, .computerOpen, .appleShortcut, .computerScript, .openBuilds,
             .netHomePower, .netHomeTemperature, .netHomeTemperatureStep,
               .netHomeMode, .netHomeFan, .netHomeAuto, .module:
            true
           case .iPhoneMedia, .iPhoneHomePower, .wledPower, .wledPreset, .wledBrightness, .eWeLinkPower,
               .localHTTP, .page:
            false
        }
    }

    private static func requiresComputer(_ source: PaperGIFRemoteTextSource) -> Bool {
        switch source {
        case .computerScript, .appleShortcut, .nowPlaying, .openBuildsPosition:
            true
        case .staticText, .dateTime, .controlValue:
            false
        }
    }

    private static func validate(
        _ manifest: PaperGIFModuleManifest,
        expectedModuleID: String
    ) throws {
        guard manifest.schemaVersion == 1,
              manifest.id == expectedModuleID,
              !manifest.name.isEmpty,
              !manifest.version.isEmpty,
              (manifest.pages ?? []).count <= 8,
              Set((manifest.pages ?? []).map(\.id)).count == (manifest.pages ?? []).count,
              (manifest.pages ?? []).allSatisfy({
                  !$0.id.isEmpty && !$0.detail.isEmpty && !$0.page.name.isEmpty &&
                      $0.page.controls.count <= PaperGIFRemoteProfile.maximumControlsPerPage
              }) else {
            throw PaperGIFModuleCatalogError.invalidManifest
        }
    }
}

private enum PaperGIFModuleCatalogError: LocalizedError {
    case bundledCatalogMissing
    case invalidManifest
    case downloadFailed
    case downloadTooLarge

    var errorDescription: String? {
        switch self {
        case .bundledCatalogMissing: "The built-in module catalog is missing."
        case .invalidManifest: "The module is invalid."
        case .downloadFailed: "The module could not be downloaded."
        case .downloadTooLarge: "The module is too large."
        }
    }
}