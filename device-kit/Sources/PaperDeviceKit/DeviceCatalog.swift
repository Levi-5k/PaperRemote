import CryptoKit
import Foundation

public struct BoardDefinition: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var boardID: String
    public var hardwareRevisions: [String]
    public var version: Int
    public var name: String
    public var layout: DeviceLayout
}

public struct BoardCatalogIndex: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public var boardID: String
        public var hardwareRevisions: [String]
        public var version: Int
        public var path: String
        public var sha256: String
    }
    public var schemaVersion: Int
    public var boards: [Entry]
}

public struct BoardResolution: Sendable {
    public var layout: DeviceLayout
    public var message: String
}

final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

public enum DeviceHTTP {
    public static func validateProfileAcknowledgement(_ data: Data, status: Int) throws {
        struct Acknowledgement: Decodable { let ok: Bool }
        guard status == 200 || status == 201 else {
            throw DeviceContractError.invalid("profile upload HTTP \(status)")
        }
        let acknowledgement = try JSONDecoder().decode(Acknowledgement.self, from: data)
        guard acknowledgement.ok else {
            throw DeviceContractError.invalid("the device did not install the profile")
        }
    }

    public static func endpoint(_ address: String, path: String) throws -> URL {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: address.contains("://") ? address : "http://\(address)"),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.port == nil || (1...65535).contains(parts.port!) else {
            throw DeviceContractError.invalid("enter a hostname or address with optional port")
        }
        parts.path = path
        guard let url = parts.url else { throw DeviceContractError.invalid("device address") }
        return url
    }

    /// One keep-alive session for all device requests, so repeated control and
    /// profile requests reuse the TCP connection instead of reconnecting.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    public static func request(_ request: URLRequest, maximumBytes: Int,
                               timeout: TimeInterval = 10) async throws -> (Data, Int) {
        var request = request
        request.timeoutInterval = timeout
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse,
              response.expectedContentLength <= maximumBytes else {
            throw DeviceContractError.invalid("response exceeds download limit")
        }
        var data = Data()
        data.reserveCapacity(max(0, min(maximumBytes, Int(response.expectedContentLength))))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else {
                throw DeviceContractError.invalid("response exceeds download limit")
            }
            data.append(byte)
        }
        return (data, response.statusCode)
    }
}

public actor DeviceCatalog {
    public static let indexURL = URL(string: "https://raw.githubusercontent.com/Levi-5k/PaperRemote/main/boards/index.json")!
    private let cacheDirectory: URL
    private let indexURL: URL

    public init(cacheDirectory: URL? = nil, indexURL: URL = DeviceCatalog.indexURL) {
        self.cacheDirectory = cacheDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PaperRemote/boards", isDirectory: true)
        self.indexURL = indexURL
    }

    public static func match(_ index: BoardCatalogIndex, descriptor: DeviceDescriptor) throws -> BoardCatalogIndex.Entry? {
        guard index.schemaVersion == 1, index.boards.count <= 4096 else {
            throw DeviceContractError.invalid("board catalog version or size")
        }
        let matches = index.boards.filter {
            $0.boardID == descriptor.boardID && $0.hardwareRevisions.contains(descriptor.hardwareRevision)
        }
        let sorted = matches.sorted { $0.version > $1.version }
        if sorted.count > 1, sorted[0].version == sorted[1].version {
            throw DeviceContractError.invalid("ambiguous catalog entries")
        }
        return sorted.first
    }

    public static func validated(_ data: Data, descriptor: DeviceDescriptor,
                                 entry: BoardCatalogIndex.Entry? = nil) throws -> BoardDefinition {
        guard data.count <= 262_144 else { throw DeviceContractError.invalid("board package size") }
        if let entry {
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard entry.sha256 == digest else { throw DeviceContractError.invalid("board package digest") }
        }
        let board = try JSONDecoder().decode(BoardDefinition.self, from: data)
        guard board.schemaVersion == 1, board.version > 0, !board.name.isEmpty,
              board.boardID == descriptor.boardID,
              board.hardwareRevisions.contains(descriptor.hardwareRevision),
              entry == nil || board.version == entry?.version else {
            throw DeviceContractError.invalid("board identity, revision or version mismatch")
        }
        try board.layout.validate(inputIDs: Set(descriptor.inputs.map(\.id)), hasDisplay: descriptor.display != nil)
        return board
    }

    private func cacheURL(_ descriptor: DeviceDescriptor) -> URL {
        let identity = Data("\(descriptor.boardID)\n\(descriptor.hardwareRevision)".utf8)
        let key = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent("\(key).json")
    }

    public func resolve(descriptor: DeviceDescriptor) async -> BoardResolution {
        var layout = descriptor.layout
        var source = "device layout"
        var cacheProblem: String?
        let cached = cacheURL(descriptor)
        if FileManager.default.fileExists(atPath: cached.path) {
            do {
                layout = try Self.validated(Data(contentsOf: cached), descriptor: descriptor).layout
                source = "cached board layout"
            } catch { cacheProblem = "Cached layout rejected: \(error.localizedDescription). " }
        } else if let bundled = Bundle.module.url(forResource: "index", withExtension: "json", subdirectory: "Boards") {
            do {
                let index = try JSONDecoder().decode(BoardCatalogIndex.self, from: Data(contentsOf: bundled))
                if let entry = try Self.match(index, descriptor: descriptor) {
                    let url = try Self.packageURL(entry.path, relativeTo: bundled)
                    layout = try Self.validated(Data(contentsOf: url), descriptor: descriptor, entry: entry).layout
                    source = "bundled board layout"
                }
            } catch { cacheProblem = "Bundled layout rejected: \(error.localizedDescription). " }
        }
        do {
            guard indexURL.scheme == "https", indexURL.host == "raw.githubusercontent.com",
                  indexURL.path == "/Levi-5k/PaperRemote/main/boards/index.json" else {
                throw DeviceContractError.invalid("catalog must use the curated repository")
            }
            let (indexData, indexStatus) = try await DeviceHTTP.request(URLRequest(url: indexURL), maximumBytes: 1_048_576)
            guard indexStatus == 200 else { throw DeviceContractError.invalid("catalog HTTP \(indexStatus)") }
            let index = try JSONDecoder().decode(BoardCatalogIndex.self, from: indexData)
            guard let entry = try Self.match(index, descriptor: descriptor) else {
                return BoardResolution(layout: layout, message: "\(cacheProblem ?? "")No matching GitHub board; using \(source).")
            }
            let url = try Self.packageURL(entry.path, relativeTo: indexURL)
            let (data, status) = try await DeviceHTTP.request(URLRequest(url: url), maximumBytes: 262_144)
            guard status == 200 else { throw DeviceContractError.invalid("board package HTTP \(status)") }
            let board = try Self.validated(data, descriptor: descriptor, entry: entry)
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try data.write(to: cached, options: .atomic)
            return BoardResolution(layout: board.layout, message: "GitHub board layout v\(board.version)")
        } catch {
            return BoardResolution(layout: layout, message: "\(cacheProblem ?? "")GitHub unavailable: \(error.localizedDescription). Using \(source).")
        }
    }

    private static func packageURL(_ path: String, relativeTo index: URL) throws -> URL {
        guard !path.isEmpty, path.utf8.count <= 128,
              path.hasSuffix(".json"), !path.contains(".."), !path.contains("/"),
              path.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }) else {
            throw DeviceContractError.invalid("unsafe catalog package path")
        }
        return index.deletingLastPathComponent().appendingPathComponent(path)
    }
}
