import Combine
import CryptoKit
import Foundation

struct PaperGIFDeviceEndpoint: Equatable {
    let url: URL
    let authorization: String?

    func request(path: String) -> URLRequest {
        var request = URLRequest(url: url.appendingPathComponent(path))
        if let authorization {
            request.setValue("Bearer \(authorization)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}

/// Checks GitHub releases for M5Paper firmware and installs it over Wi-Fi, like the computer apps.
@MainActor
final class PaperGIFFirmwareUpdater: ObservableObject {
    struct Release: Equatable {
        let version: String
        let firmwareURL: URL
        let sha256: String
        let size: Int
    }

    @Published private(set) var release: Release?
    /// nil when the M5Paper could not be reached.
    @Published private(set) var deviceFirmware: String?
    @Published private(set) var activity: String?
    @Published private(set) var problem: String?
    @Published private(set) var notice: String?

    static let usbOnlyVersion = "0.0.0"
    private static let repository = "Levi-5k/PaperRemote"
    private static let manifestName = "papergif-release.json"

    var updateAvailable: Bool {
        guard let release, let deviceFirmware else { return false }
        return Self.isNewer(release.version, than: deviceFirmware)
    }

    var needsUSB: Bool { updateAvailable && deviceFirmware == Self.usbOnlyVersion }

    func refresh(endpoint: PaperGIFDeviceEndpoint?) async {
        guard activity == nil else { return }
        activity = "Checking for updates…"
        defer { activity = nil }
        do {
            release = try await Self.latestRelease()
            problem = nil
        } catch {
            if release == nil { problem = "Could not check for updates: \(error.localizedDescription)" }
        }
        if let endpoint {
            deviceFirmware = await Self.installedVersion(at: endpoint)
        } else {
            deviceFirmware = nil
        }
    }

    func install(endpoint: PaperGIFDeviceEndpoint) async {
        guard activity == nil, updateAvailable, !needsUSB, let release else { return }
        problem = nil
        notice = nil
        defer { activity = nil }
        do {
            activity = "Downloading firmware \(release.version)…"
            let firmware = try await Self.download(release)
            activity = "Installing firmware \(release.version)… the M5Paper shows progress and restarts when done."
            try await Self.upload(firmware, to: endpoint)
            try await Self.waitForRestart(endpoint: endpoint, version: release.version)
            deviceFirmware = release.version
            notice = "The M5Paper restarted with firmware \(release.version)."
        } catch {
            problem = error.localizedDescription
        }
    }

    func dismissMessages() {
        problem = nil
        notice = nil
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func components(_ version: String) -> [Int] {
            let trimmed = version.hasPrefix("v") ? String(version.dropFirst()) : version
            return trimmed.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        var lhs = components(candidate)
        var rhs = components(current)
        let count = max(lhs.count, rhs.count)
        lhs += Array(repeating: 0, count: count - lhs.count)
        rhs += Array(repeating: 0, count: count - rhs.count)
        return rhs.lexicographicallyPrecedes(lhs)
    }

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
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    private struct Manifest: Decodable {
        struct Asset: Decodable {
            let name: String
            let sha256: String
            let size: Int
        }

        let version: String
        let firmware: Asset?
    }

    private struct DeviceStatus: Decodable {
        let device: String
        let firmware: String?
    }

    private struct DeviceError: Decodable {
        let error: String?
    }

    private enum UpdateError: LocalizedError {
        case unavailable(String)
        case checksumMismatch
        case rejected(String)
        case didNotRestart

        var errorDescription: String? {
            switch self {
            case .unavailable(let detail): detail
            case .checksumMismatch: "The firmware download failed its checksum and was discarded."
            case .rejected(let detail): "The M5Paper rejected the firmware: \(detail)"
            case .didNotRestart: "The firmware was sent, but the M5Paper did not come back with the new version."
            }
        }
    }

    private static func isTrusted(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "github.com"
    }

    private static func latestRelease() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.unavailable("No paperGIF release is available.")
        }
        let github = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let downloads = Dictionary(
            github.assets.filter { isTrusted($0.browserDownloadURL) }.map { ($0.name, $0.browserDownloadURL) },
            uniquingKeysWith: { first, _ in first }
        )
        guard let manifestURL = downloads[manifestName] else {
            throw UpdateError.unavailable("The latest release has no \(manifestName).")
        }
        let (manifestData, _) = try await URLSession.shared.data(from: manifestURL)
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        guard let firmware = manifest.firmware,
              let firmwareURL = downloads[firmware.name],
              firmware.sha256.count == 64, firmware.sha256.allSatisfy(\.isHexDigit), firmware.size > 0,
              !isNewer(github.tagName, than: manifest.version), !isNewer(manifest.version, than: github.tagName) else {
            throw UpdateError.unavailable("The latest release has no valid M5Paper firmware.")
        }
        return Release(version: manifest.version, firmwareURL: firmwareURL, sha256: firmware.sha256.lowercased(), size: firmware.size)
    }

    private static func installedVersion(at endpoint: PaperGIFDeviceEndpoint) async -> String? {
        var request = endpoint.request(path: "status")
        request.timeoutInterval = 4
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let status = try? JSONDecoder().decode(DeviceStatus.self, from: data),
              status.device == "paperGIF" else { return nil }
        return status.firmware ?? usbOnlyVersion
    }

    private static func download(_ release: Release) async throws -> Data {
        var request = URLRequest(url: release.firmwareURL)
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.unavailable("Could not download the firmware.")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard data.count == release.size, digest == release.sha256 else { throw UpdateError.checksumMismatch }
        return data
    }

    private static func upload(_ firmware: Data, to endpoint: PaperGIFDeviceEndpoint) async throws {
        let boundary = "paperGIF-\(UUID().uuidString)"
        var request = endpoint.request(path: "firmware")
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(String(firmware.count), forHTTPHeaderField: "X-PGIF-Size")
        request.setValue(
            Insecure.MD5.hash(data: firmware).map { String(format: "%02x", $0) }.joined(),
            forHTTPHeaderField: "X-PGIF-MD5"
        )
        var body = Data("--\(boundary)\r\n".utf8)
        body.append(Data("Content-Disposition: form-data; name=\"firmware\"; filename=\"firmware.bin\"\r\n".utf8))
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(firmware)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.upload(for: request, from: body)
        } catch {
            throw UpdateError.unavailable("Could not reach the M5Paper. Keep it on Wi-Fi and nearby.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let detail = (try? JSONDecoder().decode(DeviceError.self, from: data))?.error
            throw UpdateError.rejected(status == 401 ? "this iPhone is not authorized" : detail ?? "HTTP \(status)")
        }
    }

    private static func waitForRestart(endpoint: PaperGIFDeviceEndpoint, version: String) async throws {
        let deadline = Date().addingTimeInterval(90)
        try await Task.sleep(for: .seconds(4))
        while Date() < deadline {
            if let installed = await installedVersion(at: endpoint), !isNewer(version, than: installed) {
                return
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw UpdateError.didNotRestart
    }
}
