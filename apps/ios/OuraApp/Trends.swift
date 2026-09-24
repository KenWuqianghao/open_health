import SwiftUI
import Charts

// History: the three scores, sleep, activity, and the vitals over time. One chart
// view (bars for per-day totals and scores, lines for continuous vitals), one card
// around it, a Trends page with a period picker, and a compact 7-day card for the
// Summary. Series come from the shared summary JSON; nothing new is computed here.

struct DatedValue: Identifiable, Equatable {
    let date: Date
    let value: Double
    var id: Date { date }
}

enum TrendStyle { case bars, line }

// ── series ───────────────────────────────────────────────────────────────────
extension Summary {
    private func dated(_ pairs: [(String, Double)]) -> [DatedValue] {
        pairs.compactMap { day, v in
            guard v.isFinite, let d = Fmt.date(day) else { return nil }
            return DatedValue(date: d, value: v)
        }
        .sorted { $0.date < $1.date }
    }

    func scoreSeries(_ kind: ScoreKind) -> [DatedValue] {
        dated((scores?.days ?? [:]).compactMap { day, d in d.score(kind).map { (day, $0.score) } })
    }

    /// Hours in bed per wake date (the longest sleep of each morning).
    var sleepHoursSeries: [DatedValue] {
        dated(nightlySeries(\.in_bed_h).map { ($0.date, $0.value) })
    }

    var stepsSeries: [DatedValue] {
        dated(activity_daily.compactMap { day, st in st.steps.map { (day, $0) } })
    }

    var activeEnergySeries: [DatedValue] {
        dated(activity_daily.compactMap { day, st in st.active_kcal.map { (day, $0) } })
    }

    func vitalSeries(_ kind: VitalKind) -> [DatedValue] {
        dated(kind.series(in: self).map { ($0.date, $0.value) })
    }
}

/// The last `days` days ending today, or everything since `earliest` for `nil`.
func trendWindow(days: Int?, earliest: Date?) -> ClosedRange<Date> {
    let cal = Calendar.current
    let today = cal.startOfDay(for: Date())
    let start: Date
    if let days {
        start = cal.date(byAdding: .day, value: -(days - 1), to: today) ?? today
    } else {
        start = min(earliest.map { cal.startOfDay(for: $0) } ?? today, today)
    }
    // one day past the end, so the last day's bar has room
    let end = cal.date(byAdding: .day, value: 1, to: today) ?? today
    return start...end
}

// ── the chart ────────────────────────────────────────────────────────────────
struct TrendChart: View {
    let points: [DatedValue]
    let tint: Color
    var style: TrendStyle = .bars
    var unit: String = ""
    var decimals = 0
    let domain: ClosedRange<Date>
    var yDomain: ClosedRange<Double>? = nil
    var reference: (value: Double, label: String)? = nil
    var height: CGFloat = 180
    /// Compact: no axes, no selection — for rows on the Summary.
    var compact = false
    @State private var selectedDate: Date?

    private var visible: [DatedValue] { points.filter { domain.contains($0.date) } }

    private var selected: DatedValue? {
        guard let selectedDate else { return nil }
        let cal = Calendar.current
        return visible.first { cal.isDate($0.date, inSameDayAs: selectedDate) }
            ?? visible.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }

    private var autoYDomain: ClosedRange<Double> {
        if let yDomain { return yDomain }
        let values = visible.map(\.value) + (reference.map { [$0.value] } ?? [])
        let lo = values.min() ?? 0, hi = values.max() ?? 1
        if style == .bars { return 0...max(hi * 1.12, 1) }
        // a flat or single-reading series still gets a readable span (at least 10 %
        // of the value, and at least 1 unit), so the gridlines never repeat a number
        let span = max(hi - lo, abs(hi) * 0.1, 1)
        let mid = (hi + lo) / 2
        return (mid - span * 0.75)...(mid + span * 0.75)
    }

    var body: some View {
        let sel = selected
        Chart {
            ForEach(visible) { p in
                switch style {
                case .bars:
                    BarMark(x: .value("Day", p.date, unit: .day), y: .value("Value", p.value), width: .ratio(0.62))
                        .foregroundStyle(tint.gradient)
                        .opacity(sel == nil || sel == p ? 1 : 0.35)
                        .cornerRadius(compact ? 2.5 : 4)
                case .line:
                    LineMark(x: .value("Day", p.date, unit: .day), y: .value("Value", p.value))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(tint)
                        .lineStyle(StrokeStyle(lineWidth: compact ? 1.8 : 2.5, lineCap: .round))
                    PointMark(x: .value("Day", p.date, unit: .day), y: .value("Value", p.value))
                        .foregroundStyle(tint)
                        .symbolSize(visible.count > 45 || compact ? 0 : 26)
                }
            }
            if let reference {
                RuleMark(y: .value(reference.label, reference.value))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .leading) {
                        if !compact { Text(reference.label).font(.caption2).foregroundStyle(.secondary) }
                    }
            }
            if let sel, !compact {
                RuleMark(x: .value("Selected", sel.date, unit: .day))
                    .foregroundStyle(.secondary.opacity(0.35))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sel.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                                .font(.caption2).foregroundStyle(.secondary)
                            Text("\(Fmt.number(sel.value, decimals: decimals))\(unit.isEmpty ? "" : " \(unit)")")
                                .font(.caption.weight(.semibold)).monospacedDigit()
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: autoYDomain)
        .chartXAxis {
            if compact {
                AxisMarks { _ in }
            } else {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
        }
        .chartYAxis {
            if compact {
                AxisMarks { _ in }
            } else {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text(Fmt.number(v, decimals: decimals)) }
                    }
                }
            }
        }
        .chartXSelection(value: $selectedDate)
        .sensoryFeedback(.selection, trigger: sel?.date)
        // compact rows sit inside a tappable card: let the tap reach the card
        .allowsHitTesting(!compact)
        .frame(height: height)
        .animation(Motion.settle, value: domain)
        .accessibilityLabel(compact ? "" : "Trend chart")
    }
}

