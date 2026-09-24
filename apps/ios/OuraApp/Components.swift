import SwiftUI
import Charts

// Activity type → a clean SF Symbol. Keyword-matched so the ~40 AAD behaviour labels all
// resolve to a sensible figure.* glyph; unknowns fall back to a neutral cardio symbol.
func activitySymbol(_ label: String) -> String {
    let l = label.lowercased()
    switch true {
    case l.contains("run"): return "figure.run"
    case l.contains("walk"): return "figure.walk"
    case l.contains("hik"): return "figure.hiking"
    case l.contains("cycl"), l.contains("bik"): return "figure.outdoor.cycle"
    case l.contains("swim"): return "figure.pool.swim"
    case l.contains("row"): return "figure.rower"
    case l.contains("core"): return "figure.core.training"
    case l.contains("strength"): return "figure.strengthtraining.traditional"
    case l.contains("cross train"): return "figure.cross.training"
    case l.contains("yoga"): return "figure.yoga"
    case l.contains("pilates"): return "figure.pilates"
    case l.contains("hiit"), l.contains("interval"): return "figure.highintensity.intervaltraining"
    case l.contains("elliptical"): return "figure.elliptical"
    case l.contains("box"): return "figure.boxing"
    case l.contains("martial"): return "figure.martial.arts"
    case l.contains("danc"): return "figure.dance"
    case l.contains("basketball"): return "figure.basketball"
    case l.contains("soccer"): return "figure.soccer"
    case l.contains("football"): return "figure.american.football"
    case l.contains("baseball"): return "figure.baseball"
    case l.contains("volleyball"): return "figure.volleyball"
    case l.contains("tennis"), l.contains("padel"), l.contains("badminton"): return "figure.tennis"
    case l.contains("hockey"): return "figure.hockey"
    case l.contains("surf"): return "figure.surfing"
    case l.contains("snowboard"): return "figure.snowboarding"
    case l.contains("ski"): return "figure.skiing.crosscountry"
    case l.contains("horse"): return "figure.equestrian.sports"
    case l.contains("stretch"): return "figure.flexibility"
    case l.contains("climb"): return "figure.climbing"
    case l.contains("golf"): return "figure.golf"
    case l.contains("meditat"): return "figure.mind.and.body"
    case l.contains("fitness"): return "figure.strengthtraining.functional"
    default: return "figure.mixed.cardio"
    }
}

// Capitalise an activity label's first letter for display.
func actLabel(_ s: String) -> String { s.isEmpty ? s : s.prefix(1).uppercased() + s.dropFirst() }

// ── card primitives ──────────────────────────────────────────────────────────

/// A Health-style content card: secondary grouped background, continuous corners.
struct Card: ViewModifier {
    var padding: CGFloat = Theme.cardPadding
    var fillHeight = false
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .scrollIn()
    }
}

extension View {
    func card(padding: CGFloat = Theme.cardPadding, fillHeight: Bool = false) -> some View {
        modifier(Card(padding: padding, fillHeight: fillHeight))
    }
}

