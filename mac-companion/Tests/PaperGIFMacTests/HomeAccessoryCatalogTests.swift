import XCTest
@testable import PaperGIFMac

final class HomeAccessoryCatalogTests: XCTestCase {
    private func payload(_ accessories: [[String: String]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["accessories": accessories])
    }

    private func accessory(name: String = "Desk Lamp", accessoryID: String = UUID().uuidString) -> [String: String] {
        ["homeName": "Home", "accessoryName": name, "serviceName": name,
         "accessoryID": accessoryID, "serviceID": UUID().uuidString]
    }

    func testAcceptsWellFormedSharedAccessories() {
        let accessories = HomeAccessoryCatalog.validated(payload([accessory(), accessory(name: "Fan")]))
        XCTAssertEqual(accessories?.map(\.accessoryName), ["Desk Lamp", "Fan"])
        XCTAssertEqual(accessories?.first?.displayName, "Home · Desk Lamp")
    }

    func testRejectsMalformedOversizedOrNonUUIDLists() {
        XCTAssertNil(HomeAccessoryCatalog.validated(Data("not json".utf8)))
        XCTAssertNil(HomeAccessoryCatalog.validated(payload([accessory(accessoryID: "not-a-uuid")])))
        XCTAssertNil(HomeAccessoryCatalog.validated(payload([accessory(name: String(repeating: "x", count: 129))])))
        let tooMany = (0...HomeAccessoryCatalog.maximumAccessories).map { _ in accessory() }
        XCTAssertNil(HomeAccessoryCatalog.validated(payload(tooMany)))
    }

    @MainActor
    func testReplacePersistsForTheNextLaunch() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/home.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let shared = try XCTUnwrap(HomeAccessoryCatalog.validated(payload([accessory()])))

        try HomeAccessoryCatalog(fileURL: file).replace(with: shared)

        XCTAssertEqual(HomeAccessoryCatalog(fileURL: file).accessories, shared)
    }
}
