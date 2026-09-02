import CryptoKit
import Foundation
import HealthKit

/// Pure planning: one day's bundle + the on-device stages + workouts → the samples
/// to write and the windows to clear. No HealthKit store access, so it is unit-
/// testable in full. Rules (the honesty rule: measured data only):
///
/// - sleep: one `inBed` per in-bed window; stage runs from the 30-s hypnogram
///   (1 deep, 2 core, 3 REM, 4 awake; anything else is a gap, never "awake").
/// - heart rate: the 1-minute means, 25..230 bpm, ≤ 1440 per day.
/// - HRV: SDNN only when the Rust side computed one (≥ 30 beats in the window).
/// - resting HR, respiratory rate (one per night, spanning the in-bed window),
///   SpO2 (1-min means, 0..1), steps and energy per hourly bucket.
/// - distance is never written (a MET estimate of an estimate).
/// - workouts only when the torch build supplies them; their energy is carved out of
///   the hourly buckets so day totals stay the same.
enum HealthPlanner {
    static func plan(day: HealthDay, stages: StageTrack?, workouts: [WorkoutInput],
                     includeBasal: Bool, epoch: String) -> DayPlan {
        var samples: [PlannedSample] = []
        let dayWindow = day.dayWindow

        // Sleep: in-bed envelopes + stage runs inside the main night.
        var sleepWindows: [DateInterval] = []
        for w in day.in_bed {
            let iv = w.interval
            sleepWindows.append(iv)
            samples.append(.sleep(.inBed, start: iv.start, end: iv.end))
        }
        if let track = stages, let night = day.night {
            for (value, iv) in stageIntervals(track, clipTo: night.interval) {
                samples.append(.sleep(value, start: iv.start, end: iv.end))
            }
        }

        // Heart rate: 1-min means, capped.
        var hrCount = 0
        for p in day.heart_rate.sorted(by: { $0.t_unix < $1.t_unix }) where (25...230).contains(p.bpm) {
            guard hrCount < 1440 else { break }
            let t = Date(timeIntervalSince1970: p.t_unix)
            samples.append(.quantity(.heartRate, value: p.bpm, unit: .bpm, start: t, end: t))
            hrCount += 1
        }
        // HRV SDNN.
        for p in day.hrv where p.sdnn_ms != nil {
            let start = Date(timeIntervalSince1970: p.t_unix)
            let end = start.addingTimeInterval(p.window_s ?? 300)
            samples.append(.quantity(.heartRateVariabilitySDNN, value: p.sdnn_ms!, unit: .milliseconds, start: start, end: end))
        }
        if let r = day.resting_hr, r.bpm > 0 {
            let t = Date(timeIntervalSince1970: r.t_unix)
            samples.append(.quantity(.restingHeartRate, value: r.bpm, unit: .bpm, start: t, end: t))
        }
        // Respiratory rate: the night's average over the in-bed window.
        if let night = day.night, !day.respiratory_rate.isEmpty {
            let mean = day.respiratory_rate.map(\.brpm).reduce(0, +) / Double(day.respiratory_rate.count)
            if (4...40).contains(mean) {
                let iv = night.interval
                samples.append(.quantity(.respiratoryRate, value: mean, unit: .breathsPerMinute, start: iv.start, end: iv.end))
            }
        }
        // SpO2: 1-min means as fractions.
        for p in day.spo2 where (50...100).contains(p.pct) {
            let t = Date(timeIntervalSince1970: p.t_unix)
            samples.append(.quantity(.oxygenSaturation, value: p.pct / 100.0, unit: .percent, start: t, end: t))
        }
        // Steps / energy per hourly bucket.
        for b in day.steps {
            guard let count = b.count, count > 0 else { continue }
            samples.append(.quantity(.stepCount, value: Double(count), unit: .count,
                                     start: Date(timeIntervalSince1970: b.start_unix), end: Date(timeIntervalSince1970: b.end_unix)))
        }
        let plainWorkouts = plannedWorkouts(workouts, day: day)
        let (plainEnergy, perWorkout) = carveWorkoutEnergy(buckets: day.active_energy, workouts: plainWorkouts)
        for b in plainEnergy where b.kcal > 0.05 {
            samples.append(.quantity(.activeEnergyBurned, value: b.kcal, unit: .kilocalorie, start: b.start, end: b.end))
        }
        if includeBasal {
            for b in day.basal_energy {
                guard let kcal = b.kcal, kcal > 0.05 else { continue }
                samples.append(.quantity(.basalEnergyBurned, value: kcal, unit: .kilocalorie,
                                         start: Date(timeIntervalSince1970: b.start_unix), end: Date(timeIntervalSince1970: b.end_unix)))
            }
        }
        let workoutsOut: [PlannedWorkout] = plainWorkouts.map { w in
            PlannedWorkout(id: w.id, type: activityType(w.label), start: w.start, end: w.end, energy: perWorkout[w.id] ?? [])
        }
        let workoutWindows = workoutsOut.map { DateInterval(start: $0.start, end: max($0.end, $0.start.addingTimeInterval(1))) }

        return DayPlan(
            ymd: day.ymd,
            dayWindow: dayWindow,
            sleepWindows: sleepWindows,
            workoutWindows: workoutWindows,
            samples: samples,
            workouts: workoutsOut,
            fingerprint: fingerprint(day: day, stages: stages, workouts: workouts, includeBasal: includeBasal, epoch: epoch),
            finalized: day.finalized,
            updatedAt: Date(timeIntervalSince1970: day.updated_unix),
            warnings: day.warnings
        )
    }

