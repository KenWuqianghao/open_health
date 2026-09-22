import SwiftUI

// The design tokens. Every color is a system semantic color and every font is a
// text style, so the app follows Dark Mode, Increase Contrast, Dynamic Type, and the
// Liquid Glass chrome on iOS 26 without extra code. The visual model is the Apple
// Health app: a grouped background, cards with a colored category label, big rounded
// numbers, and one accent color per metric.

enum Theme {
    // ── metric accents (the Apple Health category hues) ──────────────────────
    static let sleep = Color.indigo
    static let activity = Color.orange
    static let readiness = Color.teal
    static let heart = Color.red
    static let hrv = Color.mint
    static let temperature = Color.purple
    static let oxygen = Color.cyan
    static let cardio = Color.pink
    static let device = Color.gray

    // ── status ───────────────────────────────────────────────────────────────
    static let good = Color.green
    static let caution = Color.orange
    static let alert = Color.red

    // ── sleep stages (the Health app hypnogram palette) ──────────────────────
    static let deep = Color.indigo
    static let light = Color.blue
    static let rem = Color.cyan
    static let awake = Color.orange
    static func stage(_ s: Int) -> Color {
        switch s { case 1: return deep; case 2: return light; case 3: return rem; default: return awake }
    }
    static func stageName(_ s: Int) -> String {
        switch s { case 1: return "Deep"; case 2: return "Core"; case 3: return "REM"; default: return "Awake" }
    }

    /// Color a change only when it is large enough to matter. Small moves stay gray.
    static func tone(delta: Double?, goodWhenPositive: Bool = true, threshold: Double = 8) -> Color {
        guard let d = delta, abs(d) >= threshold else { return .secondary }
        let isGood = d >= 0 ? goodWhenPositive : !goodWhenPositive
        return isGood ? good : alert
    }

    /// Oura's three score bands: optimal from 85, good from 70, pay attention below.
    static func scoreBand(_ score: Double) -> (label: String, color: Color) {
        switch score {
        case 85...: return ("Optimal", good)
        case 70..<85: return ("Good", .secondary)
        case 60..<70: return ("Fair", caution)
        default: return ("Pay attention", alert)
        }
    }

    static func debt(_ state: String) -> Color {
        switch state {
        case "none": return good
        case "low": return sleep
        case "moderate": return caution
        case "high": return alert
        default: return .secondary
        }
    }

    // ── shape ────────────────────────────────────────────────────────────────
    static let cardRadius: CGFloat = 20
    static let cardPadding: CGFloat = 16
    static let gutter: CGFloat = 16

    // ── type ─────────────────────────────────────────────────────────────────
    /// The big number in a card: rounded, semibold, tabular digits.
    static func number(_ style: Font.TextStyle = .title) -> Font {
        .system(style, design: .rounded).weight(.semibold)
    }
    static func mono(_ style: Font.TextStyle = .footnote) -> Font {
        .system(style, design: .monospaced)
    }
}

// ── date + duration formatting ───────────────────────────────────────────────
enum Fmt {
    private static let ymd: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static let short: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return f
    }()
    private static let medium: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE MMMM d")
        return f
    }()
    private static let monthDayFmt: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d")
        return f
    }()

    static func date(_ day: String) -> Date? { ymd.date(from: day) }

    /// "Today", "Yesterday", or "Mon, Sep 22".
    static func dayLabel(_ day: String, now: Date = Date()) -> String {
        guard let d = date(day) else { return day }
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { return "Today" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "Yesterday" }
        return short.string(from: d)
    }

    /// "Monday, September 22" for page titles.
    static func dayTitle(_ day: String) -> String {
        guard let d = date(day) else { return day }
        return medium.string(from: d)
    }

    private static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                     "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// "Sep 22" for axes and small captions. Accepts "yyyy-MM-dd", "MM-dd", and the
    /// summary's weekday labels ("Mon 09-07").
    static func monthDay(_ day: String) -> String {
        if let d = date(day) { return monthDayFmt.string(from: d) }
        let tail = String(day.suffix(5))
        let parts = tail.split(separator: "-").compactMap { Int($0) }
        if parts.count == 2, (1...12).contains(parts[0]) {
            return "\(monthNames[parts[0] - 1]) \(parts[1])"
        }
        return day
    }

    /// Hours as "7 hr 41 min" parts for a big number.
    static func hoursMinutes(_ hours: Double) -> [(String, String)] {
        let total = max(0, Int((hours * 60).rounded()))
        if total < 60 { return [("\(total)", "min")] }
        return [("\(total / 60)", "hr"), ("\(total % 60)", "min")]
    }
    static func minutes(_ minutes: Double) -> [(String, String)] { hoursMinutes(minutes / 60) }

    static func minutesText(_ minutes: Double) -> String {
        hoursMinutes(minutes / 60).map { "\($0.0) \($0.1)" }.joined(separator: " ")
    }

    static func number(_ v: Double?, decimals: Int = 0, fallback: String = "—") -> String {
        guard let v, v.isFinite else { return fallback }
        return decimals > 0 ? String(format: "%.\(decimals)f", v) : Int(v.rounded()).formatted(.number)
    }

    static func steps(_ steps: Double?) -> String {
        guard let steps else { return "—" }
        return Int(steps.rounded()).formatted(.number)
    }
}
