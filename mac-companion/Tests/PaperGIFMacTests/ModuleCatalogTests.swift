import Foundation
import XCTest
@testable import PaperGIFMac

final class ModuleCatalogTests: XCTestCase {
    func testSharedModuleManifestCreatesControlsWithFreshIDs() throws {
        let module = try JSONDecoder().decode(
            PaperModuleManifest.self,
            from: Data(contentsOf: moduleFixture("media-controls.json"))
        )

        XCTAssertEqual(module.schemaVersion, 1)
        XCTAssertEqual(module.id, "media-controls")
        XCTAssertEqual(module.controls.count, 6)

        let definition = try XCTUnwrap(module.controls.first)
        let template = RemoteControlTemplate.module(module, control: definition)
        let first = template.control
        let second = template.control

        XCTAssertNotEqual(definition.control.id, first.id)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(definition.control.action, first.action)
    }

    func testOpenBuildsModuleContainsOnlyOpenBuildsActions() throws {
        let module = try JSONDecoder().decode(
            PaperModuleManifest.self,
            from: Data(contentsOf: moduleFixture("openbuilds-control.json"))
        )

        XCTAssertEqual(module.id, "openbuilds-control")
        XCTAssertEqual(module.controls.count, 16)
        XCTAssertTrue(module.controls.allSatisfy { $0.control.action.type == .openBuilds })
        let definition = try XCTUnwrap(module.pages?.first)
        let page = ModuleCatalog.clonePage(definition, moduleID: module.id)
        XCTAssertEqual(page.layout, .openBuildsController)
        XCTAssertEqual(page.gridColumns, 9)
        XCTAssertEqual(page.gridRows, 14)
        XCTAssertEqual(page.openBuildsController?.jogMode, .incremental)
        XCTAssertEqual(page.controls.count, 11)
        XCTAssertEqual(page.controls[0].gridSpan(columns: page.gridColumns, rows: page.gridRows),
                   RemoteGridSpan(width: 3, height: 2))
        XCTAssertEqual(page.controls[3].layoutSlot, 18)
        XCTAssertEqual(page.controls[3].gridSpan(columns: page.gridColumns, rows: page.gridRows),
                   RemoteGridSpan(width: 2, height: 2))
        XCTAssertEqual(page.moduleID, module.id)
        XCTAssertNotEqual(page.id, definition.page.id)
        XCTAssertTrue(zip(page.controls, definition.page.controls).allSatisfy { $0.id != $1.id })
    }
}

private func moduleFixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("modules")
        .appendingPathComponent(name)
}