    /// Run-length merge of the hypnogram into stage intervals, clipped to `clipTo`,
    /// non-overlapping and ascending. Unknown codes are gaps (left unwritten).
    static func stageIntervals(_ track: StageTrack, clipTo: DateInterval) -> [(HKCategoryValueSleepAnalysis, DateInterval)] {
        var out: [(HKCategoryValueSleepAnalysis, DateInterval)] = []
        var i = 0
        let codes = track.codes
        while i < codes.count {
            let code = codes[i]
            var j = i + 1
            while j < codes.count, codes[j] == code { j += 1 }
            if let value = stageValue(code) {
                let start = max(clipTo.start, Date(timeIntervalSince1970: track.startUnix + Double(i) * track.epochSeconds))
                let end = min(clipTo.end, Date(timeIntervalSince1970: track.startUnix + Double(j) * track.epochSeconds))
                if end > start {
                    if let last = out.last, last.1.end > start {
                        // overlap with the previous run (clock drift): trim, never overlap
                        if last.1.end < end { out.append((value, DateInterval(start: last.1.end, end: end))) }
                    } else {
                        out.append((value, DateInterval(start: start, end: end)))
                    }
                }
            }
            i = j
        }
        return out
    }

    static func stageValue(_ code: Int) -> HKCategoryValueSleepAnalysis? {
        switch code {
        case 1: return .asleepDeep
        case 2: return .asleepCore
        case 3: return .asleepREM
        case 4: return .awake
        default: return nil
        }
    }

    /// Workouts that fall on this day (by start time inside the day window).
    static func plannedWorkouts(_ workouts: [WorkoutInput], day: HealthDay) -> [WorkoutInput] {
        let w = day.dayWindow
        return workouts.filter { w.contains($0.start) && $0.end > $0.start }.sorted { $0.start < $1.start }
    }

