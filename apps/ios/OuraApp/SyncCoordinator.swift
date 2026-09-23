import CoreBluetooth
import Foundation
import SwiftUI
import UIKit

// The ONLY code that connects, authenticates, drains, and runs the post-sync hooks.
// The UI, the background tasks, the restore wake, and the pairing flow all call
// `SyncCoordinator.shared.sync(trigger:)`; each trigger has its own budget
// (`SyncPolicy`). Progress and results are published on `RingSync.shared` for the UI.
//
// What keeps a background sync alive: `bluetooth-central` mode plus live BLE traffic
// (each delegate callback grants time), a `KeepAlive` background-task assertion for
// the phases with no traffic (retry sleeps, post-sync hooks), and the BGTask
// assertion for scheduled runs. `IdleTimerLock` is UX only (progress stays visible).

// UniFFI records are plain value types; they cross actor boundaries here.
extension SyncReport: @unchecked Sendable {}
extension PairReport: @unchecked Sendable {}
extension ProbeReport: @unchecked Sendable {}

enum SyncTrigger: String, Codable, Sendable {
    case manual, foreground, postPair, bgRefresh, bgProcessing, bleRestore
}

enum SyncExit: String, Codable, Sendable {
    case completed, deadline, osExpired, cancelled, connectFailed, linkLost, authRejected,
         dbError, busy, cooldown, notPaired, noKey, bluetoothOff, heldByOtherApp
}

enum SyncOutcome: Sendable {
    case synced(SyncReport)
    /// The cursor advanced but the run ended early; the next run resumes.
    case partial(SyncExit)
    case skipped(SyncExit)
    case failed(SyncExit, String)

    var report: SyncReport? {
        if case .synced(let r) = self { return r }
        return nil
    }
}

enum ConnectStrategy: Sendable {
    /// A transport handed in by the caller (pairing) is already connected.
    case reuse
    /// The paired peripheral only (no scan): a parked link connects in 0 s.
    case known
    /// The paired peripheral, then a scan for `scanTimeout` seconds.
    case knownThenScan(scanTimeout: TimeInterval, mode: ScanMode)
    /// A foreground scan (the manual path, also when nothing is paired yet).
    case scan(timeout: TimeInterval)
}

struct SyncPolicy: Sendable {
    let attempts: Int
    let connectTimeout: TimeInterval
    /// Wall-clock budget for the whole run, or nil for "as long as it takes".
    let deadline: TimeInterval?
    let batchEvents: UInt16
    let connect: ConnectStrategy
    let runModels: Bool
    let refreshSummary: Bool
    let exportHealth: Bool
    let idleLock: Bool

    static func policy(for trigger: SyncTrigger) -> SyncPolicy {
        switch trigger {
        case .manual:
            return SyncPolicy(attempts: 6, connectTimeout: 50, deadline: nil, batchEvents: 0,
                              connect: .knownThenScan(scanTimeout: 50, mode: .foreground),
                              runModels: true, refreshSummary: true, exportHealth: true, idleLock: true)
        case .foreground:
            return SyncPolicy(attempts: 2, connectTimeout: 15, deadline: 10 * 60, batchEvents: 0,
                              connect: .knownThenScan(scanTimeout: 15, mode: .foreground),
                              runModels: true, refreshSummary: true, exportHealth: true, idleLock: false)
        case .postPair:
            return SyncPolicy(attempts: 6, connectTimeout: 50, deadline: nil, batchEvents: 0,
                              connect: .reuse,
                              runModels: true, refreshSummary: true, exportHealth: true, idleLock: true)
        case .bgRefresh:
            return SyncPolicy(attempts: 1, connectTimeout: 8, deadline: 22, batchEvents: 512,
                              connect: .knownThenScan(scanTimeout: 8, mode: .background),
                              runModels: false, refreshSummary: false, exportHealth: true, idleLock: false)
        case .bgProcessing:
            return SyncPolicy(attempts: 3, connectTimeout: 30, deadline: 5 * 60, batchEvents: 0,
                              connect: .knownThenScan(scanTimeout: 20, mode: .background),
                              runModels: true, refreshSummary: true, exportHealth: true, idleLock: false)
        case .bleRestore:
            return SyncPolicy(attempts: 2, connectTimeout: 10, deadline: 5 * 60, batchEvents: 2048,
                              connect: .reuse,
                              runModels: false, refreshSummary: true, exportHealth: true, idleLock: false)
        }
    }
}

