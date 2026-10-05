import Foundation
import WidgetKit

/// Builds the widget snapshot from a summary and tells WidgetKit to draw again.
enum SnapshotWriter {
    static func snapshot(from s: Summary) -> Snapshot? {
        guard s.error == nil, let day = s.days.first else { return nil }
        let score = { (kind: ScoreKind) in s.latestScore(kind, upTo: day) }
        let readiness = score(.readiness)
        let night = s.night(forDay: day)
        let battery = s.device?.battery?.value
        var out = Snapshot()
        out.day = readiness?.day ?? day
        out.readiness = readiness.map { Int($0.score.score.rounded()) }
        out.sleep = score(.sleep).map { Int($0.score.score.rounded()) }
        out.activity = score(.activity).map { Int($0.score.score.rounded()) }
        out.provisional = readiness?.score.provisional ?? false
        out.hrv = s.vitals.hrv.latest.map { Int($0.rounded()) }
        out.restingHR = s.vitals.rhr.latest.map { Int($0.rounded()) }
        out.inBedHours = night?.in_bed_h
        out.steps = s.activity_daily[day]?.steps.map { Int($0.rounded()) }
        out.batteryPct = s.device?.battery_pct
        out.batteryDaysLeft = battery?.days_left
        out.bedtimeStart = s.guidance?.value?.bedtime?.start
        out.bedtimeEnd = s.guidance?.value?.bedtime?.end
        out.highlight = s.highlight(for: day)
        out.lastSync = UserDefaults.standard.double(forKey: "ring.last-successful-sync-at") > 0
            ? Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: "ring.last-successful-sync-at"))
            : nil
        return out
    }

    /// Write the snapshot when it changed. Safe to call from any thread.
    static func publish(_ s: Summary) {
        guard var next = snapshot(from: s) else {
            dlog("widgets", "no snapshot — the summary has \(s.error == nil ? "no days" : "an error")")
            return
        }
        if var previous = SnapshotStore.load() {
            previous.writtenAt = next.writtenAt
            if previous == next { return }
        }
        next.writtenAt = Date()
        if SnapshotStore.save(next) {
            dlog("widgets", "snapshot written for \(next.day ?? "no day")")
            WidgetCenter.shared.reloadAllTimelines()
        } else {
            let group = SnapshotStore.groupID ?? "none"
            let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
            dlog("widgets", "snapshot NOT written — group \(group), container \(container?.path ?? "not available")")
        }
    }
}
