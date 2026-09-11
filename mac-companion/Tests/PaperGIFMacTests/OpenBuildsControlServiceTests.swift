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
            OpenBuildsCommandMapper.emission(command: "zeroX", value: 0),
            OpenBuildsEmission(event: "runCommand", payload: .string("G10 L20 P1 X0\n"))
        )
        XCTAssertEqual(
            OpenBuildsCommandMapper.emission(command: "zeroY", value: 0),
            OpenBuildsEmission(event: "runCommand", payload: .string("G10 L20 P1 Y0\n"))
        )
        XCTAssertEqual(
            OpenBuildsCommandMapper.emission(command: "zeroZ", value: 0),
            OpenBuildsEmission(event: "runCommand", payload: .string("G10 L20 P1 Z0\n"))
        )
        XCTAssertEqual(
            OpenBuildsCommandMapper.emission(command: "jogXNegativeYPositive", value: 2),
            OpenBuildsEmission(event: "jogXY", payload: .jogXY(x: -2, y: 2, feed: 1_000))
        )
        XCTAssertEqual(
            OpenBuildsCommandMapper.emission(
                command: "jogXPositiveYNegative",
                value: 0,
                valueTenths: 1,
                modifiers: ["feed=2400"]
            ),
            OpenBuildsEmission(event: "jogXY", payload: .jogXY(x: 0.1, y: -0.1, feed: 2_400))
        )
        XCTAssertEqual(
            OpenBuildsCommandMapper.emission(command: "continuousJogXNegativeYPositive", value: 3_200),
            OpenBuildsEmission(event: "runCommand", payload: .string("$J=G91 G21 X-1000 Y1000 F3200\n"))
        )
        XCTAssertEqual(
            OpenBuildsCommandMapper.emission(command: "cancelJog", value: 0),
            OpenBuildsEmission(event: "stop", payload: .stop(stop: false, jog: true, abort: false))
        )
    }

    func testRejectsUnknownCommandsAndUnsafeJogDistances() {
        XCTAssertNil(OpenBuildsCommandMapper.emission(command: "runCommand", value: 1))
        XCTAssertNil(OpenBuildsCommandMapper.emission(command: "jogXPositive", value: 0))
        XCTAssertNil(OpenBuildsCommandMapper.emission(command: "jogXPositive", value: 101))
        XCTAssertNil(OpenBuildsCommandMapper.emission(command: "jogXPositiveYPositive", value: 101))
        XCTAssertNil(OpenBuildsCommandMapper.emission(command: "continuousJogXPositive", value: 99))
    }

    func testConvertsInchJogDistanceAndFeedToMillimeters() {
        XCTAssertEqual(
            OpenBuildsCommandMapper.emission(
                command: "jogXPositive",
                value: 0,
                modifiers: ["feed=10", "units=in", "dist=1"]
            ),
            OpenBuildsEmission(event: "jog", payload: .string("X,0.0254,254"))
        )
        XCTAssertEqual(
            OpenBuildsCommandMapper.emission(
                command: "continuousJogYPositive",
                value: 20,
                modifiers: ["units=in"]
            ),
            OpenBuildsEmission(event: "runCommand", payload: .string("$J=G91 G21 Y1000 F508\n"))
        )
    }

    func testBuildsOnlyLocalNetworkTargets() {
        XCTAssertEqual(OpenBuildsControlService.endpoints(host: "").count, 4)
        XCTAssertEqual(OpenBuildsControlService.endpoints(host: "192.168.50.44:3020").first?.port, 3_020)
        XCTAssertEqual(OpenBuildsControlService.endpoints(host: "cnc.local").count, 4)
        XCTAssertTrue(OpenBuildsControlService.endpoints(host: "8.8.8.8").isEmpty)
        XCTAssertTrue(OpenBuildsControlService.endpoints(host: "example.com").isEmpty)
        XCTAssertTrue(OpenBuildsControlService.endpoints(host: "localhost/path").isEmpty)
    }

    func testParsesWorkPositionFromStatusPayload() {
        let position = OpenBuildsControlService.position(from: [
            "machine": ["position": ["work": ["x": 12.5, "y": "-3.25", "z": 0]]],
        ])

        XCTAssertEqual(position, OpenBuildsPosition(x: 12.5, y: -3.25, z: 0))
        XCTAssertNil(OpenBuildsControlService.position(from: ["machine": [:]]))
    }

    func testParsesGRBLRunStatusFromStatusPayload() {
        XCTAssertEqual(
            OpenBuildsControlService.runStatus(from: ["comms": ["runStatus": "Hold:0"]]),
            "Hold:0"
        )
        XCTAssertNil(OpenBuildsControlService.runStatus(from: ["comms": [:]]))
    }

    func testAllowsCommandsOnlyInCompatibleGRBLStates() {
        XCTAssertTrue(OpenBuildsCommandPolicy.allows(command: "jogXPositive", runStatus: "Idle"))
        XCTAssertFalse(OpenBuildsCommandPolicy.allows(command: "jogXPositive", runStatus: "Run"))
        XCTAssertFalse(OpenBuildsCommandPolicy.allows(command: "zeroX", runStatus: "Hold:0"))
        XCTAssertTrue(OpenBuildsCommandPolicy.allows(command: "home", runStatus: "Alarm"))
        XCTAssertFalse(OpenBuildsCommandPolicy.allows(command: "home", runStatus: "Run"))
        XCTAssertTrue(OpenBuildsCommandPolicy.allows(command: "unlock", runStatus: "Alarm"))
        XCTAssertFalse(OpenBuildsCommandPolicy.allows(command: "unlock", runStatus: "Idle"))
        XCTAssertTrue(OpenBuildsCommandPolicy.allows(command: "pause", runStatus: "Run"))
        XCTAssertTrue(OpenBuildsCommandPolicy.allows(command: "resume", runStatus: "Hold:0"))
        XCTAssertTrue(OpenBuildsCommandPolicy.allows(command: "resume", runStatus: "Door:0"))
        XCTAssertFalse(OpenBuildsCommandPolicy.allows(command: "resume", runStatus: "Run"))
        XCTAssertTrue(OpenBuildsCommandPolicy.allows(command: "stop", runStatus: nil))
        XCTAssertTrue(OpenBuildsCommandPolicy.allows(command: "abort", runStatus: "Run"))
        XCTAssertTrue(OpenBuildsCommandPolicy.allows(command: "cancelJog", runStatus: "Jog"))
    }
}