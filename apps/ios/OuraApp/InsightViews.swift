import SwiftUI
import Charts

// Cards and pages for the estimates of oura-summary `extras.rs`: daytime stress,
// resilience, bedtime guidance and sleep regularity, and the weekly and monthly
// reports. The numbers come from the summary JSON; nothing is computed here.

// ── daytime stress ───────────────────────────────────────────────────────────

/// The share of each zone as one bar.
private struct ZoneBar: View {
    let day: StressDay
    var height: CGFloat = 12
    var body: some View {
        GeometryReader { geo in
            let total = max(day.measured_min, 1)
            HStack(spacing: 2) {
                ForEach(StressZone.allCases) { zone in
                    let share = zone.minutes(in: day) / total
                    if share > 0 {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(zone.color)
                            .frame(width: max(0, geo.size.width * CGFloat(share) - 2))
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

struct StressCard: View {
    let stress: StressSummary
    let resilience: ResilienceSummary?
    var body: some View {
        NavigationLink(value: Route.stress) {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(title: "Daytime Stress", icon: "bolt.heart.fill", tint: Theme.stress,
                           detail: stress.latest.map { Fmt.dayLabel($0) }, chevron: true)
                if let key = stress.latest, let day = stress.days[key] {
                    FitStack(alignment: .bottom, spacing: 20) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Stressed").font(.subheadline).foregroundStyle(.secondary)
                            BigValue(parts: Fmt.minutes(day.stressed_min), style: .title2)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Restored").font(.subheadline).foregroundStyle(.secondary)
                            BigValue(parts: Fmt.minutes(day.restored_min), style: .title2)
                        }
                    }
                    ZoneBar(day: day).reveal(delay: 0.2)
                }
                if let resilience {
                    Divider()
                    StatRow(label: "Resilience", value: resilience.level.capitalized,
                            color: Theme.scoreBand(resilience.score).color == .secondary ? .primary : Theme.scoreBand(resilience.score).color)
                }
            }
            .card()
            .zoomSource(Route.stress)
        }
        .buttonStyle(.pressable)
    }
}

struct StressDetailView: View {
    let stress: StressSummary
    let resilience: ResilienceSummary?

    private var days: [(day: String, value: StressDay)] {
        stress.days.keys.sorted().map { ($0, stress.days[$0]!) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let key = stress.latest, let day = stress.days[key] {
                    VStack(alignment: .leading, spacing: 12) {
                        CardHeader(title: Fmt.dayLabel(key), icon: "bolt.heart.fill", tint: Theme.stress,
                                   detail: "\(Fmt.minutesText(day.measured_min)) measured")
                        ZoneBar(day: day, height: 16)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), alignment: .leading, spacing: 14) {
                            ForEach(StressZone.allCases) { zone in
                                HStack(spacing: 8) {
                                    Circle().fill(zone.color).frame(width: 9, height: 9)
                                    Readout(value: Fmt.minutesText(zone.minutes(in: day)), caption: zone.title)
                                }
                            }
                        }
                        if day.active_min > 0 {
                            Text("\(Fmt.minutesText(day.active_min)) with movement are not included: the ring cannot tell exercise from stress there.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .card()
                }

                if stress.timeline.count > 2 {
                    VStack(alignment: .leading, spacing: 10) {
                        CardHeader(title: "Last 48 Hours", icon: "waveform.path", tint: Theme.stress)
                        Chart(stress.timeline) { p in
                            BarMark(x: .value("Time", p.date, unit: .minute),
                                    yStart: .value("Base", 0), yEnd: .value("Stress", p.index),
                                    width: .fixed(2))
                                .foregroundStyle((StressZone(rawValue: p.zone) ?? .engaged).color)
                        }
                        .chartYScale(domain: -3...3)
                        .chartYAxis {
                            AxisMarks(position: .trailing, values: [-2, 0, 2]) { value in
                                AxisGridLine().foregroundStyle(.quaternary)
                                AxisValueLabel {
                                    if let v = value.as(Double.self) {
                                        Text(v > 0 ? "Tense" : (v < 0 ? "Calm" : "Usual"))
                                    }
                                }
                            }
                        }
                        .chartXAxis {
                            AxisMarks(preset: .aligned, values: .stride(by: .hour, count: 12)) { _ in
                                AxisGridLine().foregroundStyle(.quaternary)
                                AxisValueLabel(format: .dateTime.weekday(.abbreviated).hour())
                            }
                        }
                        .frame(height: 170)
                        .reveal(delay: 0.15)
                        .accessibilityLabel("Stress level in the last 48 hours")
                    }
                    .card()
                }

                if days.count > 1 {
                    VStack(alignment: .leading, spacing: 10) {
                        CardHeader(title: "Past 14 Days", icon: "chart.bar.fill", tint: Theme.stress)
                        Chart {
                            ForEach(days, id: \.day) { entry in
                                ForEach(StressZone.allCases) { zone in
                                    BarMark(x: .value("Day", Fmt.date(entry.day) ?? Date(), unit: .day),
                                            y: .value("Hours", zone.minutes(in: entry.value) / 60),
                                            width: .ratio(0.62))
                                        .foregroundStyle(by: .value("Zone", zone.title))
                                }
                            }
                        }
                        .chartForegroundStyleScale(domain: StressZone.allCases.map(\.title),
                                                   range: StressZone.allCases.map(\.color))
                        .chartXAxis {
                            AxisMarks(preset: .aligned, values: .automatic(desiredCount: 4)) { _ in
                                AxisGridLine().foregroundStyle(.quaternary)
                                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                            }
                        }
                        .chartYAxis {
                            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                                AxisGridLine().foregroundStyle(.quaternary)
                                AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v)) h") } }
                            }
                        }
                        .frame(height: 190)
                        .reveal(delay: 0.15)
                    }
                    .card()
                }

                if let resilience {
                    ResilienceCard(resilience: resilience)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("About").font(.headline)
                    Text("While you are awake and do not move, the ring measures your heart rate and the time between beats. A high heart rate with a low variability is a sign of tension. The app compares each 5 minutes with your own usual daytime values of the last 14 days, so \u{201C}stressed\u{201D} means high for you.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let ref = stress.reference, let bpm = ref.bpm {
                        Text("Your usual daytime values: \(Int(bpm.rounded())) bpm\(ref.rmssd_ms.map { ", HRV \(Int($0.rounded())) ms" } ?? "").")
                            .font(.caption).foregroundStyle(.tertiary).padding(.top, 2)
                    }
                    Text("This is an estimate from published methods. It is not Oura's stress model and not a diagnosis.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .card()
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Daytime Stress")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ResilienceCard: View {
    let resilience: ResilienceSummary
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "Resilience", icon: "shield.lefthalf.filled", tint: Theme.resilience,
                       detail: "\(resilience.days) of 14 days")
            HStack(spacing: 16) {
                ScoreRing(score: resilience.score, tint: Theme.resilience, size: 72, lineWidth: 8, delay: 0.2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(resilience.level.capitalized).font(.title3.weight(.semibold))
                    Text("How well you balance stress with recovery")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Divider()
            part("Recovery in sleep", resilience.sleep_recovery)
            part("Recovery in the day", resilience.daytime_recovery)
            part("Stress load", resilience.stress_load)
        }
        .card()
    }

    @ViewBuilder private func part(_ name: String, _ value: Double?) -> some View {
        if let value {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(name).font(.subheadline)
                    Spacer()
                    Text("\(Int(value.rounded()))").font(.subheadline.weight(.semibold)).monospacedDigit()
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(.tertiarySystemFill))
                        Capsule().fill(Theme.resilience).frame(width: geo.size.width * CGFloat(value / 100))
                    }
                }
                .frame(height: 6)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(name) \(Int(value.rounded())) out of 100")
        }
    }
}

// ── bedtime guidance and regularity ──────────────────────────────────────────

struct GuidanceCard: View {
    let guidance: Guidance
    var body: some View {
        NavigationLink(value: Route.guidance) {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(title: "Bedtime", icon: "moon.stars.fill", tint: Theme.sleep, chevron: true)
                if let bed = guidance.bedtime {
                    Text("Ideal bedtime").font(.subheadline).foregroundStyle(.secondary)
                    BigValue("\(Fmt.clock(bed.start)) – \(Fmt.clock(bed.end))", "", style: .title2)
                }
                if let r = guidance.regularity {
                    if guidance.bedtime != nil { Divider() }
                    StatRow(label: "Sleep regularity", value: r.band.label,
                            color: r.band.color == .secondary ? .primary : r.band.color)
                }
            }
            .card()
            .zoomSource(Route.guidance)
        }
        .buttonStyle(.pressable)
    }
}

