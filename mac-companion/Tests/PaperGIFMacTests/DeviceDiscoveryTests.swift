import Darwin
import Foundation
import XCTest
@testable import PaperGIFMac

final class DeviceDiscoveryTests: XCTestCase {
    func testExtractsNumericIPv4AddressFromResolvedServiceData() {
        var socketAddress = sockaddr_in()
        socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        socketAddress.sin_family = sa_family_t(AF_INET)
        XCTAssertEqual(inet_pton(AF_INET, "192.168.50.142", &socketAddress.sin_addr), 1)
        let data = Data(bytes: &socketAddress, count: MemoryLayout<sockaddr_in>.size)

        XCTAssertEqual(DeviceDiscovery.ipv4Address(from: [data]), "192.168.50.142")
    }

    func testRecognizesOnlyPaperGIFStatusReplies() {
        XCTAssertTrue(DeviceDiscovery.isPaperGIFStatus(
            Data(#"{"device":"paperGIF","ready":true,"uploading":false,"ssid":"Home"}"#.utf8)
        ))
        XCTAssertFalse(DeviceDiscovery.isPaperGIFStatus(Data(#"{"device":"WLED"}"#.utf8)))
        XCTAssertFalse(DeviceDiscovery.isPaperGIFStatus(Data("<html>router</html>".utf8)))
        XCTAssertFalse(DeviceDiscovery.isPaperGIFStatus(Data(#"["paperGIF"]"#.utf8)))
    }

    func testSweepCoversSubnetExcludingSelfNetworkAndBroadcast() {
        let address: UInt32 = 0xC0A8_3214 // 192.168.50.20
        let hosts = DeviceDiscovery.sweepHosts(address: address, netmask: 0xFFFF_FF00)

        XCTAssertEqual(hosts.count, 253)
        XCTAssertEqual(hosts.first, 0xC0A8_3201)
        XCTAssertEqual(hosts.last, 0xC0A8_32FE)
        XCTAssertFalse(hosts.contains(address))
    }

    func testSweepLimitsWideSubnetsToSurroundingSlash24() {
        let hosts = DeviceDiscovery.sweepHosts(address: 0x0A00_0542, netmask: 0xFF00_0000) // 10.0.5.66/8

        XCTAssertEqual(hosts.count, 253)
        XCTAssertTrue(hosts.allSatisfy { $0 >> 8 == 0x0A00_05 })
    }

    func testSweepSkipsPointToPointMasks() {
        XCTAssertTrue(DeviceDiscovery.sweepHosts(address: 0x0A00_0001, netmask: 0xFFFF_FFFF).isEmpty)
        XCTAssertTrue(DeviceDiscovery.sweepHosts(address: 0x0A00_0001, netmask: 0xFFFF_FFFE).isEmpty)
    }
}