/// One line per run, kept for the diagnostics screen and the transcript.
struct SyncMetrics: Codable, Sendable, Identifiable {
    var id: Date { startedAt }
    let trigger: SyncTrigger
    let startedAt: Date
    var appState: String = "unknown"
    var relaunchedByBluetooth = false
    var attempts = 0
    var connectMs = 0
    var handshakeMs = 0
    var drainMs = 0
    var events: UInt32 = 0
    var inserted: UInt32 = 0
    var cursorBefore: UInt32 = 0
    var cursorAfter: UInt32 = 0
    var bytesLeftAtExit: UInt64 = 0
    var exit: SyncExit = .completed
    var lowPower = false
    var batteryPct = -1
    var availableMemMB = 0
    var keyReadable = false
    var detail = ""

    var line: String {
        "trigger=\(trigger.rawValue) exit=\(exit.rawValue) attempts=\(attempts) events=\(events) inserted=\(inserted) "
            + "cursor=\(cursorBefore)→\(cursorAfter) bytesLeft=\(bytesLeftAtExit) connect=\(connectMs)ms drain=\(drainMs)ms "
            + "app=\(appState) bt-relaunch=\(relaunchedByBluetooth) lowPower=\(lowPower) battery=\(batteryPct)% mem=\(availableMemMB)MB key=\(keyReadable)"
            + (detail.isEmpty ? "" : " — \(detail)")
    }
}

enum SyncHistoryStore {
    private static let queue = DispatchQueue(label: "md.thomas.openoura.sync-history", qos: .utility)
    private static let keep = 50
    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sync-history.json")
    }
    static func load() -> [SyncMetrics] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([SyncMetrics].self, from: data)) ?? []
    }
    static func append(_ m: SyncMetrics) -> [SyncMetrics] {
        var all = load()
        all.append(m)
        if all.count > keep { all.removeFirst(all.count - keep) }
        let snapshot = all
        queue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
        return all
    }
}

/// A `beginBackgroundTask` assertion for phases with no BLE traffic. The expiration
/// handler only logs and ends the assertion: it must NOT cancel the sync, because an
/// active BLE session in `bluetooth-central` mode keeps the process alive on its own.
@MainActor
enum KeepAlive {
    static func begin(_ name: String) -> UIBackgroundTaskIdentifier {
        final class Cell: @unchecked Sendable { var id = UIBackgroundTaskIdentifier.invalid }
        let cell = Cell()
        cell.id = UIApplication.shared.beginBackgroundTask(withName: name) {
            dlog("bg", "background task '\(name)' expired (remaining \(Int(UIApplication.shared.backgroundTimeRemaining))s)")
            UIApplication.shared.endBackgroundTask(cell.id)
        }
        return cell.id
    }
    static func end(_ id: UIBackgroundTaskIdentifier) {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
    }
}

/// Runs after every completed sync. Set by the app layer so this file stays
/// independent of the Health exporter and the background scheduler.
struct SyncHooks: Sendable {
    /// `report` is nil when the run did not complete.
    var afterSync: @Sendable (SyncTrigger, SyncReport?, SyncPolicy) async -> Void = { _, _, _ in }
    /// Called on every scene `.background` and after each run: (re)submit BG tasks.
    var schedule: @Sendable () -> Void = {}
}

