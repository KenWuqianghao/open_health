import Combine
import Foundation
import HealthKit
import UIKit

// The Apple Health exporter. Continuous and idempotent:
//  - a day is exported as soon as its samples exist (no waiting for finalization);
//  - every export DELETES our previous samples inside the day's windows before it
//    writes fresh ones, so re-running never duplicates;
//  - finalized days behind the `exportThroughYmd` cursor are never touched again;
//  - the recent tail is rewritten only when its fingerprint changed.
// Ownership is by source (`HKSource.default()`) plus an `HKDevice` named after the
// ring. Sync identifiers are not used: a same-version save is silently ignored by
// HealthKit, which would mask a half-failed delete.

enum ExportReason: Equatable, Sendable {
    case enabled, sync, backgroundSync, modelsUpdated, foreground, unlocked, manual(full: Bool)
    var isFull: Bool {
        switch self {
        case .enabled, .manual(full: true): return true
        default: return false
        }
    }
    var tag: String {
        switch self {
        case .enabled: return "enabled"
        case .sync: return "sync"
        case .backgroundSync: return "background"
        case .modelsUpdated: return "models"
        case .foreground: return "foreground"
        case .unlocked: return "unlocked"
        case .manual(let full): return full ? "manual-full" : "manual"
        }
    }
}

struct ExportOutcome: Sendable {
    var daysWritten = 0
    var samplesWritten = 0
    var workoutsWritten = 0
    var daysSkipped = 0
    var daysFailed = 0
    var deferredForUnlock = false
    var error: String?
}

struct HealthExportStatus: Equatable {
    var running = false
    var progress = ""
    var lastSuccessAt: Date?
    var lastError: String?
    var pendingDays = 0
    var lastCounts = "—"
    var deferredForUnlock = false
}

