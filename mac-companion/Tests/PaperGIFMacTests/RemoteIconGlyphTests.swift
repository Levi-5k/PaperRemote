import CoreGraphics
import XCTest
@testable import PaperGIFMac

final class RemoteIconGlyphTests: XCTestCase {
    func testEveryPickerIconHasTheDeviceOutline() {
        for icon in RemoteIcon.all {
            let path = RemoteIconGlyphs.path(named: icon.id)
            XCTAssertNotNil(path, icon.id)
            guard let bounds = path?.boundingBoxOfPath else { continue }
            XCTAssertGreaterThan(bounds.width * bounds.height, 0.01, icon.id)
            XCTAssertTrue(CGRect(x: 0, y: 0, width: 1, height: 1).insetBy(dx: -0.001, dy: -0.001).contains(bounds), icon.id)
        }
    }

    func testUnknownSymbolsHaveNoOutline() {
        XCTAssertNil(RemoteIconGlyphs.path(named: ""))
        XCTAssertNil(RemoteIconGlyphs.path(named: "square.dashed"))
        XCTAssertNotNil(RemoteIconGlyphs.templateImage(named: "power", size: 16))
        XCTAssertNil(RemoteIconGlyphs.templateImage(named: "keyboard", size: 16))
    }
}
