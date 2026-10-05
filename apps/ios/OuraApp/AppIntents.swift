import AppIntents
import Foundation

// Siri and Shortcuts. Each intent answers from the snapshot that the app wrote after
// the last summary, so an answer needs no Bluetooth and no open app.

private func noData() -> String {
    "Open Oura has no data yet. Open the app to sync your ring."
}

struct ReadinessIntent: AppIntent {
    static let title: LocalizedStringResource = "Readiness Score"
    static let description = IntentDescription("Says your readiness score and what it means for the day.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Int> {
        guard let snap = SnapshotStore.load(), let score = snap.readiness else {
            return .result(value: 0, dialog: IntentDialog(stringLiteral: noData()))
        }
        var text = "Your readiness is \(score), \(Snapshot.band(score))."
        if !snap.isRecent { text = "Your last readiness, from \(snap.dayText), is \(score)." }
        if let hrv = snap.hrv { text += " HRV \(hrv) milliseconds." }
        return .result(value: score, dialog: IntentDialog(stringLiteral: text))
    }
}

struct SleepScoreIntent: AppIntent {
    static let title: LocalizedStringResource = "Sleep Score"
    static let description = IntentDescription("Says your sleep score and your time in bed.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Int> {
        guard let snap = SnapshotStore.load(), let score = snap.sleep else {
            return .result(value: 0, dialog: IntentDialog(stringLiteral: noData()))
        }
        var text = snap.isRecent ? "Your sleep score is \(score), \(Snapshot.band(score))."
            : "Your last sleep score, from \(snap.dayText), is \(score)."
        if let hours = snap.inBedHours {
            let minutes = Int((hours * 60).rounded())
            text += " You were in bed for \(minutes / 60) hours and \(minutes % 60) minutes."
        }
        return .result(value: score, dialog: IntentDialog(stringLiteral: text))
    }
}

struct RingBatteryIntent: AppIntent {
    static let title: LocalizedStringResource = "Ring Battery"
    static let description = IntentDescription("Says the battery level of your ring at the last sync.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Int> {
        guard let snap = SnapshotStore.load(), let pct = snap.batteryPct else {
            return .result(value: 0, dialog: IntentDialog(stringLiteral: noData()))
        }
        var text = "Your ring was at \(pct) percent at the last sync."
        if let days = snap.batteryDaysLeft {
            text += days < 1 ? " It has less than a day left." : " It has about \(Int(days.rounded())) days left."
        }
        return .result(value: pct, dialog: IntentDialog(stringLiteral: text))
    }
}

struct OuraShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ReadinessIntent(),
                    phrases: ["What is my readiness in \(.applicationName)",
                              "\(.applicationName) readiness"],
                    shortTitle: "Readiness", systemImageName: "bolt.heart.fill")
        AppShortcut(intent: SleepScoreIntent(),
                    phrases: ["How did I sleep in \(.applicationName)",
                              "\(.applicationName) sleep score"],
                    shortTitle: "Sleep Score", systemImageName: "bed.double.fill")
        AppShortcut(intent: RingBatteryIntent(),
                    phrases: ["What is my ring battery in \(.applicationName)",
                              "\(.applicationName) ring battery"],
                    shortTitle: "Ring Battery", systemImageName: "battery.75percent")
    }
}
