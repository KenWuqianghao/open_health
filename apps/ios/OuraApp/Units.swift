import Foundation

/// Metric or imperial. The summary JSON is always metric; only the display changes.
enum Units: String, CaseIterable, Identifiable {
    case metric, imperial
    var id: String { rawValue }
    var title: String { self == .metric ? "Metric (°C, km, kg)" : "Imperial (°F, mi, lb)" }

    private static let key = "display.units"
    static var current: Units {
        get {
            if let raw = UserDefaults.standard.string(forKey: key), let u = Units(rawValue: raw) { return u }
            return Locale.current.measurementSystem == .us ? .imperial : .metric
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    var temperatureUnit: String { self == .metric ? "°C" : "°F" }
    var distanceUnit: String { self == .metric ? "km" : "mi" }
    var weightUnit: String { self == .metric ? "kg" : "lb" }
    var heightUnit: String { self == .metric ? "cm" : "in" }

    /// An absolute temperature from °C.
    func temperature(_ celsius: Double) -> Double {
        self == .metric ? celsius : celsius * 9 / 5 + 32
    }
    /// A temperature difference from °C.
    func temperatureDelta(_ celsius: Double) -> Double {
        self == .metric ? celsius : celsius * 9 / 5
    }
    func distance(meters: Double) -> Double {
        meters / (self == .metric ? 1000 : 1609.344)
    }
    func weight(kg: Double) -> Double { self == .metric ? kg : kg * 2.204_622_6 }
    func kilograms(_ shown: Double) -> Double { self == .metric ? shown : shown / 2.204_622_6 }
    func height(cm: Double) -> Double { self == .metric ? cm : cm / 2.54 }
    func centimeters(_ shown: Double) -> Double { self == .metric ? shown : shown * 2.54 }
}

extension Fmt {
    /// "35.4 °C" or "95.7 °F".
    static func temperature(_ celsius: Double?) -> String {
        guard let celsius else { return "—" }
        let u = Units.current
        return "\(number(u.temperature(celsius), decimals: 1)) \(u.temperatureUnit)"
    }
    /// "+0.3 °C": a difference, with its sign.
    static func temperatureDelta(_ celsius: Double?) -> String {
        guard let celsius else { return "—" }
        let u = Units.current
        let v = u.temperatureDelta(celsius)
        let text = number(abs(v), decimals: 1)
        let sign = text == "0.0" ? "" : (v > 0 ? "+" : "−")
        return "\(sign)\(text) \(u.temperatureUnit)"
    }
    /// "6.2 km" or "3.9 mi".
    static func distance(meters: Double?) -> String {
        guard let meters else { return "—" }
        let u = Units.current
        return "\(number(u.distance(meters: meters), decimals: 1)) \(u.distanceUnit)"
    }
    /// "in 3 days", "tomorrow", "today", "2 days ago".
    static func relativeDays(_ days: Int) -> String {
        switch days {
        case 0: return "today"
        case 1: return "tomorrow"
        case -1: return "yesterday"
        case 2...: return "in \(days) days"
        default: return "\(-days) days ago"
        }
    }
    /// A clock time "23:05" in the phone's 12 or 24 hour style.
    static func clock(_ hm: String?) -> String {
        guard let hm else { return "—" }
        let parts = hm.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return hm }
        var c = DateComponents()
        c.hour = parts[0]; c.minute = parts[1]
        guard let date = Calendar.current.date(from: c) else { return hm }
        return date.formatted(date: .omitted, time: .shortened)
    }
}
