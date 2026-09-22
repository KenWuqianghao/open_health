import SwiftUI

// The SwiftUI screens for OuraApp. Data types live in Models.swift, the model/FFI
// orchestration in Core.swift, the reusable cards/charts in Components.swift, and the
// full-page sleep/activity reports in Reports.swift.
// SIBLING CLIENT: the web dashboard (dashboard/web/app.js) renders the SAME summary
// JSON — a user-facing change here usually belongs there too (docs/clients-web-and-ios.md).
//
// Layout follows the Apple Health "Summary" tab: a large-title NavigationStack, a
// grouped background, one card per topic, and push navigation into each detail page.

// ── the day cards ────────────────────────────────────────────────────────────
// Last night's sleep. Tap for the full sleep report.
struct SleepCard: View {
    let s: Summary
    let day: String
    var body: some View {
        NavigationLink(value: Route.report(ReportSel(day: day, sleep: true))) {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(title: "Sleep", icon: "bed.double.fill", tint: Theme.sleep,
                           detail: s.night(forDay: day).map { "\($0.start ?? "—") – \($0.end ?? "—")" },
                           chevron: true)
                if let n = s.night(forDay: day) {
                    Text("Time in Bed").font(.subheadline).foregroundStyle(.secondary)
                    BigValue(parts: n.in_bed_h.map(Fmt.hoursMinutes) ?? [("—", "")])
                    if n.hasHypnogram {
                        Hypnogram(stages: n.stages!, height: 34).padding(.top, 2)
                    }
                    if n.hasHypnogram {
                        HStack(spacing: 12) {
                            ForEach([(1, n.deep_pct), (2, n.light_pct), (3, n.rem_pct)], id: \.0) { code, pct in
                                HStack(spacing: 4) {
                                    Circle().fill(Theme.stage(code)).frame(width: 7, height: 7)
                                    Text("\(Theme.stageName(code)) \(Int(pct ?? 0))%")
                                }
                            }
                            Spacer()
                            if let e = n.efficiency { Text("\(Int(e))% efficient") }
                        }
                        .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    }
                } else {
                    EmptyCardState(icon: "moon.zzz", title: "No Sleep Yet",
                                   text: "Wear your ring tonight. Tomorrow morning, last night will appear here.")
                }
            }
            .card()
        }
        .buttonStyle(.plain)
    }
}

// The day's movement. Tap for the full activity report.
struct ActivityCard: View {
    let s: Summary
    let day: String
    var body: some View {
        let st = s.activity_daily[day]
        NavigationLink(value: Route.report(ReportSel(day: day, sleep: false))) {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(title: "Activity", icon: "flame.fill", tint: Theme.activity, chevron: true)
                if st == nil && (s.activity_profile[day] ?? []).count < 2 {
                    EmptyCardState(icon: "figure.walk", title: "No Movement Yet",
                                   text: "Steps and active energy appear after the first sync of the day.")
                } else {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Steps").font(.subheadline).foregroundStyle(.secondary)
                            BigValue(Fmt.steps(st?.steps), "")
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Active Energy").font(.subheadline).foregroundStyle(.secondary)
                            BigValue(Fmt.number(st?.active_kcal), "kcal")
                        }
                    }
                }
                let profile = s.activity_profile[day] ?? []
                if profile.count > 1 {
                    MovementRidge(profile: profile, height: 40)
                }
                let ws = s.workoutsOn(day).prefix(2)
                if !ws.isEmpty {
                    Divider()
                    ForEach(Array(ws)) { w in
                        SessionRow(label: w.label, durationMin: w.durationMin, startHM: w.startHM)
                    }
                }
            }
            .card()
        }
        .buttonStyle(.plain)
    }
}

