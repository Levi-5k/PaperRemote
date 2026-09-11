import Foundation

struct PaperGIFModulePageDefinition: Decodable, Sendable {
    let id: String
    let detail: String
    let page: PaperGIFRemotePage
}

private struct PaperGIFModuleManifest: Decodable, Sendable {
    let schemaVersion: Int
    let id: String
    let pages: [PaperGIFModulePageDefinition]?
}

enum PaperGIFModuleCatalog {
    static let openBuildsModuleID = "openbuilds-control"
    static let motionControllerPageID = "motion-controller"
    private static let openBuildsManifestURL = URL(
        string: "https://raw.githubusercontent.com/Levi-5k/PaperRemote/main/modules/openbuilds-control.json"
    )!
    private static let maximumDownloadBytes = 512 * 1024

    static func downloadMotionControllerPage() async throws -> PaperGIFRemotePage {
        var components = URLComponents(url: openBuildsManifestURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "_", value: String(Int(Date().timeIntervalSince1970 * 1_000)))
        ]
        var request = URLRequest(url: components?.url ?? openBuildsManifestURL)
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
        return try decodeMotionControllerPage(from: data)
    }

    static func decodeMotionControllerPage(from data: Data) throws -> PaperGIFRemotePage {
        let manifest = try JSONDecoder().decode(PaperGIFModuleManifest.self, from: data)
        guard manifest.schemaVersion == 1,
              manifest.id == openBuildsModuleID,
              let definition = manifest.pages?.first(where: { $0.id == motionControllerPageID }),
              !definition.page.name.isEmpty,
              definition.page.controls.count <= PaperGIFRemoteProfile.maximumControlsPerPage else {
            throw PaperGIFModuleCatalogError.invalidManifest
        }

        var page = definition.page
        page.id = UUID()
        page.controls = page.controls.map { control in
            var copy = control
            copy.id = UUID()
            return copy
        }
        page.moduleID = openBuildsModuleID
        page.modulePageID = motionControllerPageID
        return page
    }
}

private enum PaperGIFModuleCatalogError: LocalizedError {
    case invalidManifest
    case downloadFailed
    case downloadTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidManifest: "The OpenBuilds module is invalid."
        case .downloadFailed: "The OpenBuilds module could not be downloaded."
        case .downloadTooLarge: "The OpenBuilds module is too large."
        }
    }
}