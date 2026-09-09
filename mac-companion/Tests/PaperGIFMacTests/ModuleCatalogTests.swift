import Foundation
import XCTest
@testable import PaperGIFMac

final class ModuleCatalogTests: XCTestCase {
    func testModuleVersionComparisonPreventsDowngrades() {
        XCTAssertTrue(ModuleCatalog.isVersion("1.4.0", newerThan: "1.3.0"))
        XCTAssertTrue(ModuleCatalog.isVersion("1.10.0", newerThan: "1.9.0"))
        XCTAssertFalse(ModuleCatalog.isVersion("1.3.0", newerThan: "1.4.0"))
        XCTAssertFalse(ModuleCatalog.isVersion("1.4.0", newerThan: "1.4.0"))
    }

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
        XCTAssertEqual(module.controls.count, 19)
        XCTAssertTrue(module.controls.allSatisfy { $0.control.action.type == .openBuilds })
        let definition = try XCTUnwrap(module.pages?.first)
        let page = ModuleCatalog.clonePage(definition, moduleID: module.id)
        XCTAssertEqual(page.layout, .openBuildsController)
        XCTAssertEqual(page.gridColumns, 9)
        XCTAssertEqual(page.gridRows, 14)
        XCTAssertEqual(page.openBuildsController?.jogMode, .incremental)
        XCTAssertEqual(page.openBuildsController?.units, .millimeters)
        XCTAssertEqual(page.openBuildsController?.jogDistanceThousandths, 1_000)
        XCTAssertEqual(page.controls.count, 22)
        XCTAssertEqual(page.controls[0].gridSpan(columns: page.gridColumns, rows: page.gridRows),
                   RemoteGridSpan(width: 3, height: 2))
        XCTAssertEqual(page.controls[3].layoutSlot, 18)
        XCTAssertEqual(page.controls[3].gridSpan(columns: page.gridColumns, rows: page.gridRows),
                   RemoteGridSpan(width: 3, height: 1))
        XCTAssertEqual(page.controls.first(where: { $0.title == "STOP" })?.layoutSlot, 47)
        XCTAssertEqual(page.controls.filter { $0.action.text.hasPrefix("zero") }.count, 3)
        XCTAssertEqual(page.moduleID, module.id)
        XCTAssertNotEqual(page.id, definition.page.id)
        XCTAssertTrue(zip(page.controls, definition.page.controls).allSatisfy { $0.id != $1.id })
    }

    func testUpdatingModulePagePreservesIdentitySettingsAndRouting() throws {
        let module = try JSONDecoder().decode(
            PaperModuleManifest.self,
            from: Data(contentsOf: moduleFixture("openbuilds-control.json"))
        )
        let definition = try XCTUnwrap(module.pages?.first)
        var existing = ModuleCatalog.clonePage(definition, moduleID: module.id)
        existing.name = "Workshop CNC"
        existing.openBuildsController?.jogSpeed = 2_500
        existing.controls.removeAll { $0.title == "STOP" }
        for index in existing.controls.indices {
            existing.controls[index].action.computerID = "windows-computer"
            existing.controls[index].action.host = "10.0.0.25"
            if existing.controls[index].textBox?.source == .openBuildsPosition {
                existing.controls[index].textBox?.computerID = UUID(
                    uuidString: "11111111-1111-1111-1111-111111111111"
                )
                existing.controls[index].textBox?.sourceText = "10.0.0.25|x|mm"
            }
        }
        let existingID = existing.id
        let xControlID = try XCTUnwrap(existing.controls.first { $0.title == "X+" }?.id)

        let updated = ModuleCatalog.updatedPage(existing, from: definition, moduleID: module.id)

        XCTAssertEqual(updated.id, existingID)
        XCTAssertEqual(updated.name, "Workshop CNC")
        XCTAssertEqual(updated.openBuildsController?.jogSpeed, 2_500)
        XCTAssertEqual(updated.controls.first { $0.title == "X+" }?.id, xControlID)
        XCTAssertNotNil(updated.controls.first { $0.title == "STOP" })
        XCTAssertTrue(updated.controls.allSatisfy { $0.action.computerID == "windows-computer" })
        XCTAssertTrue(updated.controls.allSatisfy { $0.action.host == "10.0.0.25" })
        XCTAssertTrue(updated.controls.compactMap(\.textBox).allSatisfy {
            $0.computerID?.uuidString == "11111111-1111-1111-1111-111111111111" &&
                $0.sourceText.hasPrefix("10.0.0.25|")
        })
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