import HealthKit
import XCTest
@testable import OuraApp

final class HealthBackgroundTests: XCTestCase {
    /// Counts pushes and can hold one open until released.
    actor PushGate {
        var reasons: [String] = []
        var release: CheckedContinuation<Void, Never>?
        var hold = false
        func push(_ reason: String) async {
            reasons.append(reason)
            if hold {
                await withCheckedContinuation { c in release = c }
            }
        }
        func setHold(_ v: Bool) { hold = v }
        func open() { release?.resume(); release = nil }
    }

    func testABurstOfWakesBecomesOnePushAndEveryCompletionRuns() async {
        let gate = PushGate()
        let wake = HealthWake(debounce: 0.05) { await gate.push($0) }
        let done = Counter()
        for kind in ["heart_rate", "step_count", "heart_rate", "sleep_analysis", "workout"] {
            await wake.wake(kind: kind) { done.bump() }
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        let reasons = await gate.reasons
        XCTAssertEqual(reasons, ["hk-wake:heart_rate,sleep_analysis,step_count,workout"])
        XCTAssertEqual(done.value, 5)
        let pushes = await wake.pushes
        XCTAssertEqual(pushes, 1)
    }

    func testAWakeDuringAPushQueuesOneMorePush() async {
        let gate = PushGate()
        await gate.setHold(true)
        let wake = HealthWake(debounce: 0.01) { await gate.push($0) }
        let first = Counter(), second = Counter()
        await wake.wake(kind: "heart_rate") { first.bump() }
        try? await Task.sleep(nanoseconds: 100_000_000)   // the first push is now held open
        await wake.wake(kind: "vo2_max") { second.bump() }
        await wake.wake(kind: "vo2_max") { second.bump() }
        XCTAssertEqual(first.value, 0)
        await gate.setHold(false)
        await gate.open()
        try? await Task.sleep(nanoseconds: 200_000_000)
        let reasons = await gate.reasons
        XCTAssertEqual(reasons, ["hk-wake:heart_rate", "hk-wake:vo2_max"])
        XCTAssertEqual(first.value, 1)
        XCTAssertEqual(second.value, 2)
    }

    func testFrequenciesRespectHealthKitLimits() {
        XCTAssertEqual(HealthBackground.frequency(for: "step_count"), .hourly)
        XCTAssertEqual(HealthBackground.frequency(for: "active_energy"), .hourly)
        XCTAssertEqual(HealthBackground.frequency(for: "heart_rate"), .immediate)
        XCTAssertEqual(HealthBackground.frequency(for: "sleep_analysis"), .immediate)
        XCTAssertEqual(HealthBackground.frequency(for: "workout"), .immediate)
    }

    func testFakeClientRecordsDeliveryAndObservers() async throws {
        let client = FakeHealthReadClient()
        for t in HealthReadTypes.all {
            try await client.enableBackgroundDelivery(t.sampleType, frequency: HealthBackground.frequency(for: t.kind))
            _ = client.observe(t.sampleType) { completion in completion() }
        }
        XCTAssertEqual(client.delivery.count, HealthReadTypes.all.count)
        XCTAssertEqual(client.observed.count, HealthReadTypes.all.count)
        XCTAssertTrue(client.delivery.contains { $0.0 == HKQuantityType(.stepCount).identifier && $0.1 == .hourly })
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    func bump() { lock.lock(); n += 1; lock.unlock() }
}
