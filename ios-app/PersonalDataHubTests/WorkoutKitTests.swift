import XCTest
@testable import PersonalDataHub

@available(iOS 17.0, *)
final class WorkoutKitTests: XCTestCase {

    /// Verify the JSON payload that the CLI sends decodes cleanly and then
    /// builds into a valid WorkoutKit CustomWorkout without throwing.
    func testTempoWorkoutFromCLIJson() throws {
        let json = """
        {
          "id": "test-tempo-001",
          "displayName": "Wk 3 Tue Tempo 7km",
          "activity": "running",
          "location": "outdoor",
          "warmup": {
            "goal": { "distance_m": 1500, "time_s": null, "energy_kcal": null },
            "alert": {
              "type": "heart_rate_zone",
              "min": null, "max": null,
              "minPace": null, "maxPace": null,
              "zone": 2, "metric": "current"
            },
            "displayName": null
          },
          "blocks": [
            {
              "iterations": 1,
              "steps": [
                {
                  "purpose": "work",
                  "goal": { "distance_m": 4000, "time_s": null, "energy_kcal": null },
                  "alert": {
                    "type": "pace",
                    "min": null, "max": null,
                    "minPace": "5:10", "maxPace": "5:20",
                    "zone": null, "metric": "current"
                  },
                  "displayName": null
                }
              ]
            }
          ],
          "cooldown": {
            "goal": { "distance_m": 1500, "time_s": null, "energy_kcal": null },
            "alert": null,
            "displayName": null
          },
          "notes": null
        }
        """.data(using: .utf8)!

        let spec = try JSONDecoder().decode(WorkoutSpec.self, from: json)
        XCTAssertEqual(spec.id, "test-tempo-001")
        XCTAssertEqual(spec.displayName, "Wk 3 Tue Tempo 7km")
        XCTAssertEqual(spec.blocks.count, 1)
        XCTAssertEqual(spec.blocks[0].steps.count, 1)
        XCTAssertEqual(spec.blocks[0].steps[0].goal.distance_m, 4000)

        let workout = try WorkoutBuilder.build(from: spec)
        XCTAssertEqual(workout.displayName, "Wk 3 Tue Tempo 7km")
        XCTAssertNotNil(workout.warmup)
        XCTAssertNotNil(workout.cooldown)
        XCTAssertEqual(workout.blocks.count, 1)
    }

    func testTrackWorkoutWithNestedIntervals() throws {
        let json = """
        {
          "id": "test-track-001",
          "displayName": "Wk 1 KCTC 2x800 + 4x200",
          "activity": "running",
          "location": "outdoor",
          "warmup": {
            "goal": { "distance_m": 1500, "time_s": null, "energy_kcal": null },
            "alert": null,
            "displayName": null
          },
          "blocks": [
            {
              "iterations": 2,
              "steps": [
                {
                  "purpose": "work",
                  "goal": { "distance_m": 800, "time_s": null, "energy_kcal": null },
                  "alert": {
                    "type": "pace", "min": null, "max": null,
                    "minPace": "4:10", "maxPace": "4:20",
                    "zone": null, "metric": "current"
                  },
                  "displayName": null
                },
                {
                  "purpose": "recovery",
                  "goal": { "distance_m": null, "time_s": 120, "energy_kcal": null },
                  "alert": null,
                  "displayName": null
                }
              ]
            },
            {
              "iterations": 4,
              "steps": [
                {
                  "purpose": "work",
                  "goal": { "distance_m": 200, "time_s": null, "energy_kcal": null },
                  "alert": {
                    "type": "pace", "min": null, "max": null,
                    "minPace": "3:20", "maxPace": "3:30",
                    "zone": null, "metric": "current"
                  },
                  "displayName": null
                },
                {
                  "purpose": "recovery",
                  "goal": { "distance_m": null, "time_s": 90, "energy_kcal": null },
                  "alert": null,
                  "displayName": null
                }
              ]
            }
          ],
          "cooldown": {
            "goal": { "distance_m": 1000, "time_s": null, "energy_kcal": null },
            "alert": null,
            "displayName": null
          },
          "notes": null
        }
        """.data(using: .utf8)!

        let spec = try JSONDecoder().decode(WorkoutSpec.self, from: json)
        let workout = try WorkoutBuilder.build(from: spec)
        XCTAssertEqual(workout.blocks.count, 2)
        XCTAssertEqual(workout.blocks[0].iterations, 2)
        XCTAssertEqual(workout.blocks[1].iterations, 4)
    }

    func testPaceStringConversion() throws {
        let mps500 = try WorkoutBuilder.paceStringToMPS("5:00")
        XCTAssertEqual(mps500, 1000.0 / 300.0, accuracy: 0.001)

        let mps510 = try WorkoutBuilder.paceStringToMPS("5:10")
        XCTAssertEqual(mps510, 1000.0 / 310.0, accuracy: 0.001)

        XCTAssertThrowsError(try WorkoutBuilder.paceStringToMPS("invalid"))
        XCTAssertThrowsError(try WorkoutBuilder.paceStringToMPS("5:70"))
    }

    func testInvalidPaceAlertThrows() throws {
        let spec = WorkoutSpec(
            id: "bad-pace",
            displayName: "Bad pace alert",
            activity: "running",
            location: "outdoor",
            warmup: nil,
            blocks: [
                WorkoutSpec.BlockSpec(
                    iterations: 1,
                    steps: [
                        WorkoutSpec.IntervalStepSpec(
                            purpose: "work",
                            goal: WorkoutSpec.GoalSpec(distance_m: 1000, time_s: nil, energy_kcal: nil),
                            alert: WorkoutSpec.AlertSpec(
                                type: "pace",
                                min: nil, max: nil,
                                minPace: nil, maxPace: nil,
                                zone: nil, metric: "current"
                            ),
                            displayName: nil
                        )
                    ]
                )
            ],
            cooldown: nil,
            notes: nil
        )

        XCTAssertThrowsError(try WorkoutBuilder.build(from: spec))
    }

    func testQueueBatchDecoding() throws {
        let json = """
        {
          "workouts": [
            {
              "id": "a",
              "displayName": "A",
              "activity": "running",
              "location": "outdoor",
              "warmup": null,
              "blocks": [],
              "cooldown": null,
              "notes": null
            },
            {
              "id": "b",
              "displayName": "B",
              "activity": "running",
              "location": "outdoor",
              "warmup": null,
              "blocks": [],
              "cooldown": null,
              "notes": null
            }
          ]
        }
        """.data(using: .utf8)!
        let batch = try JSONDecoder().decode(WorkoutQueueBatch.self, from: json)
        XCTAssertEqual(batch.workouts.count, 2)
    }
}
