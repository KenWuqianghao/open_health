import XCTest
@testable import OuraApp

final class SyncBackoffTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    private func holdOff(success: TimeInterval?, failures: Int, failure: TimeInterval?) -> TimeInterval {
        SyncCoordinator.wakeHoldOff(now: now,
                                    lastSuccessAt: success.map { now.addingTimeInterval(-$0) },
                                    failedRunsInARow: failures,
                                    lastFailureAt: failure.map { now.addingTimeInterval(-$0) })
    }

    func testRingWakeWaitsLongerAfterEachFailedRun() {
        let daysAgo: TimeInterval = 4 * 86_400
        XCTAssertEqual(holdOff(success: daysAgo, failures: 0, failure: nil), 0)
        // A ring that refuses each request: 2, 4, 8 min, then at most 10 min.
        let waits = [1, 2, 3, 4, 50].map { holdOff(success: daysAgo, failures: $0, failure: 0) }
        XCTAssertEqual(waits, [120, 240, 480, 600, 600])
        XCTAssertEqual(holdOff(success: daysAgo, failures: 2, failure: 300), 0)
    }

    func testRingWakeKeepsTheCooldownAfterASuccess() {
        XCTAssertEqual(holdOff(success: 30, failures: 0, failure: nil), 570)
        XCTAssertEqual(holdOff(success: 120, failures: 1, failure: 0), 480)
        // A success stamped in the future (the clock was set back).
        XCTAssertEqual(holdOff(success: -86_400, failures: 0, failure: nil), 600)
    }
}
