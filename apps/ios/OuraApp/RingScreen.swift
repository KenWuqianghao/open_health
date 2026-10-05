import CoreBluetooth
import SwiftUI
import Charts

// The ring's own page: battery with its history, the measurement features, and the
// finder. Reads and changes go over a short ring session (`SyncCoordinator.withRing`).

/// Reads the ring's state and changes its features.
@MainActor
final class RingControl: ObservableObject {
    static let shared = RingControl()
    @Published private(set) var status: RingStatus?
    @Published private(set) var readAt: Date?
    @Published private(set) var busy: String?
    @Published var error: String?

    /// Battery and feature modes, read from the ring now.
    func read() async {
        guard busy == nil else { return }
        busy = "Reading your ring…"
        error = nil
        defer { busy = nil }
        do {
            status = try await SyncCoordinator.shared.withRing(trigger: .ringControl) { session, key in
                try await session.ringStatus(dbPath: DB.url.path, keyHex: key)
            }
            readAt = Date()
        } catch {
            self.error = BLEErrorHint.text(error) ?? error.localizedDescription
        }
    }

    /// Returns true when the ring accepted the change.
    func set(_ feature: String, on: Bool) async -> Bool {
        guard busy == nil else { return false }
        busy = on ? "Turning on…" : "Turning off…"
        error = nil
        defer { busy = nil }
        do {
            let state = try await SyncCoordinator.shared.withRing(trigger: .ringControl) { session, key in
                try await session.setFeature(dbPath: DB.url.path, keyHex: key, feature: feature, on: on)
            }
            if var s = status, let i = s.features.firstIndex(where: { $0.feature == feature }) {
                s.features[i] = state
                status = s
            }
            return true
        } catch {
            self.error = BLEErrorHint.text(error) ?? error.localizedDescription
            return false
        }
    }
}

enum RingFeatureInfo {
    static func title(_ feature: String) -> String {
        switch feature {
        case "daytime_hr": return "Daytime Heart Rate"
        case "spo2": return "Blood Oxygen"
        case "exercise_hr": return "Workout Heart Rate"
        case "real_steps": return "Step Sensing"
        case "cva_ppg": return "Cardiovascular Sensing"
        default: return feature
        }
    }
    static func detail(_ feature: String) -> String {
        switch feature {
        case "daytime_hr": return "Heart beats in the day and the night. Almost every result needs it."
        case "spo2": return "Blood oxygen while you sleep. It is more than half of the data of a night, so a sync takes longer."
        case "exercise_hr": return "Heart rate during activity."
        case "real_steps": return "Step features from the motion sensor, for the activity model."
        case "cva_ppg": return "Pulse wave samples for the vascular age model."
        default: return ""
        }
    }
}

// ── the finder ───────────────────────────────────────────────────────────────

/// Looks for the ring's Bluetooth signal and reports how strong it is. The ring has
/// no sound and no light that an app can turn on, so the signal is the only guide.
@MainActor
final class RingFinder: ObservableObject {
    enum Range: String {
        case none = "No signal", far = "Far", room = "In the room", near = "Near", close = "Very close"
        var bars: Int {
            switch self { case .none: return 0; case .far: return 1; case .room: return 2; case .near: return 3; case .close: return 4 }
        }
    }
    @Published private(set) var rssi: Double?
    @Published private(set) var lastHeard: Date?
    @Published private(set) var scanning = false
    @Published private(set) var bluetoothOff = false
    private var loop: Task<Void, Never>?

    /// Signal strength to a range. Indoor Bluetooth loses about 20 dB per tenfold
    /// distance; these limits are for a ring in open air.
    nonisolated static func range(rssi: Double?, heardAgo: TimeInterval?) -> Range {
        guard let rssi, let heardAgo, heardAgo < 12 else { return .none }
        switch rssi {
        case (-58)...: return .close
        case (-70)...: return .near
        case (-84)...: return .room
        default: return .far
        }
    }

    var range: Range { Self.range(rssi: rssi, heardAgo: lastHeard.map { Date().timeIntervalSince($0) }) }

