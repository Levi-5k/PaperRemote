import Foundation

/// Read-only access to the old library. Never use the storage/player helpers here:
/// their lookups create directories, and player initialization configures audio.
nonisolated enum PaperGIFLegacyMusicLibrary {
    nonisolated enum ExportError: LocalizedError, Equatable {
        case missingLibrary
        case emptyLibrary
        case invalidLibrary
        case unsupportedItem(String)

        var errorDescription: String? {
            switch self {
            case .missingLibrary:
                "No legacy music library was found on this device. Export from the device where you imported your music into paperGIF."
            case .emptyLibrary:
                "The legacy music library contains no files to export. Nothing has been changed."
            case .invalidLibrary:
                "The legacy Music location is not a regular folder. Nothing has been changed."
            case .unsupportedItem(let name):
                "The library contains an unsupported item or symbolic link: \(name). Nothing has been changed."
            }
        }
    }

    static func root(in applicationSupportDirectory: URL) -> URL {
        applicationSupportDirectory
            .appendingPathComponent("paperGIF-v2", isDirectory: true)
            .appendingPathComponent("Music", isDirectory: true)
    }

    /// Returns the existing Music root, not its contents or its parent.
    /// A library containing only empty subfolders is also considered empty.
    /// The optional base is for isolated tests; production always uses this app's container.
    static func exportRoot(
        applicationSupportDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let support: URL
        let library: URL
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        do {
            if let applicationSupportDirectory {
                support = applicationSupportDirectory
            } else {
                support = try fileManager.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: false
                )
            }
            library = root(in: support)
            let values = try library.resourceValues(forKeys: keys)
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw ExportError.invalidLibrary
            }
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            throw ExportError.missingLibrary
        }

        // Inspect metadata off the main actor before presenting Files. Do not
        // flatten, filter by audio extension, stage, move, or delete any content.
        var directories = [library]
        var containsFile = false
        while let directory = directories.popLast() {
            let children = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: []
            )
            for child in children {
                let values = try child.resourceValues(forKeys: keys)
                guard values.isSymbolicLink != true else {
                    throw ExportError.unsupportedItem(child.lastPathComponent)
                }
                if values.isDirectory == true {
                    directories.append(child)
                } else if values.isRegularFile == true {
                    guard fileManager.isReadableFile(atPath: child.path) else {
                        throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: child.path])
                    }
                    containsFile = true
                } else {
                    throw ExportError.unsupportedItem(child.lastPathComponent)
                }
            }
        }
        guard containsFile else { throw ExportError.emptyLibrary }
        return library
    }
}