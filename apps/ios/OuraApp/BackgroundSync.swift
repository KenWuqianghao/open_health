import BackgroundTasks
import Foundation

/// The two scheduled wakes: a light refresh (~25 s budget: sync only, small
/// batches) and a processing task (minutes: full sync, summary, Health export, and
/// the on-device models when the device is healthy). Both are registered before
/// the app finishes launching and re-submitted after every run, so a kill or an
/// expiry never breaks the chain. iOS decides when they actually run.
enum BGSync {
    static let refreshID = "md.thomas.openoura.sync.refresh"
    static let processingID = "md.thomas.openoura.sync.processing"
    private static let completed = NSLock()

    static func register() {
        let ok1 = BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshID, using: nil) { task in
            handle(task, trigger: .bgRefresh)
        }
        let ok2 = BGTaskScheduler.shared.register(forTaskWithIdentifier: processingID, using: nil) { task in
            handle(task, trigger: .bgProcessing)
        }
        dlog("bg", "bg-tasks registered: refresh=\(ok1) processing=\(ok2)")
    }

    static func scheduleRefresh(after: TimeInterval = 2 * 3600) {
        let req = BGAppRefreshTaskRequest(identifier: refreshID)
        req.earliestBeginDate = Date(timeIntervalSinceNow: after)
        submit(req)
    }

    static func scheduleProcessing(earliest: Date = nextLocalTime(hour: 2)) {
        let req = BGProcessingTaskRequest(identifier: processingID)
        req.earliestBeginDate = earliest
        req.requiresExternalPower = false
        req.requiresNetworkConnectivity = false
        submit(req)
    }

    static func scheduleAll() {
        guard PairedRingStore.load() != nil else { return }
        scheduleRefresh()
        scheduleProcessing()
    }

    private static func submit(_ req: BGTaskRequest) {
        do {
            try BGTaskScheduler.shared.submit(req)
        } catch {
            // .notPermitted = plist mismatch; .unavailable = Background App Refresh
            // off or Low Power Mode; .tooManyPendingTaskRequests = already queued.
            dlog("bg", "submit \(req.identifier) failed: \(error)")
        }
    }

    private static func handle(_ task: BGTask, trigger: SyncTrigger) {
        // 1. re-submit first: a kill or an expiry must not break the chain.
        scheduleAll()
        dlog("bg", "task \(task.identifier) started (\(trigger.rawValue))")
        var done = false
        let finish: (Bool) -> Void = { success in
            completed.lock(); defer { completed.unlock() }
            guard !done else { return }
            done = true
            // Always success: a failed run is retried by the cursor, and failure
            // signals only make iOS throttle our budget.
            task.setTaskCompleted(success: true)
            dlog("bg", "task \(task.identifier) completed (reported success=\(true), ran ok=\(success))")
        }
        let run = Task {
            let outcome = await SyncCoordinator.shared.sync(trigger: trigger)
            if case .synced = outcome { finish(true) } else { finish(false) }
        }
        task.expirationHandler = {
            dlog("bg", "task \(task.identifier) EXPIRED — cancelling the sync")
            Task {
                await SyncCoordinator.shared.cancelCurrent(reason: .osExpired)
                // give the cancel a moment to land, then hand the task back
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                run.cancel()
                finish(false)
            }
        }
    }

    static func nextLocalTime(hour: Int) -> Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: Date())
        comps.hour = hour
        comps.minute = 0
        let today = cal.date(from: comps) ?? Date()
        return today > Date() ? today : cal.date(byAdding: .day, value: 1, to: today) ?? today
    }
}
