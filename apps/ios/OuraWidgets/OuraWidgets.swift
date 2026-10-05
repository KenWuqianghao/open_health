import SwiftUI
import WidgetKit

// The widgets. They draw the snapshot that the app wrote to the App Group after its
// last summary (`Snapshot.swift`, part of both targets). A widget never talks to the
// ring: iOS gives a widget no Bluetooth and a small time budget.

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: Snapshot?
    /// True in the widget gallery: sample numbers, no private data.
    var sample = false
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .placeholder, sample: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let stored = SnapshotStore.load()
        completion(SnapshotEntry(date: Date(), snapshot: context.isPreview ? (stored ?? .placeholder) : stored,
                                 sample: context.isPreview && stored == nil))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        // The app asks for a reload after each summary. This refresh is the backstop,
        // and it moves "Today" to "Yesterday" after midnight.
        let entry = SnapshotEntry(date: Date(), snapshot: SnapshotStore.load())
        let midnight = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86_400 + 60)
        let next = min(Date().addingTimeInterval(2 * 3600), midnight)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// ── the look ─────────────────────────────────────────────────────────────────
// One dark tile in every appearance, like the app icon: the scores are the only
// colour. Layout is a strict grid, so every edge lines up with another edge:
// a Readiness dial as the hero, Sleep and Activity as rows that share one value
// column and one bar width.

enum WidgetPalette {
    static let background = LinearGradient(
        colors: [Color(red: 0.118, green: 0.125, blue: 0.204), Color(red: 0.035, green: 0.039, blue: 0.063)],
        startPoint: .top, endPoint: .bottom)
    static let text = Color.white
    static let secondary = Color.white.opacity(0.58)
    static let track = Color.white.opacity(0.12)
}

enum WidgetScore: CaseIterable {
    case readiness, sleep, activity
    var title: String {
        switch self {
        case .readiness: return "Readiness"
        case .sleep: return "Sleep"
        case .activity: return "Activity"
        }
    }
    var icon: String {
        switch self {
        case .readiness: return "bolt.heart.fill"
        case .sleep: return "moon.fill"
        case .activity: return "flame.fill"
        }
    }
    /// The app icon's ring colours, bright enough for the dark tile.
    var tint: Color {
        switch self {
        case .readiness: return Color(red: 0.25, green: 0.84, blue: 0.87)
        case .sleep: return Color(red: 0.51, green: 0.50, blue: 1.0)
        case .activity: return Color(red: 1.0, green: 0.62, blue: 0.04)
        }
    }
    func value(in s: Snapshot) -> Int? {
        switch self {
        case .readiness: return s.readiness
        case .sleep: return s.sleep
        case .activity: return s.activity
        }
    }
    /// The plain number behind the score: time in bed, steps.
    func detail(in s: Snapshot) -> String? {
        switch self {
        case .readiness: return nil
        case .sleep:
            guard let h = s.inBedHours, h > 0 else { return nil }
            let minutes = Int((h * 60).rounded())
            return "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
        case .activity:
            return s.steps.map { "\($0.formatted(.number)) steps" }
        }
    }
}

/// The hero: a thick dial with the score and its name inside.
struct ScoreDial: View {
    let kind: WidgetScore
    let score: Int?
    var lineWidth: CGFloat = 10
    var numberSize: CGFloat = 34

