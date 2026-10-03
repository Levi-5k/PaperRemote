import Foundation
import Testing
@testable import paperGIF

struct PaperGIFLegacyMusicLibraryTests {
    @Test func legacyPathIsExactAndConstructionDoesNotCreateIt() throws {
        try withTemporaryDirectory { support in
            let before = try snapshot(support)
            let root = PaperGIFLegacyMusicLibrary.root(in: support)

            #expect(root.path == support.path + "/paperGIF-v2/Music")
            #expect(!FileManager.default.fileExists(atPath: root.path))
            #expect(try snapshot(support) == before)
        }
    }

    @Test func missingApplicationSupportIsNotCreated() throws {
        try withTemporaryDirectory { sandbox in
            let support = sandbox.appendingPathComponent("Missing Application Support", isDirectory: true)
            let before = try snapshot(sandbox)

            #expect(throws: PaperGIFLegacyMusicLibrary.ExportError.missingLibrary) {
                try PaperGIFLegacyMusicLibrary.exportRoot(applicationSupportDirectory: support)
            }

            #expect(!FileManager.default.fileExists(atPath: support.path))
            #expect(try snapshot(sandbox) == before)
        }
    }

    @Test func missingMusicDoesNotChangeOtherAppData() throws {
        try withTemporaryDirectory { support in
            try write(Data("remote".utf8), relativePath: "paperGIF-v2/Remote/remote-profile.json", in: support)
            try write(Data("media".utf8), relativePath: "paperGIF-v2/Media/item.pgif", in: support)
            let before = try snapshot(support)

            #expect(throws: PaperGIFLegacyMusicLibrary.ExportError.missingLibrary) {
                try PaperGIFLegacyMusicLibrary.exportRoot(applicationSupportDirectory: support)
            }

            #expect(try snapshot(support) == before)
        }
    }

    @Test(arguments: [false, true])
    func emptyLibraryIncludingEmptyDefaultFolderIsNotChanged(nested: Bool) throws {
        try withTemporaryDirectory { support in
            let root = PaperGIFLegacyMusicLibrary.root(in: support)
            let emptyFolder = nested ? root.appendingPathComponent("Music/Empty Album", isDirectory: true) : root
            try FileManager.default.createDirectory(at: emptyFolder, withIntermediateDirectories: true)
            let before = try snapshot(support)

            #expect(throws: PaperGIFLegacyMusicLibrary.ExportError.emptyLibrary) {
                try PaperGIFLegacyMusicLibrary.exportRoot(applicationSupportDirectory: support)
            }

            #expect(try snapshot(support) == before)
        }
    }

    @Test func exportReturnsOuterMusicRootAndPreservesCompleteTree() throws {
        try withTemporaryDirectory { support in
            let root = PaperGIFLegacyMusicLibrary.root(in: support)
            // The old default collection is Music/Music. Neither that collection
            // nor files with matching basenames in other folders may be flattened.
            try write(Data([0, 1, 2, 255]), relativePath: "paperGIF-v2/Music/Music/Song.m4a", in: support)
            try write(Data([3, 4, 5]), relativePath: "paperGIF-v2/Music/Artíst/Album/Song.m4a", in: support)
            try write(Data("notes".utf8), relativePath: "paperGIF-v2/Music/Artíst/Album/notes.txt", in: support)
            try write(Data("hidden".utf8), relativePath: "paperGIF-v2/Music/.metadata", in: support)
            try write(Data("media".utf8), relativePath: "paperGIF-v2/Media/item.pgif", in: support)
            try write(Data("remote".utf8), relativePath: "paperGIF-v2/Remote/remote-profile.json", in: support)
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("Empty Folder", isDirectory: true),
                withIntermediateDirectories: true
            )
            let before = try snapshot(support)

            for _ in 0..<2 {
                let exportedRoot = try PaperGIFLegacyMusicLibrary.exportRoot(applicationSupportDirectory: support)
                #expect(exportedRoot == root)
                #expect(try snapshot(support) == before)
            }
        }
    }

    @Test func fileAtMusicPathIsNotReplacedWithDirectory() throws {
        try withTemporaryDirectory { support in
            try write(Data("not a folder".utf8), relativePath: "paperGIF-v2/Music", in: support)
            let before = try snapshot(support)

            #expect(throws: PaperGIFLegacyMusicLibrary.ExportError.invalidLibrary) {
                try PaperGIFLegacyMusicLibrary.exportRoot(applicationSupportDirectory: support)
            }

            #expect(try snapshot(support) == before)
        }
    }

    @Test(arguments: [false, true])
    func symbolicLinksAreRejectedWithoutFollowingOrChangingThem(atRoot: Bool) throws {
        try withTemporaryDirectory { support in
            let root = PaperGIFLegacyMusicLibrary.root(in: support)
            let outside = support.appendingPathComponent("Outside", isDirectory: true)
            try write(Data("private".utf8), relativePath: "Outside/Other.txt", in: support)
            try FileManager.default.createDirectory(
                at: atRoot ? root.deletingLastPathComponent() : root,
                withIntermediateDirectories: true
            )
            let link = atRoot ? root : root.appendingPathComponent("External", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            let before = try snapshot(support)
            let expected: PaperGIFLegacyMusicLibrary.ExportError = atRoot
                ? .invalidLibrary : .unsupportedItem("External")

            #expect(throws: expected) {
                try PaperGIFLegacyMusicLibrary.exportRoot(applicationSupportDirectory: support)
            }

            #expect(try snapshot(support) == before)
        }
    }

    private struct Entry: Equatable {
        let modificationDate: Date?
        let contents: Data?
        let linkDestination: String?
    }

    /// Include directories, file bytes, symlinks and modification dates; ignore
    /// access times, which a read-only filesystem lookup may legitimately change.
    private func snapshot(_ directory: URL) throws -> [String: Entry] {
        let manager = FileManager.default
        var result: [String: Entry] = [:]
        for path in [""] + (try manager.subpathsOfDirectory(atPath: directory.path)) {
            let url = path.isEmpty ? directory : directory.appendingPathComponent(path)
            let attributes = try manager.attributesOfItem(atPath: url.path)
            let type = attributes[.type] as? FileAttributeType
            result[path] = Entry(
                modificationDate: attributes[.modificationDate] as? Date,
                contents: type == .typeRegular ? try Data(contentsOf: url) : nil,
                linkDestination: type == .typeSymbolicLink
                    ? try manager.destinationOfSymbolicLink(atPath: url.path) : nil
            )
        }
        return result
    }

    private func write(_ data: Data, relativePath: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("paperGIF-migration-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}