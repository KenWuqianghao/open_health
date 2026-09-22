import Foundation
import HealthKit

// Reads Apple Health samples (the Apple Watch, and every other source except this
// app's own export) and hands them to the hub in pages. Anchored queries with saved
// anchors give only what changed since the last run, deletions included.

/// One HealthKit type the reader follows: its hub kind and the unit for values.
struct HealthReadType: @unchecked Sendable {
    let kind: String
    let sampleType: HKSampleType
    let unit: HKUnit?
    let unitLabel: String?

    init(_ kind: String, _ sampleType: HKSampleType, unit: HKUnit? = nil, label: String? = nil) {
        self.kind = kind; self.sampleType = sampleType; self.unit = unit; unitLabel = label
    }
}

enum HealthReadTypes {
    static let all: [HealthReadType] = {
        var out: [HealthReadType] = []
        func q(_ kind: String, _ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ label: String) {
            if let t = HKObjectType.quantityType(forIdentifier: id) { out.append(HealthReadType(kind, t, unit: unit, label: label)) }
        }
        func c(_ kind: String, _ id: HKCategoryTypeIdentifier) {
            if let t = HKObjectType.categoryType(forIdentifier: id) { out.append(HealthReadType(kind, t)) }
        }
        let bpm = HKUnit.count().unitDivided(by: .minute())
        q("heart_rate", .heartRate, bpm, "count/min")
        q("resting_heart_rate", .restingHeartRate, bpm, "count/min")
        q("walking_heart_rate_average", .walkingHeartRateAverage, bpm, "count/min")
        q("hrv_sdnn", .heartRateVariabilitySDNN, .secondUnit(with: .milli), "ms")
        q("vo2_max", .vo2Max, HKUnit(from: "ml/kg*min"), "ml/kg/min")
        q("step_count", .stepCount, .count(), "count")
        q("active_energy", .activeEnergyBurned, .kilocalorie(), "kcal")
        q("basal_energy", .basalEnergyBurned, .kilocalorie(), "kcal")
        q("exercise_time", .appleExerciseTime, .minute(), "min")
        q("stand_time", .appleStandTime, .minute(), "min")
        q("distance_walking_running", .distanceWalkingRunning, .meter(), "m")
        q("respiratory_rate", .respiratoryRate, bpm, "count/min")
        q("oxygen_saturation", .oxygenSaturation, .percent(), "fraction")
        q("wrist_temperature", .appleSleepingWristTemperature, .degreeCelsius(), "degC")
        c("sleep_analysis", .sleepAnalysis)
        c("stand_hour", .appleStandHour)
        out.append(HealthReadType("workout", HKObjectType.workoutType()))
        return out
    }()

    static var objectTypes: Set<HKObjectType> { Set(all.map { $0.sampleType as HKObjectType }) }
}

/// A sample with its provenance read out, so the encoder never touches
/// `HKObject.sourceRevision` (which traps on an unsaved object, as in tests).
struct HealthRead: @unchecked Sendable {
    let sample: HKSample
    let sourceBundle: String?
    let sourceName: String?
    let device: String?

    init(_ sample: HKSample, sourceBundle: String?, sourceName: String?, device: String? = nil) {
        self.sample = sample; self.sourceBundle = sourceBundle; self.sourceName = sourceName; self.device = device
    }

    /// From a saved sample.
    init(saved sample: HKSample) {
        self.sample = sample
        let src = sample.sourceRevision.source
        sourceBundle = src.bundleIdentifier
        sourceName = src.name
        device = sample.device.flatMap { $0.model ?? $0.name }
    }
}

struct HealthPage: @unchecked Sendable {
    var added: [HealthRead] = []
    var deleted: [String] = []
    var anchor: HKQueryAnchor?
}

/// The seam over `HKHealthStore` for reads, so the engine runs against a fake.
protocol HealthReadClient: AnyObject, Sendable {
    var isAvailable: Bool { get }
    func requestRead(_ types: Set<HKObjectType>) async throws
    func page(_ type: HKSampleType, after anchor: HKQueryAnchor?, limit: Int) async throws -> HealthPage
}

final class HKReadClient: HealthReadClient, @unchecked Sendable {
    private let store = HKHealthStore()
    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestRead(_ types: Set<HKObjectType>) async throws {
        try await store.requestAuthorization(toShare: [], read: types)
    }

    func page(_ type: HKSampleType, after anchor: HKQueryAnchor?, limit: Int) async throws -> HealthPage {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<HealthPage, Error>) in
            let q = HKAnchoredObjectQuery(type: type, predicate: nil, anchor: anchor, limit: limit) { _, added, deleted, newAnchor, error in
                if let error { c.resume(throwing: error); return }
                var page = HealthPage()
                page.added = (added ?? []).map { HealthRead(saved: $0) }
                page.deleted = (deleted ?? []).map { $0.uuid.uuidString }
                page.anchor = newAnchor
                c.resume(returning: page)
            }
            store.execute(q)
        }
    }
}

