import Foundation

/// Last successfully rendered summary. It is display-only: the SQLite store remains
/// the source of truth and a fresh summary always replaces this after launch. Keeping
/// it out of UserDefaults avoids loading a potentially large signal payload there.
enum SummaryCache {
    private static let queue = DispatchQueue(label: "md.thomas.openoura.summary-cache", qos: .utility)
    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("summary-cache.json")
    }

    static func load() -> Summary? {
        guard let data = try? Data(contentsOf: url),
              let summary = try? JSONDecoder().decode(Summary.self, from: data),
              summary.error == nil else { return nil }
        return summary
    }

    static func save(_ summary: Summary) {
        guard summary.error == nil else { return }
        queue.async {
            guard let data = try? JSONEncoder().encode(summary) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    static func clear() {
        queue.sync { try? FileManager.default.removeItem(at: url) }
    }
}

enum Core {
    /// The Apple Health sample bundles from the shared brain. `sinceUnix` trims the
    /// JSON to days whose data changed after that capture time.
    static func healthSamples(sinceUnix: Int64?) -> HealthEnvelope {
        let json = healthSamplesJson(dbPath: DB.readPath(), tzOffsetS: Int64(TimeZone.current.secondsFromGMT()),
                                     sinceUnix: sinceUnix)
        guard let data = json.data(using: .utf8),
              let env = try? JSONDecoder().decode(HealthEnvelope.self, from: data)
        else { return HealthEnvelope(error: "decode failed") }
        return env
    }

    /// Fast, model-free summary (vitals, activity ridges, device) straight from the
    /// shared-core JSON — safe to compute on a background queue and show immediately.
    static func base() -> Summary { baseWithJson().summary }

    /// `base()` plus the JSON string it was decoded from. The hub push sends the
    /// string: the Swift struct drops fields the agent tools read.
    static func baseWithJson() -> (summary: Summary, json: String) {
        let path = DB.readPath()   // synced DB if present, else the bundled seed
        // the phone's actual UTC offset, so night labels / sleep windows / digest
        // timing match the wearer's local clock — not a hardcoded constant. The whole
        // stack (web --tz-offset, the Python model runners, this FFI) takes whole
        // hours, so round to the nearest hour (best representable value for the rare
        // sub-hour zones like IST +5:30).
        let secs = TimeZone.current.secondsFromGMT()
        let tzOffset = Int64((Double(secs) / 3600).rounded())
        let json = summaryJson(dbPath: path, tzOffset: tzOffset)
        guard let data = json.data(using: .utf8),
              let s = try? JSONDecoder().decode(Summary.self, from: data)
        else { return (Summary(error: "decode failed"), json) }
        return (s, json)
    }
}
