import Foundation
import SwiftUI

// The results on top of the core summary, decoded (oura-summary `extras.rs`,
// `journal.rs`). The web dashboard gets the same JSON. Nothing is computed here
// except what joins the on-device model results with the JSON.

/// A value that decodes to `nil` when its JSON does not match, so one section with a
/// new shape cannot make the whole summary fail.
struct Lenient<T: Codable>: Codable {
    var value: T?
    init(_ value: T?) { self.value = value }
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if let value { try c.encode(value) } else { try c.encodeNil() }
    }
}

// ── workouts from every source ───────────────────────────────────────────────
struct WorkoutEntry: Codable, Identifiable, Hashable {
    var id: String
    var day: String
    /// Local "YYYY-MM-DD HH:MM".
    var start: String
    var end: String
    var start_unix: Double
    var end_unix: Double
    var duration_min: Double
    var label: String
    /// "ring" (model), "ring_met" (rule), "health" (Apple Health), "manual".
    var source: String
    var source_name: String
    var active_kcal: Double? = nil
    var distance_m: Double? = nil
    var avg_hr: Double? = nil
    var max_hr: Double? = nil
    var note: String? = nil

    var startHM: String { String(start.suffix(5)) }
    var fromRing: Bool { source == "ring" || source == "ring_met" }
    var sourceIcon: String {
        switch source {
        case "health": return "applewatch"
        case "manual": return "square.and.pencil"
        default: return "circle.circle"
        }
    }
    /// The id the journal uses for a manual workout.
    var journalID: String? { source == "manual" ? String(id.dropFirst("manual-".count)) : nil }
}

// ── daytime stress and resilience ────────────────────────────────────────────
struct StressDay: Codable {
    var stressed_min: Double = 0
    var engaged_min: Double = 0
    var relaxed_min: Double = 0
    var restored_min: Double = 0
    var active_min: Double = 0
    var measured_min: Double = 0
    var mean_index: Double? = nil
}
struct StressPoint: Codable, Identifiable {
    var t: Double
    var index: Double
    var zone: String
    var id: Double { t }
    var date: Date { Date(timeIntervalSince1970: t) }
}
struct StressReference: Codable {
    var bpm: Double? = nil
    var rmssd_ms: Double? = nil
    var windows: Int? = nil
}
struct StressSummary: Codable {
    var latest: String? = nil
    var days: [String: StressDay] = [:]
    var timeline: [StressPoint] = []
    var reference: StressReference? = nil
}
struct ResilienceSummary: Codable {
    var score: Double
    var level: String
    var days: Int
    var sleep_recovery: Double? = nil
    var daytime_recovery: Double? = nil
    var stress_load: Double? = nil
}

enum StressZone: String, CaseIterable, Identifiable {
    case stressed, engaged, relaxed, restored
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var color: Color {
        switch self {
        case .stressed: return .orange
        case .engaged: return .yellow
        case .relaxed: return .teal
        case .restored: return .blue
        }
    }
    func minutes(in day: StressDay) -> Double {
        switch self {
        case .stressed: return day.stressed_min
        case .engaged: return day.engaged_min
        case .relaxed: return day.relaxed_min
        case .restored: return day.restored_min
        }
    }
}

// ── guidance ─────────────────────────────────────────────────────────────────
struct BedtimeGuidance: Codable {
    var start: String
    var end: String
    var start_min: Double
    var end_min: Double
    var usual_wake: String
    var nights_used: Int
    var basis: String
    var need_h: Double
}
struct RegularityInfo: Codable {
    var sri: Double
    var day_pairs: Int
    var days: Int
    var bedtime: String
    var bedtime_sd_min: Double
    var wake: String
    var wake_sd_min: Double
    var midpoint: String
    var midpoint_sd_min: Double
    var chronotype: String

