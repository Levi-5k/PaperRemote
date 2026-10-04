import XCTest
@testable import PaperGIFMac

final class MatterDeviceManagerTests: XCTestCase {
    func testPairingCodesAcceptAppleHomeFormatsAndQRPayloads() {
        XCTAssertEqual(MatterDeviceManager.normalizedPairingCode(" 2011-505-9866 "), "20115059866")
        XCTAssertEqual(MatterDeviceManager.normalizedPairingCode("2011 505 9866"), "20115059866")
        XCTAssertEqual(MatterDeviceManager.normalizedPairingCode("MT:Y.K9042C00KA0648G00"), "MT:Y.K9042C00KA0648G00")
        XCTAssertTrue(MatterDeviceManager.isPlausiblePairingCode("2011-505-9866"))
        XCTAssertTrue(MatterDeviceManager.isPlausiblePairingCode("mt:Y.K9042C00KA0648G00"))
    }

    func testIncompletePairingCodesAreRejectedBeforeContactingTheModule() {
        XCTAssertFalse(MatterDeviceManager.isPlausiblePairingCode(""))
        XCTAssertFalse(MatterDeviceManager.isPlausiblePairingCode("2011-505"))
        XCTAssertFalse(MatterDeviceManager.isPlausiblePairingCode("MT:"))
    }

    func testManageRequestsCarryTheirOwnTypeSoDeviceActionsCannotReachThem() throws {
        let data = try JSONEncoder().encode(ModuleManageRequest(command: "list"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "manage")
        XCTAssertEqual(object["command"] as? String, "list")
    }
}
