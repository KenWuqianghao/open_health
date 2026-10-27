import Foundation
import HealthKit
import CryptoKit

// Apple Health → the summary. Workouts and the measured VO2 max that an Apple Watch
// or another app wrote go into `external.json` next to the database; the shared
// brain (oura-summary) joins them with the ring's data. Samples that this app wrote
// itself are left out, so the Health export and this import cannot feed each other.

struct HealthImportStatus: Equatable {
    var lastRunAt: Date?
    var workouts = 0
    var sleepStages = 0
    var vo2max: Double?
    var error: String?
}

@MainActor
final class HealthImport: ObservableObject {
    static let shared = HealthImport()
    private static let enabledKey = "health.import-workouts"
    private static let hashKey = "health.import-hash"
    private static let requestedKey = "health.import-requested-types"
    static let lookBackDays = 120
    static let sleepLookBackDays = 60

    @Published private(set) var enabled: Bool
    @Published private(set) var status = HealthImportStatus()
    private let store = HKHealthStore()
    private var running = false

    private init() {
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    private static var readTypes: Set<HKObjectType> {
        [HKObjectType.workoutType(),
         HKQuantityType(.vo2Max), HKQuantityType(.heartRate), HKQuantityType(.activeEnergyBurned),
         HKQuantityType(.distanceWalkingRunning), HKQuantityType(.distanceCycling), HKQuantityType(.distanceSwimming),
         HKCategoryType(.sleepAnalysis), HKQuantityType(.heartRateVariabilitySDNN)]
    }

    func setEnabled(_ on: Bool) async {
        if on {
            guard HKHealthStore.isHealthDataAvailable() else {
                status.error = "Apple Health is not available on this device."
                return
            }
            do {
                try await store.requestAuthorization(toShare: [], read: Self.readTypes)
                UserDefaults.standard.set(Self.readTypesKey, forKey: Self.requestedKey)
            } catch {
                status.error = error.localizedDescription
                return
            }
        }
        enabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on {
            _ = await run()
        } else {
            // the summary must not keep workouts that the user turned off
            try? externalWrite(dbPath: DB.url.path, json: "{}")
            UserDefaults.standard.removeObject(forKey: Self.hashKey)
            status = HealthImportStatus()
        }
    }

    /// Read Apple Health and write `external.json`. Returns true when the content
    /// changed, so the caller builds the summary again.
    @discardableResult
    func run() async -> Bool {
        guard enabled, !running, HKHealthStore.isHealthDataAvailable() else { return false }
        running = true
        defer { running = false }
        do {
            let workouts = try await readWorkouts()
            let vo2 = try await readVO2Max()
            let sleep = try await readSleep()
            let payload = Self.payload(workouts: workouts, vo2max: vo2, sleep: sleep)
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            status = HealthImportStatus(lastRunAt: Date(), workouts: workouts.count, sleepStages: sleep.stages.count,
                                        vo2max: vo2?.value, error: nil)
            guard hash != UserDefaults.standard.string(forKey: Self.hashKey) else { return false }
            try externalWrite(dbPath: DB.url.path, json: String(decoding: data, as: UTF8.self))
            UserDefaults.standard.set(hash, forKey: Self.hashKey)
            dlog("health-import", "wrote \(workouts.count) workout(s), \(sleep.stages.count) sleep stage(s), vo2max=\(vo2?.value ?? 0)")
            return true
        } catch {
            status.error = error.localizedDescription
            dlog("health-import", "FAILED: \(error)")
            return false
        }
    }

    private static var readTypesKey: String {
        readTypes.map(\.identifier).sorted().joined(separator: ",")
    }

    /// Without read access HealthKit returns no samples and no error.
    func requestNewTypesIfNeeded() async {
        guard enabled, UserDefaults.standard.string(forKey: Self.requestedKey) != Self.readTypesKey else { return }
        do {
            try await store.requestAuthorization(toShare: [], read: Self.readTypes)
            UserDefaults.standard.set(Self.readTypesKey, forKey: Self.requestedKey)
        } catch {
            dlog("health-import", "read access request failed: \(error.localizedDescription)")
        }
    }

    struct ImportedWorkout: Equatable {
        var id: String
        var start: Date
        var end: Date
        var label: String
        var activeKcal: Double?
        var distanceM: Double?
        var avgHR: Double?
        var maxHR: Double?
        var source: String
    }
    struct ImportedValue: Equatable {
        var value: Double
        var at: Date
        var source: String
    }
    struct ImportedSleep: Equatable {
        struct Stage: Equatable {
            var start: Date
            var end: Date
            var stage: String
        }
        struct Reading: Equatable {
            var at: Date
            var value: Double
        }
        var stages: [Stage] = []
        var hr: [Reading] = []
        var hrvSDNN: [Reading] = []
    }

    /// The JSON of `oura_summary::external::External`.
    nonisolated static func payload(workouts: [ImportedWorkout], vo2max: ImportedValue?,
                                    sleep: ImportedSleep) -> [String: Any] {
        let unix = { (d: Date) in Int(d.timeIntervalSince1970.rounded()) }
        let pairs = { (r: [ImportedSleep.Reading]) -> [[Any]] in
            r.map { [unix($0.at), ($0.value * 10).rounded() / 10] }
        }
        var out: [String: Any] = [
            "workouts": workouts.sorted { $0.start < $1.start }.map { w -> [String: Any] in
                var row: [String: Any] = [
                    "id": w.id,
                    "start_unix": Int(w.start.timeIntervalSince1970.rounded()),
                    "end_unix": Int(w.end.timeIntervalSince1970.rounded()),
                    "label": w.label,
                    "source": w.source,
                ]
                if let v = w.activeKcal { row["active_kcal"] = (v * 10).rounded() / 10 }
                if let v = w.distanceM { row["distance_m"] = v.rounded() }
                if let v = w.avgHR { row["avg_hr"] = v.rounded() }
                if let v = w.maxHR { row["max_hr"] = v.rounded() }
                return row
            },
        ]
        out["sleep"] = [
            "stages": sleep.stages.map { ["start_unix": unix($0.start), "end_unix": unix($0.end), "stage": $0.stage] },
            "hr": pairs(sleep.hr),
            "hrv_sdnn": pairs(sleep.hrvSDNN),
        ]
        if let vo2max {
            out["vo2max"] = ["value": (vo2max.value * 10).rounded() / 10,
                             "at_unix": Int(vo2max.at.timeIntervalSince1970.rounded()),
                             "source": vo2max.source]
        }
        return out
    }

    /// The display name of a workout type: `.paddleSports` → "Paddle sports".
    nonisolated static func label(_ type: HKWorkoutActivityType) -> String {
        let raw = HealthSampleEncoder.activityName(type).replacingOccurrences(of: "_", with: " ")
        if raw == "hiit" { return "HIIT" }
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }

    private func notOurs() -> NSPredicate {
        let ours = HKSource.default()
        return NSCompoundPredicate(notPredicateWithSubpredicate: HKQuery.predicateForObjects(from: ours))
    }

    private func readWorkouts() async throws -> [ImportedWorkout] {
        let since = Date().addingTimeInterval(-Double(Self.lookBackDays) * 86_400)
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: since, end: nil, options: .strictStartDate),
            notOurs(),
        ])
        let samples: [HKSample] = try await withCheckedThrowingContinuation { c in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let q = HKSampleQuery(sampleType: .workoutType(), predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, error in
                if let error { c.resume(throwing: error) } else { c.resume(returning: samples ?? []) }
            }
            store.execute(q)
        }
        return samples.compactMap { $0 as? HKWorkout }.map { w in
            let sum = { (id: HKQuantityTypeIdentifier, unit: HKUnit) -> Double? in
                w.statistics(for: HKQuantityType(id))?.sumQuantity()?.doubleValue(for: unit)
            }
            let bpm = HKUnit.count().unitDivided(by: .minute())
            let hr = w.statistics(for: HKQuantityType(.heartRate))
            let distance = sum(.distanceWalkingRunning, .meter()) ?? sum(.distanceCycling, .meter())
                ?? sum(.distanceSwimming, .meter())
            return ImportedWorkout(
                id: w.uuid.uuidString, start: w.startDate, end: w.endDate,
                label: Self.label(w.workoutActivityType),
                activeKcal: sum(.activeEnergyBurned, .kilocalorie()),
                distanceM: distance,
                avgHR: hr?.averageQuantity()?.doubleValue(for: bpm),
                maxHR: hr?.maximumQuantity()?.doubleValue(for: bpm),
                source: w.sourceRevision.source.name)
        }
    }

    nonisolated static func stageName(_ value: Int) -> String? {
        guard let stage = HKCategoryValueSleepAnalysis(rawValue: value) else { return nil }
        switch stage {
        case .asleepDeep: return "deep"
        case .asleepCore: return "core"
        case .asleepREM: return "rem"
        case .awake: return "awake"
        case .inBed, .asleepUnspecified: return nil
        @unknown default: return nil
        }
    }

    nonisolated static func fromWatch(_ sample: HKSample) -> Bool {
        sample.sourceRevision.productType?.hasPrefix("Watch") == true
    }

    nonisolated static let windowGap: TimeInterval = 3600

    nonisolated static func windows(_ stages: [ImportedSleep.Stage]) -> [DateInterval] {
        var out: [DateInterval] = []
        for s in stages.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, s.start.timeIntervalSince(last.end) <= windowGap {
                out[out.count - 1] = DateInterval(start: last.start, end: max(last.end, s.end))
            } else {
                out.append(DateInterval(start: s.start, end: s.end))
            }
        }
        return out
    }

    private func samples(_ type: HKSampleType, _ predicate: NSPredicate) async throws -> [HKSample] {
        let filter = NSCompoundPredicate(andPredicateWithSubpredicates: [predicate, notOurs()])
        return try await withCheckedThrowingContinuation { c in
            let q = HKSampleQuery(sampleType: type, predicate: filter, limit: HKObjectQueryNoLimit,
                                  sortDescriptors: nil) { _, samples, error in
                if let error { c.resume(throwing: error) } else { c.resume(returning: samples ?? []) }
            }
            store.execute(q)
        }
    }

    private func readings(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit,
                          during: NSPredicate) async throws -> [ImportedSleep.Reading] {
        try await samples(HKQuantityType(id), during)
            .compactMap { $0 as? HKQuantitySample }
            .filter(Self.fromWatch)
            .map { .init(at: $0.startDate, value: $0.quantity.doubleValue(for: unit)) }
            .sorted { $0.at < $1.at }
    }

    private func readSleep() async throws -> ImportedSleep {
        let since = Date().addingTimeInterval(-Double(Self.sleepLookBackDays) * 86_400)
        let stages = try await samples(HKCategoryType(.sleepAnalysis),
                                       HKQuery.predicateForSamples(withStart: since, end: nil, options: .strictStartDate))
            .compactMap { $0 as? HKCategorySample }
            .filter(Self.fromWatch)
            .compactMap { s in Self.stageName(s.value).map { ImportedSleep.Stage(start: s.startDate, end: s.endDate, stage: $0) } }
            .sorted { $0.start < $1.start }
        let windows = Self.windows(stages)
        guard !windows.isEmpty else { return ImportedSleep() }
        let during = NSCompoundPredicate(orPredicateWithSubpredicates: windows.map {
            HKQuery.predicateForSamples(withStart: $0.start, end: $0.end, options: .strictStartDate)
        })
        return ImportedSleep(
            stages: stages,
            hr: try await readings(.heartRate, HKUnit.count().unitDivided(by: .minute()), during: during),
            hrvSDNN: try await readings(.heartRateVariabilitySDNN, .secondUnit(with: .milli), during: during))
    }

    private func readVO2Max() async throws -> ImportedValue? {
        let sample: HKQuantitySample? = try await withCheckedThrowingContinuation { c in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let q = HKSampleQuery(sampleType: HKQuantityType(.vo2Max), predicate: notOurs(), limit: 1,
                                  sortDescriptors: [sort]) { _, samples, error in
                if let error { c.resume(throwing: error) } else { c.resume(returning: samples?.first as? HKQuantitySample) }
            }
            store.execute(q)
        }
        guard let sample else { return nil }
        let unit = HKUnit(from: "ml/kg*min")
        return ImportedValue(value: sample.quantity.doubleValue(for: unit), at: sample.endDate,
                             source: sample.sourceRevision.source.name)
    }
}