actor SyncCoordinator {
    static let shared = SyncCoordinator()

    private struct Run {
        let trigger: SyncTrigger
        var session: RingSession?
        var transport: BLETransport?
        var deadlineTask: Task<Void, Never>?
        var cancelReason: SyncExit?
    }
    private var current: Run?
    var hooks = SyncHooks()

    private static let lastSuccessKey = "ring.last-successful-sync-at"
    private static let lastCursorKey = "ring.last-cursor"
    private static let syncIncompleteKey = "ring.sync-incomplete"
    static let automaticSyncCooldown: TimeInterval = 3 * 60
    private var lastAutomaticAttemptAt: Date?
    /// Set the moment a drain reports real progress, cleared only on a completed sync.
    private var markedIncompleteThisRun = false

    private init() {}

    func setHooks(_ h: SyncHooks) { hooks = h }

    var lastSuccessAt: Date? {
        let t = UserDefaults.standard.double(forKey: Self.lastSuccessKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    var hasIncompleteSync: Bool { UserDefaults.standard.bool(forKey: Self.syncIncompleteKey) }

    var isBusy: Bool { current != nil }

    /// A launch/foreground refresh behind a cooldown; eager when the last drain was
    /// interrupted mid-transfer (data is sitting half-pulled on the ring).
    func automaticSyncIfNeeded(now: Date = Date()) async -> SyncOutcome {
        guard current == nil else { return .skipped(.busy) }
        let resuming = hasIncompleteSync
        if !resuming, let ok = lastSuccessAt, now.timeIntervalSince(ok) < Self.automaticSyncCooldown {
            return .skipped(.cooldown)
        }
        if let attempted = lastAutomaticAttemptAt, now.timeIntervalSince(attempted) < 60 {
            return .skipped(.cooldown)
        }
        lastAutomaticAttemptAt = now
        return await sync(trigger: .foreground)
    }

    func scenePhaseChanged(_ phase: ScenePhase) async {
        switch phase {
        case .active:
            _ = await automaticSyncIfNeeded()
        case .background:
            hooks.schedule()
            RingCentral.shared.arm()
        default:
            break
        }
    }

    /// The armed connect fired, a restored session came back connected, or a parked
    /// ring spoke: sync over the link we already have.
    /// A ring on its charger reconnects within seconds of being released, and a
    /// worn ring never stops producing events, so "new data" alone cannot gate a
    /// wake. No ring-initiated sync starts this soon after a completed one.
    static let wakeCooldown: TimeInterval = 10 * 60

    func handleUnsolicitedConnect(_ peripheral: CBPeripheral) {
        guard current == nil else {
            dlog("sync", "unsolicited connect while busy — ignored")
            return
        }
        if let last = lastSuccessAt, Date().timeIntervalSince(last) < Self.wakeCooldown {
            dlog("sync", "ring reconnected \(Int(Date().timeIntervalSince(last))) s after a sync — waiting out the \(Int(Self.wakeCooldown / 60)) min cooldown")
            RingCentral.shared.settle(policy: SyncSettings.linkPolicy, holdOff: Self.wakeCooldown)
            return
        }
        let transport = RingCentral.shared.claim(peripheral, for: .bleRestore)
        Task { _ = await self.sync(trigger: .bleRestore, reuse: transport) }
    }

    /// Cancel the run in flight. `session.cancel()` returns within one poll; the
    /// transport abort is the backstop for a drain waiting out its quiet window.
    func cancelCurrent(reason: SyncExit) {
        guard var run = current else { return }
        dlog("sync", "cancelling (\(reason.rawValue))")
        run.cancelReason = reason
        current = run
        run.session?.cancel()
        let t = run.transport
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            t?.abort()
            RingCentral.shared.cancelInFlight()
        }
    }

    // ── the run ──

    func sync(trigger: SyncTrigger, reuse: BLETransport? = nil) async -> SyncOutcome {
        if current != nil {
            if let reuse { RingCentral.shared.release(reuse, policy: SyncSettings.linkPolicy) }
            return .skipped(.busy)
        }
        // Claim the slot before the first await. The actor is reentrant, so two
        // triggers that arrive together (bleRestore and foreground at launch) would
        // otherwise both pass the guard and drive the same link at once.
        current = Run(trigger: trigger, session: nil, transport: reuse, deadlineTask: nil, cancelReason: nil)
        let policy = SyncPolicy.policy(for: trigger)
        var metrics = SyncMetrics(trigger: trigger, startedAt: Date())
        metrics.cursorBefore = UInt32(clamping: UserDefaults.standard.integer(forKey: Self.lastCursorKey))
        metrics.appState = await MainActor.run { Self.appStateName(UIApplication.shared.applicationState) }
        metrics.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        metrics.availableMemMB = Int(os_proc_available_memory() / 1_048_576)
        metrics.batteryPct = await MainActor.run {
            UIDevice.current.isBatteryMonitoringEnabled = true
            let level = UIDevice.current.batteryLevel
            return level < 0 ? -1 : Int(level * 100)
        }

        guard let key = Keychain.loadKey() else {
            metrics.exit = PairedRingStore.load() == nil ? .notPaired : .noKey
            metrics.detail = "no auth key in the Keychain (locked phone before first unlock, or not paired)"
            if let reuse { RingCentral.shared.release(reuse, policy: SyncSettings.linkPolicy) }
            current = nil
            record(metrics)
            return .skipped(metrics.exit)
        }
        metrics.keyReadable = true

        markedIncompleteThisRun = false
        RingDiag.shared.clear()
        dlog("sync", "run trigger=\(trigger.rawValue) app=\(metrics.appState) lowPower=\(metrics.lowPower) mem=\(metrics.availableMemMB)MB")
        await RingSync.shared.begin(trigger: trigger)
        if policy.idleLock { await MainActor.run { IdleTimerLock.acquire("ring-sync") } }
        let keepAlive = await MainActor.run { KeepAlive.begin("ring-sync-\(trigger.rawValue)") }

        if let deadline = policy.deadline {
            current?.deadlineTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(1, deadline - 6)) * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.cancelCurrent(reason: .deadline)
            }
        }

        var outcome: SyncOutcome = .failed(.connectFailed, "no attempt made")
        var transport: BLETransport? = reuse
        let started = Date()
        for attempt in 1...max(1, policy.attempts) {
            metrics.attempts = attempt
            if let reason = current?.cancelReason {
                outcome = .partial(reason)
                break
            }
            if attempt > 1 {
                dlog("sync", "attempt \(attempt)/\(policy.attempts) — resuming from the checkpointed cursor in 3 s")
                await RingSync.shared.set(status: "connection lost — resuming (attempt \(attempt)/\(policy.attempts))…")
                if policy.deadline == nil { try? await Task.sleep(nanoseconds: 3_000_000_000) }
            }

            // 1. a link
            let connectStart = Date()
            if transport == nil {
                await RingSync.shared.set(status: attempt == 1 ? "connecting to ring…" : "reconnecting to ring…")
                do {
                    transport = try await acquireLink(policy, trigger: trigger)
                } catch {
                    dlog("sync", "BLE connect FAILED: \(error)")
                    let exit: SyncExit = (error as? BLEError).map { e -> SyncExit in
                        if case .poweredOff = e { return .bluetoothOff }
                        return .connectFailed
                    } ?? .connectFailed
                    outcome = .failed(exit, "\(error)")
                    if exit == .bluetoothOff { break }
                    continue
                }
            }
            guard let t = transport else { continue }
            current?.transport = t
            do {
                try await t.prepare()
            } catch {
                dlog("sync", "link prepare FAILED: \(error)")
                RingCentral.shared.release(t, policy: .release)
                transport = nil
                outcome = .failed(.connectFailed, "\(error)")
                continue
            }
            metrics.connectMs = Int(Date().timeIntervalSince(connectStart) * 1000)

            // 2. the Rust session over it
            let s = RingSession(writer: RingWriter(t))
            current?.session = s
            let pump = Task { for await frame in t.notifications { s.pushFrame(data: frame) } }
            await RingSync.shared.set(status: "syncing…")
            dlog("sync", "starting FFI sync — authenticate, app stream, then event drain (batch=\(policy.batchEvents == 0 ? 4096 : Int(policy.batchEvents)))")
            let drainStart = Date()
            do {
                let progress = SyncProgressBridge { [weak self] stage, bytesLeft, events in
                    RingSync.shared.showProgress(stage: stage, bytesLeft: bytesLeft, events: events)
                    if events > 0 { Task { await self?.markIncomplete() } }
                }
                let report = try await s.syncWith(dbPath: DB.url.path, keyHex: key,
                                                  options: SyncOptions(batchEvents: policy.batchEvents),
                                                  progress: progress)
                pump.cancel()
                metrics.drainMs = Int(Date().timeIntervalSince(drainStart) * 1000)
                metrics.events = report.eventsSynced
                metrics.inserted = report.inserted
                metrics.cursorAfter = report.nextCursor
                UserDefaults.standard.set(Int(report.nextCursor), forKey: Self.lastCursorKey)
                metrics.exit = .completed
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastSuccessKey)
                UserDefaults.standard.removeObject(forKey: Self.syncIncompleteKey)
                dlog("sync", "OK — serial=\(report.serial) inserted=\(report.inserted) events=\(report.eventsSynced) cursor=\(report.nextCursor)")
                await RingSync.shared.set(status: "synced — \(report.inserted) new events from \(report.serial)")
                outcome = .synced(report)
                break
            } catch {
                pump.cancel()
                metrics.drainMs = Int(Date().timeIntervalSince(drainStart) * 1000)
                dlog("sync", "attempt \(attempt) FAILED: \(error)")
                if let syncError = error as? SyncError, case .Cancelled = syncError {
                    outcome = .partial(current?.cancelReason ?? .cancelled)
                    break
                }
                if Self.isAuthenticationFailure(error) {
                    await RingSync.shared.set(status: "auth failed — this ring rejected the saved key. Factory-reset the ring and pair it again in Settings.")
                    dlog("sync", "not retrying: auth rejection is deterministic")
                    UserDefaults.standard.removeObject(forKey: Self.syncIncompleteKey)
                    outcome = .failed(.authRejected, "\(error)")
                    break
                }
                await RingSync.shared.set(status: "sync interrupted: \(error)")
                outcome = .failed(.linkLost, "\(error)")
                // release the (possibly half-dead) link before retrying
                RingCentral.shared.release(t, policy: .release)
                transport = nil
                if let deadline = policy.deadline, Date().timeIntervalSince(started) > deadline { break }
            }
        }

        // 3. wrap up
        current?.deadlineTask?.cancel()
        switch outcome {
        case .synced: break
        case .partial(let exit): metrics.exit = exit
        case .failed(let exit, let detail): metrics.exit = exit; metrics.detail = detail
        case .skipped(let exit): metrics.exit = exit
        }
        if case .synced = outcome {} else {
            await RingSync.shared.finishFailure(trigger: trigger, outcome: outcome, attempts: policy.attempts)
        }
        await hooks.afterSync(trigger, outcome.report, policy)
        if let t = transport {
            // With the release policy the ring reconnects the moment we drop it, so
            // the re-arm waits; a parked link needs no hold-off (wakes are gated by
            // `wakeCooldown`).
            let holdOff: TimeInterval = SyncSettings.linkPolicy == .release ? 15 * 60 : 0
            RingCentral.shared.release(t, policy: SyncSettings.linkPolicy, holdOff: holdOff)
        } else {
            RingCentral.shared.arm()
        }
        hooks.schedule()
        if policy.idleLock { await MainActor.run { IdleTimerLock.release("ring-sync") } }
        await MainActor.run { KeepAlive.end(keepAlive) }
        record(metrics)
        await RingSync.shared.end(outcome: outcome)
        current = nil
        return outcome
    }

    private func markIncomplete() {
        guard !markedIncompleteThisRun else { return }
        markedIncompleteThisRun = true
        UserDefaults.standard.set(true, forKey: Self.syncIncompleteKey)
    }

    private func record(_ metrics: SyncMetrics) {
        var m = metrics
        // A run that never reached a report leaves the cursor where it was.
        if m.cursorAfter == 0 { m.cursorAfter = m.cursorBefore }
        dlog("sync-metrics", m.line)
        let all = SyncHistoryStore.append(m)
        Task { await RingSync.shared.set(history: all) }
    }

    private static func isAuthenticationFailure(_ error: Error) -> Bool {
        let s = String(describing: error).lowercased()
        return s.contains("authentication failed") || s.contains("ring rejected auth")
    }

    private static func appStateName(_ s: UIApplication.State) -> String {
        switch s {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "?"
        }
    }

    /// Find and GATT-connect the ring per the policy, then claim it.
    private func acquireLink(_ policy: SyncPolicy, trigger: SyncTrigger) async throws -> BLETransport {
        let central = RingCentral.shared
        try await central.waitPoweredOn()
        // A parked link needs no connect at all.
        if let parked = central.parkedPeripheral, parked.state == .connected {
            dlog("sync", "using the parked link")
            return central.claim(parked, for: trigger)
        }
        if let held = central.systemConnectedRing() {
            dlog("sync", "another app on this phone holds the ring (\(held.identifier.uuidString.suffix(12)))")
            await RingSync.shared.set(otherAppHoldsRing: true)
            throw BLEError.busy
        }
        await RingSync.shared.set(otherAppHoldsRing: false)
        // The armed wait (pending connect + filtered scan) must not race the connect
        // below; `release` arms again after the run.
        if central.isArmed { central.disarm() }
        let peripheral: CBPeripheral
        switch policy.connect {
        case .reuse, .known:
            guard let p = central.pairedPeripheral() else { throw BLEError.notFound }
            try await central.connect(p, timeout: policy.connectTimeout)
            peripheral = p
        case .knownThenScan(let scanTimeout, let mode):
            if let p = central.pairedPeripheral() {
                do {
                    // The ring rotates its address, so the known identifier is often
                    // stale: give it a short try, then scan.
                    try await central.connect(p, timeout: min(policy.connectTimeout, 6))
                    peripheral = p
                    break
                } catch {
                    dlog("sync", "known ring did not connect (\(error)) — scanning")
                }
            }
            let found = try await central.scanForRing(timeout: scanTimeout, mode: mode)
            try await central.connect(found, timeout: policy.connectTimeout)
            Self.noteIdentifier(of: found)
            peripheral = found
        case .scan(let timeout):
            let found = try await central.scanForRing(timeout: timeout, mode: .foreground)
            try await central.connect(found, timeout: policy.connectTimeout)
            Self.noteIdentifier(of: found)
            peripheral = found
        }
        return central.claim(peripheral, for: trigger)
    }

    /// A scan found the ring under a rotated address: remember it so the next
    /// known-identifier connect and the armed connect target the right one.
    private static func noteIdentifier(of peripheral: CBPeripheral) {
        guard let ring = PairedRingStore.load(), ring.peripheralID != peripheral.identifier else { return }
        PairedRingStore.updatePeripheralID(peripheral.identifier)
        dlog("sync", "ring found under a new identifier \(peripheral.identifier.uuidString.suffix(12)) — saved")
    }
}