/// The colored category label at the top of a card, with an optional trailing detail
/// and a chevron when the card opens something.
struct CardHeader: View {
    let title: String
    let icon: String
    let tint: Color
    var detail: String? = nil
    var chevron = false
    var body: some View {
        HStack(spacing: 6) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            if let detail {
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// A section title between cards ("Vitals", "Past 14 days").
struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.title2.bold())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The big number with its unit: "7 hr 41 min", "58 ms".
struct BigValue: View {
    let parts: [(String, String)]
    var style: Font.TextStyle = .title
    var color: Color = .primary
    init(_ value: String, _ unit: String, style: Font.TextStyle = .title, color: Color = .primary) {
        parts = [(value, unit)]; self.style = style; self.color = color
    }
    init(parts: [(String, String)], style: Font.TextStyle = .title, color: Color = .primary) {
        self.parts = parts; self.style = style; self.color = color
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            ForEach(parts.indices, id: \.self) { i in
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(parts[i].0).font(Theme.number(style)).monospacedDigit().foregroundStyle(color)
                        .contentTransition(.numericText())
                    if !parts[i].1.isEmpty {
                        Text(parts[i].1).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .animation(Motion.snappy, value: parts.map { $0.0 })
        .accessibilityElement(children: .combine)
        .accessibilityLabel(parts.map { "\($0.0) \($0.1)" }.joined(separator: " "))
    }
}

/// A label / value row inside a card.
struct StatRow: View {
    let label: String
    let value: String
    var color: Color = .primary
    var body: some View {
        LabeledContent(label) {
            Text(value).foregroundStyle(color).monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

/// A small numeric readout with a caption below it (the report grid atom).
struct Readout: View {
    let value: String
    let caption: String
    var color: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Theme.number(.title3)).monospacedDigit().foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The one prominent call to action on a screen. Liquid Glass on iOS 26, the
/// bordered prominent style before that.
struct PrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var busy = false
    let action: () -> Void
    var body: some View {
        Group {
            if #available(iOS 26, *) {
                button.buttonStyle(.glassProminent)
            } else {
                button.buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.large)
        .disabled(busy)
    }
    private var button: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy { ProgressView().tint(.white) }
                else if let systemImage { Image(systemName: systemImage) }
                Text(title).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

struct SecondaryButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void
    var body: some View {
        Group {
            if #available(iOS 26, *) {
                button.buttonStyle(.glass)
            } else {
                button.buttonStyle(.bordered)
            }
        }
        .controlSize(.large)
    }
    private var button: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).fontWeight(.medium)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// A labelled activity/workout row: SF Symbol in a tinted circle, name, duration, start.
struct SessionRow: View {
    let label: String
    let durationMin: Int
    let startHM: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: activitySymbol(label))
                .font(.body.weight(.medium))
                .foregroundStyle(Theme.activity)
                .frame(width: 36, height: 36)
                .background(Theme.activity.opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(actLabel(label)).font(.body.weight(.medium))
                Text(startHM).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(durationMin) min").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

// ── charts ───────────────────────────────────────────────────────────────────
struct IndexedValue: Identifiable {
    let index: Int
    let value: Double
    var id: Int { index }
}

/// A small trend line for a vitals card. No axes; the latest point is marked.
struct Sparkline: View {
    let series: [Double]
    var accent: Color = .secondary
    var baseline: Double? = nil

    var body: some View {
        let points = series.enumerated().filter { $0.element.isFinite }
            .map { IndexedValue(index: $0.offset, value: $0.element) }
        let lo = points.map(\.value).min() ?? 0
        let hi = points.map(\.value).max() ?? 1
        let pad = max(hi - lo, 1e-6) * 0.15
        Chart {
            ForEach(points) { p in
                AreaMark(x: .value("Night", p.index),
                         yStart: .value("Floor", lo - pad), yEnd: .value("Value", p.value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [accent.opacity(0.25), accent.opacity(0)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Night", p.index), y: .value("Value", p.value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(accent)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            if let last = points.last {
                PointMark(x: .value("Night", last.index), y: .value("Value", last.value))
                    .foregroundStyle(accent)
                    .symbolSize(40)
            }
            if let baseline, baseline.isFinite, baseline >= lo - pad, baseline <= hi + pad {
                RuleMark(y: .value("Baseline", baseline))
                    .foregroundStyle(.tertiary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: (lo - pad)...(hi + pad))
        .chartLegend(.hidden)
        .frame(height: 40)
        .clipped()
        .reveal(delay: 0.25)
        .accessibilityHidden(true)
    }
}

// A vitals card: category label, big value, change vs baseline, sparkline.
struct VitalCell: View {
    let kind: VitalKind
    let value: String
    var delta: Double? = nil
    var series: [Double] = []
    var baseline: Double? = nil
    var detail: String? = nil

    var body: some View {
        let tone = Theme.tone(delta: delta, goodWhenPositive: kind.goodWhenPositive)
        NavigationLink(value: Route.vital(kind)) {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(title: kind.shortTitle, icon: kind.icon, tint: kind.tint, chevron: hasValue)
                if hasValue {
                    BigValue(value, kind.unit, style: .title2)
                    Group {
                        if let d = delta {
                            Text("\(d >= 0 ? "+" : "")\(Int(d.rounded()))% vs baseline")
                                .foregroundStyle(tone)
                        } else if let detail {
                            Text(detail).foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                    .lineLimit(1)
                } else {
                    Text("No Data").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                    Text(kind.emptyHint).font(.caption).foregroundStyle(.secondary)
                }
                if series.count > 1 {
                    Spacer(minLength: 2)
                    Sparkline(series: series, accent: kind.tint, baseline: baseline)
                }
            }
            .card(fillHeight: true)
            .zoomSource(Route.vital(kind))
        }
        .buttonStyle(.pressable)
        .disabled(!hasValue)
        .accessibilityLabel(hasValue ? "\(kind.title) \(value) \(kind.unit)" : "\(kind.title), no data")
        .accessibilityHint("Shows the trend over time")
        .accessibilityIdentifier("vital-\(kind.rawValue)")
    }
    private var hasValue: Bool { value != "—" && !value.isEmpty }
}

enum VitalPeriod: String, CaseIterable, Identifiable {
    case d7 = "7D", d14 = "14D", d30 = "30D", d90 = "90D", all = "All"
    var id: String { rawValue }
    var days: Int? {
        switch self {
        case .d7: return 7
        case .d14: return 14
        case .d30: return 30
        case .d90: return 90
        case .all: return nil
        }
    }
}

private enum YMD {
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static func date(_ s: String) -> Date? { fmt.date(from: s) }
    static func string(_ d: Date) -> String { fmt.string(from: d) }
}

/// The full trend page for one vital: period picker, latest value, an interactive
/// Swift Chart, and the period statistics.
struct VitalTrendView: View {
    let s: Summary
    let kind: VitalKind
    @State private var period: VitalPeriod = .d30

    private var all: [DatedVital] { kind.series(in: s) }

    /// Inclusive window ending on the latest sample, not wall-clock today — so a
    /// ring that last synced weeks ago still has a 7d/30d chart to look at.
    private var window: (start: String, end: String)? {
        guard let end = all.last?.date else { return nil }
        guard let days = period.days,
              let endDate = YMD.date(end),
              let startDate = YMD.utc.date(byAdding: .day, value: -(days - 1), to: endDate)
        else {
            return all.first.map { ($0.date, end) }
        }
        return (YMD.string(startDate), end)
    }

    private var points: [DatedVital] {
        guard let window else { return [] }
        return all.filter { $0.date >= window.start && $0.date <= window.end }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Period", selection: $period) {
                    ForEach(VitalPeriod.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 12) {
                    CardHeader(title: kind.title, icon: kind.icon, tint: kind.tint,
                               detail: points.last.map { Fmt.monthDay($0.date) })
                    if let last = points.last {
                        BigValue(format(last.value), kind.unit, style: .largeTitle)
                        if let d = deltaPct {
                            Text("\(d >= 0 ? "+" : "")\(Int(d.rounded()))% vs baseline")
                                .font(.subheadline).foregroundStyle(accent)
                        }
                    }
                    if points.count > 1, let window {
                        VitalTrendChart(points: points, start: window.start, end: window.end,
                                        baseline: kind.baseline(in: s), accent: kind.tint,
                                        decimals: kind.decimals, unit: kind.unit)
                            .padding(.top, 4)
                            .reveal(delay: 0.15)
                            .animation(Motion.settle, value: period)
                    } else if all.isEmpty {
                        Text("No readings yet.").font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Text("Not enough nights in this period yet.").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .card()

                if points.count > 1 {
                    let values = points.map(\.value)
                    let avg = values.reduce(0, +) / Double(values.count)
                    VStack(spacing: 10) {
                        StatRow(label: "Average", value: "\(format(avg)) \(kind.unit)")
                        Divider()
                        StatRow(label: "Lowest", value: "\(format(values.min() ?? 0)) \(kind.unit)")
                        Divider()
                        StatRow(label: "Highest", value: "\(format(values.max() ?? 0)) \(kind.unit)")
                        Divider()
                        StatRow(label: "Nights", value: "\(points.count)")
                    }
                    .card()
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("About").font(.headline)
                    Text(kind.caption).font(.subheadline).foregroundStyle(.secondary)
                }
                .card()
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var deltaPct: Double? {
        guard let last = points.last, let base = kind.baseline(in: s), base > 0 else { return nil }
        return (last.value - base) / base * 100
    }

    private var accent: Color {
        Theme.tone(delta: deltaPct, goodWhenPositive: kind.goodWhenPositive)
    }

    private func format(_ v: Double) -> String { Fmt.number(v, decimals: kind.decimals) }
}

private struct VitalTrendChart: View {
    let points: [DatedVital]
    let start: String
    let end: String
    let baseline: Double?
    let accent: Color
    let decimals: Int
    let unit: String
    @State private var selectedDate: Date?

    private struct Sample: Identifiable {
        let date: Date
        let value: Double
        var id: Date { date }
    }

    private var samples: [Sample] {
        points.compactMap { p in YMD.date(p.date).map { Sample(date: $0, value: p.value) } }
    }

    private var selected: Sample? {
        guard let selectedDate, !samples.isEmpty else { return nil }
        return samples.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }

    var body: some View {
        let values = points.map(\.value)
        let lo = values.min() ?? 0
        let hi = values.max() ?? 1
        let pad = max(hi - lo, 1e-6) * 0.15
        let domainStart = YMD.date(start) ?? Date()
        let domainEnd = YMD.date(end) ?? Date()
        Chart {
            ForEach(samples) { p in
                AreaMark(x: .value("Date", p.date),
                         yStart: .value("Floor", lo - pad), yEnd: .value("Value", p.value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [accent.opacity(0.22), accent.opacity(0)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Date", p.date), y: .value("Value", p.value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(accent)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                PointMark(x: .value("Date", p.date), y: .value("Value", p.value))
                    .foregroundStyle(accent)
                    .symbolSize(samples.count > 40 ? 0 : 28)
            }
            if let baseline, baseline.isFinite {
                RuleMark(y: .value("Baseline", baseline))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("Baseline").font(.caption2).foregroundStyle(.secondary)
                    }
            }
            if let sel = selected {
                RuleMark(x: .value("Selected", sel.date))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sel.date, format: .dateTime.month(.abbreviated).day())
                                .font(.caption2).foregroundStyle(.secondary)
                            Text("\(Fmt.number(sel.value, decimals: decimals)) \(unit)")
                                .font(.caption.weight(.semibold)).monospacedDigit()
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                PointMark(x: .value("Selected", sel.date), y: .value("Value", sel.value))
                    .foregroundStyle(accent)
                    .symbolSize(90)
            }
        }
        .chartXScale(domain: domainStart...domainEnd)
        .chartYScale(domain: (lo - pad)...(hi + pad))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .chartYAxis {
            // A narrow span (skin temperature moves a few tenths) needs one more
            // decimal, or three ticks print the same number.
            let axisDecimals = (hi - lo) < 1 ? decimals + 1 : decimals
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(Fmt.number(v, decimals: axisDecimals)) }
                }
            }
        }
        .chartXSelection(value: $selectedDate)
        .frame(height: 220)
        .accessibilityLabel("Trend from \(Fmt.monthDay(start)) to \(Fmt.monthDay(end))")
    }
}

// Sleep-stage strip: one colored block per stage run, like the Health app's night bar.
struct Hypnogram: View {
    let stages: [Int]
    var height: CGFloat = 40
    var body: some View {
        Canvas { ctx, size in
            guard !stages.isEmpty else { return }
            let w = size.width / CGFloat(stages.count)
            for (i, s) in stages.enumerated() {
                let frac: CGFloat = switch s { case 1: 1; case 2: 0.72; case 3: 0.48; default: 0.28 }
                let h = size.height * frac
                let r = CGRect(x: CGFloat(i) * w, y: size.height - h, width: w + 0.4, height: h)
                ctx.fill(Path(r), with: .color(Theme.stage(s)))
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .reveal(delay: 0.2)
    }
}

// Continuous movement ridge from the 96 × 15-min MET-above-rest buckets — the web
// actogram's ridge, model-free (computed from raw MET). One day's profile.
struct MovementRidge: View {
    let profile: [Double]
    var height: CGFloat = 44
    var body: some View {
        let points = profile.enumerated().map { IndexedValue(index: $0.offset, value: max(0, $0.element)) }
        Chart(points) { p in
            AreaMark(x: .value("Time", p.index), y: .value("MET", p.value))
                .interpolationMethod(.monotone)
                .foregroundStyle(LinearGradient(colors: [Theme.activity.opacity(0.35), Theme.activity.opacity(0.02)],
                                                startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("Time", p.index), y: .value("MET", p.value))
                .interpolationMethod(.monotone)
                .foregroundStyle(Theme.activity)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(height: height)
        .reveal(delay: 0.2)
        .accessibilityHidden(true)
    }
}

// ── scores ───────────────────────────────────────────────────────────────────
/// A 0–100 score as a ring: the Apple Fitness gauge, one accent per score.
struct ScoreRing: View {
    let score: Double?
    let tint: Color
    var size: CGFloat = 84
    var lineWidth: CGFloat = 9
    /// Seconds to wait before filling, so a row of rings fills one after another.
    var delay: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Double = 0

    var body: some View {
        let fraction = CGFloat(min(1, max(0, shown / 100)))
        ZStack {
            Circle()
                .stroke(tint.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    AngularGradient(colors: [tint.opacity(0.55), tint],
                                    center: .center,
                                    startAngle: .degrees(0),
                                    endAngle: .degrees(360 * Double(max(fraction, 0.01)))),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: tint.opacity(score == nil ? 0 : 0.35), radius: lineWidth * 0.6)
            Group {
                if score != nil {
                    EmptyView().modifier(CountingNumber(value: shown))
                } else {
                    Text("—")
                }
            }
            .font(Theme.number(size >= 120 ? .largeTitle : .title2))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(lineWidth * 1.4)
            .foregroundStyle(score == nil ? Color.secondary : Color.primary)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .onAppear { fill(to: score, delay: delay) }
        .onChange(of: score) { _, value in fill(to: value, delay: 0) }
    }

    private func fill(to value: Double?, delay: Double) {
        let target = value ?? 0
        if reduceMotion {
            shown = target
        } else {
            withAnimation(Motion.fill.delay(delay)) { shown = target }
        }
    }
}

/// The three daily scores side by side. Each ring opens its breakdown.
struct ScoresCard: View {
    let s: Summary
    let day: String
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title2) private var ringSize: CGFloat = 84
    var body: some View {
        let found = ScoreKind.allCases.map { ($0, s.latestScore($0, upTo: day)) }
        // Three rings side by side; at accessibility text sizes, one row per score
        // with the ring on the leading side, so nothing truncates.
        let big = typeSize.isAccessibilitySize
        let rows = big ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14)) : AnyLayout(HStackLayout(spacing: 0))
        let item = big ? AnyLayout(HStackLayout(spacing: 16)) : AnyLayout(VStackLayout(spacing: 8))
        VStack(alignment: .leading, spacing: 14) {
            rows {
                ForEach(found, id: \.0) { kind, hit in
                    NavigationLink(value: Route.score(kind, hit?.day ?? day)) {
                        item {
                            ScoreRing(score: hit?.score.score, tint: kind.tint, size: min(ringSize, 120),
                                      delay: 0.2 + Double(ScoreKind.allCases.firstIndex(of: kind) ?? 0) * 0.12)
                                // the transition source clips to its bounds; pad it so
                                // the ring's glow is inside, then give the space back
                                .padding(14)
                                .zoomSource(Route.score(kind, hit?.day ?? day))
                                .padding(-14)
                            VStack(alignment: big ? .leading : .center, spacing: 4) {
                                HStack(spacing: 4) {
                                    Text(kind.title).font(.subheadline.weight(.semibold))
                                        .lineLimit(1).minimumScaleFactor(0.7)
                                    if hit?.score.provisional == true {
                                        Image(systemName: "circle.dotted")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .accessibilityLabel("provisional")
                                    }
                                }
                                if let hit {
                                    let band = Theme.scoreBand(hit.score.score)
                                    Text(hit.day == day ? band.label : Fmt.dayLabel(hit.day))
                                        .font(.caption)
                                        .foregroundStyle(hit.day == day ? band.color : .secondary)
                                } else {
                                    Text(kind == .activity ? "Tracking today" : "After a night")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: big ? .leading : .center)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                    .disabled(hit == nil)
                    .accessibilityLabel("\(kind.title) score \(hit.map { "\(Int($0.score.score.rounded()))" } ?? "not available")")
                    .accessibilityHint("Shows the breakdown")
                }
            }
            if found.allSatisfy({ $0.1 == nil }) {
                Text("Your scores start after the first night with your ring on.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if found.contains(where: { $0.1?.score.provisional == true }) {
                Label("Scores marked with a dotted ring are early estimates. They settle after about two weeks of nights.",
                      systemImage: "circle.dotted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .card()
    }
}

/// One score opened up: the ring, the band, then one bar per contributor with the
/// input behind it and the weight it carried. A score you cannot interrogate is a
/// horoscope, so the source of every curve is one tap away.
struct ScoreDetailView: View {
    let kind: ScoreKind
    let day: String
    let score: DailyScore?
    var history: [DatedValue] = []
    @State private var showSources = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 12) {
                    ScoreRing(score: score?.score, tint: kind.tint, size: 150, lineWidth: 14, delay: 0.25)
                        .padding(.top, 8)
                    if let score {
                        let band = Theme.scoreBand(score.score)
                        Text(band.label)
                            .font(.headline)
                            .foregroundStyle(band.color)
                        if score.provisional {
                            Label("Early estimate", systemImage: "circle.dotted")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("No \(kind.title.lowercased()) score for this day.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .card()

                TrendCard(title: "Past 30 Days", icon: "chart.bar.fill", tint: kind.tint,
                          points: history, domain: trendWindow(days: 30, earliest: nil), yDomain: 0...100)

                if let score {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            CardHeader(title: "Contributors", icon: kind.icon, tint: kind.tint)
                            Toggle("Sources", isOn: $showSources.animation(Motion.snappy))
                                .toggleStyle(.button)
                                .controlSize(.small)
                                .font(.caption)
                        }
                        ForEach(Array(score.contributors.enumerated()), id: \.element.id) { i, c in
                            ContributorRow(c: c, tint: kind.tint, showSource: showSources, index: i)
                        }
                    }
                    .card()
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("About").font(.headline)
                    Text(kind.blurb).font(.subheadline).foregroundStyle(.secondary)
                    Text("Estimates computed on this iPhone from ring data. They follow Oura's contributor sets and weights, not its exact curves, so expect them to track Oura's numbers rather than match them.")
                        .font(.caption).foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
                .card()
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("\(kind.title) · \(Fmt.dayLabel(day))")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ContributorRow: View {
    let c: ScoreContributor
    let tint: Color
    let showSource: Bool
    var index = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var grown = false
    private var valueText: String? {
        guard let v = c.value else { return nil }
        let number = v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v)
        return c.unit.isEmpty ? number : "\(number) \(c.unit)"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 4) {
                    Text(c.name).font(.subheadline.weight(.medium))
                    if c.provisional {
                        Image(systemName: "circle.dotted").font(.caption2).foregroundStyle(.secondary)
                            .accessibilityLabel("provisional")
                    }
                }
                Spacer()
                if let valueText {
                    Text(valueText).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
                Text("\(Int(c.score.rounded()))")
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                    .frame(width: 34, alignment: .trailing)
            }
            // bar length is the sub-score; opacity is how much it counted
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.tertiarySystemFill)).frame(height: 6)
                    Capsule().fill(tint.opacity(0.45 + 0.55 * min(1, c.weight * 3)))
                        .frame(width: geo.size.width * CGFloat(grown ? c.score / 100 : 0), height: 6)
                }
            }
            .frame(height: 6)
            .onAppear {
                guard !grown else { return }
                if reduceMotion { grown = true } else {
                    withAnimation(Motion.fill.delay(0.35 + Motion.stagger(index, step: 0.07))) { grown = true }
                }
            }
            HStack {
                Text("\(Int((c.weight * 100).rounded()))% of the score").font(.caption2).foregroundStyle(.tertiary)
                if showSource {
                    Text("· \(c.source)").font(.caption2).foregroundStyle(.tertiary)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(c.name) \(Int(c.score.rounded())) out of 100\(valueText.map { ", \($0)" } ?? ""), \(Int((c.weight * 100).rounded())) percent of the score")
    }
}


// ── adaptive layout ──────────────────────────────────────────────────────────
/// Side by side when it fits the width, stacked when the text is too large.
struct FitStack<Content: View>: View {
    var alignment: VerticalAlignment = .top
    var spacing: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: alignment, spacing: spacing) { content }
            VStack(alignment: .leading, spacing: spacing * 0.6) { content }
        }
    }
}

// ── loading placeholders ─────────────────────────────────────────────────────
/// The Summary's shape in grey while the first summary loads, with a slow shimmer,
/// so the first launch reads as "arriving" instead of "stuck".
struct SummarySkeleton: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                card(lines: [0.35, 0.8])
                bar(width: 110, height: 22).padding(.top, 8)
                HStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { _ in
                        VStack(spacing: 10) {
                            Circle().stroke(Color(.tertiarySystemFill), lineWidth: 9).frame(width: 84, height: 84)
                            bar(width: 64, height: 10)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .card()
                card(lines: [0.25, 0.5, 1.0])
                card(lines: [0.3, 0.6, 1.0])
                HStack(spacing: 12) {
                    card(lines: [0.5, 0.4])
                    card(lines: [0.5, 0.4])
                }
            }
            .padding(.horizontal, Theme.gutter)
            .shimmer()
        }
        .scrollDisabled(true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reading your ring")
    }

    private func bar(width: CGFloat? = nil, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(Color(.tertiarySystemFill))
            .frame(width: width, height: height)
    }

    private func card(lines: [CGFloat]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(lines.indices, id: \.self) { i in
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(.tertiarySystemFill))
                        .frame(width: geo.size.width * lines[i])
                }
                .frame(height: i == 0 ? 14 : 22)
            }
        }
        .card()
    }
}
