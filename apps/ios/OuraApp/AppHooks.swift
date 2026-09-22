import Foundation

/// Wires the app layer into the sync engine: what runs after a sync (summary cache,
/// Health export, models on a generous budget) and what schedules the background
/// tasks. Installed once from `AppDelegate`.
enum AppHooks {
    static func install() {
        Task {
            await SyncCoordinator.shared.setHooks(SyncHooks(
                afterSync: { trigger, report, policy in
                    await afterSync(trigger: trigger, report: report, policy: policy)
                },
                schedule: { BGSync.scheduleAll() }
            ))
        }
    }

    /// Post-sync work. Runs on whatever task the coordinator is on (never the main
    /// thread for the heavy parts).
    private static func afterSync(trigger: SyncTrigger, report: SyncReport?, policy: SyncPolicy) async {
        // 1. File protection: the DB must stay readable after the first unlock so a
        //    background sync on a locked phone can write to it.
        for name in ["oura.db", "oura.db-wal", "oura.db-shm", "summary-cache.json", "health-export-state.json"] {
            let url = DB.url.deletingLastPathComponent().appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        }
        guard let report, report.inserted > 0 || trigger == .postPair else {
            // Nothing new on the ring: the Health export may still have a tail to
            // rewrite (a day that just became final).
            if policy.exportHealth { await HealthExporter.shared.run(.backgroundSync) }
            return
        }
        // 2. The summary cache, so a widget-less relaunch shows fresh numbers and the
        //    exporter has stages/workouts to match. Skipped when the budget is short.
        var summary: Summary?
        var rawJson: String?
        // The last summary that carries model results, for the hub push below.
        let previousFull = SummaryCache.load()
        if policy.refreshSummary {
            let started = Date()
            let built = Core.baseWithJson()
            SyncSettings.lastSummaryBuildSeconds = Date().timeIntervalSince(started)
            if built.summary.error == nil {
                SummaryCache.save(built.summary)
                summary = built.summary
                rawJson = built.json
            }
            dlog("hooks", "summary rebuilt in \(String(format: "%.1f", SyncSettings.lastSummaryBuildSeconds))s")
        }
        // 3. Apple Health: only the recent tail; defers itself when the phone is locked.
        if policy.exportHealth {
            await HealthExporter.shared.run(trigger == .manual || trigger == .postPair ? .sync : .backgroundSync,
                                            summary: summary)
        }
        // 4. The hub: the summary (last model results folded in) and the new raw rows.
        //    A refresh task has about 22 s in all; the deadline keeps the push inside it.
        await HubPusher.shared.pushAll(rawJson: rawJson, models: previousFull ?? summary, reason: trigger.rawValue,
                                       deadline: trigger == .bgRefresh ? 8 : 40)
        // 5. Models: only with a generous budget and a healthy device. The foreground
        //    path runs them from RootView.load instead.
        #if TORCH
        if policy.runModels, trigger == .bgProcessing, let base = summary, modelGate() {
            let full = Core.withModels(base, previous: previousFull)
            SummaryCache.save(full)
            await HealthExporter.shared.run(.modelsUpdated, summary: full)
            if let rawJson {
                await HubPusher.shared.pushSummary(rawJson: rawJson, models: full, reason: "models", timeout: 20)
            }
        }
        #endif
    }

    #if TORCH
    private static func modelGate() -> Bool {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return false }
        if os_proc_available_memory() < 600 * 1_048_576 { return false }
        return true
    }
    #endif
}
