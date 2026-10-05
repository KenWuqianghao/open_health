import Foundation
import SwiftUI
import Charts

// Live heart rate: a spot check, a workout, or a breathing session with live HRV.
// The ring streams one frame per beat while the phone holds the link; the Rust client
// keeps the stream alive and sets the ring back to automatic at the end
// (`RingSession.liveHeartRate`). This file holds the service and the screens.

struct LiveSample: Identifiable, Equatable {
    /// Seconds from the start of the session.
    let t: Double
    let bpm: Double
    var id: Double { t }
}

struct LiveResult: Equatable {
    var seconds: Double
    var beats: Int
    var average: Double
    var lowest: Double
    var highest: Double
    /// RMSSD of the first and the last minute, when the session had both.
    var hrvStart: Double?
    var hrvEnd: Double?
}

/// Beat statistics. Plain values in and out, so they can be tested.
enum LiveMath {
    /// RMSSD (ms) of the intervals. A difference of more than 300 ms between two
    /// intervals is a missed or a false beat, not variability.
    static func rmssd(_ ibis: [Double]) -> Double? {
        let diffs = zip(ibis, ibis.dropFirst()).map { $1 - $0 }.filter { abs($0) <= 300 }
        guard diffs.count >= 8 else { return nil }
        return (diffs.map { $0 * $0 }.reduce(0, +) / Double(diffs.count)).squareRoot()
    }

    /// Share of the maximum heart rate (Tanaka 2001: 208 − 0.7 × age).
    static func zone(bpm: Double, age: Double) -> (name: String, index: Int) {
        let share = bpm / (208 - 0.7 * age)
        switch share {
        case ..<0.5: return ("Rest", 0)
        case ..<0.6: return ("Very light", 1)
        case ..<0.7: return ("Light", 2)
        case ..<0.8: return ("Moderate", 3)
        case ..<0.9: return ("Hard", 4)
        default: return ("Maximum", 5)
        }
    }

    static func result(beats: [(t: Double, ibi: Double)], seconds: Double) -> LiveResult? {
        guard !beats.isEmpty else { return nil }
        let bpm = beats.map { 60_000 / $0.ibi }
        let first = beats.filter { $0.t <= 60 }.map(\.ibi)
        let last = beats.filter { $0.t >= seconds - 60 }.map(\.ibi)
        return LiveResult(seconds: seconds, beats: beats.count,
                          average: bpm.reduce(0, +) / Double(bpm.count),
                          lowest: bpm.min() ?? 0, highest: bpm.max() ?? 0,
                          hrvStart: seconds >= 120 ? rmssd(first) : nil,
                          hrvEnd: seconds >= 120 ? rmssd(last) : nil)
    }
}

/// Forwards the beats from the Rust thread to the main actor.
private final class BeatBridge: LiveBeatListener, @unchecked Sendable {
    let onBeat: @MainActor (UInt16, UInt16) -> Void
    init(_ onBeat: @escaping @MainActor (UInt16, UInt16) -> Void) { self.onBeat = onBeat }
    func onBeat(bpm: UInt16, ibiMs: UInt16) {
        Task { @MainActor in self.onBeat(bpm, ibiMs) }
    }
}

@MainActor
final class LiveHeart: ObservableObject {
    static let shared = LiveHeart()

    enum Phase: Equatable {
        case idle
        case connecting(String)
        case streaming
        /// The stream gave no beat; this is the ring's last stored reading.
        case lastReading(Int)
        case finished
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var bpm: Int?
    @Published private(set) var hrv: Double?
    @Published private(set) var samples: [LiveSample] = []
    @Published private(set) var startedAt: Date?
    @Published private(set) var result: LiveResult?
    /// True in the simulator, which has no Bluetooth: the beats are made up.
    @Published private(set) var simulated = false

    private var beats: [(t: Double, ibi: Double)] = []
    private var task: Task<Void, Never>?
    private var stopping = false

    var isActive: Bool {
        switch phase {
        case .connecting, .streaming: return true
        default: return false
        }
    }
    var elapsed: Double { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }

