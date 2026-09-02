import Foundation

/// A closed date interval that survives encoding.
struct HealthInterval: Codable, Equatable {
    var start: Date
    var end: Date
    init(_ iv: DateInterval) { start = iv.start; end = iv.end }
    var interval: DateInterval { DateInterval(start: start, end: max(end, start)) }
}

/// What the exporter knows about one day: the fingerprint it last wrote, retry
/// state, and a ledger of the sleep/workout windows it wrote (a re-staged night can
/// move its onset; the ledger keeps the old fragments deletable).
struct HealthDayState: Codable, Equatable {
    var fingerprint: String?
    var okAt: Date?
    var attempts = 0
    var lastAttemptAt: Date?
    var lastError: String?
    var sleepWindows: [HealthInterval] = []
    var workoutWindows: [HealthInterval] = []
}

struct HealthExportState: Codable, Equatable {
    var version = 1
    /// `HealthExporter.epoch` at the time of the last purge; a mismatch purges again.
    var epoch: String = ""
    /// Contiguous prefix of finalized-and-exported (or given-up) days.
    var exportThroughYmd: String?
    var days: [String: HealthDayState] = [:]
    var lastRunAt: Date?
    var lastSuccessAt: Date?
    var lastError: String?
    var daysWritten = 0
    var samplesWritten = 0
    var workoutsWritten = 0
    var deferredForUnlock = false
}

/// A JSON file next to the DB (the `ModelCacheStore` pattern): hundreds of day
/// entries plus interval ledgers do not belong in UserDefaults.
enum HealthExportStateStore {
    private static let queue = DispatchQueue(label: "md.thomas.openoura.health-state", qos: .utility)
    static var url: URL {
        DB.url.deletingLastPathComponent().appendingPathComponent("health-export-state.json")
    }
    static func load() -> HealthExportState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(HealthExportState.self, from: data) else {
            return HealthExportState()
        }
        return state
    }
    static func save(_ state: HealthExportState) {
        queue.sync {
            guard let data = try? JSONEncoder().encode(state) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
    static func clear() {
        queue.sync { try? FileManager.default.removeItem(at: url) }
    }
}
