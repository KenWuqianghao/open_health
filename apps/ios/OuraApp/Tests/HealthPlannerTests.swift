import HealthKit
import XCTest
@testable import OuraApp

final class HealthPlannerTests: XCTestCase {
    private let anchor: Double = 1_767_268_800 // 2026-01-01 12:00:00 UTC

    private func day(_ ymd: String = "2026-01-02", night: HealthWindow? = nil, inBed: [HealthWindow] = [],
                     hr: [HRPoint] = [], hrv: [HRVPoint] = [], resting: RestingHR? = nil, resp: [RespPoint] = [],
                     spo2: [SpO2Point] = [], steps: [HealthBucket] = [], active: [HealthBucket] = [],
                     basal: [HealthBucket] = [], finalized: Bool = false, fingerprint: String = "fp") -> HealthDay {
        HealthDay(ymd: ymd, day_start_unix: anchor + 12 * 3600, day_end_unix: anchor + 36 * 3600,
                  night: night, in_bed: inBed, stage_window: night, resting_hr: resting, heart_rate: hr, hrv: hrv,
                  spo2: spo2, respiratory_rate: resp, steps: steps, active_energy: active, basal_energy: basal,
                  warnings: [], updated_unix: anchor, finalized: finalized, fingerprint: fingerprint)
    }

    private var night: HealthWindow { HealthWindow(start_unix: anchor + 11 * 3600, end_unix: anchor + 19 * 3600, start_ds: 396_000, end_ds: 684_000) }

    func testStageRunsMergeClipAndLeaveGaps() {
        let track = StageTrack(startUnix: anchor + 11 * 3600, epochSeconds: 30, codes: [4, 4, 2, 2, 2, 9, 1, 1, 3])
        let runs = HealthPlanner.stageIntervals(track, clipTo: night.interval)
        XCTAssertEqual(runs.map(\.0), [.awake, .asleepCore, .asleepDeep, .asleepREM])
        XCTAssertEqual(runs[0].1.duration, 60)
        XCTAssertEqual(runs[1].1.duration, 90)
        // the unknown code 9 is a gap: deep starts one epoch after core ends
        XCTAssertEqual(runs[2].1.start.timeIntervalSince(runs[1].1.end), 30)
        // ascending, non-overlapping
        for i in 1..<runs.count { XCTAssertGreaterThanOrEqual(runs[i].1.start, runs[i - 1].1.end) }
    }

