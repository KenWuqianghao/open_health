import XCTest
@testable import OuraApp

final class HubPushTests: XCTestCase {
    private let raw = """
    {"generated_at":1700000000.5,"tz":8,"device":{"fresh_hours":1.0},
     "nights":[{"ymd":"2023-11-14","start_ds":1000,"in_bed_h":7.5,"stages":null,"efficiency":null,"metrics":{"asleep_min":400.0}},
               {"ymd":"2023-11-13","start_ds":2000,"in_bed_h":6.0}],
     "sleep_debt":{"debt_min":100.0,"valid_days":5,"state":"none"},
     "vitals":{"hrv":{"latest":50.0}},"activity_daily":{}}
    """

    private func decode(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    func testOverlayFoldsModelsIntoTheRawJson() throws {
        var models = Summary()
        var night = NightRow(); night.start_ds = 1000; night.stages = [1, 2, 3, 4, 2, 2]
        night.deep_pct = 17; night.light_pct = 50; night.rem_pct = 17; night.wake_pct = 16; night.efficiency = 84
        var other = NightRow(); other.start_ds = 3000; other.stages = [1]   // no hypnogram, no match
        models.nights = [night, other]
        models.cardio = Cardio(vascular_age: 27.5, chronological_age: 30, pwv_ms: 6.1, segments: 12)
        models.illness = IllnessResult(available: true, status: "NO_SIGNS", trafficLight: "NO_SIGNS", score: 0.1,
                                       decision: 0, date: "2023-11-14", daysWithData: 9, biomarkers: [])
        var debt = SleepDebtSummary(); debt.debt_min = 42; debt.valid_days = 5
        models.sleepDebt = debt

        let root = decode(try HubPayload.build(rawJson: raw, models: models))
        let nights = root["nights"] as! [[String: Any]]
        XCTAssertEqual(nights[0]["stages"] as? [Int], [1, 2, 3, 4, 2, 2])
        XCTAssertEqual(nights[0]["efficiency"] as? Double, 84)
        XCTAssertEqual((nights[0]["metrics"] as? [String: Any])?["asleep_min"] as? Double, 400)   // untouched
        XCTAssertNil(nights[1]["stages"] ?? nil)
        XCTAssertEqual(root["generated_at"] as? Double, 1700000000.5)
        XCTAssertEqual(root["tz"] as? Int, 8)
        XCTAssertEqual((root["cardio"] as? [String: Any])?["vascular_age"] as? Double, 27.5)
        XCTAssertEqual((root["illness"] as? [String: Any])?["status"] as? String, "NO_SIGNS")
        XCTAssertEqual((root["sleep_debt"] as? [String: Any])?["debt_min"] as? Double, 42)
        XCTAssertEqual((root["pushed_by"] as? [String: Any])?["client"] as? String, "ios")
    }

    func testStagedSleepDebtNeverReplacesAWiderWindow() throws {
        var models = Summary()
        var debt = SleepDebtSummary(); debt.debt_min = 42; debt.valid_days = 2   // raw has 5
        models.sleepDebt = debt
        let root = decode(try HubPayload.build(rawJson: raw, models: models))
        XCTAssertEqual((root["sleep_debt"] as? [String: Any])?["debt_min"] as? Double, 100)
    }

    func testWithoutModelsTheRawJsonPassesThrough() throws {
        let root = decode(try HubPayload.build(rawJson: raw, models: nil))
        XCTAssertEqual((root["nights"] as? [[String: Any]])?.count, 2)
        XCTAssertNil(root["cardio"] ?? nil)
    }

    func testErrorsAndNonObjectsAreRejected() {
        XCTAssertThrowsError(try HubPayload.build(rawJson: "{\"error\":\"no decoded events\"}", models: nil))
        XCTAssertThrowsError(try HubPayload.build(rawJson: "[1,2]", models: nil))
        XCTAssertThrowsError(try HubPayload.build(rawJson: "not json", models: nil))
    }

    func testEndpointsAcceptOnlyUsableHttpUrls() {
        XCTAssertEqual(HubSettings.endpoint(base: "https://hub.example.com/", path: "ingest/summary")?.absoluteString,
                       "https://hub.example.com/ingest/summary")
        XCTAssertEqual(HubSettings.endpoint(base: " http://100.64.0.2:8787 ", path: "ingest/events")?.absoluteString,
                       "http://100.64.0.2:8787/ingest/events")
        XCTAssertNil(HubSettings.endpoint(base: "", path: "x"))
        XCTAssertNil(HubSettings.endpoint(base: "hub.example.com", path: "x"))
        XCTAssertNil(HubSettings.endpoint(base: "ftp://hub.example.com", path: "x"))
    }

    func testRequestCarriesTheTokenAndBody() {
        let url = URL(string: "https://hub.example.com/ingest/summary")!
        let req = HubPushEngine.request(url: url, token: "abc", body: Data("{}".utf8), timeout: 7)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer abc")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(req.httpBody, Data("{}".utf8))
        XCTAssertEqual(req.timeoutInterval, 7)
    }

    func testEventBatchHeadParses() throws {
        let b = try HubEventBatch.parse("""
        {"schema_version":2,"devices":[],"events":[{"id":1},{"id":2}],"readings":[{"id":9}],
         "next_event_id":2,"next_reading_id":9,"more":true}
        """)
        XCTAssertEqual(b.eventCount, 2)
        XCTAssertEqual(b.readingCount, 1)
        XCTAssertEqual(b.next_event_id, 2)
        XCTAssertEqual(b.more, true)
        XCTAssertFalse(b.isEmpty)
        let e = try HubEventBatch.parse("{\"error\":\"boom\"}")
        XCTAssertEqual(e.error, "boom")
        XCTAssertTrue(e.isEmpty)
        XCTAssertEqual(HubPayload.sha256(Data("a".utf8)),
                       "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb")
    }

    func testHubLinkParsesTheConnectQRCode() {
        let token = "0123456789abcdef0123456789abcdef"
        let link = HubLink.parse(URL(string: "openoura://hub?url=https%3A%2F%2Fbox.tail1.ts.net&token=\(token)")!)
        XCTAssertEqual(link, HubLink(url: "https://box.tail1.ts.net", token: token))
        XCTAssertEqual(link?.host, "box.tail1.ts.net")
        XCTAssertNotNil(HubLink.parse(URL(string: "openoura://hub?url=http://box.tail1.ts.net:8787&token=\(token)")!))
    }

    func testHubLinkRejectsBadLinks() {
        let token = "0123456789abcdef0123456789abcdef"
        XCTAssertNil(HubLink.parse(URL(string: "https://hub?url=https://a.b&token=\(token)")!))       // wrong scheme
        XCTAssertNil(HubLink.parse(URL(string: "openoura://sync?url=https://a.b&token=\(token)")!))   // wrong action
        XCTAssertNil(HubLink.parse(URL(string: "openoura://hub?url=https://a.b&token=short")!))          // short token
        XCTAssertNil(HubLink.parse(URL(string: "openoura://hub?url=ftp://a.b&token=\(token)")!))        // not http(s)
        XCTAssertNil(HubLink.parse(URL(string: "openoura://hub?token=\(token)")!))                      // no URL
    }
}