    func start() {
        guard !isActive else { return }
        beats = []
        samples = []
        bpm = nil
        hrv = nil
        result = nil
        stopping = false
        startedAt = nil
        phase = .connecting("Connecting to your ring…")
        #if targetEnvironment(simulator)
        simulated = true
        task = Task { await self.simulate() }
        #else
        simulated = false
        task = Task { await self.stream() }
        #endif
    }

    func stop() {
        guard isActive else { return }
        stopping = true
        if simulated {
            task?.cancel()
        } else {
            Task { await SyncCoordinator.shared.cancelCurrent(reason: .cancelled) }
        }
    }

    private func take(bpm: UInt16, ibi: UInt16) {
        if startedAt == nil {
            startedAt = Date()
            phase = .streaming
        }
        let t = elapsed
        beats.append((t, Double(ibi)))
        self.bpm = Int(bpm)
        // one chart point per second is enough
        if samples.last.map({ t - $0.t >= 1 }) ?? true {
            let recent = beats.suffix(5).map { 60_000 / $0.ibi }
            samples.append(LiveSample(t: t, bpm: recent.reduce(0, +) / Double(recent.count)))
        }
        hrv = LiveMath.rmssd(beats.filter { $0.t >= t - 60 }.map(\.ibi))
    }

    private func finish(error: String?) {
        result = LiveMath.result(beats: beats, seconds: elapsed)
        if result != nil {
            phase = .finished
        } else if let error {
            phase = .failed(error)
        } else {
            phase = stopping ? .idle : .failed("The ring sent no heart beats. Wear the ring, keep it near the iPhone, and try again.")
        }
    }

    private func stream() async {
        let bridge = BeatBridge { [weak self] bpm, ibi in self?.take(bpm: bpm, ibi: ibi) }
        var failure: String?
        do {
            _ = try await SyncCoordinator.shared.withRing(
                trigger: .live, restartOnDrop: true,
                onStatus: { text in
                    Task { @MainActor [weak self] in
                        guard let self, self.startedAt == nil else { return }
                        self.phase = .connecting(text == "Connected" ? "Waiting for the first beat…" : text)
                    }
                }
            ) { session, key in
                try await session.liveHeartRate(keyHex: key, listener: bridge)
            }
        } catch {
            failure = BLEErrorHint.text(error) ?? error.localizedDescription
        }
        // let the last beats reach the main actor
        try? await Task.sleep(nanoseconds: 200_000_000)
        if beats.isEmpty, !stopping {
            // No stream on this ring: show what the ring measured last.
            if let reading = try? await SyncCoordinator.shared.withRing(trigger: .ringControl, { session, key in
                try await session.latestReading(keyHex: key)
            }), let bpm = reading.bpm {
                phase = .lastReading(Int(bpm))
                return
            }
        }
        finish(error: failure)
    }

    #if targetEnvironment(simulator)
    private func simulate() async {
        try? await Task.sleep(nanoseconds: 900_000_000)
        var rate = 68.0
        var phaseAngle = 0.0
        while !Task.isCancelled {
            // a slow drift plus the rise and fall of breathing
            phaseAngle += 0.62
            rate += Double.random(in: -0.4...0.35)
            rate = min(max(rate, 58), 84)
            let ibi = 60_000 / rate + 38 * sin(phaseAngle) + Double.random(in: -12...12)
            take(bpm: UInt16(60_000 / ibi), ibi: UInt16(ibi))
            try? await Task.sleep(nanoseconds: UInt64(ibi * 1_000_000))
        }
        finish(error: nil)
    }
    #endif
}

// ── screens ──────────────────────────────────────────────────────────────────

struct LiveHeartView: View {
    let mode: LiveMode
    let profile: Profile?
    var onSaved: () -> Void = {}
    @ObservedObject private var live = LiveHeart.shared
    @ObservedObject private var ring = RingSync.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breatheMinutes = 3
    @State private var workoutLabel = "Running"
    @State private var saved = false
    @State private var now = Date()
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    static let workoutLabels = ["Running", "Walking", "Cycling", "Strength training", "Yoga", "Hiking", "Rowing", "Other"]

