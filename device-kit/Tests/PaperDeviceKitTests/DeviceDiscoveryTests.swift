import Foundation
import XCTest
@testable import PaperDeviceKit

@MainActor
final class DeviceDiscoveryTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Self.root.appendingPathComponent("protocol/fixtures/\(name)"))
    }

    private func pages(_ data: Data) -> [Data] {
        stride(from: 0, to: data.count, by: DeviceBLEDescriptorReader.pageSize).map {
            data.subdata(in: $0..<min($0 + DeviceBLEDescriptorReader.pageSize, data.count))
        }
    }

    func testReaderAssemblesMultiplePagesAndRequiresEOFRead() throws {
        var json = try fixture("device-descriptor-v1-controls.json")
        while json.count <= DeviceBLEDescriptorReader.pageSize || json.count % DeviceBLEDescriptorReader.pageSize == 0 {
            json.append(0x20)
        }
        var reader = DeviceBLEDescriptorReader()
        var result: DeviceDescriptor?
        for page in pages(json) {
            XCTAssertNil(result)
            result = try reader.append(page)
        }
        XCTAssertNil(result, "The final short page must be followed by an EOF read to release the lease")
        let descriptor = try XCTUnwrap(try reader.append(Data()))
        XCTAssertEqual(descriptor.boardID, "fixture.controls")
        XCTAssertThrowsError(try reader.append(Data()))
        XCTAssertEqual(DeviceBLEDescriptorReader.offsetRequest(0x01020304), Data([4, 3, 2, 1]))
    }

    func testReaderRejectsOversizedAndInvalidPages() throws {
        var reader = DeviceBLEDescriptorReader()
        XCTAssertThrowsError(try reader.append(Data(count: DeviceBLEDescriptorReader.pageSize + 1)))
        var invalid = DeviceBLEDescriptorReader()
        XCTAssertThrowsError(try invalid.append(Data("{not json".utf8)))
        var overflow = DeviceBLEDescriptorReader()
        for _ in 0..<(DeviceBLEDescriptorReader.maximumBytes / DeviceBLEDescriptorReader.pageSize) {
            XCTAssertNil(try overflow.append(Data(repeating: 0x20, count: DeviceBLEDescriptorReader.pageSize)))
        }
        XCTAssertThrowsError(try overflow.append(Data("{}".utf8)))
        var trailing = DeviceBLEDescriptorReader()
        XCTAssertNil(try trailing.append(fixture("device-descriptor-v1-minimal.json")))
        XCTAssertThrowsError(try trailing.append(Data("x".utf8)))
    }

    func testRememberAddsDiscoveredDeviceWithoutChangingSelection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("devices.json")
        let session = DeviceSession(storageURL: file)
        let active = try DeviceDescriptor.decode(fixture("device-descriptor-v1-minimal.json"))
        try await session.applyDescriptor(active, address: "192.168.4.1")
        let nearby = try DeviceDescriptor.decode(fixture("device-descriptor-v1-controls.json"))

        try session.remember(nearby)
        XCTAssertEqual(session.selectedID, active.deviceID)
        XCTAssertEqual(session.records.map(\.id), [active.deviceID, nearby.deviceID])
        XCTAssertEqual(session.records.last?.address, "")

        try session.remember(nearby, address: "10.0.0.9")
        try session.remember(nearby)
        XCTAssertEqual(session.records.count, 2)
        XCTAssertEqual(session.records.last?.address, "10.0.0.9", "A Bluetooth sighting keeps the known address")

        let reloaded = DeviceSession(storageURL: file)
        XCTAssertEqual(reloaded.records.map(\.id), [active.deviceID, nearby.deviceID])
    }
}
