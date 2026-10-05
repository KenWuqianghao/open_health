import XCTest
@testable import OuraApp

/// The rules behind the notifications, the live session, the finder and the imports.
/// Each test gives values and checks the decision; no Bluetooth, HealthKit or clock.
final class InsightsTests: XCTestCase {
    /// A summary from the JSON members in `json`, on top of the members that every
    /// summary has.
    private func summary(_ json: String) throws -> Summary {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let base: [String: Any] = [
            "nights": [], "activity_profile": [:], "activity_daily": [:],
            "vitals": ["hrv": ["series": []], "rhr": ["series": []]],
        ]
        root.merge(base) { given, _ in given }
        return try JSONDecoder().decode(Summary.self, from: JSONSerialization.data(withJSONObject: root))
    }

    private let today = NotificationRules.localDay(Date(timeIntervalSince1970: 1_790_000_000))
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testSummaryKeepsItsCoreWhenANewSectionHasAnotherShape() throws {
        let s = try summary("""
        {"digest":"d","nights":[{"ymd":"2026-09-26","start":"23:10","end":"07:00","in_bed_h":7.8,
          "breath":14.5,"temp_dev":-0.05,"kind":"main"}],
         "vitals":{"hrv":{"series":[1]},"rhr":{"series":[2]},"breath":{"series":[14.5],"baseline":14.3,"delta":0.2}},
         "stress":{"days":"not a map"},
         "workouts":[{"id":"manual-a","day":"2026-09-27","start":"2026-09-27 07:15","end":"2026-09-27 07:45",
           "start_unix":1,"end_unix":1801,"duration_min":30,"label":"Yoga","source":"manual","source_name":"Added by you"}],
         "rest_mode":{"on":true,"today":true,"days":["2026-09-27"]}}
        """)
        XCTAssertEqual(s.nights.first?.breath, 14.5)
        XCTAssertEqual(s.vitals.breath?.baseline, 14.3)
        XCTAssertNil(s.stress?.value, "a section with another shape is absent, not an error")
        XCTAssertEqual(s.mergedWorkouts.first?.journalID, "a")
        XCTAssertEqual(s.restMode?.value?.on, true)
    }

    func testLowBatteryNotifiesOncePerDischarge() throws {
        let s = try summary("""
        {"device":{"battery_pct":18,"battery":{"latest":{"t":1789999000,"pct":18},"history":[],
                   "charging":false,"rate_pct_per_day":15,"days_left":1.2}}}
        """)
        let on: (NotificationKind) -> Bool = { $0 == .lowBattery }
        let first = NotificationRules.plan(summary: s, state: NotifierState(), lastSync: nil, now: now, isOn: on)
        XCTAssertEqual(first.now.map(\.id), ["battery-low"])
        XCTAssertTrue(first.now[0].title.contains("18%"))
        let second = NotificationRules.plan(summary: s, state: first.state, lastSync: nil, now: now, isOn: on)
        XCTAssertTrue(second.now.isEmpty)
    }

    func testAHighBatterySchedulesTheEstimatedLowTime() throws {
        let s = try summary("""
        {"device":{"battery_pct":50,"battery":{"latest":{"t":1790000000,"pct":50},"history":[],
                   "charging":false,"rate_pct_per_day":15,"days_left":3.3}}}
        """)
        let plan = NotificationRules.plan(summary: s, state: NotifierState(), lastSync: now, now: now,
                                          isOn: { $0 == .lowBattery || $0 == .staleSync })
        XCTAssertTrue(plan.now.isEmpty)
        let estimate = try XCTUnwrap(plan.scheduled.first { $0.message.id == "battery-estimate" })
        // 30 points at 15 points per day
        XCTAssertEqual(estimate.at.timeIntervalSince(now), 2 * 86_400, accuracy: 1)
        let stale = try XCTUnwrap(plan.scheduled.first { $0.message.id == "stale-sync" })
        XCTAssertEqual(stale.at.timeIntervalSince(now), 24 * 3600, accuracy: 1)
    }

    func testBedtimeReminderIsHalfAnHourBeforeTheWindow() throws {
        let s = try summary("""
        {"guidance":{"bedtime":{"start":"00:10","end":"01:10","start_min":10,"end_min":70,
                     "usual_wake":"07:30","nights_used":5,"basis":"best_nights","need_h":8}}}
        """)
        let plan = NotificationRules.plan(summary: s, state: NotifierState(), lastSync: nil, now: now,
                                          isOn: { $0 == .bedtime })
        XCTAssertEqual(plan.daily.map(\.hour), [23])
        XCTAssertEqual(plan.daily.map(\.minute), [40])
    }

