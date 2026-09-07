import CoreGraphics
import Foundation

enum PaperGIFMonochromeMode: String, CaseIterable, Identifiable, Sendable {
    case threshold
    case monochrome
    case halftone
    case combined

    var id: Self { self }

    var title: String {
        switch self {
        case .threshold: "Threshold"
        case .monochrome: "Mono"
        case .halftone: "Halftone"
        case .combined: "Both"
        }
    }

    var usesThreshold: Bool { self != .halftone }
    var usesMonochromeLevels: Bool { self == .monochrome || self == .combined }
    var usesHalftone: Bool { self == .halftone || self == .combined }
}

struct PaperGIFConversionRecipe: Equatable, Sendable {
    var cropRect: CGRect?
    var rotationQuarterTurns: Int
    var monochromeMode: PaperGIFMonochromeMode
    var threshold: Double
    var monochromeLevels: Int
    var halftoneDotSpacing: Int
    var halftoneAngle: Int
    var halftoneDotGain: Int
    var maximumFramesPerSecond: Double
    var scanRateHz: Int
    var transitionScans: Int
    var cleanRefreshInterval: Int
    var adaptiveCleaning: Bool

    nonisolated var playbackConfiguration: PaperGIFPlaybackConfiguration {
        PaperGIFPlaybackConfiguration(
            scanRateHz: UInt16(clamping: scanRateHz),
            transitionScans: UInt8(clamping: transitionScans),
            cleanRefreshInterval: UInt16(clamping: cleanRefreshInterval),
            adaptiveCleaning: adaptiveCleaning
        )
    }
}

enum PaperGIFStorage {
    struct SavedMedia: Identifiable, Sendable {
        let id: UUID
        let name: String
        let savedAt: Date
        let byteCount: Int
        let isEditable: Bool
    }

    struct LoadedMedia: Sendable {
        let data: Data
        let sourceData: Data?
        let recipe: PaperGIFConversionRecipe?
    }

    nonisolated private static let packageExtension = "pgif"
    nonisolated private static let remoteProfileFilename = "remote-profile.json"

    nonisolated static func loadRemoteProfile() -> PaperGIFRemoteProfile {
        guard let data = try? Data(contentsOf: remoteProfileURL()),
              let profile = try? JSONDecoder().decode(PaperGIFRemoteProfile.self, from: data),
              profile.version == PaperGIFRemoteProfile.currentVersion else {
            return .starter
        }
        return profile
    }

    nonisolated static func saveRemoteProfile(_ profile: PaperGIFRemoteProfile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(
            at: try storageDirectory(),
            withIntermediateDirectories: true
        )
        try encoder.encode(profile).write(to: remoteProfileURL(), options: .atomic)
    }

    nonisolated private static func remoteProfileURL() -> URL {
        (try? storageDirectory().appendingPathComponent(remoteProfileFilename)) ??
            FileManager.default.temporaryDirectory.appendingPathComponent(remoteProfileFilename)
    }

    nonisolated static func save(
        id: UUID? = nil,
        name: String,
        data: Data,
        sourceData: Data? = nil,
        recipe: PaperGIFConversionRecipe? = nil
    ) throws -> SavedMedia {
        let directory = try storageDirectory()
        let id = id ?? UUID()
        let savedAt = Date()
        try data.write(to: packageURL(for: id, in: directory), options: .atomic)
        try Data(name.utf8).write(to: nameURL(for: id, in: directory), options: .atomic)
        if let sourceData, let recipe {
            try sourceData.write(to: sourceURL(for: id, in: directory), options: .atomic)
            try recipeData(recipe).write(to: recipeURL(for: id, in: directory), options: .atomic)
        }
        return SavedMedia(
            id: id,
            name: name,
            savedAt: savedAt,
            byteCount: data.count,
            isEditable: sourceData != nil && recipe != nil
        )
    }

