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
        XCTAssertEqual(module.controls.count, 12)
        XCTAssertTrue(module.controls.allSatisfy { $0.control.action.type == .openBuilds })
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