/// HealthKit sample → the hub row. Pure.
enum HealthSampleEncoder {
    static func encode(_ read: HealthRead, type: HealthReadType) -> [String: Any] {
        let s = read.sample
        var row: [String: Any] = [
            "uuid": s.uuid.uuidString,
            "kind": type.kind,
            "start_unix": s.startDate.timeIntervalSince1970,
            "end_unix": s.endDate.timeIntervalSince1970,
        ]
        if let b = read.sourceBundle { row["source_bundle"] = b }
        if let n = read.sourceName { row["source_name"] = n }
        if let d = read.device { row["device"] = d }
        var metadata: [String: Any] = [:]
        if let entered = s.metadata?[HKMetadataKeyWasUserEntered] as? Bool, entered { metadata["user_entered"] = true }

        if let qs = s as? HKQuantitySample, let unit = type.unit {
            row["value"] = qs.quantity.doubleValue(for: unit)
            row["unit"] = type.unitLabel ?? unit.unitString
        } else if let cs = s as? HKCategorySample {
            row["category"] = categoryLabel(type.kind, cs.value)
        } else if let w = s as? HKWorkout {
            row["category"] = activityName(w.workoutActivityType)
            row["value"] = w.duration / 60
            row["unit"] = "min"
            if let energy = w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity() {
                metadata["total_energy_kcal"] = energy.doubleValue(for: .kilocalorie())
            }
            for id in [HKQuantityTypeIdentifier.distanceWalkingRunning, .distanceCycling, .distanceSwimming] {
                if let d = w.statistics(for: HKQuantityType(id))?.sumQuantity() {
                    metadata["total_distance_m"] = d.doubleValue(for: .meter())
                    break
                }
            }
        }
        if !metadata.isEmpty { row["metadata"] = metadata }
        return row
    }

    static func categoryLabel(_ kind: String, _ value: Int) -> String {
        switch kind {
        case "sleep_analysis":
            switch HKCategoryValueSleepAnalysis(rawValue: value) {
            case .inBed: return "in_bed"
            case .asleepUnspecified: return "asleep_unspecified"
            case .awake: return "awake"
            case .asleepCore: return "asleep_core"
            case .asleepDeep: return "asleep_deep"
            case .asleepREM: return "asleep_rem"
            default: return "unknown_\(value)"
            }
        case "stand_hour":
            switch HKCategoryValueAppleStandHour(rawValue: value) {
            case .stood: return "stood"
            case .idle: return "idle"
            default: return "unknown_\(value)"
            }
        default:
            return "value_\(value)"
        }
    }

    static func activityName(_ t: HKWorkoutActivityType) -> String {
        switch t {
        case .running: return "running"
        case .walking: return "walking"
        case .hiking: return "hiking"
        case .cycling: return "cycling"
        case .swimming: return "swimming"
        case .rowing: return "rowing"
        case .elliptical: return "elliptical"
        case .stairClimbing: return "stair_climbing"
        case .yoga: return "yoga"
        case .pilates: return "pilates"
        case .traditionalStrengthTraining: return "strength_training"
        case .functionalStrengthTraining: return "functional_strength_training"
        case .highIntensityIntervalTraining: return "hiit"
        case .coreTraining: return "core_training"
        case .flexibility: return "flexibility"
        case .cooldown: return "cooldown"
        case .mindAndBody: return "mind_and_body"
        case .tennis: return "tennis"
        case .soccer: return "soccer"
        case .basketball: return "basketball"
        case .badminton: return "badminton"
        case .tableTennis: return "table_tennis"
        case .climbing: return "climbing"
        case .crossTraining: return "cross_training"
        case .mixedCardio: return "mixed_cardio"
        case .dance: return "dance"
        case .other: return "other"
        default: return "activity_\(t.rawValue)"
        }
    }
}

/// Anchors per kind and the run ledger. A JSON file next to the DB.
struct HealthReadState: Codable, Equatable {
    var version = 1
    var anchors: [String: Data] = [:]
    var lastRunAt: Date?
    var lastSuccessAt: Date?
    var samplesSent = 0
    var deletedSent = 0
    var lastError: String?

    func anchor(for kind: String) -> HKQueryAnchor? {
        guard let data = anchors[kind] else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }
    mutating func setAnchor(_ anchor: HKQueryAnchor?, for kind: String) {
        guard let anchor, let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) else { return }
        anchors[kind] = data
    }
}