    var chronotypeTitle: String {
        switch chronotype {
        case "early": return "Early type"
        case "moderately_early": return "Moderately early type"
        case "moderately_late": return "Moderately late type"
        case "late": return "Late type"
        default: return "Intermediate type"
        }
    }
    /// Phillips 2017 reports a population mean near 80 for adults.
    var band: (label: String, color: Color) {
        switch sri {
        case 85...: return ("Very regular", Theme.good)
        case 70..<85: return ("Regular", .secondary)
        case 55..<70: return ("Irregular", Theme.caution)
        default: return ("Very irregular", Theme.alert)
        }
    }
}
struct Guidance: Codable {
    var bedtime: BedtimeGuidance? = nil
    var regularity: RegularityInfo? = nil
}

// ── reports ──────────────────────────────────────────────────────────────────
struct ReportMetric: Codable {
    var name: String
    var unit: String
    var avg: Double
    var n: Int
    var prev: Double? = nil
    var delta: Double? = nil
}
struct ReportDayRef: Codable {
    var day: String
    var score: Double
}
struct ReportTotals: Codable {
    var steps: Double = 0
    var active_kcal: Double = 0
    var distance_m: Double = 0
    var workouts: Int = 0
    var workout_min: Double = 0
    var rest_days: Int = 0
}
struct PeriodReport: Codable, Identifiable {
    var id: String
    var start: String
    var end: String
    var days: Int
    var complete: Bool
    var metrics: [String: ReportMetric] = [:]
    var best_day: ReportDayRef? = nil
    var worst_day: ReportDayRef? = nil
    var totals = ReportTotals()
    var tags: [String: Int] = [:]
    var highlights: [String] = []

    var isMonth: Bool { !id.contains("W") }
    var title: String {
        guard let first = Fmt.date(start), let last = Fmt.date(end) else { return id }
        if isMonth { return first.formatted(.dateTime.month(.wide).year()) }
        let a = first.formatted(.dateTime.month(.abbreviated).day())
        let b = last.formatted(.dateTime.month(.abbreviated).day())
        return "\(a) – \(b)"
    }
}
struct Reports: Codable {
    var weeks: [PeriodReport] = []
    var months: [PeriodReport] = []
    func report(_ id: String) -> PeriodReport? { (weeks + months).first { $0.id == id } }
}

// ── tags and what follows them ───────────────────────────────────────────────
struct TagEffect: Codable, Identifiable {
    var metric: String
    var name: String
    var unit: String
    var with: Double
    var without: Double
    var delta: Double
    var delta_pct: Double? = nil
    var effect_size: Double
    /// "clear", "weak" or "none".
    var strength: String
    var nights: Int
    var id: String { metric }
    /// More is better for every night metric except heart rate and temperature.
    var goodWhenPositive: Bool { !["rhr", "temp_dev"].contains(metric) }
}
struct TagInsight: Codable, Identifiable {
    var tag: String
    var days: Int
    var nights: Int
    var other_nights: Int
    var ready: Bool
    var effects: [TagEffect] = []
    var id: String { tag }
    var found: [TagEffect] { effects.filter { $0.strength != "none" } }
}
struct Correlations: Codable {
    var min_nights: Int = 3
    var tags: [TagInsight] = []
}

struct CycleInfo: Codable {
    var cycle_day: Int
    var phase: String
    var mean_cycle_days: Double
    var cycles_used: Int
    var last_period: String
    var next_period: String
    var days_to_next_period: Int
    var ovulation: String
    var ovulation_confirmed: Bool
    var fertile_start: String
    var fertile_end: String

    var phaseTitle: String {
        switch phase {
        case "menstrual": return "Period"
        case "follicular": return "Follicular phase"
        case "fertile": return "Fertile window"
        case "luteal": return "Luteal phase"
        default: return "Period is late"
        }
    }
}

// ── the journal ──────────────────────────────────────────────────────────────
struct JournalTag: Codable, Identifiable, Hashable {
    var id: String
    var day: String
    var tag: String
    var note: String? = nil
}
struct JournalWorkout: Codable, Identifiable {
    var id: String
    var start_unix: Double
    var duration_min: Double
    var label: String
    var active_kcal: Double? = nil
    var note: String? = nil
}
struct RestPeriod: Codable {
    var start: String
    var end: String? = nil
}
struct JournalData: Codable {
    var tags: [JournalTag] = []
    var workouts: [JournalWorkout] = []
    var periods: [String] = []
    var rest_mode: [RestPeriod] = []
    func tags(on day: String) -> [JournalTag] { tags.filter { $0.day == day } }
}
struct RestModeInfo: Codable {
    var on: Bool = false
    var today: Bool = false
    var days: [String] = []
}