    nonisolated static func loadAll() throws -> [SavedMedia] {
        let directory = try storageDirectory()
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        return try urls.compactMap { url in
            guard url.pathExtension == packageExtension,
                  let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
                return nil
            }
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let name = (try? Data(contentsOf: nameURL(for: id, in: directory)))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "Saved Media"
            return SavedMedia(
                id: id,
                name: name,
                savedAt: values.contentModificationDate ?? .distantPast,
                byteCount: values.fileSize ?? 0,
                isEditable: FileManager.default.fileExists(atPath: sourceURL(for: id, in: directory).path) &&
                    FileManager.default.fileExists(atPath: recipeURL(for: id, in: directory).path)
            )
        }
        .sorted { $0.savedAt > $1.savedAt }
    }

    nonisolated static func load(_ savedMedia: SavedMedia) throws -> LoadedMedia {
        let directory = try storageDirectory()
        let recipe = savedMedia.isEditable
            ? decodeRecipe(try Data(contentsOf: recipeURL(for: savedMedia.id, in: directory)))
            : nil
        return LoadedMedia(
            data: try Data(contentsOf: packageURL(for: savedMedia.id, in: directory)),
            sourceData: savedMedia.isEditable
                ? try Data(contentsOf: sourceURL(for: savedMedia.id, in: directory))
                : nil,
            recipe: recipe
        )
    }

    nonisolated static func loadData(_ savedMedia: SavedMedia) throws -> Data {
        try Data(contentsOf: packageURL(for: savedMedia.id, in: storageDirectory()))
    }

    nonisolated static func delete(_ savedMedia: SavedMedia) throws {
        let directory = try storageDirectory()
        try FileManager.default.removeItem(at: packageURL(for: savedMedia.id, in: directory))
        try? FileManager.default.removeItem(at: nameURL(for: savedMedia.id, in: directory))
        try? FileManager.default.removeItem(at: sourceURL(for: savedMedia.id, in: directory))
        try? FileManager.default.removeItem(at: recipeURL(for: savedMedia.id, in: directory))
    }

    nonisolated private static func storageDirectory() throws -> URL {
        let baseURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = baseURL
            .appendingPathComponent("paperGIF", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    nonisolated private static func packageURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension(packageExtension)
    }

    nonisolated private static func nameURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("txt")
    }

    nonisolated private static func sourceURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("source")
    }

    nonisolated private static func recipeURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    nonisolated private static func recipeData(_ recipe: PaperGIFConversionRecipe) throws -> Data {
        var object: [String: Any] = [
            "rotationQuarterTurns": recipe.rotationQuarterTurns,
            "monochromeMode": recipe.monochromeMode.rawValue,
            "threshold": recipe.threshold,
            "monochromeLevels": recipe.monochromeLevels,
            "halftoneDotSpacing": recipe.halftoneDotSpacing,
            "halftoneAngle": recipe.halftoneAngle,
            "halftoneDotGain": recipe.halftoneDotGain,
            "maximumFramesPerSecond": recipe.maximumFramesPerSecond,
            "scanRateHz": recipe.scanRateHz,
            "transitionScans": recipe.transitionScans,
            "cleanRefreshInterval": recipe.cleanRefreshInterval,
            "adaptiveCleaning": recipe.adaptiveCleaning,
        ]
        if let cropRect = recipe.cropRect {
            object["cropRect"] = [cropRect.origin.x, cropRect.origin.y, cropRect.width, cropRect.height]
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    nonisolated private static func decodeRecipe(_ data: Data) -> PaperGIFConversionRecipe? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rotationQuarterTurns = object["rotationQuarterTurns"] as? Int,
              let threshold = object["threshold"] as? Double,
              let maximumFramesPerSecond = object["maximumFramesPerSecond"] as? Double,
              let scanRateHz = object["scanRateHz"] as? Int,
              let transitionScans = object["transitionScans"] as? Int,
              let cleanRefreshInterval = object["cleanRefreshInterval"] as? Int,
              let adaptiveCleaning = object["adaptiveCleaning"] as? Bool else {
            return nil
        }
        let cropValues = object["cropRect"] as? [Double]
        let cropRect = cropValues.flatMap { values -> CGRect? in
            guard values.count == 4 else { return nil }
            return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        }
        return PaperGIFConversionRecipe(
            cropRect: cropRect,
            rotationQuarterTurns: rotationQuarterTurns,
            monochromeMode: (object["monochromeMode"] as? String)
                .flatMap(PaperGIFMonochromeMode.init(rawValue:)) ?? .threshold,
            threshold: threshold,
            monochromeLevels: object["monochromeLevels"] as? Int ?? 16,
            halftoneDotSpacing: object["halftoneDotSpacing"] as? Int ?? 8,
            halftoneAngle: object["halftoneAngle"] as? Int ?? 45,
            halftoneDotGain: object["halftoneDotGain"] as? Int ?? 0,
            maximumFramesPerSecond: maximumFramesPerSecond,
            scanRateHz: scanRateHz,
            transitionScans: transitionScans,
            cleanRefreshInterval: cleanRefreshInterval,
            adaptiveCleaning: adaptiveCleaning
        )
    }
}