import Foundation
import XCTest
@testable import PaperGIFMac

@MainActor
final class DeviceBluetoothScannerTests: XCTestCase {
    func testAdvertisementsAreListedTaggedAndRefreshed() {
        let scanner = DeviceBluetoothScanner()
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(scanner.noteAdvertisement(id: id, name: nil, rssi: -70, at: start))
        XCTAssertEqual(scanner.nearby.first?.displayName, "PaperRemote device")

        XCTAssertTrue(scanner.noteAdvertisement(id: id, name: "paperGIF SuperMini S3", rssi: 127,
                                                at: start.addingTimeInterval(5)))
        XCTAssertEqual(scanner.nearby.count, 1)
        XCTAssertEqual(scanner.nearby.first?.name, "paperGIF SuperMini S3")
        XCTAssertEqual(scanner.nearby.first?.rssi, -70, "RSSI 127 means unavailable and must not overwrite")
        XCTAssertEqual(scanner.device(tag: "ble:\(id.uuidString)")?.id, id)
        XCTAssertNil(scanner.device(tag: "192.168.4.1"))
    }

    func testUnseenDevicesExpire() {
        let scanner = DeviceBluetoothScanner()
        let old = UUID(), fresh = UUID()
        let now = Date(timeIntervalSince1970: 2_000)
        _ = scanner.noteAdvertisement(id: old, name: "Old", rssi: -60, at: now.addingTimeInterval(-31))
        _ = scanner.noteAdvertisement(id: fresh, name: "Fresh", rssi: -60, at: now.addingTimeInterval(-5))

        scanner.expire(now: now)

        XCTAssertEqual(scanner.nearby.map(\.id), [fresh])
    }
}
