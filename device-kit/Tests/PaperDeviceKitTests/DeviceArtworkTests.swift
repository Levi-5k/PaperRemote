import ImageIO
import SwiftUI
import XCTest
@testable import PaperDeviceKit

final class DeviceArtworkTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testKnobBoardIncludesArtworkAndAlignedControls() async throws {
        var descriptor = try DeviceDescriptor.decode(Data(contentsOf: root.appendingPathComponent(
            "protocol/fixtures/device-descriptor-v1-screenless.json")))
        descriptor.boardID = "paperremote.supermini-s3-mt6701"
        descriptor.inputs = [
            DeviceInput(id: "button-1", name: "Left", kind: "button", events: ["press"]),
            DeviceInput(id: "button-2", name: "Right", kind: "button", events: ["press"]),
            DeviceInput(id: "dial-1", name: "Knob", kind: "dial", events: ["change"], minimum: 0, maximum: 16383)
        ]
        descriptor.layout = .generated(display: nil, inputs: descriptor.inputs)
        let index = try JSONDecoder().decode(BoardCatalogIndex.self,
            from: Data(contentsOf: root.appendingPathComponent("boards/index.json")))
        let entry = try XCTUnwrap(DeviceCatalog.match(index, descriptor: descriptor))
        let data = try Data(contentsOf: root.appendingPathComponent("boards/\(entry.path)"))
        XCTAssertLessThan(data.count, 65_536)
        let board = try DeviceCatalog.validated(data, descriptor: descriptor, entry: entry)
        XCTAssertEqual(board.version, 2)
        XCTAssertEqual(board.layout.width, 768)
        XCTAssertEqual(board.layout.height, 768)
        XCTAssertEqual(board.layout.inputs.map(\.id), ["button-1", "button-2", "dial-1"])
        let dial = try XCTUnwrap(board.layout.inputs.last)
        XCTAssertEqual(dial.x + dial.width / 2, 332)
        XCTAssertEqual(dial.y + dial.height / 2, 300)
        XCTAssertTrue(board.layout.inputs.prefix(2).allSatisfy { $0.y > dial.y + dial.height })
        let png = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(board.layout.artworkPNG)))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 384)
        XCTAssertEqual(image.height, 384)
        let roundTrip = try JSONDecoder().decode(DeviceLayout.self, from: JSONEncoder().encode(board.layout))
        XCTAssertEqual(roundTrip, board.layout)

        let catalog = DeviceCatalog(
            cacheDirectory: root.appendingPathComponent("nonexistent-artwork-cache"),
            indexURL: URL(string: "file:///nonexistent-board-index")!)
        let resolution = await catalog.resolve(descriptor: descriptor)
        XCTAssertEqual(resolution.layout, board.layout, "Bundled artwork must remain available offline")
    }

    func testMalformedAndOversizedArtworkRejected() {
        for encoded in ["", "not PNG data", Data("not a PNG".utf8).base64EncodedString(),
                        String(repeating: "A", count: 60_004)] {
            let layout = DeviceLayout(width: 100, height: 100, artworkPNG: encoded)
            XCTAssertThrowsError(try layout.validate(inputIDs: [], hasDisplay: false))
        }
    }

    func testOldLayoutsDoNotRequireArtwork() throws {
        let layout = try JSONDecoder().decode(DeviceLayout.self,
            from: Data(#"{"width":100,"height":100,"inputs":[]}"#.utf8))
        XCTAssertNil(layout.artworkPNG)
        try layout.validate(inputIDs: [], hasDisplay: false)
    }

    @MainActor
    func testArtworkIsVisibleUnderSelectableControls() throws {
        let board = try JSONDecoder().decode(BoardDefinition.self, from: Data(contentsOf:
            root.appendingPathComponent("boards/supermini-s3-mt6701.json")))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(
            XCTUnwrap(Data(base64Encoded: XCTUnwrap(board.layout.artworkPNG))) as CFData, nil))
        let original = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        func render(selected: String?) throws -> CGImage {
            let preview = DeviceBoardPreview(layout: board.layout, inputs: [], selectedInputID: selected, onSelect: { _ in })
                .frame(width: 384, height: 384)
            return try XCTUnwrap(ImageRenderer(content: preview).cgImage)
        }
        func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
            let cropped = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
            let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            return Array(UnsafeBufferPointer(start: bytes, count: 4))
        }
        let unselected = try render(selected: nil)
        XCTAssertEqual(unselected.width, 384)
        XCTAssertEqual(unselected.height, 384)
        for (x, y) in [(166, 150), (124, 306), (205, 306)] {
            let expected = try pixel(original, x: x, y: y)
            let actual = try pixel(unselected, x: x, y: y)
            for channel in 0..<4 {
                XCTAssertLessThanOrEqual(abs(Int(expected[channel]) - Int(actual[channel])), 3,
                                        "Control overlays must not hide the supplied artwork")
            }
        }
        let selected = try render(selected: "dial-1")
        XCTAssertNotEqual(try pixel(selected, x: 166, y: 150), try pixel(unselected, x: 166, y: 150))
        if let path = ProcessInfo.processInfo.environment["PAPERREMOTE_PREVIEW_SNAPSHOT"] {
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, unselected, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
    }
}