struct GuidanceView: View {
    let s: Summary
    let guidance: Guidance

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let bed = guidance.bedtime {
                    VStack(alignment: .leading, spacing: 10) {
                        CardHeader(title: "Ideal Bedtime", icon: "moon.stars.fill", tint: Theme.sleep)
                        BigValue("\(Fmt.clock(bed.start)) – \(Fmt.clock(bed.end))", "", style: .largeTitle)
                        Text(bed.basis == "best_nights"
                             ? "Your \(bed.nights_used) best nights of the last 30 days started near this time, and it leaves time for your sleep need of \(Fmt.minutesText(bed.need_h * 60)) before you usually wake at \(Fmt.clock(bed.usual_wake))."
                             : "From your usual wake time of \(Fmt.clock(bed.usual_wake)) and your sleep need of \(Fmt.minutesText(bed.need_h * 60)). With more scored nights, the app uses the bedtime of your best nights.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .card()
                }
                if let r = guidance.regularity {
                    VStack(alignment: .leading, spacing: 12) {
                        CardHeader(title: "Sleep Regularity", icon: "metronome.fill", tint: Theme.sleep,
                                   detail: "\(r.days) nights")
                        HStack(spacing: 16) {
                            ScoreRing(score: max(0, r.sri), tint: Theme.sleep, size: 72, lineWidth: 8, delay: 0.2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.band.label).font(.title3.weight(.semibold))
                                Text("Sleep Regularity Index").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                        StatRow(label: "Usual bedtime", value: "\(Fmt.clock(r.bedtime)) ± \(Int(r.bedtime_sd_min.rounded())) min")
                        Divider()
                        StatRow(label: "Usual wake time", value: "\(Fmt.clock(r.wake)) ± \(Int(r.wake_sd_min.rounded())) min")
                        Divider()
                        StatRow(label: "Middle of your sleep", value: Fmt.clock(r.midpoint))
                    }
                    .card()

                    VStack(alignment: .leading, spacing: 10) {
                        CardHeader(title: "Chronotype", icon: "sun.horizon.fill", tint: .orange)
                        Text(r.chronotypeTitle).font(.title3.weight(.semibold))
                        Text("The middle of your sleep is at \(Fmt.clock(r.midpoint)). An early type has it before 03:30 and a late type after 04:30. It shows when your body prefers to sleep, from the nights you had, which work and family also set.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .card()
                }
                SleepTimesChart(s: s)
                VStack(alignment: .leading, spacing: 6) {
                    Text("About").font(.headline)
                    Text("The Sleep Regularity Index is the chance that you are in the same state, asleep or awake, at two times 24 hours apart. 100 is the same schedule each day. A regular schedule goes with better sleep and better health in large studies.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("These are estimates from published methods, computed on this iPhone.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .card()
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Bedtime")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// When the main sleep of each of the last 14 days started and ended.
private struct SleepTimesChart: View {
    let s: Summary
    private struct Bar: Identifiable {
        let date: Date
        /// Hours from 18:00 of the evening the night started.
        let start: Double
        let end: Double
        var id: Date { date }
    }
    private var bars: [Bar] {
        s.days.prefix(14).compactMap { day in
            guard let n = s.night(forDay: day), !n.isNap, let date = Fmt.date(day),
                  let a = Self.hours(n.start), let h = n.in_bed_h else { return nil }
            // count from 18:00, so a bedtime before and after midnight are on one axis
            let start = (a - 18).truncatingRemainder(dividingBy: 24)
            let from = start < 0 ? start + 24 : start
            return Bar(date: date, start: from, end: from + h)
        }
    }
    private static func hours(_ hm: String?) -> Double? {
        let p = (hm ?? "").split(separator: ":").compactMap { Double($0) }
        return p.count == 2 ? p[0] + p[1] / 60 : nil
    }
    var body: some View {
        if bars.count > 2 {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(title: "Sleep Times", icon: "bed.double.fill", tint: Theme.sleep, detail: "Past 14 days")
                Chart(bars) { b in
                    BarMark(x: .value("Day", b.date, unit: .day),
                            yStart: .value("Bedtime", b.start), yEnd: .value("Wake", b.end),
                            width: .ratio(0.5))
                        .foregroundStyle(Theme.sleep.gradient)
                        .cornerRadius(4)
                }
                .chartYScale(domain: .automatic(includesZero: false, reversed: true))
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .stride(by: 3)) { value in
                        AxisGridLine().foregroundStyle(.quaternary)
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(String(format: "%02d:00", (Int(v) + 18) % 24))
                            }
                        }
                    }
                }
                .frame(height: 190)
                .reveal(delay: 0.15)
                .accessibilityLabel("Bedtime and wake time of the last 14 days")
            }
            .card()
        }
    }
}

// ── reports ──────────────────────────────────────────────────────────────────

struct ReportsView: View {
    let reports: Reports
    @State private var monthly = false
    var body: some View {
        let list = monthly ? reports.months : reports.weeks
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Period", selection: $monthly.animation(Motion.settle)) {
                    Text("Weeks").tag(false)
                    Text("Months").tag(true)
                }
                .pickerStyle(.segmented)
                if list.isEmpty {
                    ContentUnavailableView("No Report Yet", systemImage: "doc.text.magnifyingglass",
                                           description: Text("A report needs at least one day with data."))
                        .padding(.top, 40)
                }
                ForEach(list) { report in
                    NavigationLink(value: Route.periodReport(report.id)) {
                        VStack(alignment: .leading, spacing: 10) {
                            CardHeader(title: report.title, icon: "doc.text.fill", tint: .accentColor,
                                       detail: report.complete ? "\(report.days) days" : "In progress", chevron: true)
                            HStack(spacing: 0) {
                                ForEach(["readiness", "sleep_score", "activity_score"], id: \.self) { key in
                                    if let m = report.metrics[key] {
                                        Readout(value: "\(Int(m.avg.rounded()))", caption: m.name.replacingOccurrences(of: " score", with: ""))
                                    }
                                }
                            }
                            if let first = report.highlights.first {
                                Text(first).font(.subheadline).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        .card()
                    }
                    .buttonStyle(.pressable)
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Reports")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: monthly)
    }
}

struct PeriodReportView: View {
    let report: PeriodReport
    private static let sections: [(title: String, icon: String, tint: Color, keys: [String])] = [
        ("Scores", "circle.hexagongrid.fill", Theme.readiness, ["readiness", "sleep_score", "activity_score"]),
        ("Sleep", "bed.double.fill", Theme.sleep, ["asleep_min", "efficiency"]),
        ("Body", "heart.fill", Theme.heart, ["hrv", "rhr", "breath", "spo2", "temp_dev"]),
        ("Day", "flame.fill", Theme.activity, ["steps", "active_kcal", "stressed_min"]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    CardHeader(title: report.isMonth ? "Month" : "Week", icon: "doc.text.fill", tint: .accentColor,
                               detail: report.complete ? "\(report.days) days with data" : "In progress")
                    Text(report.title).font(.title2.bold())
                    ForEach(report.highlights, id: \.self) { line in
                        Label(line, systemImage: "circle.fill")
                            .labelStyle(BulletLabel())
                            .font(.subheadline)
                    }
                }
                .card()

                ForEach(Self.sections, id: \.title) { section in
                    let rows = section.keys.compactMap { key in report.metrics[key].map { (key, $0) } }
                    if !rows.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            CardHeader(title: section.title, icon: section.icon, tint: section.tint)
                            ForEach(Array(rows.enumerated()), id: \.element.0) { i, row in
                                if i > 0 { Divider() }
                                MetricRow(key: row.0, metric: row.1, monthly: report.isMonth)
                            }
                        }
                        .card()
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    CardHeader(title: "Totals", icon: "sum", tint: Theme.activity)
                    StatRow(label: "Steps", value: Fmt.steps(report.totals.steps))
                    Divider()
                    StatRow(label: "Active energy", value: "\(Fmt.number(report.totals.active_kcal)) kcal")
                    Divider()
                    StatRow(label: "Distance", value: Fmt.distance(meters: report.totals.distance_m))
                    Divider()
                    StatRow(label: "Activity sessions",
                            value: "\(report.totals.workouts), \(Fmt.minutesText(report.totals.workout_min))")
                    if report.totals.rest_days > 0 {
                        Divider()
                        StatRow(label: "Days in rest mode", value: "\(report.totals.rest_days)")
                    }
                }
                .card()

                if report.best_day != nil || !report.tags.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        CardHeader(title: "Days", icon: "calendar", tint: .accentColor)
                        if let best = report.best_day {
                            NavigationLink(value: Route.report(ReportSel(day: best.day, sleep: true))) {
                                StatRow(label: "Best day", value: "\(Fmt.dayLabel(best.day)) · \(Int(best.score.rounded()))")
                            }
                        }
                        if let worst = report.worst_day, worst.day != report.best_day?.day {
                            Divider()
                            NavigationLink(value: Route.report(ReportSel(day: worst.day, sleep: true))) {
                                StatRow(label: "Hardest day", value: "\(Fmt.dayLabel(worst.day)) · \(Int(worst.score.rounded()))")
                            }
                        }
                        if !report.tags.isEmpty {
                            Divider()
                            FlowLayout(spacing: 6) {
                                ForEach(report.tags.keys.sorted(), id: \.self) { tag in
                                    HStack(spacing: 4) {
                                        TagChip(tag: tag)
                                        Text("×\(report.tags[tag] ?? 0)").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .card()
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(report.isMonth ? "Monthly Report" : "Weekly Report")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct BulletLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.font(.system(size: 5)).foregroundStyle(.secondary)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
            configuration.title
        }
    }
}

private struct MetricRow: View {
    let key: String
    let metric: ReportMetric
    let monthly: Bool

    /// More is better, except for these.
    private var goodWhenPositive: Bool { !["rhr", "temp_dev", "stressed_min", "breath"].contains(key) }

    private func text(_ v: Double, signed: Bool = false) -> String {
        let sign = signed ? (v > 0 ? "+" : (v < 0 ? "−" : "")) : ""
        let value = signed ? abs(v) : v
        switch key {
        case "asleep_min", "stressed_min": return sign + Fmt.minutesText(value)
        case "temp_dev":
            let shown = Units.current.temperatureDelta(value)
            return "\(sign.isEmpty && !signed && v < 0 ? "−" : sign)\(Fmt.number(abs(shown), decimals: 2)) \(Units.current.temperatureUnit)"
        case "steps", "active_kcal": return sign + Fmt.number(value) + (metric.unit.isEmpty ? "" : " \(metric.unit)")
        default:
            let decimals = ["breath", "spo2"].contains(key) ? 1 : 0
            return sign + Fmt.number(value, decimals: decimals) + (metric.unit.isEmpty ? "" : " \(metric.unit)")
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(metric.name).font(.subheadline)
                Text("\(metric.n) day\(metric.n == 1 ? "" : "s")").font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(text(metric.avg)).font(.subheadline.weight(.semibold)).monospacedDigit()
                if let delta = metric.delta, let prev = metric.prev {
                    let pct = prev != 0 ? delta / abs(prev) * 100 : 0
                    Text(abs(delta) < 1e-9 ? "No change" : "\(text(delta, signed: true)) vs the \(monthly ? "month" : "week") before")
                        .font(.caption)
                        .foregroundStyle(Theme.tone(delta: pct, goodWhenPositive: goodWhenPositive, threshold: 4))
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