    func testSymptomRadarNotifiesOnAChangeOnly() throws {
        func radar(_ status: String) throws -> Summary {
            try summary("""
            {"illness":{"available":true,"status":"\(status)","traffic_light":"\(status)","score":1,"decision":1,
               "date":"2026-09-27","days_with_data":20,"basis":"rules",
               "biomarkers":[{"type":"LowestHeartRate","value":58,"lower":48,"upper":55,
                              "indicates_symptoms":true,"reason":"ELEVATED"}]}}
            """)
        }
        let on: (NotificationKind) -> Bool = { $0 == .symptomRadar }
        let first = NotificationRules.plan(summary: try radar("NO_SIGNS"), state: NotifierState(),
                                           lastSync: nil, now: now, isOn: on)
        XCTAssertTrue(first.now.isEmpty, "the first check has nothing to compare with")
        let second = NotificationRules.plan(summary: try radar("MINOR_SIGNS"), state: first.state,
                                            lastSync: nil, now: now, isOn: on)
        XCTAssertEqual(second.now.first?.title, "Symptom Radar: minor signs")
        XCTAssertTrue(second.now.first?.body.contains("Resting heart rate") ?? false)
        let third = NotificationRules.plan(summary: try radar("MINOR_SIGNS"), state: second.state,
                                           lastSync: nil, now: now, isOn: on)
        XCTAssertTrue(third.now.isEmpty)
    }

    func testNightSignalShowsOnlyForLastNight() throws {
        func radar(current: Bool) throws -> Summary {
            try summary("""
            {"illness":{"available":true,"status":"NO_SIGNS","traffic_light":"NO_SIGNS","score":0,"decision":0,
               "date":"2026-09-27","days_with_data":20,"basis":"rules","biomarkers":[],
               "nightsignal":{"alert":"yellow","date":"2026-09-27","rhr":58,"baseline":54,
                              "current":\(current),"days_with_data":20,"recent":[]}}}
            """)
        }
        XCTAssertEqual(try radar(current: true).nightSignal?.alert, "yellow")
        XCTAssertNil(try radar(current: false).nightSignal)
        XCTAssertEqual(try radar(current: true).shownIllness?.result.status, "NO_SIGNS")
    }

    func testLiveStatisticsIgnoreFalseBeats() throws {
        // 800 ms beats that change by 20 ms, with one missed beat (1600 ms)
        var ibis = (0..<40).map { 800.0 + ($0 % 2 == 0 ? 10 : -10) }
        ibis.insert(1600, at: 20)
        XCTAssertEqual(try XCTUnwrap(LiveMath.rmssd(ibis)), 20, accuracy: 0.01)
        XCTAssertNil(LiveMath.rmssd([800, 810, 790]))
        XCTAssertEqual(LiveMath.zone(bpm: 150, age: 30).name, "Hard")   // 150 / 187 = 0.80
        XCTAssertEqual(LiveMath.zone(bpm: 60, age: 30).index, 0)
        let beats = (0..<180).map { (t: Double($0), ibi: 1000.0) }
        let result = try XCTUnwrap(LiveMath.result(beats: beats, seconds: 180))
        XCTAssertEqual(result.average, 60)
        XCTAssertEqual(result.beats, 180)
    }

    func testFinderRangeNeedsAFreshSignal() {
        XCTAssertEqual(RingFinder.range(rssi: -50, heardAgo: 1), .close)
        XCTAssertEqual(RingFinder.range(rssi: -65, heardAgo: 1), .near)
        XCTAssertEqual(RingFinder.range(rssi: -80, heardAgo: 1), .room)
        XCTAssertEqual(RingFinder.range(rssi: -95, heardAgo: 1), .far)
        XCTAssertEqual(RingFinder.range(rssi: -50, heardAgo: 30), .none)
        XCTAssertEqual(RingFinder.range(rssi: nil, heardAgo: nil), .none)
    }

    func testHealthImportPayloadHasTheShapeOfTheSummaryInput() throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let payload = HealthImport.payload(
            workouts: [.init(id: "A", start: start, end: start.addingTimeInterval(1800), label: "Running",
                             activeKcal: 301.26, distanceM: 5012.4, avgHR: 151.6, maxHR: nil, source: "Apple Watch")],
            vo2max: .init(value: 44.62, at: start, source: "Apple Watch"))
        let workout = try XCTUnwrap((payload["workouts"] as? [[String: Any]])?.first)
        XCTAssertEqual(workout["start_unix"] as? Int, 1_790_000_000)
        XCTAssertEqual(workout["end_unix"] as? Int, 1_790_001_800)
        XCTAssertEqual(workout["active_kcal"] as? Double, 301.3)
        XCTAssertEqual(workout["avg_hr"] as? Double, 152)
        XCTAssertNil(workout["max_hr"])
        XCTAssertEqual((payload["vo2max"] as? [String: Any])?["value"] as? Double, 44.6)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(payload))
    }

    func testRestorePageAndUnits() throws {
        let page = try HubRestore.page(#"{"more":true,"next_event_id":2000,"next_reading_id":7,"events":[]}"#)
        XCTAssertTrue(page.more)
        XCTAssertEqual(page.nextEvent, 2000)
        XCTAssertEqual(page.nextReading, 7)
        XCTAssertThrowsError(try HubRestore.page(#"{"error":"unauthorized"}"#))

        XCTAssertEqual(Units.imperial.temperature(37), 98.6, accuracy: 0.001)
        XCTAssertEqual(Units.imperial.temperatureDelta(0.5), 0.9, accuracy: 0.001)
        XCTAssertEqual(Units.imperial.kilograms(Units.imperial.weight(kg: 75)), 75, accuracy: 0.001)
        XCTAssertEqual(Units.metric.distance(meters: 6200), 6.2, accuracy: 0.001)
    }
}