    func start() {
        guard loop == nil else { return }
        scanning = true
        let paired = PairedRingStore.load()
        loop = Task {
            // the ring advertises only while nothing holds its link
            RingCentral.shared.disarm()
            while !Task.isCancelled {
                let state = RingCentral.shared.state
                bluetoothOff = state == .poweredOff || state == .unauthorized || state == .unsupported
                await RingCentral.shared.discoverRings(timeout: 10) { candidate in
                    let mine = paired.map { p in
                        candidate.id == p.peripheralID || (candidate.name ?? "").contains(p.serial)
                            || (candidate.name ?? "").localizedCaseInsensitiveContains("oura")
                    } ?? true
                    guard mine else { return }
                    Task { @MainActor [weak self] in self?.heard(Double(candidate.rssi)) }
                }
                if !Task.isCancelled { try? await Task.sleep(nanoseconds: 200_000_000) }
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        scanning = false
        RingCentral.shared.stopDiscovery()
        RingCentral.shared.arm()
    }

    private func heard(_ value: Double) {
        guard value < 0, value > -110 else { return }
        // smooth: one reading can be off by 10 dB
        rssi = rssi.map { $0 * 0.6 + value * 0.4 } ?? value
        lastHeard = Date()
    }
}

struct RingFinderView: View {
    @StateObject private var finder = RingFinder()
    @ObservedObject private var ring = RingSync.shared
    @State private var tick = Date()
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private static let when: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    var body: some View {
        let range = finder.range
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 16) {
                    SignalBars(bars: range.bars)
                        .frame(height: 96)
                        .padding(.top, 8)
                    Text(range.rawValue).font(.title2.bold())
                        .contentTransition(.opacity)
                    Text(hint(range)).font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if let rssi = finder.rssi, range != .none {
                        Text("\(Int(rssi.rounded())) dBm").font(Theme.mono(.caption)).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity)
                .card()
                .animation(Motion.snappy, value: range)

                VStack(spacing: 10) {
                    StatRow(label: "Last connection",
                            value: ring.lastSuccessfulSyncAt.map { Self.when.string(from: $0) } ?? "—")
                    if let heard = finder.lastHeard {
                        Divider()
                        StatRow(label: "Signal heard", value: "\(max(0, Int(tick.timeIntervalSince(heard)))) s ago")
                    }
                }
                .card()

                VStack(alignment: .leading, spacing: 6) {
                    Text("How to find it").font(.headline)
                    Text("Walk slowly through the room and watch the bars. Stop for a few seconds in each place: the signal takes time to settle. The ring sends its signal about once per second, and only with enough battery.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("The ring cannot make a sound or flash a light on request, so the app uses the strength of its Bluetooth signal.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .card()
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Find My Ring")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { finder.start() }
        .onDisappear { finder.stop() }
        .onReceive(clock) { tick = $0 }
        .sensoryFeedback(.impact(weight: .medium), trigger: range.bars) { before, now in now > before }
    }

    private func hint(_ range: RingFinder.Range) -> String {
        if finder.bluetoothOff { return "Bluetooth is off or not allowed for Open Oura." }
        switch range {
        case .none: return "Looking for the ring's signal. Move to another room if nothing shows in 20 seconds."
        case .far: return "The ring is in range, but not near. Move and watch if the signal gets stronger."
        case .room: return "The ring is a few metres away."
        case .near: return "The ring is about a metre away."
        case .close: return "The ring is within arm's reach."
        }
    }
}

private struct SignalBars: View {
    let bars: Int
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(1...4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(i <= bars ? Color.accentColor : Color(.tertiarySystemFill))
                    .frame(width: 22, height: 24 * CGFloat(i))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Signal \(bars) of 4 bars")
    }
}

// ── the ring page ────────────────────────────────────────────────────────────

struct BatteryChart: View {
    let battery: BatteryInfo
    var body: some View {
        let points = battery.history
        Chart(points) { p in
            AreaMark(x: .value("Time", Date(timeIntervalSince1970: p.t)), y: .value("Battery", p.pct))
                .interpolationMethod(.monotone)
                .foregroundStyle(LinearGradient(colors: [Theme.good.opacity(0.25), Theme.good.opacity(0)],
                                                startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("Time", Date(timeIntervalSince1970: p.t)), y: .value("Battery", p.pct))
                .interpolationMethod(.monotone)
                .foregroundStyle(Theme.good)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, 50, 100]) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v))%") } }
            }
        }
        .chartXAxis {
            AxisMarks(preset: .aligned, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .frame(height: 170)
        .reveal(delay: 0.15)
        .accessibilityLabel("Ring battery level over the last 14 days")
    }
}

/// "About 4 days left", "Charging", or nil.
func batteryDetail(_ battery: BatteryInfo?) -> String? {
    guard let battery else { return nil }
    if battery.charging { return "Charging" }
    guard let days = battery.days_left else { return nil }
    if days < 1 { return "Less than a day left" }
    let n = Int(days.rounded())
    return "About \(n) day\(n == 1 ? "" : "s") left"
}

struct RingView: View {
    let s: Summary
    let onChanged: () -> Void
    let onSync: () -> Void
    @ObservedObject private var control = RingControl.shared
    @ObservedObject private var ring = RingSync.shared
    @State private var pending: String?

    private var features: [(feature: String, on: Bool, known: Bool)] {
        if let live = control.status?.features {
            return live.filter(\.supported).map { ($0.feature, $0.mode != "off", true) }
        }
        return (s.device?.measuring?.value ?? []).map { ($0.feature, $0.on, false) }
    }

    var body: some View {
        let battery = s.device?.battery?.value
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    let pct = control.status?.batteryPct.map(Int.init) ?? s.device?.battery_pct
                    CardHeader(title: "Battery", icon: "battery.75percent", tint: Theme.good,
                               detail: control.readAt != nil ? "Read now" : s.device?.synced.map { "At the last sync, \(Fmt.monthDay($0))" })
                    if let pct {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            BigValue("\(pct)", "%", style: .largeTitle, color: pct <= 20 ? Theme.alert : .primary)
                            if let text = (control.status?.chargingProgress ?? 0) > 0 ? "Charging" : batteryDetail(battery) {
                                Text(text).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("No battery reading yet").font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let battery, battery.history.count > 2 {
                        BatteryChart(battery: battery)
                        if let rate = battery.rate_pct_per_day {
                            Text("The ring uses about \(Int(rate.rounded()))% per day.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .card()

                if ring.isPaired {
                    VStack(alignment: .leading, spacing: 12) {
                        CardHeader(title: "Measurements", icon: "sensor.fill", tint: Theme.device,
                                   detail: control.status == nil ? "Last known" : nil)
                        ForEach(Array(features.enumerated()), id: \.element.feature) { i, f in
                            if i > 0 { Divider() }
                            Toggle(isOn: Binding(
                                get: { f.on },
                                set: { on in
                                    pending = f.feature
                                    Task {
                                        if await control.set(f.feature, on: on) { onChanged() }
                                        pending = nil
                                    }
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(RingFeatureInfo.title(f.feature)).font(.subheadline.weight(.medium))
                                    Text(RingFeatureInfo.detail(f.feature)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .disabled(control.busy != nil || ring.busy)
                            .accessibilityIdentifier("feature-\(f.feature)")
                        }
                        if let busy = control.busy {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(busy).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        if let error = control.error {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote).foregroundStyle(Theme.caution)
                        }
                        Button {
                            Task { await control.read(); onChanged() }
                        } label: {
                            Label("Read from the Ring", systemImage: "arrow.down.circle")
                        }
                        .disabled(control.busy != nil || ring.busy)
                        Text("A change needs the ring near the iPhone. The ring can drop the connection for a moment after a change; the change is kept.")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    .card()

                    NavigationLink {
                        RingFinderView()
                    } label: {
                        HStack {
                            Label("Find My Ring", systemImage: "dot.radiowaves.left.and.right")
                                .font(.body.weight(.medium))
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .card()
                    }
                    .buttonStyle(.pressable)
                }

                VStack(spacing: 10) {
                    CardHeader(title: "Device", icon: "circle.circle", tint: Theme.device)
                    StatRow(label: "Serial", value: s.device?.serial ?? "—")
                    Divider()
                    StatRow(label: "Model", value: s.device?.hardware_id ?? "—")
                    Divider()
                    StatRow(label: "Firmware", value: s.device?.firmware ?? "—")
                    Divider()
                    StatRow(label: "Last sync",
                            value: s.device.flatMap { d in d.synced.map { "\(Fmt.monthDay($0)) \(d.synced_hm ?? "")" } } ?? "—")
                    Divider()
                    StatRow(label: "Days of data", value: s.device?.days_of_data.map { String(format: "%.0f", $0) } ?? "—")
                    Divider()
                    StatRow(label: "Nights", value: "\(s.device?.nights ?? s.nights.count)")
                }
                .card()

                Button(action: onSync) {
                    HStack {
                        Label("Sync and Diagnostics", systemImage: "arrow.triangle.2.circlepath")
                            .font(.body.weight(.medium))
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .card()
                }
                .buttonStyle(.pressable)

                Text("A firmware update is not possible from this app: the update files come from Oura's servers and need an Oura account.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Ring")
        .navigationBarTitleDisplayMode(.inline)
    }
}
