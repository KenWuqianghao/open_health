import CryptoKit
import Foundation

// The health hub: an always-on server (crates/oura-hub) that keeps the summary for
// agents and a replica of the raw ring rows as a backup. This file holds the
// settings, the two payloads, and the pusher. See docs/health-hub.md.

/// Settings. The URL and the switch live in UserDefaults; the token lives in the
/// Keychain, readable after the first unlock so a background sync on a locked phone
/// can push.
enum HubSettings {
    private static let d = UserDefaults.standard
    static let tokenAccount = "hub-token"
    private static let enabledKey = "hub.enabled"
    private static let urlKey = "hub.url"
    private static let shaKey = "hub.last-summary-sha"
    private static let eventKey = "hub.after-event-id"
    private static let readingKey = "hub.after-reading-id"

    static var enabled: Bool {
        get { d.bool(forKey: enabledKey) }
        set { d.set(newValue, forKey: enabledKey) }
    }
    static var url: String {
        get { d.string(forKey: urlKey) ?? "" }
        set { d.set(newValue, forKey: urlKey) }
    }
    static var token: String? {
        get { Keychain.load(account: tokenAccount) }
        set {
            if let v = newValue, !v.isEmpty { Keychain.save(v, account: tokenAccount) } else { Keychain.delete(account: tokenAccount) }
        }
    }
    /// SHA-256 of the last summary body the hub accepted; an unchanged one is not sent again.
    static var lastSummarySha: String? {
        get { d.string(forKey: shaKey) }
        set { d.set(newValue, forKey: shaKey) }
    }
    /// The `oura-store` replication cursor: ids of the last rows the hub accepted.
    static var afterEventId: Int64 {
        get { Int64(d.integer(forKey: eventKey)) }
        set { d.set(Int(newValue), forKey: eventKey) }
    }
    static var afterReadingId: Int64 {
        get { Int64(d.integer(forKey: readingKey)) }
        set { d.set(Int(newValue), forKey: readingKey) }
    }
    /// Forget what was sent, so the next push starts from the first row.
    static func resetReplication() {
        afterEventId = 0
        afterReadingId = 0
        lastSummarySha = nil
    }

    /// `<base>/<path>` for a usable http(s) base URL, else nil.
    static func endpoint(base: String, path: String) -> URL? {
        var s = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard !s.isEmpty, let u = URL(string: s + "/" + path),
              let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = u.host, !host.isEmpty else { return nil }
        return u
    }
}

enum HubError: LocalizedError, Equatable {
    case notConfigured
    case badURL
    case noToken
    case payload(String)
    case status(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "hub is off"
        case .badURL: return "hub URL is not valid"
        case .noToken: return "no hub token"
        case .payload(let m): return "payload: \(m)"
        case .status(let code, let text): return "hub answered \(code): \(text.prefix(120))"
        case .badResponse: return "hub reply was not HTTP"
        }
    }
}