// ── one metric's card ────────────────────────────────────────────────────────
struct TrendCard: View {
    let title: String
    let icon: String
    let tint: Color
    let points: [DatedValue]
    let domain: ClosedRange<Date>
    var style: TrendStyle = .bars
    var unit = ""
    var decimals = 0
    var yDomain: ClosedRange<Double>? = nil
    var reference: (value: Double, label: String)? = nil
    var chevron = false

    private var visible: [DatedValue] { points.filter { domain.contains($0.date) } }

    var body: some View {
        let values = visible.map(\.value)
        let avg = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(title: title, icon: icon, tint: tint,
                       detail: values.isEmpty ? nil : "\(values.count) day\(values.count == 1 ? "" : "s")",
                       chevron: chevron)
            if let avg {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Average").font(.subheadline).foregroundStyle(.secondary)
                    BigValue(Fmt.number(avg, decimals: decimals), unit, style: .title2)
                }
                TrendChart(points: points, tint: tint, style: style, unit: unit, decimals: decimals,
                           domain: domain, yDomain: yDomain, reference: reference)
                    .reveal(delay: 0.1)
            } else {
                Text("No readings in this period yet.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        }
        .card()
    }
}

// ── the Trends page ──────────────────────────────────────────────────────────
struct TrendsView: View {
    let s: Summary
    @State private var period: VitalPeriod

    init(s: Summary) {
        self.s = s
        // open on a window the data can fill: a week until there are two weeks of history
        let earliest = ScoreKind.allCases.compactMap { s.scoreSeries($0).first?.date }.min()
        let span = earliest.map { Date().timeIntervalSince($0) / 86_400 } ?? 0
        _period = State(initialValue: span < 14 ? .d7 : .d30)
    }

    var body: some View {
        let all: [[DatedValue]] = ScoreKind.allCases.map { s.scoreSeries($0) } + [s.sleepHoursSeries, s.stepsSeries]
        let earliest = all.compactMap { $0.first?.date }.min()
        let domain = trendWindow(days: period.days, earliest: earliest)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Period", selection: $period.animation(Motion.settle)) {
                    ForEach(VitalPeriod.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .sensoryFeedback(.selection, trigger: period)

                SectionTitle("Scores")
                ForEach(ScoreKind.allCases) { kind in
                    TrendCard(title: kind.title, icon: kind.icon, tint: kind.tint,
                              points: s.scoreSeries(kind), domain: domain, yDomain: 0...100)
                }

                SectionTitle("Sleep")
                TrendCard(title: "Time in Bed", icon: "bed.double.fill", tint: Theme.sleep,
                          points: s.sleepHoursSeries, domain: domain, unit: "hr", decimals: 1,
                          reference: s.sleepDebt.map { ($0.need_h, "Your need") })

                SectionTitle("Activity")
                TrendCard(title: "Steps", icon: "figure.walk", tint: Theme.activity,
                          points: s.stepsSeries, domain: domain)
                TrendCard(title: "Active Energy", icon: "flame.fill", tint: Theme.activity,
                          points: s.activeEnergySeries, domain: domain, unit: "kcal")

                SectionTitle("Vitals")
                ForEach(VitalKind.allCases) { kind in
                    NavigationLink(value: Route.vital(kind)) {
                        TrendCard(title: kind.title, icon: kind.icon, tint: kind.tint,
                                  points: s.vitalSeries(kind), domain: domain, style: .line,
                                  unit: kind.unit, decimals: kind.decimals,
                                  reference: kind.baseline(in: s).map { ($0, "Baseline") }, chevron: true)
                    }
                    .buttonStyle(.pressable)
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Trends")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// ── the Summary card ─────────────────────────────────────────────────────────
/// The past week at a glance: one small bar row per score with its average.
struct TrendsCard: View {
    let s: Summary
    var body: some View {
        let domain = trendWindow(days: 7, earliest: nil)
        NavigationLink(value: Route.trends) {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(title: "Past 7 Days", icon: "chart.xyaxis.line", tint: .accentColor,
                           detail: "All trends", chevron: true)
                ForEach(ScoreKind.allCases) { kind in
                    let week = s.scoreSeries(kind).filter { domain.contains($0.date) }
                    HStack(spacing: 12) {
                        Label(kind.title, systemImage: kind.icon)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(kind.tint)
                            .labelStyle(.titleAndIcon)
                            .lineLimit(1)
                            .frame(width: 118, alignment: .leading)
                        TrendChart(points: week, tint: kind.tint, domain: domain, yDomain: 0...100,
                                   height: 30, compact: true)
                        Text(week.isEmpty ? "—" : "\(Int((week.map(\.value).reduce(0, +) / Double(week.count)).rounded()))")
                            .font(Theme.number(.headline)).monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(week.isEmpty ? "\(kind.title), no scores this week"
                                        : "\(kind.title), average \(Int((week.map(\.value).reduce(0, +) / Double(week.count)).rounded())) over \(week.count) days")
                }
                Text("Averages over the days with a score.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .card()
            .zoomSource(Route.trends)
        }
        .buttonStyle(.pressable)
    }
}
