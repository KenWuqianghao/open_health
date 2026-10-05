import Foundation

// The few numbers the widgets and the Siri answers need. The app writes them to the
// App Group container after each summary; the widget extension and the app intents
// read them. This file is part of both targets, so it uses Foundation only.

struct Snapshot: Codable, Equatable {
    /// The day the scores belong to, "YYYY-MM-DD".
    var day: String?
    var readiness: Int?
    var sleep: Int?
    var activity: Int?
    var provisional = false
    var hrv: Int?
    var restingHR: Int?
    var inBedHours: Double?
    var steps: Int?
    var batteryPct: Int?
    var batteryDaysLeft: Double?
    var bedtimeStart: String?
    var bedtimeEnd: String?
    var highlight: String?
    var lastSync: Date?
    var writtenAt = Date()

    static let placeholder = Snapshot(day: nil, readiness: 84, sleep: 79, activity: 72, hrv: 46,
                                      restingHR: 52, inBedHours: 7.6, steps: 8400, batteryPct: 68)
}

enum SnapshotStore {
    /// The App Group of this build, from the Info.plist of the target (the group id
    /// follows the bundle id, so a build with another bundle id has its own group).
    static var groupID: String? {
        Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String
    }

    private static var url: URL? {
        guard let groupID, !groupID.isEmpty, !groupID.contains("$(") else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("snapshot.json")
    }

    static func load() -> Snapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(Snapshot.self, from: data)
    }

    /// Returns false when the container is not available (no App Group entitlement).
    @discardableResult
    static func save(_ snapshot: Snapshot) -> Bool {
        guard let url else { return false }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(snapshot) else { return false }
        // readable after the first unlock: the widget draws on a locked phone
        return (try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil
    }
}

extension Snapshot {
    /// "Readiness 84, optimal" and the like, for Siri and the widget's accessibility label.
    static func band(_ score: Int) -> String {
        switch score {
        case 85...: return "optimal"
        case 70..<85: return "good"
        case 60..<70: return "fair"
        default: return "pay attention"
        }
    }

    /// True when the scores are of today or yesterday.
    var isRecent: Bool {
        guard let day else { return false }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        guard let date = fmt.date(from: day) else { return false }
        return Date().timeIntervalSince(date) < 2 * 86_400
    }

    var dayText: String {
        guard let day else { return "" }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        guard let date = fmt.date(from: day) else { return day }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}