    func testStagesAreClippedToTheNight() {
        let long = StageTrack(startUnix: anchor + 11 * 3600, epochSeconds: 3600, codes: [2, 2, 2, 2, 2, 2, 2, 2, 2, 2])
        let runs = HealthPlanner.stageIntervals(long, clipTo: night.interval)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].1.end, night.interval.end)
    }

    func testHeartRateCapAndRange() {
        var hr: [HRPoint] = []
        for i in 0..<1500 { hr.append(HRPoint(t_unix: anchor + 12 * 3600 + Double(i) * 60, bpm: 60, n: 5, src: "beats")) }
        hr.append(HRPoint(t_unix: anchor + 12 * 3600, bpm: 300, n: 5, src: "beats"))
        let plan = HealthPlanner.plan(day: day(hr: hr), stages: nil, workouts: [], includeBasal: false, epoch: "t")
        let hrSamples = plan.samples.filter { if case .quantity(.heartRate, _, _, _, _) = $0 { return true }; return false }
        XCTAssertEqual(hrSamples.count, 1440)
    }

    func testSpO2IsScaledToAFractionAndHrvNeedsSdnn() {
        let d = day(hrv: [HRVPoint(t_unix: anchor, window_s: 300, rmssd_ms: 40, sdnn_ms: nil, n_beats: 10),
                         HRVPoint(t_unix: anchor + 300, window_s: 300, rmssd_ms: 40, sdnn_ms: 55.5, n_beats: 200)],
                    spo2: [SpO2Point(t_unix: anchor, pct: 96, n: 60)])
        let plan = HealthPlanner.plan(day: d, stages: nil, workouts: [], includeBasal: false, epoch: "t")
        var sdnn: [Double] = []
        var spo2: [Double] = []
        for s in plan.samples {
            if case .quantity(.heartRateVariabilitySDNN, let v, _, _, _) = s { sdnn.append(v) }
            if case .quantity(.oxygenSaturation, let v, let unit, _, _) = s { spo2.append(v); XCTAssertEqual(unit, .percent) }
        }
        XCTAssertEqual(sdnn, [55.5])
        XCTAssertEqual(spo2, [0.96])
    }

    func testEnergyCarveSumsToTheBucket() {
        let hour = HealthBucket(start_unix: anchor + 12 * 3600, end_unix: anchor + 13 * 3600, count: nil, kcal: 120)
        let w = WorkoutInput(id: "w1", label: "running", start: Date(timeIntervalSince1970: anchor + 12 * 3600 + 900),
                             end: Date(timeIntervalSince1970: anchor + 12 * 3600 + 2700))
        let (plain, per) = HealthPlanner.carveWorkoutEnergy(buckets: [hour], workouts: [w])
        let inside = per["w1"]!.map(\.kcal).reduce(0, +)
        let outside = plain.map(\.kcal).reduce(0, +)
        XCTAssertEqual(inside, 60, accuracy: 0.001)   // 30 of 60 minutes
        XCTAssertEqual(outside, 60, accuracy: 0.001)
        XCTAssertEqual(inside + outside, 120, accuracy: 0.001)
    }

    func testFingerprintChangesWithStagesWorkoutsAndBasal() {
        let d = day()
        let a = HealthPlanner.fingerprint(day: d, stages: nil, workouts: [], includeBasal: false, epoch: "e")
        let b = HealthPlanner.fingerprint(day: d, stages: StageTrack(startUnix: 0, codes: [1, 2]), workouts: [], includeBasal: false, epoch: "e")
        let c = HealthPlanner.fingerprint(day: d, stages: nil, workouts: [], includeBasal: true, epoch: "e")
        let e = HealthPlanner.fingerprint(day: d, stages: nil, workouts: [], includeBasal: false, epoch: "e2")
        XCTAssertEqual(a, HealthPlanner.fingerprint(day: d, stages: nil, workouts: [], includeBasal: false, epoch: "e"))
        XCTAssertNotEqual(a, b); XCTAssertNotEqual(a, c); XCTAssertNotEqual(a, e)
        XCTAssertEqual(a.count, 32)
    }

    func testNightWithoutStagesWritesInBedOnlyAndRespiratoryRate() {
        let d = day(night: night, inBed: [night], resp: [RespPoint(t_unix: anchor + 13 * 3600, brpm: 14), RespPoint(t_unix: anchor + 14 * 3600, brpm: 16)])
        let plan = HealthPlanner.plan(day: d, stages: nil, workouts: [], includeBasal: false, epoch: "t")
        let sleep = plan.samples.filter { if case .sleep = $0 { return true }; return false }
        XCTAssertEqual(sleep.count, 1)
        if case .sleep(let v, _, _) = sleep[0] { XCTAssertEqual(v, .inBed) } else { XCTFail() }
        let resp = plan.samples.compactMap { s -> Double? in if case .quantity(.respiratoryRate, let v, _, _, _) = s { return v }; return nil }
        XCTAssertEqual(resp, [15])
        XCTAssertEqual(plan.sleepWindows, [night.interval])
    }

    func testDayWindowComesFromTheBundle() {
        let plan = HealthPlanner.plan(day: day(), stages: nil, workouts: [], includeBasal: false, epoch: "t")
        XCTAssertEqual(plan.dayWindow.start, Date(timeIntervalSince1970: anchor + 12 * 3600))
        XCTAssertEqual(plan.dayWindow.duration, 86_400)
    }
}