/// The one-line reading of the newest data, and the sync or analysis status while
/// the ring or the on-device models are working. Cached content stays visible; the
/// status is a line, not a spinner over the page.
struct HighlightsCard: View {
    let digest: String?
    let status: String?
    var body: some View {
        if digest != nil || status != nil {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(title: "Highlights", icon: "sparkles", tint: .accentColor)
                if let status {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(status).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .transition(.opacity)
                }
                if let digest {
                    Text(digest).font(.body)
                }
            }
            .card()
            .animation(.snappy, value: status)
        }
    }
}

/// An empty state inside a card: a symbol, a short title, one line of guidance.
struct EmptyCardState: View {
    let icon: String
    let title: String
    let text: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

// Every day with data; tap one for its full report.
struct AllDaysView: View {
    let s: Summary
    var body: some View {
        List(s.days, id: \.self) { day in
            NavigationLink(value: Route.report(ReportSel(day: day, sleep: true))) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(Fmt.dayLabel(day)).font(.body.weight(.medium))
                        Spacer()
                        if let sc = s.scores?.days[day] {
                            HStack(spacing: 10) {
                                ForEach(ScoreKind.allCases) { kind in
                                    if let v = sc.score(kind)?.score {
                                        Label("\(Int(v.rounded()))", systemImage: kind.icon)
                                            .font(.caption.weight(.medium)).monospacedDigit()
                                            .foregroundStyle(kind.tint)
                                            .labelStyle(.titleAndIcon)
                                            .accessibilityLabel("\(kind.title) \(Int(v.rounded()))")
                                    }
                                }
                            }
                        }
                    }
                    HStack(spacing: 14) {
                        if let n = s.night(forDay: day), let h = n.in_bed_h {
                            Label(Fmt.hoursMinutes(h).map { "\($0.0) \($0.1)" }.joined(separator: " "),
                                  systemImage: "bed.double.fill")
                                .foregroundStyle(Theme.sleep)
                        }
                        if let st = s.activity_daily[day] {
                            Label("\(Fmt.steps(st.steps)) steps", systemImage: "figure.walk")
                                .foregroundStyle(Theme.activity)
                        }
                    }
                    .font(.subheadline)
                    .labelStyle(.titleAndIcon)
                    .symbolRenderingMode(.hierarchical)
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("All Days")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// ── sync sheet ───────────────────────────────────────────────────────────────
// Sync status + controls + diagnostics. Pairing lives in `PairingView`; the key is
// in the Keychain. BLE only works on a physical device.
struct SyncView: View {
    @ObservedObject var ring: RingSync
    let onSynced: (SyncReport) -> Void
    let onReset: () -> Void
    let onPair: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var diag = RingDiag.shared
    @ObservedObject private var store = DiagStore.shared
    @State private var copied = false
    @State private var confirmReset = false
    @State private var linkPolicy = SyncSettings.linkPolicy
    private static let when: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d, HH:mm"; return f
    }()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if ring.isPaired {
                        HStack(spacing: 12) {
                            statusIcon
                            VStack(alignment: .leading, spacing: 3) {
                                Text(ring.busy ? "Syncing" : (ring.wasRecentlySynced ? "Up to date" : "Ready to sync"))
                                    .font(.headline)
                                Text(ring.status.isEmpty
                                     ? (ring.lastSuccessfulSyncAt.map { "Last sync \(Self.when.string(from: $0))" } ?? "No sync yet")
                                     : ring.status)
                                    .font(.subheadline)
                                    .foregroundStyle(ring.lastReport != nil && !ring.busy ? Theme.good : .secondary)
                            }
                        }
                        .padding(.vertical, 4)
                        Button {
                            Task { if let report = await ring.run() { onSynced(report) } }
                        } label: {
                            Label(ring.busy ? "Syncing…" : "Sync Now", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(ring.busy)
                        if ring.busy {
                            Button("Stop", role: .cancel) { ring.cancel() }
                        }
                    } else {
                        Label("No ring paired", systemImage: "circle.dashed")
                            .font(.headline)
                        Button { onPair() } label: {
                            Label("Pair a Ring", systemImage: "plus.circle")
                        }
                    }
                } footer: {
                    if ring.isPaired {
                        Text("The ring syncs when you open the app, in the background when iOS allows it, and when the ring reconnects. Put the ring on its charger next to this iPhone for the most reliable background sync.")
                    } else {
                        Text("Factory-reset your ring, put it on its charger next to this iPhone, then pair it.")
                    }
                }

                if ring.backgroundRefreshDenied || ring.otherAppHoldsRing {
                    Section {
                        if ring.backgroundRefreshDenied {
                            Label("Background App Refresh is off. Turn it on in Settings so the ring can sync while the app is closed.",
                                  systemImage: "exclamationmark.triangle.fill")
                        }
                        if ring.otherAppHoldsRing {
                            Label("Another app on this phone holds the ring's Bluetooth link. Remove the official Oura app or turn off its Bluetooth permission.",
                                  systemImage: "exclamationmark.triangle.fill")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(Theme.caution)
                }

                if ring.isPaired {
                    Section {
                        Picker("After a sync", selection: $linkPolicy) {
                            ForEach(LinkPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .onChange(of: linkPolicy) { _, v in SyncSettings.linkPolicy = v }
                    } footer: {
                        Text(linkPolicy == .park
                             ? "Keeping the link lets iOS wake the app when the ring has new data. Release it if you also sync this ring from a computer."
                             : "The ring is free for the desktop client after each sync. Background wakes need the ring to reconnect.")
                    }
                }

                if !ring.history.isEmpty {
                    Section("Recent syncs") {
                        ForEach(ring.history.suffix(8).reversed()) { m in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.trigger.rawValue.capitalized).font(.body)
                                    Text(Self.when.string(from: m.startedAt)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("+\(m.inserted)").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                                Image(systemName: m.exit == .completed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(m.exit == .completed ? Theme.good : Theme.alert)
                                    .accessibilityLabel(m.exit.rawValue)
                            }
                        }
                    }
                }

                Section {
                    NavigationLink {
                        DiagnosticsLogView()
                    } label: {
                        LabeledContent("Log", value: diag.totalLines > 0 ? "\(diag.totalLines) lines" : "")
                    }
                    if !store.incidents.isEmpty {
                        NavigationLink {
                            IncidentListView(title: "Previous Crashes", items: store.incidents)
                        } label: {
                            LabeledContent("Previous crashes", value: "\(store.incidents.count)")
                                .foregroundStyle(Theme.alert)
                        }
                    }
                    if !store.sessions.isEmpty {
                        NavigationLink {
                            IncidentListView(title: "Older Sessions", items: store.sessions)
                        } label: {
                            LabeledContent("Older sessions", value: "\(store.sessions.count)")
                        }
                    }
                    Button {
                        UIPasteboard.general.string = DiagStore.shared.exportAll()
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                    } label: {
                        Label(copied ? "Copied" : "Copy All Diagnostics", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    if store.incidents.isEmpty {
                        Text("If the app dies mid-sync or mid-analysis, the next launch keeps that session here.")
                    }
                }

                Section {
                    Button("Reset Local Sync Data", role: .destructive) { confirmReset = true }
                        .disabled(ring.busy)
                        .confirmationDialog("Reset local sync data?", isPresented: $confirmReset, titleVisibility: .visible) {
                            Button("Reset", role: .destructive) {
                                ring.resetLocalDatabase()
                                onReset()
                            }
                        } message: {
                            Text("The synced database on this iPhone is deleted. The next sync reads the whole ring history again.")
                        }
                }
            }
            .navigationTitle("Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDragIndicator(.visible)
        .sensoryFeedback(.success, trigger: ring.lastReport?.nextCursor)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, ring.busy {
                IdleTimerLock.refreshIfHeld("ring-sync")
            }
        }
    }

    @ViewBuilder private var statusIcon: some View {
        ZStack {
            Circle().fill((ring.busy ? Color.accentColor : (ring.wasRecentlySynced ? Theme.good : Color.secondary)).opacity(0.15))
            if ring.busy {
                ProgressView()
            } else {
                Image(systemName: ring.wasRecentlySynced ? "checkmark" : "arrow.triangle.2.circlepath")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(ring.wasRecentlySynced ? Theme.good : .secondary)
            }
        }
        .frame(width: 44, height: 44)
        .accessibilityHidden(true)
    }
}

/// The live transcript of this launch.
struct DiagnosticsLogView: View {
    @ObservedObject private var diag = RingDiag.shared
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(diag.tail.enumerated()), id: \.offset) { _, line in
                    Text(line).font(Theme.mono(.caption2)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding(Theme.gutter)
        }
        .defaultScrollAnchor(.bottom)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    UIPasteboard.general.string = RingDiag.shared.dump()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
        }
        .overlay {
            if diag.totalLines == 0 {
                ContentUnavailableView("No log lines yet", systemImage: "text.alignleft")
            }
        }
    }
}

/// Leftover crash reports or older session logs, one row each; tap to read.
struct IncidentListView: View {
    let title: String
    let items: [DiagStore.Incident]
    var body: some View {
        List(items) { item in
            NavigationLink {
                ScrollView {
                    Text(item.body).font(Theme.mono(.caption2)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(Theme.gutter)
                }
                .background(Color(.systemGroupedBackground))
                .navigationTitle(item.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { UIPasteboard.general.string = item.body } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.body)
                    Text(item.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The toolbar sync button doubles as a live status light. It spins only while BLE
/// is active, and stays still under Reduce Motion.
private struct SyncIndicatorButton: View {
    @ObservedObject var ring: RingSync
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotation = 0.0

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .rotationEffect(.degrees(rotation))
                .foregroundStyle(ring.busy ? Color.accentColor : (ring.wasRecentlySynced ? Theme.good : Color.primary))
        }
        .accessibilityLabel(ring.busy ? "Ring sync in progress" : "Ring sync and diagnostics")
        .accessibilityHint("Opens sync status, logs, and manual controls")
        .onAppear(perform: updateAnimation)
        .onChange(of: ring.busy) { _, _ in updateAnimation() }
        .onChange(of: reduceMotion) { _, _ in updateAnimation() }
    }

    private func updateAnimation() {
        if ring.busy && !reduceMotion {
            rotation = 0
            withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        } else {
            withAnimation(.easeOut(duration: 0.2)) { rotation = 0 }
        }
    }
}

// ── root ─────────────────────────────────────────────────────────────────────
struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var s: Summary? = SummaryCache.load()
    @State private var path = NavigationPath()
    @State private var showSync = false
    @State private var showPairing = !RingSync.shared.isPaired
    @State private var showProfile = false
    @State private var loadGeneration = 0
    @State private var isRefreshingSummary = false
    @ObservedObject private var ring = RingSync.shared
    @StateObject private var modelProgress = ModelProgress()

    private func f(_ v: Double?, _ fallback: String = "—") -> String {
        v.map { "\(Int($0))" } ?? fallback
    }
    private func relAge(_ diff: Double) -> String {
        let a = abs((diff * 10).rounded() / 10)
        if diff < -0.05 { return "\(a) yr younger" }
        if diff > 0.05 { return "\(a) yr older" }
        return "In line"
    }
    private func latestLabel(date: String?, time: String? = nil) -> String {
        let day = date.map { Fmt.monthDay($0) }
        let stamp = [day, time].compactMap { $0 }.joined(separator: ", ")
        return stamp.isEmpty ? "Latest reading" : stamp
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let s {
                    content(s)
                } else {
                    ProgressView("Reading your ring…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Summary")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    SyncIndicatorButton(ring: ring) { showSync = true }
                    Button { showProfile = true } label: {
                        Image(systemName: "person.crop.circle")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .navigationDestination(for: Route.self) { route in
                if let s {
                    switch route {
                    case .report(let sel): DayReportView(s: s, day: sel.day, tab: sel.sleep ? .sleep : .activity)
                    case .vital(let kind): VitalTrendView(s: s, kind: kind)
                    case .score(let kind, let day):
                        ScoreDetailView(kind: kind, day: day, score: s.scores?.days[day]?.score(kind))
                    case .allDays: AllDaysView(s: s)
                    case .sleepDebt:
                        if let debt = s.sleepDebt { SleepDebtDetail(debt: debt) }
                    }
                }
            }
        }
        .sheet(isPresented: $showSync) {
            SyncView(ring: ring, onSynced: refreshAfterSync, onReset: resetAndReload,
                     onPair: { showSync = false; showPairing = true })
        }
        .fullScreenCover(isPresented: $showPairing) {
            PairingView(onPaired: { refreshAfterSync($0) })
        }
        .sheet(isPresented: $showProfile) { ProfileSettingsView(profile: s?.profile, onSaved: refreshDerivedData) }
        .onAppear {
            // A cached summary makes launch immediate; this forced load replaces it
            // with SQLite + model output without blanking the existing cards.
            load(force: true, clearCurrent: false)
            requestAutomaticSync()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                IdleTimerLock.refreshIfHeld("models")
                requestAutomaticSync()
                HealthExporter.shared.schedule(.foreground)
            }
        }
        // A sync that completed elsewhere (background, restore wake) refreshes the
        // screen when its report lands.
        .onChange(of: ring.lastReport?.nextCursor) { _, _ in
            if let report = ring.lastReport { refreshAfterSync(report) }
        }
    }

    // re-read the DB after a sync brought in new events
    private func reload() {
        load(force: true, clearCurrent: true)
    }

    private func resetAndReload() {
        SummaryCache.clear()
        #if TORCH
        ModelCacheStore.clearAll()
        #endif
        reload()
    }

    /// Profile changes affect CVA and activity inference, but do not invalidate the
    /// summary already on screen. Keep the last complete result visible until every
    /// derived model has finished, avoiding a transient sleep-debt regression.
    private func refreshDerivedData() {
        load(force: true, clearCurrent: false)
    }

    /// New ring events invalidate every derived view. In particular this reruns AAD
    /// after the database transaction has completed, so newly accumulated movement
    /// cannot leave yesterday's activity sessions cached on screen.
    private func refreshAfterSync(_ report: SyncReport) {
        guard report.inserted > 0 else { return }
        load(force: true, clearCurrent: false)
    }

    private func requestAutomaticSync() {
        Task { _ = await ring.syncAutomaticallyIfNeeded() }
    }

    // The heavy on-device models run off the main thread (load): show the fast
    // model-free summary first, then fold in the hypnogram / CVA / activity results.
    // Keep the screen awake for the whole pass so auto-lock cannot kill a long
    // analysis (same IdleTimerLock the BLE sync already uses).
    private func load(force: Bool = false, clearCurrent: Bool = false) {
        guard force || s == nil else { return }
        isRefreshingSummary = true
        loadGeneration += 1
        let generation = loadGeneration
        IdleTimerLock.acquire("models")
        #if TORCH
        let publishBase = s == nil || clearCurrent
        #else
        let publishBase = true
        #endif
        // Captured before the background hop: the last published summary is the
        // fallback if a model read fails mid-sync (withModels never replaces real
        // results with emptiness).
        let previous = s
        if clearCurrent { s = nil }
        modelProgress.begin(generation)
        let progress = modelProgress.sink(generation)
        DispatchQueue.global(qos: .userInitiated).async {
            let built = Core.baseWithJson()
            let base = built.summary
            if publishBase {
                DispatchQueue.main.async {
                    guard generation == loadGeneration else { return }
                    s = base
                    SummaryCache.save(base)
                    HealthExporter.shared.schedule(.sync, summary: base)
                }
            }
            #if TORCH
            if base.error == nil {
                let full = Core.withModels(base, previous: previous, progress: progress)
                HubPusher.shared.schedule(rawJson: built.json, models: full, reason: "foreground")
                DispatchQueue.main.async { finishLoad(generation, summary: full) }
            } else {
                DispatchQueue.main.async { finishLoad(generation, summary: nil) }
            }
            #else
            if base.error == nil {
                HubPusher.shared.schedule(rawJson: built.json, models: previous ?? base, reason: "foreground")
            }
            DispatchQueue.main.async { finishLoad(generation, summary: nil) }
            #endif
        }
    }

    private func finishLoad(_ generation: Int, summary: Summary?) {
        if generation == loadGeneration {
            if let summary {
                s = summary
                SummaryCache.save(summary)
                HealthExporter.shared.schedule(.modelsUpdated, summary: summary)
            }
            isRefreshingSummary = false
            modelProgress.report(generation, nil)
        }
        IdleTimerLock.release("models")
    }

    @ViewBuilder private func content(_ s: Summary) -> some View {
        if let err = s.error {
            ContentUnavailableView {
                Label("No Data Yet", systemImage: "circle.dashed")
            } description: {
                Text(err)
            } actions: {
                if ring.isPaired {
                    Button("Sync Now") { showSync = true }.buttonStyle(.borderedProminent)
                } else {
                    Button("Pair a Ring") { showPairing = true }.buttonStyle(.borderedProminent)
                }
            }
        } else {
            let latestTemp = s.nights.first { $0.skin_temp != nil }
            let latestOxygen = s.nights.first { $0.spo2_mean != nil }
            let recentTemperatures = Array(s.nights.compactMap(\.skin_temp).prefix(14).reversed())
            let recentOxygen = Array(s.nights.compactMap(\.spo2_mean).prefix(14).reversed())
            let latestHR = s.vitals.hr
            let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    // highlights: the digest line, and the sync / analysis status while
                    // the ring or the models are working (HIG: describe the work, not the wait)
                    HighlightsCard(digest: s.digest,
                                   status: ring.busy ? (ring.status.isEmpty ? "Syncing with your ring…" : ring.status)
                                       : (isRefreshingSummary ? (modelProgress.label.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Updating your summary…") : nil))

                    // today — last night's sleep + that day's activity as one unit,
                    // the hero of the home; tap either card for its report.
                    if let day = s.days.first {
                        SectionTitle(Fmt.dayLabel(day))
                        ScoresCard(s: s, day: day)
                        SleepCard(s: s, day: day)
                        ActivityCard(s: s, day: day)
                    }

                    SectionTitle("Vitals")
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        VitalCell(kind: .hrv, value: f(s.vitals.hrv.latest),
                                  delta: s.vitals.hrv.delta_pct, series: s.vitals.hrv.series,
                                  baseline: s.vitals.hrv.baseline)
                        VitalCell(kind: .heartRate,
                                  value: f(latestHR?.latest ?? s.vitals.rhr.latest),
                                  series: s.vitals.rhr.series,
                                  baseline: s.vitals.rhr.baseline,
                                  detail: latestHR.map { latestLabel(date: $0.date, time: $0.hm) }
                                      ?? "Nightly minimum")
                        VitalCell(kind: .temp,
                                  value: latestTemp?.skin_temp.map { String(format: "%.1f", $0) } ?? "—",
                                  series: recentTemperatures,
                                  detail: latestTemp.map { latestLabel(date: s.wakeYmd($0)) })
                        VitalCell(kind: .oxygen, value: f(latestOxygen?.spo2_mean),
                                  series: recentOxygen,
                                  detail: latestOxygen.map { latestLabel(date: s.wakeYmd($0)) })
                    }

                    if s.sleepDebt != nil || s.illness != nil {
                        SectionTitle("Recovery")
                    }
                    if let debt = s.sleepDebt {
                        SleepDebtCard(debt: debt)
                    }
                    if let illness = s.illness {
                        IllnessCard(illness: illness)
                    }

                    // Cardiovascular estimates belong together: vascular age/PWV
                    // from raw PPG plus the demographic VO₂max estimate.
                    if s.cardio?.vascular_age != nil || s.fitness?.vo2max != nil {
                        SectionTitle("Cardiovascular")
                        VStack(alignment: .leading, spacing: 10) {
                            CardHeader(title: "Heart Health", icon: "heart.text.square.fill", tint: Theme.cardio)
                            if let cv = s.cardio, let va = cv.vascular_age {
                                Text("Vascular age").font(.subheadline).foregroundStyle(.secondary)
                                BigValue(String(format: "%.1f", va), "yr")
                                if let ca = cv.chronological_age {
                                    Text(relAge(va - ca) + " than your age")
                                        .font(.subheadline)
                                        .foregroundStyle(Theme.tone(delta: (va - ca) * 100, goodWhenPositive: false, threshold: 50))
                                }
                                Divider()
                                if let pwv = cv.pwv_ms { StatRow(label: "Pulse-wave velocity", value: String(format: "%.2f m/s", pwv)) }
                                if let seg = cv.segments { StatRow(label: "Segments analysed", value: "\(seg)") }
                            }
                            if let vo = s.fitness?.vo2max {
                                if s.cardio?.vascular_age != nil { Divider() }
                                StatRow(label: "VO₂max estimate", value: String(format: "%.1f ml/kg/min", vo))
                            }
                        }
                        .card()
                    }

                    // browse every day → per-day detail (sleep + activity)
                    if !s.days.isEmpty {
                        NavigationLink(value: Route.allDays) {
                            HStack {
                                Label("Show All Days", systemImage: "calendar")
                                    .font(.body.weight(.medium))
                                Spacer()
                                Text("\(s.days.count)").foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .card()
                        }
                        .buttonStyle(.plain)
                    }

                    // on-device model failures (empty unless a torch model genuinely
                    // failed — a missing bundle or an inference error, not just no data)
                    if !s.modelErrors.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            CardHeader(title: "On-Device Models", icon: "exclamationmark.triangle.fill", tint: Theme.caution)
                            ForEach(s.modelErrors, id: \.self) { e in
                                Text(e).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .card()
                    }

                    // device & data health
                    SectionTitle("Ring")
                    VStack(spacing: 10) {
                        CardHeader(title: "Device", icon: "circle.circle", tint: Theme.device,
                                   detail: s.device?.firmware.map { "Firmware \($0)" })
                        if let b = s.device?.battery_pct {
                            HStack(spacing: 12) {
                                Image(systemName: b < 20 ? "battery.25percent" : (b < 60 ? "battery.50percent" : "battery.100percent"))
                                    .font(.title2)
                                    .foregroundStyle(b < 20 ? Theme.alert : Theme.good)
                                    .accessibilityHidden(true)
                                BigValue("\(b)", "%", style: .title2)
                                Spacer()
                            }
                        }
                        Divider()
                        StatRow(label: "Serial", value: s.device?.serial ?? "—")
                        StatRow(label: "Last sync",
                                value: s.device.flatMap { d in d.synced.map { "\(Fmt.monthDay($0)) \(d.synced_hm ?? "")" } } ?? "—")
                        StatRow(label: "Days of data",
                                value: s.device?.days_of_data.map { String(format: "%.0f", $0) } ?? "—")
                        StatRow(label: "Nights", value: "\(s.device?.nights ?? s.nights.count)")
                    }
                    .card()
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, 32)
            }
            .refreshable {
                if ring.isPaired { _ = await ring.run() } else { load(force: true) }
            }
        }
    }
}

@main
struct OuraApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    init() { DiagStore.shared.bootstrap() }
    var body: some Scene {
        WindowGroup { RootView() }
            .onChange(of: scenePhase) { _, phase in
                Task { await SyncCoordinator.shared.scenePhaseChanged(phase) }
            }
    }
}
