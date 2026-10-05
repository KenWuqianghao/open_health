import Foundation
import UserNotifications

// Local notifications. The app has no server, so every notification is decided on
// this iPhone: at once when a sync brought news, or as a scheduled notification that
// iOS shows while the app does not run (a sync that is overdue, the bedtime reminder,
// the estimated time of a low battery).

enum NotificationKind: String, CaseIterable, Identifiable {
    case lowBattery, staleSync, scoresReady, symptomRadar, bedtime
    var id: String { rawValue }

    var title: String {
        switch self {
        case .lowBattery: return "Ring battery is low"
        case .staleSync: return "No sync for a day"
        case .scoresReady: return "Morning scores are ready"
        case .symptomRadar: return "Symptom Radar changes"
        case .bedtime: return "Bedtime reminder"
        }
    }
    var detail: String {
        switch self {
        case .lowBattery: return "At 20 percent, and at the estimated time when the app could not sync."
        case .staleSync: return "When the ring has not synced for 24 hours."
        case .scoresReady: return "After the first sync of the morning."
        case .symptomRadar: return "When your vital signs leave or return to your usual range."
        case .bedtime: return "30 minutes before your ideal bedtime window."
        }
    }
    fileprivate var key: String { "notify.\(rawValue)" }
}

enum NotifierSettings {
    private static let d = UserDefaults.standard
    static func isOn(_ kind: NotificationKind) -> Bool { d.bool(forKey: kind.key) }
    static func set(_ kind: NotificationKind, _ on: Bool) { d.set(on, forKey: kind.key) }
    static var anyOn: Bool { NotificationKind.allCases.contains(where: isOn) }
}

/// What the notifier remembers between runs, so one event gives one notification.
struct NotifierState: Codable, Equatable {
    var lowBatteryNotified = false
    var scoresDay: String?
    var radarStatus: String?
}

/// What to send now and what to schedule, from one summary. No side effects, so
/// the rules can be tested without the notification center.
struct NotificationPlan: Equatable {
    struct Message: Equatable {
        var id: String
        var title: String
        var body: String
    }
    var now: [Message] = []
    /// A message with the time iOS shows it.
    var scheduled: [(message: Message, at: Date)] = []
    /// A message that repeats each day at hour:minute.
    var daily: [(message: Message, hour: Int, minute: Int)] = []
    var state: NotifierState

    static func == (a: NotificationPlan, b: NotificationPlan) -> Bool {
        a.now == b.now && a.state == b.state
            && a.scheduled.map(\.message) == b.scheduled.map(\.message)
            && a.scheduled.map(\.at) == b.scheduled.map(\.at)
            && a.daily.map(\.message) == b.daily.map(\.message)
            && a.daily.map(\.hour) == b.daily.map(\.hour)
            && a.daily.map(\.minute) == b.daily.map(\.minute)
    }
}

enum NotificationRules {
    static let lowBatteryPct = 20
    static let batteryResetPct = 30
    static let staleAfter: TimeInterval = 24 * 3600

    static func plan(summary s: Summary, state: NotifierState, lastSync: Date?, now: Date,
                     isOn: (NotificationKind) -> Bool) -> NotificationPlan {
        var plan = NotificationPlan(state: state)
        let today = localDay(now)

        // low battery: once per discharge, and at the estimated time of 20 %
        if isOn(.lowBattery), let pct = s.device?.battery_pct {
            let battery = s.device?.battery?.value
            let charging = battery?.charging ?? false
            if pct > batteryResetPct || charging { plan.state.lowBatteryNotified = false }
            if pct <= lowBatteryPct, !charging, !plan.state.lowBatteryNotified {
                let days = battery?.days_left.map { $0 < 1 ? "less than a day" : "about \(Int($0.rounded())) day\(Int($0.rounded()) == 1 ? "" : "s")" }
                plan.now.append(.init(id: "battery-low", title: "Ring battery at \(pct)%",
                                      body: days.map { "It has \($0) left. Put the ring on its charger soon." }
                                          ?? "Put the ring on its charger soon."))
                plan.state.lowBatteryNotified = true
            } else if pct > lowBatteryPct, !charging, let rate = battery?.rate_pct_per_day, rate > 0,
                      let at = battery?.latest?.t {
                let seconds = Double(pct - lowBatteryPct) / rate * 86_400
                let due = Date(timeIntervalSince1970: at).addingTimeInterval(seconds)
                if due > now.addingTimeInterval(3600) {
                    plan.scheduled.append((.init(id: "battery-estimate", title: "Ring battery is probably low",
                                                 body: "At the usual rate the ring is near \(lowBatteryPct)% now. Open the app to sync and see the level."), due))
                }
            }
        }

        // the scores of this morning, once per day
        if isOn(.scoresReady), let readiness = s.scores?.days[today]?.readiness, plan.state.scoresDay != today {
            let sleep = s.scores?.days[today]?.sleep.map { " Sleep score \(Int($0.score.rounded()))." } ?? ""
            let score = Int(readiness.score.rounded())
            plan.now.append(.init(id: "scores-\(today)", title: "Readiness \(score), \(Snapshot.band(score))",
                                  body: (s.highlight(for: today) ?? "Your morning scores are ready.") + sleep))
            plan.state.scoresDay = today
        }

        // Symptom Radar: a change of status, for a check of last night
        if isOn(.symptomRadar), let radar = s.shownIllness?.result, radar.available {
            let status = radar.trafficLight
            if let before = plan.state.radarStatus, before != status {
                let flagged = radar.biomarkers.filter(\.indicatesSymptoms).map { Self.biomarkerName($0.type) }
                switch status {
                case "MAJOR_SIGNS", "MINOR_SIGNS":
                    plan.now.append(.init(id: "radar", title: status == "MAJOR_SIGNS" ? "Symptom Radar: major signs" : "Symptom Radar: minor signs",
                                          body: flagged.isEmpty ? "Some of your vital signs are outside your usual range. An easy day can help."
                                              : "\(flagged.joined(separator: ", ")) \(flagged.count == 1 ? "is" : "are") outside your usual range. An easy day can help."))
                default:
                    plan.now.append(.init(id: "radar", title: "Symptom Radar: back to usual",
                                          body: "Your vital signs are in your usual range again."))
                }
            }
            plan.state.radarStatus = status
        }

        // a sync that is overdue
        if isOn(.staleSync), let lastSync {
            let due = lastSync.addingTimeInterval(staleAfter)
            plan.scheduled.append((.init(id: "stale-sync", title: "Your ring did not sync for a day",
                                         body: "Open the app with the ring near the iPhone. The ring keeps about a week of data."),
                                   max(due, now.addingTimeInterval(60))))
        }

        // the bedtime reminder, 30 minutes before the window
        if isOn(.bedtime), let bed = s.guidance?.value?.bedtime {
            let minute = (Int(bed.start_min) - 30 + 1440) % 1440
            plan.daily.append((.init(id: "bedtime", title: "Time to wind down",
                                     body: "Your ideal bedtime is \(Fmt.clock(bed.start)) to \(Fmt.clock(bed.end))."),
                               minute / 60, minute % 60))
        }
        return plan
    }

