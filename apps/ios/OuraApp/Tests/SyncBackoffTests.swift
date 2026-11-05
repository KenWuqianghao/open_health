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
        let waits = [1, 2, 3, 4, 50].map { holdOff(success: daysAgo, failures: $0, failure: 0) }
        XCTAssertEqual(waits, [120, 240, 480, 600, 600])
        XCTAssertEqual(holdOff(success: daysAgo, failures: 2, failure: 300), 0)
        XCTAssertEqual(holdOff(success: daysAgo, failures: 0, failure: 0), 120)
    }

    func testRingWakeKeepsTheCooldownAfterASuccess() {
        XCTAssertEqual(holdOff(success: 30, failures: 0, failure: nil), 570)
        XCTAssertEqual(holdOff(success: 120, failures: 1, failure: 0), 480)
    }

    func testOnlyFailedRingWakesExtendTheStreakAndProgressEndsIt() {
        let report = SyncReport(serial: "", eventsSynced: 0, inserted: 0, nextCursor: 0, clockWritten: false)
        let next = { (outcome: SyncOutcome, trigger: SyncTrigger) in
            SyncCoordinator.failedRunsInARow(after: outcome, of: trigger, madeProgress: false, previous: 3)
        }
        XCTAssertEqual(next(.failed(.connectFailed, ""), .bleRestore), 4)
        XCTAssertEqual(next(.failed(.connectFailed, ""), .foreground), 3)
        XCTAssertEqual(next(.partial(.deadline), .bleRestore), 3)
        XCTAssertEqual(next(.skipped(.busy), .bleRestore), 3)
        XCTAssertEqual(next(.synced(report), .foreground), 0)
        XCTAssertEqual(SyncCoordinator.failedRunsInARow(after: .failed(.linkLost, ""), of: .bleRestore,
                                                        madeProgress: true, previous: 3), 0)
    }

    func testRingWakeWaitsNoLongerThanTheCooldownAfterTheClockIsSetBack() {
        XCTAssertEqual(holdOff(success: -86_400, failures: 0, failure: nil), 600)
    }
}
