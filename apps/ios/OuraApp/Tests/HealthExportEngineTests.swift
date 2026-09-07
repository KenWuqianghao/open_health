import HealthKit
import XCTest
@testable import OuraApp

/// Records every store call; can throw on demand.
final class FakeHealthStore: HealthStoreClient, @unchecked Sendable {
    var isAvailable = true
    var deletes: [(String, DateInterval?)] = []
    var saved: [[HKObject]] = []
    var workouts: [PlannedWorkout] = []
    var failNextSave: Error?
    var lockedUntilReset = false

    func requestShare(_ types: Set<HKSampleType>) async throws {}
    func deleteOurObjects(of type: HKSampleType, in window: DateInterval?) async throws -> Int {
        if lockedUntilReset {
            throw NSError(domain: HKError.errorDomain, code: HKError.Code.errorDatabaseInaccessible.rawValue)
        }
        deletes.append((type.identifier, window))
        return 0
    }
    func save(_ objects: [HKObject]) async throws {
        if let e = failNextSave { failNextSave = nil; throw e }
        saved.append(objects)
    }
    func saveWorkout(_ workout: PlannedWorkout, device: HKDevice?, metadata: [String: Any]) async throws {
        workouts.append(workout)
    }
    func countOurObjects(of type: HKSampleType, in window: DateInterval) async throws -> Int { 0 }
}

/// A clock the engine reads through a reference, so a test can move time forward.
final class ClockBox: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 1_767_400_000)
}

final class HealthExportEngineTests: XCTestCase {
    private let anchor: Double = 1_767_268_800
    private let clock = ClockBox()

    override func setUp() {
        super.setUp()
        HealthExportStateStore.clear()
        clock.date = Date(timeIntervalSince1970: 1_767_400_000)
        // Every test starts at the current epoch, so the first run is not a purge.
        var st = HealthExportState(); st.epoch = "e"; HealthExportStateStore.save(st)
    }

    override func tearDown() {
        // The test host shares the app's container: leave no state behind.
        HealthExportStateStore.clear()
        super.tearDown()
    }

    private func envelope(_ days: [HealthDay]) -> HealthEnvelope {
        var e = HealthEnvelope()
        e.version = 1; e.serial = "S1"; e.hardware_id = "COR_05"; e.generation = 5
        e.days = days
        return e
    }

    private func day(_ ymd: String, offsetDays: Int, finalized: Bool, fp: String, steps: Int = 100) -> HealthDay {
        let start = anchor + 12 * 3600 + Double(offsetDays) * 86_400
        return HealthDay(ymd: ymd, day_start_unix: start, day_end_unix: start + 86_400, night: nil, in_bed: [],
                         stage_window: nil, resting_hr: RestingHR(t_unix: start + 3600, bpm: 50),
                         heart_rate: [HRPoint(t_unix: start + 60, bpm: 61, n: 5, src: "beats")],
                         hrv: [], spo2: [], respiratory_rate: [],
                         steps: [HealthBucket(start_unix: start, end_unix: start + 3600, count: steps, kcal: nil)],
                         active_energy: [], basal_energy: [], warnings: [], updated_unix: start, finalized: finalized, fingerprint: fp)
    }

    private func engine(_ store: FakeHealthStore) -> HealthExportEngine {
        let box = clock
        return HealthExportEngine(client: store, now: { box.date })
    }

    func testTwoRunsAreIdempotentAndTheSecondSkipsUnchangedDays() async {
        let store = FakeHealthStore()
        let eng = engine(store)
        let env = envelope([day("2026-01-01", offsetDays: 0, finalized: true, fp: "a"),
                            day("2026-01-02", offsetDays: 1, finalized: false, fp: "b")])
        let first = await eng.run(.sync, envelope: env, summary: nil, includeBasal: false, epoch: "e") { _ in }
        XCTAssertEqual(first.daysWritten, 2)
        XCTAssertEqual(store.saved.count, 2)
        // every quantity type is cleared inside the day window before the write
        XCTAssertTrue(store.deletes.allSatisfy { $0.1 != nil })
        let second = await eng.run(.sync, envelope: env, summary: nil, includeBasal: false, epoch: "e") { _ in }
        XCTAssertEqual(second.daysWritten, 0)
        XCTAssertEqual(store.saved.count, 2)
        // the finalized day moved behind the cursor
        XCTAssertEqual(HealthExportStateStore.load().exportThroughYmd, "2026-01-01")
        XCTAssertNil(HealthExportStateStore.load().days["2026-01-01"])
    }

