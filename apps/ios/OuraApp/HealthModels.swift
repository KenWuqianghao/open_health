import Foundation
import HealthKit

// The `healthSamplesJson` contract (crates/oura-summary/src/health_export.rs),
// decoded, plus the plan the exporter builds from it. All times are UTC seconds.

struct HealthEnvelope: Decodable {
    var version: Int?
    var error: String?
    var serial: String?
    var hardware_id: String?
    var firmware: String?
    var generation: Int?
    var newest_event_unix: Double?
    var days: [HealthDay] = []
}

struct HealthWindow: Decodable, Equatable {
    var start_unix: Double
    var end_unix: Double
    var start_ds: Int64?
    var end_ds: Int64?
    var interval: DateInterval {
        DateInterval(start: Date(timeIntervalSince1970: start_unix), end: Date(timeIntervalSince1970: max(end_unix, start_unix + 1)))
    }
}
struct HRPoint: Decodable, Equatable { var t_unix: Double; var bpm: Double; var n: Int?; var src: String? }
struct HRVPoint: Decodable, Equatable { var t_unix: Double; var window_s: Double?; var rmssd_ms: Double?; var sdnn_ms: Double?; var n_beats: Int? }
struct RestingHR: Decodable, Equatable { var t_unix: Double; var bpm: Double }
struct RespPoint: Decodable, Equatable { var t_unix: Double; var brpm: Double }
struct SpO2Point: Decodable, Equatable { var t_unix: Double; var pct: Double; var n: Int? }
struct HealthBucket: Decodable, Equatable { var start_unix: Double; var end_unix: Double; var count: Int?; var kcal: Double? }

struct HealthDay: Decodable, Equatable {
    var ymd: String
    var day_start_unix: Double
    var day_end_unix: Double
    var night: HealthWindow?
    var in_bed: [HealthWindow] = []
    var stage_window: HealthWindow?
    var resting_hr: RestingHR?
    var heart_rate: [HRPoint] = []
    var hrv: [HRVPoint] = []
    var spo2: [SpO2Point] = []
    var respiratory_rate: [RespPoint] = []
    var steps: [HealthBucket] = []
    var active_energy: [HealthBucket] = []
    var basal_energy: [HealthBucket] = []
    var warnings: [String] = []
    var updated_unix: Double
    var finalized: Bool
    var fingerprint: String

    var dayWindow: DateInterval {
        DateInterval(start: Date(timeIntervalSince1970: day_start_unix), end: Date(timeIntervalSince1970: day_end_unix))
    }
}

/// The on-device SleepNet hypnogram for one night: 30-s epochs from `startUnix`.
struct StageTrack: Equatable {
    var startUnix: Double
    var epochSeconds: Double = 30
    var codes: [Int]
}

/// A detected workout the torch build supplies (empty in the model-free build).
struct WorkoutInput: Equatable {
    var id: String
    var label: String
    var start: Date
    var end: Date
}

enum HealthUnit: Equatable {
    case bpm, milliseconds, breathsPerMinute, percent, count, kilocalorie
    var hkUnit: HKUnit {
        switch self {
        case .bpm, .breathsPerMinute: return HKUnit.count().unitDivided(by: .minute())
        case .milliseconds: return .secondUnit(with: .milli)
        case .percent: return .percent()
        case .count: return .count()
        case .kilocalorie: return .kilocalorie()
        }
    }
}

enum PlannedSample: Equatable {
    case quantity(HKQuantityTypeIdentifier, value: Double, unit: HealthUnit, start: Date, end: Date)
    case sleep(HKCategoryValueSleepAnalysis, start: Date, end: Date)
}

struct EnergyPiece: Equatable { var start: Date; var end: Date; var kcal: Double }

struct PlannedWorkout: Equatable {
    var id: String
    var type: HKWorkoutActivityType
    var start: Date
    var end: Date
    var energy: [EnergyPiece]
}

/// Everything the exporter writes for one day, and the windows it clears first.
struct DayPlan: Equatable {
    var ymd: String
    var dayWindow: DateInterval
    var sleepWindows: [DateInterval]
    var workoutWindows: [DateInterval]
    var samples: [PlannedSample]
    var workouts: [PlannedWorkout]
    var fingerprint: String
    var finalized: Bool
    var updatedAt: Date
    var warnings: [String]
}
