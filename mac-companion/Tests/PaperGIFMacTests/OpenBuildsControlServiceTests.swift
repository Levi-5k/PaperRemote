import XCTest
@testable import PaperGIFMac

final class OpenBuildsControlServiceTests: XCTestCase {
    func testMapsApprovedCommandsToOpenBuildsEvents() {
        XCTAssertEqual(
            OpenBuildsCommandMapper.emission(command: "jogXNegative", value: 1),
            OpenBuildsEmission(event: "jog", payload: .string("X,-1,1000"))
        )
        XCTAssertEqual(
            OpenBuildsCommandMapper.emission(command: "abort", value: 0),
            OpenBuildsEmission(event: "stop", payload: .stop(stop: false, jog: false, abort: true))
        )
        XCTAssertEqual(
            OpenBuildsCommandMapper.emission(command: "home", value: 0),
            OpenBuildsEmission(event: "runCommand", payload: .string("$H\n"))
        )
        XCTAssertEqual(
            OpenBuildsCommandMapper.emission(command: "jogXNegativeYPositive", value: 2),
            OpenBuildsEmission(event: "jogXY", payload: .jogXY(x: -2, y: 2, feed: 1_000))
        )
    }

    func testRejectsUnknownCommandsAndUnsafeJogDistances() {
        XCTAssertNil(OpenBuildsCommandMapper.emission(command: "runCommand", value: 1))
        XCTAssertNil(OpenBuildsCommandMapper.emission(command: "jogXPositive", value: 0))
        XCTAssertNil(OpenBuildsCommandMapper.emission(command: "jogXPositive", value: 101))
        XCTAssertNil(OpenBuildsCommandMapper.emission(command: "jogXPositiveYPositive", value: 101))
    }

    func testBuildsOnlyLocalNetworkTargets() {
        XCTAssertEqual(OpenBuildsControlService.endpoints(host: "").count, 4)
        XCTAssertEqual(OpenBuildsControlService.endpoints(host: "192.168.50.44:3020").first?.port, 3_020)
        XCTAssertEqual(OpenBuildsControlService.endpoints(host: "cnc.local").count, 4)
        XCTAssertTrue(OpenBuildsControlService.endpoints(host: "8.8.8.8").isEmpty)
        XCTAssertTrue(OpenBuildsControlService.endpoints(host: "example.com").isEmpty)
        XCTAssertTrue(OpenBuildsControlService.endpoints(host: "localhost/path").isEmpty)
    }
}