    func testCursorAdvancesOnlyOverTheContiguousFinalizedPrefix() async {
        let store = FakeHealthStore()
        let eng = engine(store)
        let env = envelope([day("2026-01-01", offsetDays: 0, finalized: true, fp: "a"),
                            day("2026-01-02", offsetDays: 1, finalized: false, fp: "b"),
                            day("2026-01-03", offsetDays: 2, finalized: true, fp: "c")])
        _ = await eng.run(.sync, envelope: env, summary: nil, includeBasal: false, epoch: "e") { _ in }
        XCTAssertEqual(HealthExportStateStore.load().exportThroughYmd, "2026-01-01")
    }

    func testChangedFingerprintRewritesOnlyThatDay() async {
        let store = FakeHealthStore()
        let eng = engine(store)
        var env = envelope([day("2026-01-02", offsetDays: 1, finalized: false, fp: "b"),
                            day("2026-01-03", offsetDays: 2, finalized: false, fp: "c")])
        _ = await eng.run(.sync, envelope: env, summary: nil, includeBasal: false, epoch: "e") { _ in }
        clock.date = clock.date.addingTimeInterval(3600)
        env.days[1] = day("2026-01-03", offsetDays: 2, finalized: false, fp: "c2", steps: 500)
        let out = await eng.run(.sync, envelope: env, summary: nil, includeBasal: false, epoch: "e") { _ in }
        XCTAssertEqual(out.daysWritten, 1)
        XCTAssertEqual(out.daysSkipped, 1)
    }

    func testFailedDayBacksOffAndDoesNotWedgeTheCursor() async {
        let store = FakeHealthStore()
        let eng = engine(store)
        let env = envelope([day("2026-01-01", offsetDays: 0, finalized: true, fp: "a")])
        store.failNextSave = NSError(domain: "test", code: 1)
        let out = await eng.run(.sync, envelope: env, summary: nil, includeBasal: false, epoch: "e") { _ in }
        XCTAssertEqual(out.daysFailed, 1)
        var st = HealthExportStateStore.load()
        XCTAssertEqual(st.days["2026-01-01"]?.attempts, 1)
        XCTAssertNil(st.exportThroughYmd)
        // inside the backoff window: skipped, no attempt
        let again = await eng.run(.sync, envelope: env, summary: nil, includeBasal: false, epoch: "e") { _ in }
        XCTAssertEqual(again.daysWritten, 0)
        XCTAssertEqual(HealthExportStateStore.load().days["2026-01-01"]?.attempts, 1)
        // give up after six attempts → the cursor still advances past it
        st = HealthExportStateStore.load()
        st.days["2026-01-01"]?.attempts = HealthExportEngine.maxAttempts
        HealthExportStateStore.save(st)
        _ = await eng.run(.sync, envelope: env, summary: nil, includeBasal: false, epoch: "e") { _ in }
        XCTAssertEqual(HealthExportStateStore.load().exportThroughYmd, "2026-01-01")
    }

    func testLockedDatabaseDefersWithoutCountingAnAttempt() async {
        let store = FakeHealthStore()
        store.lockedUntilReset = true
        let eng = engine(store)
        let env = envelope([day("2026-01-02", offsetDays: 1, finalized: false, fp: "b")])
        // the epoch purge also hits the locked store: purge failure returns early
        var st = HealthExportState(); st.epoch = "e"; HealthExportStateStore.save(st)
        let out = await eng.run(.sync, envelope: env, summary: nil, includeBasal: false, epoch: "e") { _ in }
        XCTAssertTrue(out.deferredForUnlock)
        XCTAssertEqual(out.daysFailed, 0)
        XCTAssertEqual(HealthExportStateStore.load().days["2026-01-02"]?.attempts ?? 0, 0)
        XCTAssertTrue(HealthExportStateStore.load().deferredForUnlock)
    }

    func testEpochMismatchPurgesEverythingFirst() async {
        let store = FakeHealthStore()
        let eng = engine(store)
        var st = HealthExportState(); st.epoch = "old"; st.exportThroughYmd = "2025-12-31"
        HealthExportStateStore.save(st)
        let env = envelope([day("2026-01-01", offsetDays: 0, finalized: true, fp: "a")])
        _ = await eng.run(.sync, envelope: env, summary: nil, includeBasal: false, epoch: "new") { _ in }
        // unbounded deletes (window nil) for every type = the purge
        XCTAssertTrue(store.deletes.contains { $0.1 == nil })
        XCTAssertEqual(HealthExportStateStore.load().epoch, "new")
    }

    func testUnionMergesOverlappingWindows() {
        let a = DateInterval(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 100))
        let b = DateInterval(start: Date(timeIntervalSince1970: 50), end: Date(timeIntervalSince1970: 150))
        let c = DateInterval(start: Date(timeIntervalSince1970: 200), end: Date(timeIntervalSince1970: 250))
        let u = HealthExportEngine.union([c, a, b])
        XCTAssertEqual(u.count, 2)
        XCTAssertEqual(u[0].end, Date(timeIntervalSince1970: 150))
    }
}
