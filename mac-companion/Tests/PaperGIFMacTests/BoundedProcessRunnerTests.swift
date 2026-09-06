import Foundation
import XCTest
@testable import PaperGIFMac

final class BoundedProcessRunnerTests: XCTestCase {
    func testDrainsBothPipesAndCapsCapturedOutput() throws {
        let result = try BoundedProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [
                "-c",
                "import os; os.write(1, b'o' * 200000); os.write(2, b'e' * 200000)",
            ],
            timeout: 5,
            maximumOutputBytes: 4096
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.output.count, 4096)
        XCTAssertEqual(result.errorOutput.count, 4096)
    }

    func testKillsProcessThatIgnoresTermination() throws {
        let startedAt = Date()
        let result = try BoundedProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [
                "-c",
                "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)",
            ],
            captureOutput: false,
            timeout: 0.1
        )

        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 3)
    }
}