    var body: some View {
        let fraction = CGFloat(min(max(Double(score ?? 0) / 100, 0), 1))
        ZStack {
            Circle().stroke(WidgetPalette.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    AngularGradient(colors: [kind.tint.opacity(0.6), kind.tint], center: .center,
                                    startAngle: .degrees(0), endAngle: .degrees(360 * Double(max(fraction, 0.01)))),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .widgetAccentable()
            VStack(spacing: 0) {
                Text(score.map(String.init) ?? "–")
                    .font(.system(size: numberSize, weight: score == nil ? .regular : .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(score == nil ? WidgetPalette.secondary : WidgetPalette.text)
                Text(kind.title.uppercased())
                    .font(.system(size: numberSize * 0.25, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(WidgetPalette.secondary)
            }
            .minimumScaleFactor(0.7)
            .lineLimit(1)
            .padding(lineWidth * 1.6)
        }
        .padding(lineWidth / 2)
    }
}

/// One supporting score: name and detail on the left, the value in a fixed column
/// on the right, a bar under both. Rows stack with identical edges.
struct ScoreRow: View {
    let kind: WidgetScore
    let snapshot: Snapshot

    var body: some View {
        let value = kind.value(in: snapshot)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: kind.icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(kind.tint)
                    .frame(width: 13)
                    .widgetAccentable()
                Text(kind.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(WidgetPalette.text)
                if let detail = kind.detail(in: snapshot) {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(WidgetPalette.secondary)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 2)
                Text(value.map(String.init) ?? "–")
                    .font(.system(size: 17, weight: value == nil ? .regular : .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(value == nil ? WidgetPalette.secondary : WidgetPalette.text)
            }
            .lineLimit(1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(WidgetPalette.track)
                    Capsule().fill(kind.tint)
                        .frame(width: max(geo.size.height, geo.size.width * CGFloat(min(max(Double(value ?? 0) / 100, 0), 1))))
                        .opacity(value == nil ? 0 : 1)
                        .widgetAccentable()
                }
            }
            .frame(height: 5)
        }
    }
}

/// Day on the left, ring battery on the right: the caption line of the tile.
struct WidgetCaption: View {
    let snapshot: Snapshot
    var body: some View {
        HStack(spacing: 4) {
            Text(snapshot.dayText.uppercased())
                .tracking(0.6)
            Spacer(minLength: 4)
            if let pct = snapshot.batteryPct {
                Image(systemName: pct <= 20 ? "battery.25percent" : (pct <= 60 ? "battery.50percent" : "battery.100percent"))
                Text("\(pct)%").monospacedDigit()
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(WidgetPalette.secondary)
        .lineLimit(1)
    }
}

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "circle.dashed")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(WidgetScore.readiness.tint)
                .widgetAccentable()
            Text("Open the app to sync")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(WidgetPalette.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// ── the scores, small and medium ─────────────────────────────────────────────

/// Small: the Readiness dial, with Sleep and Activity as two numbers under it.
struct ScoresSmallView: View {
    let snapshot: Snapshot
    var body: some View {
        VStack(spacing: 8) {
            ScoreDial(kind: .readiness, score: snapshot.readiness, lineWidth: 9, numberSize: 32)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxHeight: .infinity)
            HStack(spacing: 0) {
                ForEach([WidgetScore.sleep, .activity], id: \.title) { kind in
                    HStack(spacing: 4) {
                        Image(systemName: kind.icon)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(kind.tint)
                            .widgetAccentable()
                        Text(kind.value(in: snapshot).map(String.init) ?? "–")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(kind.value(in: snapshot) == nil ? WidgetPalette.secondary : WidgetPalette.text)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Medium: the dial fills the tile's height on the left; the right column is
/// caption, Sleep, Activity, spread evenly over the same height.
struct ScoresMediumView: View {
    let snapshot: Snapshot
    var body: some View {
        HStack(spacing: 18) {
            ScoreDial(kind: .readiness, score: snapshot.readiness, lineWidth: 11, numberSize: 38)
                .aspectRatio(1, contentMode: .fit)
            VStack(alignment: .leading, spacing: 0) {
                WidgetCaption(snapshot: snapshot)
                Spacer(minLength: 6)
                ScoreRow(kind: .sleep, snapshot: snapshot)
                Spacer(minLength: 6)
                ScoreRow(kind: .activity, snapshot: snapshot)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ScoresWidgetView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let s = entry.snapshot, s.readiness != nil || s.sleep != nil || s.activity != nil {
                if family == .systemSmall { ScoresSmallView(snapshot: s) } else { ScoresMediumView(snapshot: s) }
            } else {
                EmptyState()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.snapshot.map(label) ?? "Open the app to sync")
        .containerBackground(for: .widget) { WidgetPalette.background }
    }

    private func label(_ s: Snapshot) -> String {
        let scores = WidgetScore.allCases.compactMap { kind in
            kind.value(in: s).map { "\(kind.title) \($0)" }
        }.joined(separator: ", ")
        return scores.isEmpty ? "Open the app to sync" : scores + (s.dayText.isEmpty ? "" : ", \(s.dayText)")
    }
}

struct ScoresWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "scores", provider: SnapshotProvider()) { entry in
            ScoresWidgetView(entry: entry)
        }
        .configurationDisplayName("Scores")
        .description("Your readiness, sleep and activity scores.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// ── readiness on the Lock Screen ─────────────────────────────────────────────

struct ReadinessAccessoryView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular: circular
            case .accessoryInline: inline
            default: rectangular
            }
        }
        .containerBackground(.clear, for: .widget)
    }

    private var score: Int? { entry.snapshot?.readiness }

    private var circular: some View {
        Gauge(value: Double(score ?? 0), in: 0...100) {
            Image(systemName: "bolt.heart.fill")
        } currentValueLabel: {
            Text(score.map(String.init) ?? "—")
        }
        .gaugeStyle(.accessoryCircular)
        .accessibilityLabel(score.map { "Readiness \($0)" } ?? "Readiness, no data")
    }

    private var inline: some View {
        Label(score.map { "Readiness \($0)" } ?? "Open Oura", systemImage: "bolt.heart.fill")
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Readiness", systemImage: "bolt.heart.fill")
                .font(.caption.weight(.semibold))
                .widgetAccentable()
            if let s = entry.snapshot, let score = s.readiness {
                Text("\(score) · \(Snapshot.band(score).capitalized)")
                    .font(.system(.headline, design: .rounded)).monospacedDigit()
                Text([s.sleep.map { "Sleep \($0)" }, s.hrv.map { "HRV \($0)" }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Open the app to sync").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ReadinessAccessoryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "readiness", provider: SnapshotProvider()) { entry in
            ReadinessAccessoryView(entry: entry)
        }
        .configurationDisplayName("Readiness")
        .description("Your readiness score on the Lock Screen.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct OuraWidgetBundle: WidgetBundle {
    var body: some Widget {
        ScoresWidget()
        ReadinessAccessoryWidget()
    }
}