// ── the rule-based illness check (the model-free Symptom Radar) ───────────────
struct RulesBiomarker: Codable {
    var type: String
    var value: Double
    var lower: Double
    var upper: Double
    var indicates_symptoms: Bool
    var reason: String? = nil
}
/// NightSignal (Mishra 2022): a sustained rise of the resting heart rate from
/// 00:00 to 06:59 against the median of all earlier nights.
struct NightSignal: Codable {
    var alert: String           // green | yellow | red
    var date: String
    var rhr: Int
    var baseline: Int
    var current: Bool
    var days_with_data: Int
}
struct RulesIllness: Codable {
    var nightsignal: NightSignal? = nil
    var available: Bool
    var status: String
    var traffic_light: String
    var score: Double
    var decision: Int
    var date: String? = nil
    var days_with_data: Int
    var biomarkers: [RulesBiomarker] = []
    var basis: String? = nil

    var result: IllnessResult {
        IllnessResult(available: available, status: status, trafficLight: traffic_light,
                      score: score, decision: decision, date: date ?? "",
                      daysWithData: days_with_data,
                      biomarkers: biomarkers.map {
                          IllnessBiomarker(type: $0.type, value: $0.value, lower: $0.lower, upper: $0.upper,
                                           indicatesSymptoms: $0.indicates_symptoms, reason: $0.reason)
                      })
    }
}

extension Summary {
    /// The Symptom Radar to show: the on-device model's result, else the rules.
    var shownIllness: (result: IllnessResult, fromRules: Bool)? {
        if let illness { return (illness, false) }
        if let rules = rulesIllness?.value, rules.basis == "rules" { return (rules.result, true) }
        return nil
    }

    /// The NightSignal alert of the newest night, when it is from last night.
    var nightSignal: NightSignal? {
        rulesIllness?.value?.nightsignal.flatMap { $0.current ? $0 : nil }
    }

    /// Every workout, newest first. The on-device activity model's sessions replace
    /// the rule-based ring sessions of the JSON; entries from Apple Health and the
    /// journal win over a ring session of the same time.
    var mergedWorkouts: [WorkoutEntry] {
        let json = entries?.value ?? []
        let model = workouts.filter { $0.isWorkout >= 0.5 }
        guard !model.isEmpty else { return json }
        let others = json.filter { !$0.fromRing }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        let fromModel: [WorkoutEntry] = model.compactMap { w in
            guard let start = fmt.date(from: w.start) else { return nil }
            let a = start.timeIntervalSince1970
            let b = a + Double(w.durationMin) * 60
            let covered = others.contains { o in
                min(b, o.end_unix) - max(a, o.start_unix) >= 0.5 * (b - a)
            }
            guard !covered else { return nil }
            return WorkoutEntry(id: "ring-\(Int(a))", day: w.dayLabel, start: w.start, end: w.end,
                                start_unix: a, end_unix: b, duration_min: Double(w.durationMin),
                                label: w.label, source: "ring", source_name: "Ring")
        }
        return (others + fromModel).sorted { $0.start_unix > $1.start_unix }
    }

    func mergedWorkouts(on day: String) -> [WorkoutEntry] {
        mergedWorkouts.filter { $0.day == day }.sorted { $0.start_unix < $1.start_unix }
    }

    /// The naps that ended on `day`.
    func naps(forDay day: String) -> [NightRow] {
        let main = night(forDay: day)
        return nights.filter { wakeYmd($0) == day && $0.id != main?.id && ($0.in_bed_h ?? 0) < 3 }
    }

    /// Minutes of one sleep stage per wake date, oldest first.
    func stageSeries(_ code: Int) -> [DatedVital] {
        nightlySeries { $0.stageMinutes(code) }
    }
}
