import Foundation
import XCTest
@testable import PaperGIFMac

final class CompanionRequestSchedulerTests: XCTestCase {
    func testReceiveDeadlineCannotBeExtendedAfterExpiry() {
        let now = DispatchTime(uptimeNanoseconds: 1_000_000_000)
        let lifetime = CompanionRequestLifetime(receiveTimeout: 10, now: now)
        XCTAssertFalse(lifetime.admit(timeout: 33, now: now + 10))
        XCTAssertTrue(lifetime.expire(now: now + 10))
        XCTAssertFalse(lifetime.begin(now: now + 10))
    }

    func testValidatedClimateRequestReplacesReceiveDeadline() {
        let now = DispatchTime(uptimeNanoseconds: 1_000_000_000)
        let lifetime = CompanionRequestLifetime(now: now)
        XCTAssertTrue(lifetime.admit(timeout: 33, now: now + 1))
        XCTAssertFalse(lifetime.expire(now: now + 10))
        XCTAssertTrue(lifetime.begin(now: now + 11))
        XCTAssertFalse(lifetime.begin(now: now + 12))
        XCTAssertTrue(lifetime.expire(now: now + 34))
        XCTAssertNil(lifetime.nextDeadline)
    }

    func testExpiredOrDisconnectedQueuedRequestsCannotBegin() {
        let now = DispatchTime(uptimeNanoseconds: 1_000_000_000)
        let expired = CompanionRequestLifetime(now: now)
        XCTAssertTrue(expired.admit(timeout: 4, now: now))
        // Admission checks the clock even if the network timer has not fired.
        XCTAssertFalse(expired.begin(now: now + 4))
        let cancelled = CompanionRequestLifetime(now: now)
        XCTAssertTrue(cancelled.admit(timeout: 4, now: now))
        cancelled.cancel()
        XCTAssertFalse(cancelled.begin(now: now + 1))
        XCTAssertNil(cancelled.nextDeadline)
    }

    func testInteractiveLaneDoesNotWaitForTextOrClimate() {
        let scheduler = CompanionRequestScheduler()
        let blocked = expectation(description: "Slow lanes started")
        blocked.expectedFulfillmentCount = 2
        let release = DispatchSemaphore(value: 0)
        let finished = expectation(description: "Slow lanes finished")
        finished.expectedFulfillmentCount = 2
        for lane in [CompanionRequestScheduler.Lane.text, .climate] {
            XCTAssertTrue(scheduler.submit(on: lane, lifetime: admitted()) {
                blocked.fulfill()
                _ = release.wait(timeout: .now() + 5)
                finished.fulfill()
            })
        }
        wait(for: [blocked], timeout: 2)
        let interactive = expectation(description: "Interactive request ran")
        XCTAssertTrue(scheduler.submit(on: .interactive, lifetime: admitted()) {
            interactive.fulfill()
        })
        wait(for: [interactive], timeout: 2)
        release.signal()
        release.signal()
        wait(for: [finished], timeout: 2)
    }

    func testFIFOAndCancelledWorkAndBoundedBacklog() {
        let scheduler = CompanionRequestScheduler(capacity: 3)
        let started = expectation(description: "First started")
        let release = DispatchSemaphore(value: 0)
        let third = expectation(description: "Third ran after first")
        let lock = NSLock()
        var values: [Int] = []
        XCTAssertTrue(scheduler.submit(on: .interactive, lifetime: admitted()) {
            started.fulfill()
            _ = release.wait(timeout: .now() + 5)
            lock.lock()
            values.append(1)
            lock.unlock()
        })
        wait(for: [started], timeout: 2)
        let cancelled = admitted()
        XCTAssertTrue(scheduler.submit(on: .interactive, lifetime: cancelled) {
            XCTFail("Disconnected request must not execute")
        })
        cancelled.cancel()
        XCTAssertTrue(scheduler.submit(on: .interactive, lifetime: admitted()) {
            lock.lock()
            values.append(3)
            lock.unlock()
            third.fulfill()
        })
        XCTAssertFalse(scheduler.submit(on: .interactive, lifetime: admitted()) {
            XCTFail("Overflow must be rejected")
        })
        release.signal()
        wait(for: [third], timeout: 2)
        lock.lock()
        XCTAssertEqual(values, [1, 3])
        lock.unlock()
    }

    func testActionClassificationKeepsMotionCommandsOrdered() {
        XCTAssertEqual(CompanionRequestScheduler.Lane.action("netHomeFan"), .climate)
        XCTAssertEqual(CompanionRequestScheduler.Lane.action("netHomeClimate"), .climate)
        XCTAssertEqual(CompanionRequestScheduler.Lane.action("macMedia"), .interactive)
        XCTAssertEqual(CompanionRequestScheduler.Lane.action("openBuilds"), .interactive)
    }

    private func admitted() -> CompanionRequestLifetime {
        let lifetime = CompanionRequestLifetime()
        XCTAssertTrue(lifetime.admit(timeout: 30))
        return lifetime
    }
}