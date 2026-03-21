import Foundation

struct HealthSample: Codable {
    let date: String
    let value: Double
    let unit: String
}

struct HealthDaySummary: Codable {
    let date: String
    let steps: Int
    let heartRateAvg: Int
    let heartRateMin: Int
    let heartRateMax: Int
    let sleepHours: Double
    let activeCalories: Int
    let distanceKm: Double

    enum CodingKeys: String, CodingKey {
        case date, steps
        case heartRateAvg = "heart_rate_avg"
        case heartRateMin = "heart_rate_min"
        case heartRateMax = "heart_rate_max"
        case sleepHours = "sleep_hours"
        case activeCalories = "active_calories"
        case distanceKm = "distance_km"
    }
}

struct HealthSummaryResponse: Codable {
    let daysRequested: Int
    let daily: [HealthDaySummary]

    enum CodingKeys: String, CodingKey {
        case daysRequested = "days_requested"
        case daily
    }
}

struct HealthMetricResponse: Codable {
    let metric: String
    let daysRequested: Int
    let samples: [HealthSample]

    enum CodingKeys: String, CodingKey {
        case metric
        case daysRequested = "days_requested"
        case samples
    }
}

struct SplitData: Codable {
    let km: Int
    let durationSec: Double
    let paceMinPerKm: String

    enum CodingKeys: String, CodingKey {
        case km
        case durationSec = "duration_sec"
        case paceMinPerKm = "pace_min_per_km"
    }
}

struct WorkoutSample: Codable {
    let date: String
    let type: String
    let durationMin: Int
    let calories: Int
    let distanceKm: Double?
    let heartRateAvg: Int?
    let heartRateMax: Int?
    let paceAvgMinPerKm: String?
    let source: String?
    let splits: [SplitData]?

    enum CodingKeys: String, CodingKey {
        case date, type, calories, source, splits
        case durationMin = "duration_min"
        case distanceKm = "distance_km"
        case heartRateAvg = "heart_rate_avg"
        case heartRateMax = "heart_rate_max"
        case paceAvgMinPerKm = "pace_avg_min_per_km"
    }
}

struct WorkoutResponse: Codable {
    let daysRequested: Int
    let workouts: [WorkoutSample]

    enum CodingKeys: String, CodingKey {
        case daysRequested = "days_requested"
        case workouts
    }
}

struct StatusResponse: Codable {
    let online: Bool
    let device: String
    let iosVersion: String
    let healthKitAuthorized: Bool
    let timestamp: String

    enum CodingKeys: String, CodingKey {
        case online, device, timestamp
        case iosVersion = "ios_version"
        case healthKitAuthorized = "healthkit_authorized"
    }
}

struct SyncBulkResponse: Codable {
    let since: String?
    let health: HealthSummaryResponse
    let workouts: WorkoutResponse
    let timestamp: String
}
