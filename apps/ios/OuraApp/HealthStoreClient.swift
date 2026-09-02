import Foundation
import HealthKit

/// The only seam that touches `HKHealthStore`, so the engine can be tested against a
/// fake. Deletes are scoped to OUR source (`HKSource.default()`) inside a window.
protocol HealthStoreClient: AnyObject, Sendable {
    var isAvailable: Bool { get }
    func requestShare(_ types: Set<HKSampleType>) async throws
    /// Delete our objects of `type` inside `window` (all of them when nil). Returns
    /// the number deleted. An empty window is not an error.
    func deleteOurObjects(of type: HKSampleType, in window: DateInterval?) async throws -> Int
    func save(_ objects: [HKObject]) async throws
    func saveWorkout(_ workout: PlannedWorkout, device: HKDevice?, metadata: [String: Any]) async throws
    func countOurObjects(of type: HKSampleType, in window: DateInterval) async throws -> Int
}

final class HKStoreClient: HealthStoreClient, @unchecked Sendable {
    private let store = HKHealthStore()

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestShare(_ types: Set<HKSampleType>) async throws {
        try await store.requestAuthorization(toShare: types, read: [])
    }

    private func predicate(_ window: DateInterval?) -> NSPredicate {
        let ours = HKQuery.predicateForObjects(from: HKSource.default())
        guard let window else { return ours }
        let range = HKQuery.predicateForSamples(withStart: window.start, end: window.end, options: [])
        return NSCompoundPredicate(andPredicateWithSubpredicates: [ours, range])
    }

    func deleteOurObjects(of type: HKSampleType, in window: DateInterval?) async throws -> Int {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int, Error>) in
            store.deleteObjects(of: type, predicate: predicate(window)) { _, count, error in
                if let error {
                    // Nothing to delete is fine: HealthKit reports an error for an empty
                    // match on some versions; a missing-permission error is real.
                    if (error as NSError).code == HKError.Code.errorInvalidArgument.rawValue, count == 0 {
                        c.resume(returning: 0)
                    } else {
                        c.resume(throwing: error)
                    }
                } else {
                    c.resume(returning: count)
                }
            }
        }
    }

    func save(_ objects: [HKObject]) async throws {
        guard !objects.isEmpty else { return }
        try await store.save(objects)
    }

    func saveWorkout(_ workout: PlannedWorkout, device: HKDevice?, metadata: [String: Any]) async throws {
        let config = HKWorkoutConfiguration()
        config.activityType = workout.type
        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: device)
        try await builder.beginCollection(at: workout.start)
        if !metadata.isEmpty { try await builder.addMetadata(metadata) }
        if let type = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) {
            let samples: [HKSample] = workout.energy.filter { $0.kcal > 0.05 }.map {
                HKQuantitySample(type: type, quantity: HKQuantity(unit: .kilocalorie(), doubleValue: $0.kcal),
                                 start: $0.start, end: $0.end, device: device, metadata: nil)
            }
            if !samples.isEmpty { try await builder.addSamples(samples) }
        }
        try await builder.endCollection(at: workout.end)
        _ = try await builder.finishWorkout()
    }

    func countOurObjects(of type: HKSampleType, in window: DateInterval) async throws -> Int {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int, Error>) in
            let q = HKSampleQuery(sampleType: type, predicate: predicate(window), limit: HKObjectQueryNoLimit,
                                  sortDescriptors: nil) { _, samples, error in
                if let error { c.resume(throwing: error) } else { c.resume(returning: samples?.count ?? 0) }
            }
            store.execute(q)
        }
    }
}
