import Foundation

// MARK: - WorkoutSpec
// Codable JSON schema sent from the Mac CLI. Mirrors WorkoutKit CustomWorkout
// but is deliberately flat/JSON-friendly so the CLI doesn't need Swift types.

struct WorkoutSpec: Codable, Identifiable {
    // id is client-generated (UUID) so the CLI can reference the workout before save.
    let id: String
    let displayName: String
    let activity: String?        // "running" (default) / "cycling" / "hiit" / "strength"
    let location: String?        // "outdoor" (default) / "indoor" / "unknown"
    let warmup: StepSpec?
    let blocks: [BlockSpec]
    let cooldown: StepSpec?
    let notes: String?

    struct BlockSpec: Codable {
        let iterations: Int      // 1 = no repeat; N = repeat N times
        let steps: [IntervalStepSpec]
    }

    struct IntervalStepSpec: Codable {
        let purpose: String      // "work" | "recovery"
        let goal: GoalSpec
        let alert: AlertSpec?
        let displayName: String?
    }

    struct StepSpec: Codable {
        let goal: GoalSpec
        let alert: AlertSpec?
        let displayName: String?
    }

    // MARK: - Goals
    //
    // Exactly one of distance_m, time_s, energy_kcal must be provided (else open).
    struct GoalSpec: Codable {
        let distance_m: Double?
        let time_s: Double?
        let energy_kcal: Double?
    }

    // MARK: - Alerts
    //
    // Supported alert kinds (pick one):
    //   type: "pace"          → min/max as "m:ss" strings (min/km)
    //   type: "speed_mps"     → min/max as m/s numbers
    //   type: "heart_rate"    → min/max as bpm ints
    //   type: "heart_rate_zone" → zone (1-5)
    //   type: "cadence"       → min/max as steps/min
    struct AlertSpec: Codable {
        let type: String
        let min: Double?
        let max: Double?
        let minPace: String?        // "5:10"  (min/km) for pace alerts
        let maxPace: String?        // "5:20"
        let zone: Int?              // 1-5 for hr_zone
        let metric: String?         // "current" | "average" — defaults to .current
    }
}

struct WorkoutQueueBatch: Codable {
    let workouts: [WorkoutSpec]
}

// MARK: - Queued workout on the iPhone

struct QueuedWorkout: Codable, Identifiable {
    let id: String
    let spec: WorkoutSpec
    let receivedAt: Date
    var status: String  // "pending" | "saved" | "dismissed"

    init(spec: WorkoutSpec, status: String = "pending") {
        self.id = spec.id
        self.spec = spec
        self.receivedAt = Date()
        self.status = status
    }
}