/// The summary body: the full `build_summary` JSON from the shared core with the
/// on-device model results folded in. The Swift `Summary` struct drops fields the
/// agent tools need (`generated_at`, `tz`, night `metrics`), so the raw JSON is the
/// base and is never re-encoded from the struct.
enum HubPayload {
    static func build(rawJson: String, models: Summary?) throws -> Data {
        guard let data = rawJson.data(using: .utf8),
              var root = (try JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { throw HubError.payload("summary JSON is not an object") }
        if let e = root["error"] as? String { throw HubError.payload(e) }
        if let models { overlay(&root, models: models) }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        root["pushed_by"] = ["client": "ios", "version": version]
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    /// Fold the model results in. Nights are matched by `start_ds`; only nights with
    /// a hypnogram change. `sleep_debt` is replaced only when the staged version
    /// covers at least as many days (the same rule as `Core.withModels`).
    static func overlay(_ root: inout [String: Any], models: Summary) {
        if var nights = root["nights"] as? [[String: Any]] {
            var byStart: [Int64: NightRow] = [:]
            for n in models.nights { if let s = n.start_ds, byStart[s] == nil { byStart[s] = n } }
            for i in nights.indices {
                guard let sds = (nights[i]["start_ds"] as? NSNumber)?.int64Value,
                      let m = byStart[sds], m.hasHypnogram else { continue }
                nights[i]["stages"] = m.stages
                if let v = m.deep_pct { nights[i]["deep_pct"] = v }
                if let v = m.light_pct { nights[i]["light_pct"] = v }
                if let v = m.rem_pct { nights[i]["rem_pct"] = v }
                if let v = m.wake_pct { nights[i]["wake_pct"] = v }
                if let v = m.efficiency { nights[i]["efficiency"] = v }
            }
            root["nights"] = nights
        }
        if let sd = models.sleepDebt {
            let rawDays = ((root["sleep_debt"] as? [String: Any])?["valid_days"] as? NSNumber)?.intValue ?? 0
            if sd.valid_days >= rawDays, let dict = encode(sd) { root["sleep_debt"] = dict }
        }
        if let c = models.cardio, let dict = encode(c) { root["cardio"] = dict }
        if let ill = models.illness {
            root["illness"] = [
                "available": ill.available, "status": ill.status, "traffic_light": ill.trafficLight,
                "score": ill.score, "decision": ill.decision, "date": ill.date, "days_with_data": ill.daysWithData,
            ] as [String: Any]
        }
        if !models.workouts.isEmpty, let arr = encodeArray(models.workouts) { root["workouts"] = arr }
    }

    private static func encode<T: Encodable>(_ v: T) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(v) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    private static func encodeArray<T: Encodable>(_ v: [T]) -> [[String: Any]]? {
        guard let data = try? JSONEncoder().encode(v) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// The head of one `export_batch_json` page: enough to drive the loop.
struct HubEventBatch: Decodable {
    struct Row: Decodable {}
    var error: String?
    var events: [Row]?
    var readings: [Row]?
    var next_event_id: Int64?
    var next_reading_id: Int64?
    var more: Bool?

    var eventCount: Int { events?.count ?? 0 }
    var readingCount: Int { readings?.count ?? 0 }
    var isEmpty: Bool { eventCount == 0 && readingCount == 0 }

    static func parse(_ json: String) throws -> HubEventBatch {
        try JSONDecoder().decode(HubEventBatch.self, from: Data(json.utf8))
    }
}

/// The HTTP side. One POST per body, a bearer token, a JSON reply.
enum HubPushEngine {
    static func request(url: URL, token: String, body: Data, timeout: TimeInterval) -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("open-oura-ios", forHTTPHeaderField: "User-Agent")
        req.httpBody = body
        return req
    }

    static func send(body: Data, url: URL, token: String, timeout: TimeInterval) async throws -> [String: Any] {
        let req = request(url: url, token: token, body: body, timeout: timeout)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw HubError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw HubError.status(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }
}

struct HubPushStatus: Equatable {
    var running = false
    var lastSummaryAt: Date?
    var lastEventsAt: Date?
    var lastHealthAt: Date?
    var lastError: String?
}

/// The UI face and the push logic. Status is published on the main actor; the
/// network and the payload work run wherever the caller is.
final class HubPusher: ObservableObject {
    static let shared = HubPusher()
    /// Rows per page. About 1 MB of hex per page at most.
    static let page: UInt32 = 1000

    @Published var enabled: Bool { didSet { HubSettings.enabled = enabled } }
    @Published var url: String { didSet { HubSettings.url = url } }
    @Published private(set) var hasToken: Bool
    @Published private(set) var status = HubPushStatus()

    private init() {
        enabled = HubSettings.enabled
        url = HubSettings.url
        hasToken = HubSettings.token?.isEmpty == false
    }

    func setToken(_ value: String) {
        HubSettings.token = value
        hasToken = !value.isEmpty
    }

    var isConfigured: Bool {
        enabled && hasToken && HubSettings.endpoint(base: url, path: "ingest/summary") != nil
    }

    private func targets() throws -> (summary: URL, events: URL, health: URL, token: String) {
        guard enabled else { throw HubError.notConfigured }
        guard let s = HubSettings.endpoint(base: url, path: "ingest/summary"),
              let e = HubSettings.endpoint(base: url, path: "ingest/events"),
              let h = HubSettings.endpoint(base: url, path: "ingest/health") else { throw HubError.badURL }
        guard let token = HubSettings.token, !token.isEmpty else { throw HubError.noToken }
        return (s, e, h, token)
    }

    private func update(_ change: @escaping (inout HubPushStatus) -> Void) async {
        await MainActor.run { change(&self.status) }
    }

    private func fail(_ error: Error, _ what: String) async {
        let text = (error as? HubError)?.errorDescription ?? error.localizedDescription
        dlog("hub", "\(what) failed: \(text)")
        await update { $0.lastError = text; $0.running = false }
    }

    /// Everything after a sync: the summary, then the new raw rows. `deadline` bounds
    /// the whole call; a page that did not go out is sent next time.
    func pushAll(rawJson: String?, models: Summary?, reason: String, deadline: TimeInterval) async {
        guard isConfigured else { return }
        let start = Date()
        if let rawJson {
            await pushSummary(rawJson: rawJson, models: models, reason: reason, timeout: min(deadline, 20))
        }
        var left = deadline - Date().timeIntervalSince(start)
        if left > 2 { await pushEvents(reason: reason, deadline: left) }
        left = deadline - Date().timeIntervalSince(start)
        if left > 2 { await pushHealth(reason: reason, deadline: left) }
    }

    /// Fire-and-forget from the UI thread or a dispatch queue.
    func schedule(rawJson: String?, models: Summary?, reason: String) {
        Task.detached(priority: .utility) {
            await self.pushAll(rawJson: rawJson, models: models, reason: reason, deadline: 60)
        }
    }

    /// From Settings: rebuild the summary, fold the last model results in, send all.
    func pushNow() {
        Task.detached(priority: .userInitiated) {
            let built = Core.baseWithJson()
            let models = SummaryCache.load() ?? built.summary
            await self.pushAll(rawJson: built.json, models: models, reason: "manual", deadline: 120)
        }
    }

    func sendAllRingDataAgain() {
        HubSettings.resetReplication()
        pushNow()
    }

    @discardableResult
    func pushSummary(rawJson: String, models: Summary?, reason: String, timeout: TimeInterval) async -> Bool {
        let t: (summary: URL, events: URL, health: URL, token: String)
        do { t = try targets() } catch { await fail(error, "summary"); return false }
        let body: Data
        do { body = try HubPayload.build(rawJson: rawJson, models: models) } catch { await fail(error, "summary"); return false }
        let sha = HubPayload.sha256(body)
        if sha == HubSettings.lastSummarySha, reason != "manual" {
            dlog("hub", "summary unchanged, not sent (\(reason))")
            return true
        }
        await update { $0.running = true; $0.lastError = nil }
        do {
            let reply = try await HubPushEngine.send(body: body, url: t.summary, token: t.token, timeout: timeout)
            HubSettings.lastSummarySha = sha
            dlog("hub", "summary sent: \(body.count) B, stored=\(reply["stored"] ?? "?") (\(reason))")
            await update { $0.running = false; $0.lastSummaryAt = Date() }
            return true
        } catch {
            await fail(error, "summary")
            return false
        }
    }

    /// Send the raw rows the hub does not have yet, page by page, until the
    /// deadline. The cursor advances after every accepted page, so a stop loses nothing.
    @discardableResult
    func pushEvents(reason: String, deadline: TimeInterval) async -> Bool {
        // Never send the bundled seed database: only a store this phone synced.
        guard FileManager.default.fileExists(atPath: DB.url.path) else { return true }
        let t: (summary: URL, events: URL, health: URL, token: String)
        do { t = try targets() } catch { await fail(error, "events"); return false }
        let start = Date()
        var events = 0, readings = 0, pages = 0
        await update { $0.running = true; $0.lastError = nil }
        while true {
            let left = deadline - Date().timeIntervalSince(start)
            guard left > 1 else { break }
            let json = exportBatchJson(dbPath: DB.url.path, afterEventId: HubSettings.afterEventId,
                                       afterReadingId: HubSettings.afterReadingId, limit: Self.page)
            let batch: HubEventBatch
            do { batch = try HubEventBatch.parse(json) } catch { await fail(HubError.payload("\(error)"), "events"); return false }
            if let e = batch.error { await fail(HubError.payload(e), "events"); return false }
            if batch.isEmpty { break }
            do {
                _ = try await HubPushEngine.send(body: Data(json.utf8), url: t.events, token: t.token, timeout: min(20, left))
            } catch {
                await fail(error, "events")
                return false
            }
            if let n = batch.next_event_id { HubSettings.afterEventId = n }
            if let n = batch.next_reading_id { HubSettings.afterReadingId = n }
            events += batch.eventCount; readings += batch.readingCount; pages += 1
            if batch.more != true { break }
        }
        if pages > 0 {
            dlog("hub", "events sent: \(events) events, \(readings) readings in \(pages) page(s), through id \(HubSettings.afterEventId) (\(reason))")
        }
        await update { $0.running = false; if pages > 0 { $0.lastEventsAt = Date() } }
        return true
    }

    /// Apple Health samples (the Watch) that changed since the last run, in pages.
    /// The reader keeps its own anchors; `deadline` bounds the whole walk.
    @discardableResult
    func pushHealth(reason: String, deadline: TimeInterval) async -> Bool {
        let reader = HealthReader.shared
        guard reader.enabled, reader.isAvailable else { return true }
        let t: (summary: URL, events: URL, health: URL, token: String)
        do { t = try targets() } catch { await fail(error, "health"); return false }
        await update { $0.running = true; $0.lastError = nil }
        let tz = TimeZone.current.secondsFromGMT()
        let start = Date()
        let outcome = await reader.engine.run(types: HealthReadTypes.all, deadline: deadline, tzOffsetS: tz) { body in
            let data = try JSONSerialization.data(withJSONObject: body)
            let left = max(5, min(20, deadline - Date().timeIntervalSince(start)))
            _ = try await HubPushEngine.send(body: data, url: t.health, token: t.token, timeout: left)
        }
        await reader.record(outcome)
        if let e = outcome.error {
            await fail(HubError.payload(e), "health")
            return false
        }
        if outcome.pages > 0 {
            dlog("hub", "health sent: \(outcome.samples) samples, \(outcome.deleted) deletions in \(outcome.pages) page(s)\(outcome.hitDeadline ? ", deadline hit" : "") (\(reason))")
        }
        await update { $0.running = false; if outcome.pages > 0 { $0.lastHealthAt = Date() } }
        return true
    }
}