/// The export pipeline. Runs off the main actor; the UI face is `HealthExporter`.
actor HealthExportEngine {
    static let backoff: [TimeInterval] = [5 * 60, 30 * 60, 2 * 3600, 6 * 3600, 24 * 3600]
    static let maxAttempts = 6
    static let minRewriteInterval: TimeInterval = 15 * 60
    static let saveChunk = 2000

    private let client: HealthStoreClient
    private let now: @Sendable () -> Date

    init(client: HealthStoreClient, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.now = now
    }

    static var shareTypes: Set<HKSampleType> {
        var set: Set<HKSampleType> = [HKObjectType.workoutType()]
        if let t = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { set.insert(t) }
        for id in Self.quantityIdentifiers {
            if let t = HKObjectType.quantityType(forIdentifier: id) { set.insert(t) }
        }
        return set
    }

    /// Every quantity type we write, plus distance (delete scope only: the old
    /// exporter wrote it).
    static let quantityIdentifiers: [HKQuantityTypeIdentifier] = [
        .heartRate, .heartRateVariabilitySDNN, .restingHeartRate, .respiratoryRate, .oxygenSaturation,
        .stepCount, .activeEnergyBurned, .basalEnergyBurned, .distanceWalkingRunning,
    ]

    func requestAuthorization() async throws {
        try await client.requestShare(Self.shareTypes)
    }

    /// Remove every object we ever wrote and forget the state.
    func purgeAll() async throws -> Int {
        var removed = 0
        for type in Self.shareTypes {
            removed += try await client.deleteOurObjects(of: type, in: nil)
        }
        HealthExportStateStore.clear()
        return removed
    }

    // MARK: the pass

    func run(_ reason: ExportReason, envelope: HealthEnvelope, summary: Summary?,
             includeBasal: Bool, epoch: String,
             progress: @escaping @Sendable (String) -> Void) async -> ExportOutcome {
        var outcome = ExportOutcome()
        var state = HealthExportStateStore.load()

        // Epoch migration: purge everything the old exporter wrote, start clean.
        if state.epoch != epoch {
            progress("removing samples from an older exporter…")
            do {
                let removed = try await purgeAll()
                dlog("health", "epoch \(state.epoch.isEmpty ? "<none>" : state.epoch) → \(epoch): purged \(removed) objects")
            } catch {
                outcome.error = "purge failed: \(error.localizedDescription)"
                dlog("health", outcome.error!)
                return outcome
            }
            state = HealthExportState()
            state.epoch = epoch
            HealthExportStateStore.save(state)
        }
        if reason.isFull {
            state.exportThroughYmd = nil
            state.days = [:]
        }
        state.lastRunAt = now()
        state.deferredForUnlock = false

        let device = Self.device(envelope)
        let stagesByStartDs = Self.stages(from: summary)
        let workouts = Self.workouts(from: summary)

        // Pending days, newest first (today lands first in Health).
        let days = envelope.days.sorted { $0.ymd > $1.ymd }
        var pending: [HealthDay] = []
        for day in days {
            if let through = state.exportThroughYmd, day.ymd <= through { continue }
            pending.append(day)
        }
        outcome.daysSkipped = days.count - pending.count

        for day in pending {
            let stages = day.stage_window?.start_ds.flatMap { stagesByStartDs[$0] }
            let plan = HealthPlanner.plan(day: day, stages: stages, workouts: workouts,
                                          includeBasal: includeBasal, epoch: epoch)
            var ds = state.days[day.ymd] ?? HealthDayState()
            let unchanged = ds.fingerprint == plan.fingerprint && ds.okAt != nil
            if unchanged && !reason.isFull {
                outcome.daysSkipped += 1
                continue
            }
            if !plan.finalized, let ok = ds.okAt, now().timeIntervalSince(ok) < Self.minRewriteInterval, !reason.isFull {
                outcome.daysSkipped += 1
                continue
            }
            if ds.attempts >= Self.maxAttempts && !reason.isFull {
                if plan.finalized && ds.fingerprint != plan.fingerprint {
                    ds.attempts = 0 // the day changed since we gave up: one more budget
                } else {
                    outcome.daysSkipped += 1
                    continue
                }
            }
            if ds.attempts > 0, let last = ds.lastAttemptAt, !reason.isFull {
                let wait = Self.backoff[min(ds.attempts, Self.backoff.count) - 1]
                if now().timeIntervalSince(last) < wait {
                    outcome.daysSkipped += 1
                    continue
                }
            }

            progress("exporting \(day.ymd)…")
            do {
                let written = try await export(plan, previous: ds, device: device)
                ds.fingerprint = plan.fingerprint
                ds.okAt = now()
                ds.attempts = 0
                ds.lastError = nil
                ds.sleepWindows = plan.sleepWindows.map(HealthInterval.init)
                ds.workoutWindows = plan.workoutWindows.map(HealthInterval.init)
                outcome.daysWritten += 1
                outcome.samplesWritten += written.samples
                outcome.workoutsWritten += written.workouts
                dlog("health", "\(day.ymd): wrote \(written.samples) samples, \(written.workouts) workouts\(plan.warnings.isEmpty ? "" : " — \(plan.warnings.joined(separator: "; "))")")
            } catch {
                let ns = error as NSError
                if ns.domain == HKError.errorDomain, ns.code == HKError.Code.errorDatabaseInaccessible.rawValue {
                    // Locked phone: HealthKit queries fail until first unlock. Not an
                    // attempt; resume on protectedDataDidBecomeAvailable.
                    state.deferredForUnlock = true
                    outcome.deferredForUnlock = true
                    dlog("health", "\(day.ymd): Health database locked — deferring the rest of the pass")
                    state.days[day.ymd] = ds
                    break
                }
                ds.attempts += 1
                ds.lastAttemptAt = now()
                ds.lastError = error.localizedDescription
                outcome.daysFailed += 1
                outcome.error = "\(day.ymd): \(error.localizedDescription)"
                dlog("health", "\(day.ymd): export FAILED (attempt \(ds.attempts)): \(error)")
            }
            state.days[day.ymd] = ds
            HealthExportStateStore.save(state)
            await Task.yield()
        }

        // Advance the cursor over the contiguous prefix of settled days.
        let ascending = days.sorted { $0.ymd < $1.ymd }
        var through = state.exportThroughYmd
        for day in ascending {
            if let t = through, day.ymd <= t { continue }
            guard day.finalized else { break }
            let ds = state.days[day.ymd]
            let settled = (ds?.okAt != nil && ds?.fingerprint == HealthPlanner.fingerprint(
                day: day, stages: day.stage_window?.start_ds.flatMap { stagesByStartDs[$0] },
                workouts: workouts, includeBasal: includeBasal, epoch: epoch))
                || (ds?.attempts ?? 0) >= Self.maxAttempts
            guard settled else { break }
            through = day.ymd
        }
        if through != state.exportThroughYmd {
            state.exportThroughYmd = through
            if let t = through { state.days = state.days.filter { $0.key > t } }
        }
        outcome.daysSkipped = max(0, outcome.daysSkipped)
        state.daysWritten += outcome.daysWritten
        state.samplesWritten += outcome.samplesWritten
        state.workoutsWritten += outcome.workoutsWritten
        if outcome.error == nil, !outcome.deferredForUnlock { state.lastSuccessAt = now() }
        state.lastError = outcome.error
        HealthExportStateStore.save(state)
        return outcome
    }

    /// Delete our objects in the day's windows, then write the plan.
    private func export(_ plan: DayPlan, previous: HealthDayState, device: HKDevice?) async throws -> (samples: Int, workouts: Int) {
        for id in Self.quantityIdentifiers {
            guard let type = HKObjectType.quantityType(forIdentifier: id) else { continue }
            _ = try await client.deleteOurObjects(of: type, in: plan.dayWindow)
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            for w in Self.union(previous.sleepWindows.map(\.interval) + plan.sleepWindows) {
                _ = try await client.deleteOurObjects(of: sleep, in: w)
            }
        }
        for w in Self.union(previous.workoutWindows.map(\.interval) + plan.workoutWindows) {
            _ = try await client.deleteOurObjects(of: HKObjectType.workoutType(), in: w)
        }

        let objects = Self.materialize(plan.samples, device: device)
        var written = 0
        var i = 0
        while i < objects.count {
            let chunk = Array(objects[i..<min(i + Self.saveChunk, objects.count)])
            try await client.save(chunk)
            written += chunk.count
            i += Self.saveChunk
        }
        var workouts = 0
        for w in plan.workouts {
            try await client.saveWorkout(w, device: device, metadata: ["OuraWorkoutID": w.id])
            workouts += 1
        }
        return (written, workouts)
    }

    static func union(_ windows: [DateInterval]) -> [DateInterval] {
        let sorted = windows.sorted { $0.start < $1.start }
        var out: [DateInterval] = []
        for w in sorted {
            if let last = out.last, w.start <= last.end {
                out[out.count - 1] = DateInterval(start: last.start, end: max(last.end, w.end))
            } else {
                out.append(w)
            }
        }
        return out
    }

    static func materialize(_ samples: [PlannedSample], device: HKDevice?) -> [HKObject] {
        var out: [HKObject] = []
        out.reserveCapacity(samples.count)
        for s in samples {
            switch s {
            case .quantity(let id, let value, let unit, let start, let end):
                guard let type = HKObjectType.quantityType(forIdentifier: id) else { continue }
                let q = HKQuantity(unit: unit.hkUnit, doubleValue: value)
                out.append(HKQuantitySample(type: type, quantity: q, start: start, end: max(end, start), device: device, metadata: nil))
            case .sleep(let value, let start, let end):
                guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { continue }
                out.append(HKCategorySample(type: type, value: value.rawValue, start: start, end: max(end, start.addingTimeInterval(1)), device: device, metadata: nil))
            }
        }
        return out
    }

    static func device(_ env: HealthEnvelope) -> HKDevice? {
        HKDevice(name: "Oura Ring", manufacturer: "Oura", model: env.hardware_id ?? "Oura Ring",
                 hardwareVersion: env.generation.map { "Ring \($0)" }, firmwareVersion: env.firmware,
                 softwareVersion: coreVersion(), localIdentifier: env.serial, udiDeviceIdentifier: nil)
    }

    /// The on-device hypnograms keyed by the night's `start_ds` (the exact key the
    /// summary uses, so two sleeps on one day cannot collide).
    static func stages(from summary: Summary?) -> [Int64: StageTrack] {
        var out: [Int64: StageTrack] = [:]
        guard let summary else { return out }
        for n in summary.nights {
            guard let sds = n.start_ds, let stages = n.stages, stages.count > 1, let eds = n.end_ds else { continue }
            // The window in unix time comes from the Rust bundle (start_unix); the
            // hypnogram tiles the night uniformly, so derive the epoch from the span.
            let spanS = Double(eds - sds) / 10.0
            let epoch = spanS / Double(stages.count)
            out[sds] = StageTrack(startUnix: 0, epochSeconds: epoch > 0 ? epoch : 30, codes: stages)
        }
        return out
    }

    static func workouts(from summary: Summary?) -> [WorkoutInput] {
        guard let summary else { return [] }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm"
        var out: [WorkoutInput] = []
        for w in summary.workouts where w.isWorkout >= 0.5 {
            guard let start = f.date(from: w.start) else { continue }
            let day = String(w.start.prefix(10))
            guard var end = f.date(from: "\(day) \(w.end)") else { continue }
            if end <= start { end = Calendar.current.date(byAdding: .day, value: 1, to: end) ?? end }
            out.append(WorkoutInput(id: w.id, label: w.label, start: start, end: end))
        }
        return out
    }
}

