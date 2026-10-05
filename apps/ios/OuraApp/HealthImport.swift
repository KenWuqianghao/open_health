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
    var vo2max: Double?
    var error: String?
}

@MainActor
final class HealthImport: ObservableObject {
    static let shared = HealthImport()
    private static let enabledKey = "health.import-workouts"
    private static let hashKey = "health.import-hash"
    static let lookBackDays = 120

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
         HKQuantityType(.distanceWalkingRunning), HKQuantityType(.distanceCycling), HKQuantityType(.distanceSwimming)]
    }

    func setEnabled(_ on: Bool) async {
        if on {
            guard HKHealthStore.isHealthDataAvailable() else {
                status.error = "Apple Health is not available on this device."
                return
            }
            do {
                try await store.requestAuthorization(toShare: [], read: Self.readTypes)
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
            let payload = Self.payload(workouts: workouts, vo2max: vo2)
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            status = HealthImportStatus(lastRunAt: Date(), workouts: workouts.count, vo2max: vo2?.value, error: nil)
            guard hash != UserDefaults.standard.string(forKey: Self.hashKey) else { return false }
            try externalWrite(dbPath: DB.url.path, json: String(decoding: data, as: UTF8.self))
            UserDefaults.standard.set(hash, forKey: Self.hashKey)
            dlog("health-import", "wrote \(workouts.count) workout(s), vo2max=\(vo2?.value ?? 0)")
            return true
        } catch {
            status.error = error.localizedDescription
            dlog("health-import", "FAILED: \(error)")
            return false
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

    /// The JSON of `oura_summary::external::External`.
    nonisolated static func payload(workouts: [ImportedWorkout], vo2max: ImportedValue?) -> [String: Any] {
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
        if let vo2max {
            out["vo2max"] = ["value": (vo2max.value * 10).rounded() / 10,
                             "at_unix": Int(vo2max.at.timeIntervalSince1970.rounded()),
                             "source": vo2max.source]
        }
        return out
    }

    /// "traditional_strength_training" → "Strength training".
    nonisolated static func label(_ type: HKWorkoutActivityType) -> String {
        let raw = HealthSampleEncoder.activityName(type).replacingOccurrences(of: "_", with: " ")
        let short = raw.replacingOccurrences(of: "traditional ", with: "")
        return short.prefix(1).uppercased() + short.dropFirst()
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
