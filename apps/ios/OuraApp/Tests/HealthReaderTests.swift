import HealthKit
import XCTest
@testable import OuraApp

/// Pages per kind, in order; records the anchors it was asked for.
final class FakeHealthReadClient: HealthReadClient, @unchecked Sendable {
    var isAvailable = true
    var pages: [String: [HealthPage]] = [:]
    var asked: [(String, HKQueryAnchor?)] = []
    var failKind: String?

    func requestRead(_ types: Set<HKObjectType>) async throws {}
    func page(_ type: HKSampleType, after anchor: HKQueryAnchor?, limit: Int) async throws -> HealthPage {
        let key = type.identifier
        asked.append((key, anchor))
        if key.hasSuffix(failKind ?? "§") { throw NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"]) }
        guard var list = pages[key], !list.isEmpty else { return HealthPage(added: [], deleted: [], anchor: anchor) }
        let p = list.removeFirst()
        pages[key] = list
        return p
    }
}

final class HealthReaderTests: XCTestCase {
    private let hr = HealthReadTypes.all.first { $0.kind == "heart_rate" }!
    private let steps = HealthReadTypes.all.first { $0.kind == "step_count" }!
    private let sleep = HealthReadTypes.all.first { $0.kind == "sleep_analysis" }!
    private let workout = HealthReadTypes.all.first { $0.kind == "workout" }!

    private func hrSample(_ bpm: Double, at: TimeInterval) -> HKQuantitySample {
        HKQuantitySample(type: HKQuantityType(.heartRate),
                         quantity: HKQuantity(unit: .count().unitDivided(by: .minute()), doubleValue: bpm),
                         start: Date(timeIntervalSince1970: at), end: Date(timeIntervalSince1970: at))
    }

    func testEncoderMapsQuantityCategoryAndWorkout() {
        let q = HealthSampleEncoder.encode(HealthRead(hrSample(62, at: 1000), sourceBundle: "com.apple.health", sourceName: "Watch", device: "Watch7,1"), type: hr)
        XCTAssertEqual(q["kind"] as? String, "heart_rate")
        XCTAssertEqual(q["value"] as? Double, 62)
        XCTAssertEqual(q["unit"] as? String, "count/min")
        XCTAssertEqual(q["start_unix"] as? Double, 1000)
        XCTAssertEqual(q["source_bundle"] as? String, "com.apple.health")
        XCTAssertEqual(q["device"] as? String, "Watch7,1")
        XCTAssertNotNil(UUID(uuidString: q["uuid"] as! String))

        let cs = HKCategorySample(type: HKCategoryType(.sleepAnalysis), value: HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                                  start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 1800))
        let c = HealthSampleEncoder.encode(HealthRead(cs, sourceBundle: nil, sourceName: nil), type: sleep)
        XCTAssertEqual(c["category"] as? String, "asleep_deep")
        XCTAssertNil(c["value"])
        XCTAssertEqual(HealthSampleEncoder.categoryLabel("stand_hour", HKCategoryValueAppleStandHour.stood.rawValue), "stood")