    static func biomarkerName(_ type: String) -> String {
        switch type {
        case "AverageBreath": return "Breathing rate"
        case "LowestHeartRate": return "Resting heart rate"
        case "AverageHrv": return "HRV"
        case "TemperatureDeviation": return "Body temperature"
        default: return type
        }
    }

    static func localDay(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = Notifier()
    private static let stateKey = "notify.state"
    private let center = UNUserNotificationCenter.current()
    private let queue = DispatchQueue(label: "md.thomas.openoura.notifier")

    /// Call before launch ends, so a tap on a notification reaches the app.
    func install() {
        center.delegate = self
    }

    /// Ask for permission. Returns false when the user said no (now or before).
    func requestPermission() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied: return false
        default: return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        }
    }

    func isDenied() async -> Bool {
        await center.notificationSettings().authorizationStatus == .denied
    }

    private var state: NotifierState {
        get {
            UserDefaults.standard.data(forKey: Self.stateKey)
                .flatMap { try? JSONDecoder().decode(NotifierState.self, from: $0) } ?? NotifierState()
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: Self.stateKey)
            }
        }
    }

    /// Decide and deliver for one summary. Safe to call after every load.
    func evaluate(_ summary: Summary) {
        guard summary.error == nil, NotifierSettings.anyOn else {
            if !NotifierSettings.anyOn { center.removeAllPendingNotificationRequests() }
            return
        }
        let lastSync = UserDefaults.standard.double(forKey: "ring.last-successful-sync-at")
        queue.async {
            let plan = NotificationRules.plan(
                summary: summary, state: self.state,
                lastSync: lastSync > 0 ? Date(timeIntervalSince1970: lastSync) : nil,
                now: Date(), isOn: NotifierSettings.isOn)
            self.state = plan.state
            self.deliver(plan)
        }
    }

    /// A setting changed: drop what is scheduled for kinds that are off now.
    func settingsChanged(summary: Summary?) {
        var stale: [String] = []
        if !NotifierSettings.isOn(.staleSync) { stale.append("stale-sync") }
        if !NotifierSettings.isOn(.bedtime) { stale.append("bedtime") }
        if !NotifierSettings.isOn(.lowBattery) { stale.append("battery-estimate") }
        center.removePendingNotificationRequests(withIdentifiers: stale)
        if let summary { evaluate(summary) }
    }

    private func deliver(_ plan: NotificationPlan) {
        func content(_ m: NotificationPlan.Message) -> UNMutableNotificationContent {
            let c = UNMutableNotificationContent()
            c.title = m.title
            c.body = m.body
            c.sound = .default
            c.threadIdentifier = m.id
            return c
        }
        for m in plan.now {
            center.add(UNNotificationRequest(identifier: m.id, content: content(m), trigger: nil))
        }
        // a request with the id of a pending one replaces it
        center.removePendingNotificationRequests(withIdentifiers: ["battery-estimate"])
        for (m, at) in plan.scheduled {
            let seconds = max(60, at.timeIntervalSinceNow)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
            center.add(UNNotificationRequest(identifier: m.id, content: content(m), trigger: trigger))
        }
        for (m, hour, minute) in plan.daily {
            var when = DateComponents()
            when.hour = hour
            when.minute = minute
            let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: true)
            center.add(UNNotificationRequest(identifier: m.id, content: content(m), trigger: trigger))
        }
    }

    // show a notification also while the app is open
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
