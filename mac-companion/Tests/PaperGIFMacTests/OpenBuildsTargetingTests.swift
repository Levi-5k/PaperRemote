import XCTest
@testable import PaperGIFMac

final class OpenBuildsTargetingTests: XCTestCase {
    private let local = "11111111-1111-1111-1111-111111111111"

    private func control(_ type: RemoteActionType, host: String, computerID: String? = nil) -> RemoteControl {
        var action = RemoteAction(type: type, host: host)
        action.computerID = computerID
        return RemoteControl(title: "C", symbol: "circle", kind: .button, action: action)
    }

    func testLoopbackOpenBuildsControlsTargetTheAddingComputer() {
        for host in ["127.0.0.1", "localhost", " ", ""] {
            let targeted = RemoteEditorStore.targetingLocalOpenBuilds(
                control(.openBuilds, host: host),
                localComputerID: local
            )
            XCTAssertEqual(targeted.action.computerID, local, "host '\(host)'")
        }
    }

    func testExplicitTargetsRemoteHostsAndOtherActionsAreUnchanged() {
        let explicit = control(.openBuilds, host: "127.0.0.1", computerID: "other")
        XCTAssertEqual(RemoteEditorStore.targetingLocalOpenBuilds(explicit, localComputerID: local).action.computerID, "other")
        let remote = control(.openBuilds, host: "192.168.50.40:3000")
        XCTAssertNil(RemoteEditorStore.targetingLocalOpenBuilds(remote, localComputerID: local).action.computerID)
        let media = control(.macMedia, host: "")
        XCTAssertNil(RemoteEditorStore.targetingLocalOpenBuilds(media, localComputerID: local).action.computerID)
        let unknownLocal = control(.openBuilds, host: "127.0.0.1")
        XCTAssertNil(RemoteEditorStore.targetingLocalOpenBuilds(unknownLocal, localComputerID: nil).action.computerID)
    }
}