    /// Split each hourly active-energy bucket at workout boundaries, time-
    /// proportionally (energy is assumed uniform within the hour). The pieces inside a
    /// workout are attached to it; the rest stays a plain sample. Every kcal lands in
    /// exactly one place, so day totals are unchanged.
    static func carveWorkoutEnergy(buckets: [HealthBucket], workouts: [WorkoutInput])
        -> (plain: [EnergyPiece], perWorkout: [String: [EnergyPiece]]) {
        var plain: [EnergyPiece] = []
        var per: [String: [EnergyPiece]] = [:]
        for b in buckets {
            guard let kcal = b.kcal, kcal > 0 else { continue }
            let start = Date(timeIntervalSince1970: b.start_unix)
            let end = Date(timeIntervalSince1970: b.end_unix)
            let span = end.timeIntervalSince(start)
            guard span > 0 else { continue }
            // boundaries inside the bucket
            var cuts: [Date] = [start, end]
            for w in workouts {
                for d in [w.start, w.end] where d > start && d < end { cuts.append(d) }
            }
            cuts = Array(Set(cuts)).sorted()
            for k in 0..<(cuts.count - 1) {
                let a = cuts[k], z = cuts[k + 1]
                let piece = EnergyPiece(start: a, end: z, kcal: kcal * z.timeIntervalSince(a) / span)
                if let w = workouts.first(where: { $0.start <= a && $0.end >= z }) {
                    per[w.id, default: []].append(piece)
                } else if let last = plain.last, last.end == a {
                    plain[plain.count - 1] = EnergyPiece(start: last.start, end: z, kcal: last.kcal + piece.kcal)
                } else {
                    plain.append(piece)
                }
            }
        }
        return (plain, per)
    }

    static func fingerprint(day: HealthDay, stages: StageTrack?, workouts: [WorkoutInput], includeBasal: Bool, epoch: String) -> String {
        var text = "\(epoch)|\(day.fingerprint)|basal:\(includeBasal)|"
        if let stages {
            text += "stages:\(Int(stages.startUnix)):\(stages.codes.count):\(stages.codes.reduce(0, +))|"
        }
        for w in workouts.sorted(by: { $0.start < $1.start }) {
            text += "w:\(w.id):\(Int(w.start.timeIntervalSince1970)):\(Int(w.end.timeIntervalSince1970))|"
        }
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func activityType(_ label: String) -> HKWorkoutActivityType {
        let l = label.lowercased()
        switch true {
        case l.contains("hik"): return .hiking
        case l.contains("nordic"): return .walking
        case l.contains("walk"): return .walking
        case l.contains("run"), l.contains("jog"): return .running
        case l.contains("mountain"), l.contains("cycl"), l.contains("bik"): return .cycling
        case l.contains("swim"): return .swimming
        case l.contains("row"): return .rowing
        case l.contains("strength"), l.contains("weight"): return .traditionalStrengthTraining
        case l.contains("yoga"): return .yoga
        case l.contains("pilates"): return .pilates
        case l.contains("hiit"), l.contains("interval"): return .highIntensityIntervalTraining
        case l.contains("elliptical"): return .elliptical
        case l.contains("cross country"), l.contains("ski"): return .crossCountrySkiing
        case l.contains("snowboard"): return .snowboarding
        case l.contains("climb"): return .climbing
        case l.contains("golf"): return .golf
        case l.contains("dance"): return .cardioDance
        case l.contains("box"): return .boxing
        case l.contains("martial"): return .martialArts
        case l.contains("badminton"): return .badminton
        case l.contains("tennis"), l.contains("padel"): return .tennis
        case l.contains("soccer"), l.contains("football") && !l.contains("american"): return .soccer
        case l.contains("american football"): return .americanFootball
        case l.contains("basketball"): return .basketball
        case l.contains("volleyball"): return .volleyball
        case l.contains("baseball"): return .baseball
        case l.contains("hockey"): return .hockey
        case l.contains("cricket"): return .cricket
        case l.contains("surf"): return .surfingSports
        case l.contains("horse"), l.contains("equestrian"): return .equestrianSports
        case l.contains("core"): return .coreTraining
        case l.contains("stretch"): return .flexibility
        case l.contains("cross train"), l.contains("crosstrain"): return .crossTraining
        case l.contains("fitness class"), l.contains("cardio"): return .mixedCardio
        default: return .other
        }
    }
}
