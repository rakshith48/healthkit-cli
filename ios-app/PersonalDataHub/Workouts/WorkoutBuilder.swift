import Foundation
import HealthKit
import WorkoutKit

/// Converts a JSON `WorkoutSpec` into a `CustomWorkout` that can be
/// displayed via `.workoutPreview()` and saved to the user's Apple Watch.
enum WorkoutBuilderError: Error, LocalizedError {
    case unsupportedActivity(String)
    case invalidGoal(String)
    case invalidAlert(String)
    case invalidPaceString(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedActivity(let a): return "Unsupported activity: \(a)"
        case .invalidGoal(let g): return "Invalid goal spec: \(g)"
        case .invalidAlert(let a): return "Invalid alert spec: \(a)"
        case .invalidPaceString(let s): return "Pace string must be m:ss — got '\(s)'"
        }
    }
}

@available(iOS 17.0, *)
struct WorkoutBuilder {

    static func build(from spec: WorkoutSpec) throws -> CustomWorkout {
        let activity = try activityType(from: spec.activity ?? "running")
        let location = locationType(from: spec.location ?? "outdoor")

        let warmupStep = try spec.warmup.map { try workoutStep(from: $0) }
        let cooldownStep = try spec.cooldown.map { try workoutStep(from: $0) }
        let blocks = try spec.blocks.map { try intervalBlock(from: $0) }

        return CustomWorkout(
            activity: activity,
            location: location,
            displayName: spec.displayName,
            warmup: warmupStep,
            blocks: blocks,
            cooldown: cooldownStep
        )
    }

    // MARK: - Activity / location

    private static func activityType(from raw: String) throws -> HKWorkoutActivityType {
        switch raw.lowercased() {
        case "running": return .running
        case "cycling": return .cycling
        case "walking": return .walking
        case "hiit", "highintensityintervaltraining": return .highIntensityIntervalTraining
        case "strength", "traditionalstrengthtraining": return .traditionalStrengthTraining
        case "functional", "functionalstrengthtraining": return .functionalStrengthTraining
        case "swimming": return .swimming
        case "elliptical": return .elliptical
        case "rowing": return .rowing
        default: throw WorkoutBuilderError.unsupportedActivity(raw)
        }
    }

    private static func locationType(from raw: String) -> HKWorkoutSessionLocationType {
        switch raw.lowercased() {
        case "outdoor": return .outdoor
        case "indoor": return .indoor
        default: return .unknown
        }
    }

    // MARK: - Steps

    private static func workoutStep(from s: WorkoutSpec.StepSpec) throws -> WorkoutStep {
        var step = WorkoutStep(goal: try goal(from: s.goal))
        if let a = s.alert {
            step.alert = try alert(from: a)
        }
        // Note: WorkoutStep.displayName is iOS 18+. Skip for iOS 17 compatibility.
        return step
    }

    private static func intervalBlock(from b: WorkoutSpec.BlockSpec) throws -> IntervalBlock {
        var block = IntervalBlock(iterations: max(b.iterations, 1))
        block.steps = try b.steps.map { try intervalStep(from: $0) }
        return block
    }

    private static func intervalStep(from s: WorkoutSpec.IntervalStepSpec) throws -> IntervalStep {
        let purpose: IntervalStep.Purpose = (s.purpose.lowercased() == "recovery") ? .recovery : .work
        var step = IntervalStep(purpose)
        step.step.goal = try goal(from: s.goal)
        if let a = s.alert {
            step.step.alert = try alert(from: a)
        }
        // Note: displayName is iOS 18+. Skip for iOS 17 compatibility.
        return step
    }

    // MARK: - Goals

    private static func goal(from g: WorkoutSpec.GoalSpec) throws -> WorkoutGoal {
        if let d = g.distance_m, d > 0 {
            return .distance(d, .meters)
        }
        if let t = g.time_s, t > 0 {
            return .time(t, .seconds)
        }
        if let e = g.energy_kcal, e > 0 {
            return .energy(e, .kilocalories)
        }
        return .open
    }

    // MARK: - Alerts

    private static func alert(from a: WorkoutSpec.AlertSpec) throws -> any WorkoutAlert {
        let metric: WorkoutAlertMetric = (a.metric?.lowercased() == "average") ? .average : .current

        switch a.type.lowercased() {
        case "pace":
            // min:max are "m:ss" per km — convert to m/s range.
            // Note WorkoutKit uses speed ranges; faster pace = higher speed,
            // so minSpeed corresponds to the SLOWER pace (maxPace).
            guard let slowPace = a.maxPace, let fastPace = a.minPace else {
                throw WorkoutBuilderError.invalidAlert("pace requires minPace+maxPace (m:ss strings)")
            }
            let slow = try paceStringToMPS(slowPace)
            let fast = try paceStringToMPS(fastPace)
            let lowMPS = min(slow, fast)
            let highMPS = max(slow, fast)
            let low = Measurement(value: lowMPS, unit: UnitSpeed.metersPerSecond)
            let high = Measurement(value: highMPS, unit: UnitSpeed.metersPerSecond)
            return SpeedRangeAlert(target: low...high, metric: metric)

        case "speed_mps":
            guard let lo = a.min, let hi = a.max else {
                throw WorkoutBuilderError.invalidAlert("speed_mps requires min+max (m/s)")
            }
            let low = Measurement(value: lo, unit: UnitSpeed.metersPerSecond)
            let high = Measurement(value: hi, unit: UnitSpeed.metersPerSecond)
            return SpeedRangeAlert(target: low...high, metric: metric)

        case "heart_rate", "hr":
            guard let lo = a.min, let hi = a.max else {
                throw WorkoutBuilderError.invalidAlert("heart_rate requires min+max (bpm)")
            }
            // WorkoutKit uses Measurement<UnitFrequency>; 1 bpm = 1/60 Hz.
            let low = Measurement(value: lo / 60.0, unit: UnitFrequency.hertz)
            let high = Measurement(value: hi / 60.0, unit: UnitFrequency.hertz)
            return HeartRateRangeAlert(target: low...high)

        case "heart_rate_zone", "hr_zone":
            guard let z = a.zone, (1...5).contains(z) else {
                throw WorkoutBuilderError.invalidAlert("heart_rate_zone requires zone 1-5")
            }
            return HeartRateZoneAlert(zone: z)

        default:
            // Cadence and other alert types are deliberately omitted — Phase 1 uses
            // pace + heart rate only. Add here with Measurement<UnitFrequency> if needed.
            throw WorkoutBuilderError.invalidAlert("unsupported alert type '\(a.type)'")
        }
    }

    // MARK: - Helpers

    /// Convert "m:ss" per km into meters/second. e.g. "5:00" → ~3.333 m/s.
    static func paceStringToMPS(_ pace: String) throws -> Double {
        let parts = pace.split(separator: ":")
        guard parts.count == 2,
              let minutes = Int(parts[0]),
              let seconds = Int(parts[1]),
              minutes >= 0, seconds >= 0, seconds < 60 else {
            throw WorkoutBuilderError.invalidPaceString(pace)
        }
        let secondsPerKm = Double(minutes * 60 + seconds)
        guard secondsPerKm > 0 else {
            throw WorkoutBuilderError.invalidPaceString(pace)
        }
        return 1000.0 / secondsPerKm
    }
}