        let w = HKWorkout(activityType: .running, start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 1800))
        let wr = HealthSampleEncoder.encode(HealthRead(w, sourceBundle: nil, sourceName: "Watch"), type: workout)
        XCTAssertEqual(wr["category"] as? String, "running")
        XCTAssertEqual(wr["value"] as? Double, 30)
        XCTAssertEqual(wr["unit"] as? String, "min")
        XCTAssertEqual(HealthSampleEncoder.activityName(.traditionalStrengthTraining), "strength_training")
    }

    func testEnginePagesExcludesOwnSourceAndAdvancesAnchors() async {
        let client = FakeHealthReadClient()
        let a1 = HKQueryAnchor(fromValue: 1), a2 = HKQueryAnchor(fromValue: 2)
        // heart rate: a full page (limit-sized) then a short one; steps: nothing new
        var full = HealthPage(added: [], deleted: [], anchor: a1)
        for i in 0..<HealthReadEngine.page {
            let bundle = i % 4 == 0 ? "md.thomas.openoura" : "com.apple.health"
            full.added.append(HealthRead(hrSample(60, at: Double(i)), sourceBundle: bundle, sourceName: "x"))
        }
        let short = HealthPage(added: [HealthRead(hrSample(70, at: 9999), sourceBundle: "com.apple.health", sourceName: "x")],
                               deleted: ["DEAD-1"], anchor: a2)
        client.pages[HKQuantityType(.heartRate).identifier] = [full, short]

        let engine = HealthReadEngine(client: client, ownBundle: "md.thomas.openoura", state: HealthReadState())
        var bodies: [[String: Any]] = []
        let lock = NSLock()
        let out = await engine.run(types: [hr, steps], deadline: 30, tzOffsetS: 7200) { body in
            lock.lock(); bodies.append(body); lock.unlock()
        }
        XCTAssertNil(out.error)
        XCTAssertEqual(out.pages, 2)
        XCTAssertEqual(out.samples, HealthReadEngine.page * 3 / 4 + 1)
        XCTAssertEqual(out.deleted, 1)
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies[0]["tz_offset_s"] as? Int, 7200)
        XCTAssertEqual((bodies[1]["deleted"] as? [String]), ["DEAD-1"])
        // anchors: first ask has none, the second carries a1; steps asked once with none
        XCTAssertEqual(client.asked.count, 3)
        XCTAssertNil(client.asked[0].1)
        XCTAssertEqual(client.asked[1].1, a1)
        XCTAssertEqual(client.asked[2].0, HKQuantityType(.stepCount).identifier)
        let state = await engine.currentState
        XCTAssertEqual(state.anchor(for: "heart_rate"), a2)
        XCTAssertEqual(state.samplesSent, out.samples)
        XCTAssertNotNil(state.lastSuccessAt)
    }

    func testEngineStopsOnASendFailureAndKeepsTheAnchor() async {
        let client = FakeHealthReadClient()
        let a1 = HKQueryAnchor(fromValue: 1)
        client.pages[HKQuantityType(.heartRate).identifier] = [
            HealthPage(added: [HealthRead(hrSample(60, at: 1), sourceBundle: "com.apple.health", sourceName: "x")], deleted: [], anchor: a1)
        ]
        let engine = HealthReadEngine(client: client, ownBundle: nil, state: HealthReadState())
        let out = await engine.run(types: [hr, steps], deadline: 30, tzOffsetS: 0) { _ in
            throw NSError(domain: "net", code: 7, userInfo: [NSLocalizedDescriptionKey: "offline"])
        }
        XCTAssertEqual(out.error, "heart_rate: offline")
        XCTAssertEqual(out.pages, 0)
        let state = await engine.currentState
        XCTAssertNil(state.anchor(for: "heart_rate"))   // read again next time
        XCTAssertEqual(state.lastError, "heart_rate: offline")
        XCTAssertEqual(client.asked.count, 1)            // steps were not reached
    }

    func testEngineHonoursTheDeadlineAndReadErrors() async {
        let client = FakeHealthReadClient()
        let engine = HealthReadEngine(client: client, ownBundle: nil, state: HealthReadState())
        let out = await engine.run(types: [hr, steps], deadline: 0, tzOffsetS: 0) { _ in }
        XCTAssertTrue(out.hitDeadline)
        XCTAssertEqual(client.asked.count, 0)

        client.failKind = "HeartRate"
        let failed = await engine.run(types: [hr], deadline: 30, tzOffsetS: 0) { _ in }
        XCTAssertEqual(failed.error, "heart_rate: boom")
    }

    func testStateRoundTripsAnchors() throws {
        var s = HealthReadState()
        s.setAnchor(HKQueryAnchor(fromValue: 42), for: "heart_rate")
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(HealthReadState.self, from: data)
        XCTAssertEqual(back.anchor(for: "heart_rate"), HKQueryAnchor(fromValue: 42))
        XCTAssertNil(back.anchor(for: "steps"))
    }
}