/// The UI face: the toggle, the status line, single-flight scheduling, triggers.
@MainActor
final class HealthExporter: ObservableObject {
    static let shared = HealthExporter()
    /// Bump to purge and re-export everything (a rule change, a new exporter).
    static let epoch = "2026-09-hk2"
    private static let enabledKey = "health.export.enabled"
    private static let basalKey = "health.export.basal"

    @Published private(set) var enabled: Bool
    @Published var includeBasal: Bool {
        didSet { UserDefaults.standard.set(includeBasal, forKey: Self.basalKey) }
    }
    @Published private(set) var status = HealthExportStatus()

    private let engine: HealthExportEngine
    private var inFlight: Task<ExportOutcome, Never>?
    private var rerun: (ExportReason, Summary?)?
    private var observers: [NSObjectProtocol] = []

    init(client: HealthStoreClient = HKStoreClient()) {
        engine = HealthExportEngine(client: client)
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        includeBasal = UserDefaults.standard.bool(forKey: Self.basalKey)
        let st = HealthExportStateStore.load()
        status.lastSuccessAt = st.lastSuccessAt
        status.lastError = st.lastError
        status.deferredForUnlock = st.deferredForUnlock
        status.lastCounts = "\(st.daysWritten) days · \(st.samplesWritten) samples · \(st.workoutsWritten) workouts"
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.status.deferredForUnlock else { return }
                self.schedule(.unlocked)
            }
        })
    }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func setEnabled(_ on: Bool) async {
        guard on else {
            enabled = false
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
            status.progress = "Export paused. Samples already in Health are left in place."
            return
        }
        guard isAvailable else {
            status.lastError = "Apple Health is unavailable on this device."
            dlog("health", "enable refused: Apple Health unavailable")
            return
        }
        do {
            try await engine.requestAuthorization()
        } catch {
            status.lastError = error.localizedDescription
            dlog("health", "enable failed: authorization error — \(error.localizedDescription)")
            return
        }
        status.lastError = nil
        enabled = true
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        dlog("health", "export enabled")
        await run(.enabled)
    }

    /// Fire-and-forget; a trigger during a pass queues exactly one more pass.
    func schedule(_ reason: ExportReason, summary: Summary? = nil) {
        if inFlight != nil {
            if rerun == nil || reason.isFull { rerun = (reason, summary) }
            return
        }
        Task { await run(reason, summary: summary) }
    }

    @discardableResult
    func run(_ reason: ExportReason, summary: Summary? = nil) async -> ExportOutcome {
        if let inFlight { return await inFlight.value }
        guard enabled, isAvailable else { return ExportOutcome() }
        let task = Task<ExportOutcome, Never> { [engine, includeBasal] in
            let envelope = await Task.detached(priority: .utility) { Core.healthSamples(sinceUnix: nil) }.value
            if let err = envelope.error {
                var o = ExportOutcome(); o.error = err; return o
            }
            let summary = summary ?? SummaryCache.load()
            return await engine.run(reason, envelope: envelope, summary: summary,
                                    includeBasal: includeBasal, epoch: Self.epoch) { text in
                Task { @MainActor in HealthExporter.shared.status.progress = text }
            }
        }
        inFlight = task
        status.running = true
        status.progress = "starting…"
        let outcome = await task.value
        inFlight = nil
        status.running = false
        status.progress = ""
        status.deferredForUnlock = outcome.deferredForUnlock
        if let err = outcome.error {
            status.lastError = err
        } else if !outcome.deferredForUnlock {
            status.lastError = nil
            status.lastSuccessAt = Date()
        }
        let st = HealthExportStateStore.load()
        status.lastCounts = "\(st.daysWritten) days · \(st.samplesWritten) samples · \(st.workoutsWritten) workouts"
        status.pendingDays = st.days.values.filter { $0.okAt == nil }.count
        dlog("health", "pass \(reason.tag): wrote \(outcome.daysWritten) days / \(outcome.samplesWritten) samples / \(outcome.workoutsWritten) workouts, skipped \(outcome.daysSkipped), failed \(outcome.daysFailed)\(outcome.deferredForUnlock ? ", deferred (locked)" : "")\(outcome.error.map { " — \($0)" } ?? "")")
        if let (r, s) = rerun {
            rerun = nil
            Task { await run(r, summary: s) }
        }
        return outcome
    }

    func removeAllExportedData() async -> String {
        do {
            let n = try await engine.purgeAll()
            status.lastCounts = "—"
            status.lastSuccessAt = nil
            status.pendingDays = 0
            let text = "Removed \(n) Open Oura objects from Apple Health."
            dlog("health", text)
            return text
        } catch {
            return error.localizedDescription
        }
    }
}
