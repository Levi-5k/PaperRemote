import XCTest
@testable import PaperGIFMac

final class OpenBuildsTargetingTests: XCTestCase {
    private let local = "11111111-1111-1111-1111-111111111111"

    private func control(_ type: RemoteActionType, host: String, computerID: String? = nil) -> RemoteControl {
        var action = RemoteAction(type: type, host: host)
        action.computerID = computerID
        return RemoteControl(title: "C", symbol: "circle", kind: .button, action: action)
    }

    func testLoopbackOpenBuildsControlsTargetTheChosenComputer() {
        for host in ["127.0.0.1", "localhost", " ", ""] {
            let targeted = RemoteEditorStore.targetingOpenBuilds(
                control(.openBuilds, host: host),
                computerID: local
            )
            XCTAssertEqual(targeted.action.computerID, local, "host '\(host)'")
        }
    }

    func testLoopbackPositionReadoutsTargetTheChosenComputer() {
        var readout = control(.openBuilds, host: "127.0.0.1")
        readout.kind = .textBox
        readout.textBox = RemoteTextBox(source: .openBuildsPosition, sourceText: "127.0.0.1|x|mm")
        let targeted = RemoteEditorStore.targetingOpenBuilds(readout, computerID: local)
        XCTAssertEqual(targeted.textBox?.computerID, UUID(uuidString: local))

        readout.textBox?.sourceText = "192.168.50.40:3000|x|mm"
        XCTAssertNil(RemoteEditorStore.targetingOpenBuilds(readout, computerID: local).textBox?.computerID)
    }

    func testExplicitTargetsRemoteHostsAndOtherActionsAreUnchanged() {
        let explicit = control(.openBuilds, host: "127.0.0.1", computerID: "other")
        XCTAssertEqual(RemoteEditorStore.targetingOpenBuilds(explicit, computerID: local).action.computerID, "other")
        let remote = control(.openBuilds, host: "192.168.50.40:3000")
        XCTAssertNil(RemoteEditorStore.targetingOpenBuilds(remote, computerID: local).action.computerID)
        let media = control(.computerMedia, host: "")
        XCTAssertNil(RemoteEditorStore.targetingOpenBuilds(media, computerID: local).action.computerID)
        let unknownLocal = control(.openBuilds, host: "127.0.0.1")
        XCTAssertNil(RemoteEditorStore.targetingOpenBuilds(unknownLocal, computerID: nil).action.computerID)
    }

    func testModulePageControlsAlwaysTargetThisComputer() {
        let remoteOpenBuilds = control(.openBuilds, host: "192.168.50.40:3000", computerID: "other")
        XCTAssertEqual(remoteOpenBuilds.targetingComputer(local).action.computerID, local)
        XCTAssertEqual(control(.computerMedia, host: "").targetingComputer(local).action.computerID, local)
        XCTAssertNil(control(.wledPower, host: "lights.local").targetingComputer(local).action.computerID)

        var readout = control(.wledPower, host: "lights.local")
        readout.kind = .textBox
        readout.textBox = RemoteTextBox(source: .openBuildsPosition, sourceText: "192.168.50.40:3000|x|mm")
        readout.textBox?.tapAction = RemoteAction(type: .computerKey, host: "")
        let targeted = readout.targetingComputer(local)
        XCTAssertEqual(targeted.textBox?.computerID, UUID(uuidString: local))
        XCTAssertEqual(targeted.textBox?.tapAction?.computerID, local)
        XCTAssertNil(targeted.action.computerID)
    }
}