    private var age: Double { profile?.age ?? 30 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                readout
                if mode == .breathe { breathCard }
                if live.samples.count > 2 { chart }
                if let result = live.result, !live.isActive { resultCard(result) }
                controls
                about
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(mode.title)
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(clock) { date in
            now = date
            if mode == .breathe, live.phase == .streaming, live.elapsed >= Double(breatheMinutes * 60) {
                live.stop()
            }
        }
        .onDisappear { live.stop() }
        .sensoryFeedback(.success, trigger: live.phase == .finished) { _, done in done }
    }

    // the number, the state, and the clock
    private var readout: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(title: "Heart Rate", icon: "heart.fill", tint: Theme.heart,
                       detail: live.simulated && live.phase != .idle ? "Simulated" : nil)
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                BigValue(live.bpm.map(String.init) ?? "—", "bpm", style: .largeTitle)
                if live.phase == .streaming {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(Theme.heart)
                        .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                        .accessibilityHidden(true)
                }
                Spacer()
                if live.startedAt != nil {
                    Text(Self.clockText(live.isActive ? live.elapsed : (live.result?.seconds ?? 0)))
                        .font(Theme.number(.title3)).monospacedDigit().foregroundStyle(.secondary)
                        .accessibilityLabel("Elapsed time")
                }
            }
            statusLine
            if live.phase == .streaming || live.result != nil {
                Divider()
                HStack(spacing: 0) {
                    if let bpm = live.bpm, mode == .workout {
                        let zone = LiveMath.zone(bpm: Double(bpm), age: age)
                        Readout(value: zone.name, caption: "Effort", color: Self.zoneColor(zone.index))
                    }
                    Readout(value: live.hrv.map { "\(Int($0.rounded())) ms" } ?? "—", caption: "HRV, last minute")
                }
            }
        }
        .card()
        .animation(Motion.snappy, value: live.phase)
    }

    @ViewBuilder private var statusLine: some View {
        switch live.phase {
        case .idle:
            Text(Self.isSimulator ? "The simulator has no Bluetooth. A session here uses made-up beats."
                 : (ring.isPaired ? "Wear the ring and keep the iPhone near."
                    : "Pair a ring to measure your heart rate."))
                .font(.subheadline).foregroundStyle(.secondary)
        case .connecting(let text):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        case .streaming:
            Text(live.simulated ? "Made-up beats, not from a ring" : "Live from your ring")
                .font(.subheadline).foregroundStyle(.secondary)
        case .lastReading(let bpm):
            Text("This ring did not start a live stream. Its last stored reading is \(bpm) bpm.")
                .font(.subheadline).foregroundStyle(.secondary)
        case .finished:
            Text("Session complete").font(.subheadline).foregroundStyle(Theme.good)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline).foregroundStyle(Theme.caution)
        }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(title: "This Session", icon: "waveform.path.ecg", tint: Theme.heart)
            let values = live.samples.map(\.bpm)
            let lo = (values.min() ?? 50) - 5, hi = (values.max() ?? 100) + 5
            Chart(live.samples) { s in
                LineMark(x: .value("Seconds", s.t), y: .value("Heart rate", s.bpm))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Theme.heart)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            .chartYScale(domain: lo...hi)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel {
                        if let t = value.as(Double.self) { Text(Self.clockText(t)) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel()
                }
            }
            .frame(height: 160)
            .accessibilityLabel("Heart rate during this session")
        }
        .card()
    }

    private var breathCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "Breathe", icon: "wind", tint: Theme.breath,
                       detail: live.phase == .streaming ? Self.clockText(max(0, Double(breatheMinutes * 60) - live.elapsed)) + " left" : nil)
            if live.phase == .streaming {
                BreathPacer(start: live.startedAt ?? now)
                    .frame(maxWidth: .infinity)
            } else {
                Picker("Length", selection: $breatheMinutes) {
                    ForEach([1, 3, 5, 10], id: \.self) { Text("\($0) min").tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Breathe in for 4 seconds and out for 6 seconds. At this pace, heart rate and breathing move together, and HRV rises for most people.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private func resultCard(_ r: LiveResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "Result", icon: "checkmark.seal.fill", tint: Theme.good,
                       detail: Fmt.minutesText(max(1, r.seconds / 60)))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), alignment: .leading, spacing: 16) {
                Readout(value: "\(Int(r.average.rounded()))", caption: "Average bpm")
                Readout(value: "\(Int(r.lowest.rounded()))", caption: "Lowest")
                Readout(value: "\(Int(r.highest.rounded()))", caption: "Highest")
            }
            if let a = r.hrvStart, let b = r.hrvEnd {
                Divider()
                let change = b - a
                StatRow(label: "HRV, first minute", value: "\(Int(a.rounded())) ms")
                StatRow(label: "HRV, last minute", value: "\(Int(b.rounded())) ms",
                        color: Theme.tone(delta: change / max(a, 1) * 100))
            }
            if mode != .check, r.seconds >= 60 {
                Divider()
                if mode == .workout {
                    Picker("Activity", selection: $workoutLabel) {
                        ForEach(Self.workoutLabels, id: \.self) { Text($0).tag($0) }
                    }
                }
                Button {
                    save(r)
                } label: {
                    Label(saved ? "Saved" : (mode == .workout ? "Save Workout" : "Add to Journal"),
                          systemImage: saved ? "checkmark" : "square.and.arrow.down")
                }
                .disabled(saved)
            }
        }
        .card()
    }

    private var controls: some View {
        Group {
            if live.isActive {
                SecondaryButton(title: "Stop", systemImage: "stop.fill") { live.stop() }
            } else {
                PrimaryButton(title: live.result == nil ? "Start" : "Start Again", systemImage: "play.fill") {
                    saved = false
                    live.start()
                }
                .disabled(!ring.isPaired && !Self.isSimulator)
            }
        }
        .padding(.top, 4)
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("About").font(.headline)
            Text("The ring sends each heart beat while the iPhone is connected to it. A live session uses more of the ring's battery than usual, so the ring goes back to its automatic measurements when you stop. The ring cannot sync during a session.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .card()
    }

    private func save(_ r: LiveResult) {
        let start = (live.startedAt ?? Date()).timeIntervalSince1970
        let op: [String: Any] = mode == .workout
            ? ["op": "add_workout", "start_unix": Int(start), "duration_min": max(1, (r.seconds / 60).rounded()),
               "label": workoutLabel,
               "note": "Live session: average \(Int(r.average.rounded())) bpm, highest \(Int(r.highest.rounded())) bpm"]
            : ["op": "add_tag", "day": NotificationRules.localDay(Date()), "tag": "breathing"]
        if JournalStore.apply(op) != nil {
            saved = true
            onSaved()
        }
    }

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    static func clockText(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func zoneColor(_ index: Int) -> Color {
        [Color.secondary, .blue, .green, .yellow, .orange, .red][min(max(index, 0), 5)]
    }
}

/// A circle that grows for 4 seconds and shrinks for 6: six breaths per minute.
struct BreathPacer: View {
    let start: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let inhale = 4.0, exhale = 6.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let t = context.date.timeIntervalSince(start).truncatingRemainder(dividingBy: Self.inhale + Self.exhale)
            let inhaling = t < Self.inhale
            // an eased position in 0...1: 1 at the end of the breath in
            let raw = inhaling ? t / Self.inhale : 1 - (t - Self.inhale) / Self.exhale
            let eased = 0.5 - 0.5 * cos(raw * .pi)
            let left = Int((inhaling ? Self.inhale - t : Self.inhale + Self.exhale - t).rounded(.up))
            ZStack {
                Circle().fill(Theme.breath.opacity(0.12)).frame(width: 190, height: 190)
                Circle()
                    .fill(Theme.breath.gradient.opacity(0.75))
                    .frame(width: 190, height: 190)
                    .scaleEffect(reduceMotion ? 0.7 : 0.42 + 0.58 * eased)
                VStack(spacing: 2) {
                    Text(inhaling ? "Breathe In" : "Breathe Out").font(.headline)
                    Text("\(left)").font(Theme.number(.title2)).monospacedDigit()
                }
                .foregroundStyle(.white)
            }
            .frame(height: 200)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(inhaling ? "Breathe in" : "Breathe out")
        }
    }
}
