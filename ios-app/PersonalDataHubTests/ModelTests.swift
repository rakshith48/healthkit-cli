import XCTest
@testable import PersonalDataHub

final class ModelTests: XCTestCase {

    func testHealthSampleRoundTrip() throws {
        let sample = HealthSample(date: "2026-03-21", value: 8500, unit: "count")
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(HealthSample.self, from: data)
        XCTAssertEqual(decoded.date, "2026-03-21")
        XCTAssertEqual(decoded.value, 8500)
        XCTAssertEqual(decoded.unit, "count")
    }

    func testHealthDaySummarySnakeCaseKeys() throws {
        let json = """
        {
            "date": "2026-03-21",
            "steps": 8500,
            "heart_rate_avg": 72,
            "heart_rate_min": 52,
            "heart_rate_max": 145,
            "sleep_hours": 7.5,
            "active_calories": 450,
            "distance_km": 5.2
        }
        """.data(using: .utf8)!

        let summary = try JSONDecoder().decode(HealthDaySummary.self, from: json)
        XCTAssertEqual(summary.steps, 8500)
        XCTAssertEqual(summary.heartRateAvg, 72)
        XCTAssertEqual(summary.sleepHours, 7.5)
        XCTAssertEqual(summary.distanceKm, 5.2)
    }

    func testWorkoutSampleOptionalHeartRate() throws {
        let withHR = WorkoutSample(date: "2026-03-21", type: "Running", durationMin: 30, calories: 350, distanceKm: 5.0, heartRateAvg: 155, heartRateMax: 175, paceAvgMinPerKm: "6:00", source: "Apple Watch", splits: nil)
        let withoutHR = WorkoutSample(date: "2026-03-21", type: "Walking", durationMin: 45, calories: 200, distanceKm: nil, heartRateAvg: nil, heartRateMax: nil, paceAvgMinPerKm: nil, source: nil, splits: nil)

        let encoder = JSONEncoder()
        let data1 = try encoder.encode(withHR)
        let data2 = try encoder.encode(withoutHR)

        let decoded1 = try JSONDecoder().decode(WorkoutSample.self, from: data1)
        let decoded2 = try JSONDecoder().decode(WorkoutSample.self, from: data2)

        XCTAssertEqual(decoded1.heartRateAvg, 155)
        XCTAssertNil(decoded2.heartRateAvg)
    }

    func testStatusResponseEncoding() throws {
        let status = StatusResponse(
            online: true,
            device: "iPhone 16",
            iosVersion: "26.3.1",
            healthKitAuthorized: true,
            timestamp: "2026-03-21T10:00:00Z"
        )
        let data = try JSONEncoder().encode(status)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["online"] as? Bool, true)
        XCTAssertEqual(json?["ios_version"] as? String, "26.3.1")
        XCTAssertEqual(json?["healthkit_authorized"] as? Bool, true)
    }

    func testHealthSummaryResponseEncoding() throws {
        let response = HealthSummaryResponse(
            daysRequested: 1,
            daily: [
                HealthDaySummary(
                    date: "2026-03-21", steps: 10000,
                    heartRateAvg: 70, heartRateMin: 50, heartRateMax: 130,
                    sleepHours: 7.0, activeCalories: 400, distanceKm: 6.5
                )
            ]
        )
        let data = try JSONEncoder().encode(response)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["days_requested"] as? Int, 1)
        XCTAssertNotNil(json?["daily"])
    }
}