enum HealthReadStateStore {
    private static let queue = DispatchQueue(label: "md.thomas.openoura.health-read-state", qos: .utility)
    static var url: URL { DB.url.deletingLastPathComponent().appendingPathComponent("health-read-state.json") }
    static func load() -> HealthReadState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(HealthReadState.self, from: data) else { return HealthReadState() }
        return state
    }
    static func save(_ state: HealthReadState) {
        queue.sync {
            guard let data = try? JSONEncoder().encode(state) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
    static func clear() { queue.sync { try? FileManager.default.removeItem(at: url) } }
}

struct HealthReadOutcome: Equatable {
    var pages = 0
    var samples = 0
    var deleted = 0
    var hitDeadline = false
    var error: String?
}

/// Walks every type with anchored queries and hands each page to `send`. The anchor
/// advances only after `send` returned, so a failed page is read again next time.
actor HealthReadEngine {
    static let page = 2000
    private let client: HealthReadClient
    private let ownBundle: String?
    private var state: HealthReadState

    init(client: HealthReadClient, ownBundle: String?, state: HealthReadState = HealthReadStateStore.load()) {
        self.client = client
        self.ownBundle = ownBundle
        self.state = state
    }

    var currentState: HealthReadState { state }

    func resetAnchors() {
        state.anchors = [:]
        state.samplesSent = 0
        state.deletedSent = 0
        HealthReadStateStore.save(state)
    }

    func run(types: [HealthReadType], deadline: TimeInterval, tzOffsetS: Int,
             send: @Sendable ([String: Any]) async throws -> Void) async -> HealthReadOutcome {
        var out = HealthReadOutcome()
        let start = Date()
        state.lastRunAt = start
        state.lastError = nil
        types: for type in types {
            while true {
                if Date().timeIntervalSince(start) >= deadline { out.hitDeadline = true; break types }
                let page: HealthPage
                do {
                    page = try await client.page(type.sampleType, after: state.anchor(for: type.kind), limit: Self.page)
                } catch {
                    out.error = "\(type.kind): \(error.localizedDescription)"
                    break types
                }
                // Our own export is not Apple Watch data, and the hub already has it.
                let rows = page.added
                    .filter { ownBundle == nil || $0.sourceBundle != ownBundle }
                    .map { HealthSampleEncoder.encode($0, type: type) }
                if !rows.isEmpty || !page.deleted.isEmpty {
                    let body: [String: Any] = ["tz_offset_s": tzOffsetS, "samples": rows, "deleted": page.deleted]
                    do {
                        try await send(body)
                    } catch {
                        out.error = "\(type.kind): \(error.localizedDescription)"
                        break types
                    }
                    out.pages += 1
                    out.samples += rows.count
                    out.deleted += page.deleted.count
                }
                state.setAnchor(page.anchor, for: type.kind)
                HealthReadStateStore.save(state)
                if page.added.count < Self.page { break }
            }
        }
        state.samplesSent += out.samples
        state.deletedSent += out.deleted
        if out.error == nil { state.lastSuccessAt = Date() } else { state.lastError = out.error }
        HealthReadStateStore.save(state)
        return out
    }
}

struct HealthReadStatus: Equatable {
    var lastSuccessAt: Date?
    var lastError: String?
    var samplesSent = 0
}

/// The UI face: the switch (asks for read access), the status, the engine.
final class HealthReader: ObservableObject {
    static let shared = HealthReader()
    private static let enabledKey = "hub.health.enabled"

    @Published private(set) var enabled: Bool
    @Published private(set) var status = HealthReadStatus()
    let engine: HealthReadEngine
    private let client: HealthReadClient

    init(client: HealthReadClient = HKReadClient()) {
        self.client = client
        engine = HealthReadEngine(client: client, ownBundle: Bundle.main.bundleIdentifier)
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        let st = HealthReadStateStore.load()
        status = HealthReadStatus(lastSuccessAt: st.lastSuccessAt, lastError: st.lastError, samplesSent: st.samplesSent)
    }

    var isAvailable: Bool { client.isAvailable }

    @MainActor
    func setEnabled(_ on: Bool) async {
        guard on else {
            enabled = false
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
            return
        }
        guard isAvailable else {
            status.lastError = "Apple Health is unavailable on this device."
            return
        }
        do {
            try await client.requestRead(HealthReadTypes.objectTypes)
        } catch {
            status.lastError = error.localizedDescription
            dlog("health-read", "enable failed: \(error.localizedDescription)")
            return
        }
        status.lastError = nil
        enabled = true
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        dlog("health-read", "reading enabled")
    }

    @MainActor
    func record(_ outcome: HealthReadOutcome) async {
        let st = await engine.currentState
        status = HealthReadStatus(lastSuccessAt: st.lastSuccessAt, lastError: st.lastError, samplesSent: st.samplesSent)
    }
}
