import CoreLocation
import Foundation
import HealthKit

extension HealthKitManager {

    // MARK: - Steps

    func querySteps(days: Int) async throws -> [HealthSample] {
        let type = HKQuantityType.quantityType(forIdentifier: .stepCount)!
        let samples = try await queryDailySum(type: type, days: days)
        return samples.map { (date, value) in
            HealthSample(date: date, value: round(value), unit: "count")
        }
    }

    // MARK: - Heart Rate

    func queryHeartRate(days: Int) async throws -> [HealthSample] {
        let type = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        let samples = try await queryDailyAvg(type: type, unit: HKUnit.count().unitDivided(by: .minute()), days: days)
        return samples.map { (date, value) in
            HealthSample(date: date, value: round(value), unit: "bpm")
        }
    }

    // MARK: - HRV

    func queryHRV(days: Int) async throws -> [HealthSample] {
        let type = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!
        let samples = try await queryDailyAvg(type: type, unit: HKUnit.secondUnit(with: .milli), days: days)
        return samples.map { (date, value) in
            HealthSample(date: date, value: round(value), unit: "ms")
        }
    }

    // MARK: - SpO2

    func querySpO2(days: Int) async throws -> [HealthSample] {
        let type = HKQuantityType.quantityType(forIdentifier: .oxygenSaturation)!
        let samples = try await queryDailyAvg(type: type, unit: HKUnit.percent(), days: days)
        return samples.map { (date, value) in
            HealthSample(date: date, value: round(value * 100), unit: "%")
        }
    }

    // MARK: - Active Calories

    func queryActiveCalories(days: Int) async throws -> [HealthSample] {
        let type = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!
        let samples = try await queryDailySum(type: type, days: days)
        return samples.map { (date, value) in
            HealthSample(date: date, value: round(value), unit: "kcal")
        }
    }

    // MARK: - Distance

    func queryDistance(days: Int) async throws -> [HealthSample] {
        let type = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning)!
        let samples = try await queryDailySum(type: type, unit: HKUnit.meter(), days: days)
        return samples.map { (date, value) in
            HealthSample(date: date, value: round(value / 1000 * 10) / 10, unit: "km")
        }
    }

    // MARK: - Sleep

    func querySleep(days: Int) async throws -> [HealthSample] {
        let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
        let start = Calendar.current.date(byAdding: .day, value: -(days + 1), to: Date())!
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, results, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let samples = results as? [HKCategorySample] else {
                    continuation.resume(returning: [])
                    return
                }

                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                let calendar = Calendar.current

                // Step 1: Filter to asleep states only (not inBed or awake)
                // Use Ultrahuman as preferred sleep source.
                // Fall back to Apple Watch if no Ultrahuman data exists.
                let asleepSamples = samples.filter { sample in
                    let value = HKCategoryValueSleepAnalysis(rawValue: sample.value)
                    return value == .asleepCore || value == .asleepDeep || value == .asleepREM || value == .asleepUnspecified
                }

                let ultrahumanSamples = asleepSamples.filter {
                    $0.sourceRevision.source.bundleIdentifier.contains("ultrahuman")
                }
                let samplesToUse = ultrahumanSamples.isEmpty ? asleepSamples : ultrahumanSamples

                // Step 2: Sum sleep durations per night.
                // A "night" = the date you went to bed.
                // Samples after 6pm count as tonight. Samples before 6pm count as last night.
                var dailySleep: [String: Double] = [:]

                for sample in samplesToUse {
                    let hour = calendar.component(.hour, from: sample.startDate)
                    let nightDate: Date
                    if hour < 18 {
                        // Before 6pm → attribute to previous night (yesterday)
                        nightDate = calendar.date(byAdding: .day, value: -1, to: sample.startDate)!
                    } else {
                        // After 6pm → tonight
                        nightDate = sample.startDate
                    }
                    let dateKey = formatter.string(from: nightDate)
                    let hours = sample.endDate.timeIntervalSince(sample.startDate) / 3600
                    dailySleep[dateKey, default: 0] += hours
                }

                // Only return requested days
                let cutoff = calendar.date(byAdding: .day, value: -days, to: Date())!
                let cutoffStr = formatter.string(from: cutoff)

                let result = dailySleep
                    .filter { $0.key >= cutoffStr }
                    .map { (date, hours) in
                        HealthSample(date: date, value: round(hours * 10) / 10, unit: "hours")
                    }.sorted { $0.date > $1.date }

                continuation.resume(returning: result)
            }
            healthStore.execute(query)
        }
    }

    // MARK: - Workouts

    func queryWorkouts(days: Int) async throws -> [WorkoutSample] {
        let start = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)

        let workouts: [HKWorkout] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, results, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (results as? [HKWorkout]) ?? [])
            }
            healthStore.execute(query)
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        var samples: [WorkoutSample] = []
        for workout in workouts {
            // Get heart rate data during workout
            let (hrAvg, hrMax) = await queryWorkoutHeartRate(workout: workout)

            // Get splits from workout route
            let splits = await queryWorkoutSplits(workout: workout)

            // Calculate distance and pace
            let distanceM = workout.totalDistance?.doubleValue(for: .meter())
            let distanceKm = distanceM.map { round($0 / 100) / 10 }  // 1 decimal

            var paceStr: String? = nil
            if let dist = distanceKm, dist > 0 {
                let paceSecPerKm = (workout.duration / dist)
                let paceMin = Int(paceSecPerKm) / 60
                let paceSec = Int(paceSecPerKm) % 60
                paceStr = String(format: "%d:%02d", paceMin, paceSec)
            }

            samples.append(WorkoutSample(
                date: formatter.string(from: workout.startDate),
                type: workout.workoutActivityType.displayName,
                durationMin: Int(workout.duration / 60),
                calories: Int(workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()) ?? 0),
                distanceKm: distanceKm,
                heartRateAvg: hrAvg,
                heartRateMax: hrMax,
                paceAvgMinPerKm: paceStr,
                source: workout.sourceRevision.source.name,
                splits: splits.isEmpty ? nil : splits
            ))
        }
        return samples
    }

    // Query heart rate samples during a workout's time range
    private func queryWorkoutHeartRate(workout: HKWorkout) async -> (avg: Int?, max: Int?) {
        let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        let predicate = HKQuery.predicateForSamples(
            withStart: workout.startDate, end: workout.endDate, options: .strictStartDate
        )

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: hrType,
                quantitySamplePredicate: predicate,
                options: [.discreteAverage, .discreteMax]
            ) { _, stats, _ in
                let unit = HKUnit.count().unitDivided(by: .minute())
                let avg = stats?.averageQuantity()?.doubleValue(for: unit).rounded()
                let max = stats?.maximumQuantity()?.doubleValue(for: unit).rounded()
                continuation.resume(returning: (avg.map { Int($0) }, max.map { Int($0) }))
            }
            healthStore.execute(query)
        }
    }

    // Query workout route and calculate per-km splits
    private func queryWorkoutSplits(workout: HKWorkout) async -> [SplitData] {
        // First get the route object associated with the workout
        let routeType = HKSeriesType.workoutRoute()
        let predicate = HKQuery.predicateForObjects(from: workout)

        let routes: [HKWorkoutRoute] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: routeType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, results, _ in
                continuation.resume(returning: (results as? [HKWorkoutRoute]) ?? [])
            }
            healthStore.execute(query)
        }

        guard let route = routes.first else { return [] }

        // Get all GPS points from the route
        let locations: [CLLocation] = await withCheckedContinuation { continuation in
            var allLocations: [CLLocation] = []
            let query = HKWorkoutRouteQuery(route: route) { _, newLocations, done, _ in
                if let newLocations {
                    allLocations.append(contentsOf: newLocations)
                }
                if done {
                    continuation.resume(returning: allLocations)
                }
            }
            healthStore.execute(query)
        }

        guard locations.count >= 2 else { return [] }

        // Calculate per-km splits
        var splits: [SplitData] = []
        var kmCount = 1
        var cumulativeDistance: Double = 0
        var kmStartTime = locations[0].timestamp

        for i in 1..<locations.count {
            let segmentDistance = locations[i].distance(from: locations[i - 1])
            cumulativeDistance += segmentDistance

            if cumulativeDistance >= Double(kmCount) * 1000 {
                let splitDuration = locations[i].timestamp.timeIntervalSince(kmStartTime)
                let paceMin = Int(splitDuration) / 60
                let paceSec = Int(splitDuration) % 60
                let paceStr = String(format: "%d:%02d", paceMin, paceSec)

                splits.append(SplitData(
                    km: kmCount,
                    durationSec: round(splitDuration * 10) / 10,
                    paceMinPerKm: paceStr
                ))

                kmCount += 1
                kmStartTime = locations[i].timestamp
            }
        }

        // Add final partial km if any distance remains
        let remainingDistance = cumulativeDistance - Double(kmCount - 1) * 1000
        if remainingDistance > 100 { // Only if > 100m remaining
            let splitDuration = locations.last!.timestamp.timeIntervalSince(kmStartTime)
            let equivalentPace = splitDuration / (remainingDistance / 1000) // normalize to per-km
            let paceMin = Int(equivalentPace) / 60
            let paceSec = Int(equivalentPace) % 60
            let paceStr = String(format: "%d:%02d", paceMin, paceSec)

            splits.append(SplitData(
                km: kmCount,
                durationSec: round(splitDuration * 10) / 10,
                paceMinPerKm: paceStr
            ))
        }

        return splits
    }

    // MARK: - Summary

    func querySummary(days: Int) async throws -> [HealthDaySummary] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        async let steps = querySteps(days: days)
        async let hr = queryHeartRate(days: days)
        async let sleep = querySleep(days: days)
        async let calories = queryActiveCalories(days: days)
        async let distance = queryDistance(days: days)

        let allSteps = try await steps
        let allHR = try await hr
        let allSleep = try await sleep
        let allCalories = try await calories
        let allDistance = try await distance

        func lookup(_ samples: [HealthSample]) -> [String: Double] {
            Dictionary(samples.map { ($0.date, $0.value) }, uniquingKeysWith: { a, _ in a })
        }

        let stepsMap = lookup(allSteps)
        let hrMap = lookup(allHR)
        let sleepMap = lookup(allSleep)
        let calMap = lookup(allCalories)
        let distMap = lookup(allDistance)

        var summaries: [HealthDaySummary] = []
        for i in 0..<days {
            let date = Calendar.current.date(byAdding: .day, value: -i, to: Date())!
            let dateStr = formatter.string(from: date)
            summaries.append(HealthDaySummary(
                date: dateStr,
                steps: Int(stepsMap[dateStr] ?? 0),
                heartRateAvg: Int(hrMap[dateStr] ?? 0),
                heartRateMin: 0,
                heartRateMax: 0,
                sleepHours: sleepMap[dateStr] ?? 0,
                activeCalories: Int(calMap[dateStr] ?? 0),
                distanceKm: distMap[dateStr] ?? 0
            ))
        }
        return summaries
    }

    // MARK: - Private Helpers

    private func queryDailySum(type: HKQuantityType, unit: HKUnit? = nil, days: Int) async throws -> [(String, Double)] {
        let calendar = Calendar.current
        let now = Date()
        let start = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now))!

        let interval = DateComponents(day: 1)
        let anchorDate = calendar.startOfDay(for: now)

        let resolvedUnit = unit ?? defaultUnit(for: type)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: nil,
                options: .cumulativeSum,
                anchorDate: anchorDate,
                intervalComponents: interval
            )

            query.initialResultsHandler = { _, results, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let results else {
                    continuation.resume(returning: [])
                    return
                }

                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                var data: [(String, Double)] = []

                results.enumerateStatistics(from: start, to: now) { stats, _ in
                    let value = stats.sumQuantity()?.doubleValue(for: resolvedUnit) ?? 0
                    data.append((formatter.string(from: stats.startDate), value))
                }
                continuation.resume(returning: data)
            }
            healthStore.execute(query)
        }
    }

    private func queryDailyAvg(type: HKQuantityType, unit: HKUnit, days: Int) async throws -> [(String, Double)] {
        let calendar = Calendar.current
        let now = Date()
        let start = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now))!

        let interval = DateComponents(day: 1)
        let anchorDate = calendar.startOfDay(for: now)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: nil,
                options: .discreteAverage,
                anchorDate: anchorDate,
                intervalComponents: interval
            )

            query.initialResultsHandler = { _, results, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let results else {
                    continuation.resume(returning: [])
                    return
                }

                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                var data: [(String, Double)] = []

                results.enumerateStatistics(from: start, to: now) { stats, _ in
                    if let avg = stats.averageQuantity()?.doubleValue(for: unit) {
                        data.append((formatter.string(from: stats.startDate), avg))
                    }
                }
                continuation.resume(returning: data)
            }
            healthStore.execute(query)
        }
    }

    private func defaultUnit(for type: HKQuantityType) -> HKUnit {
        switch type.identifier {
        case HKQuantityTypeIdentifier.stepCount.rawValue:
            return .count()
        case HKQuantityTypeIdentifier.heartRate.rawValue:
            return HKUnit.count().unitDivided(by: .minute())
        case HKQuantityTypeIdentifier.activeEnergyBurned.rawValue:
            return .kilocalorie()
        case HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue:
            return .meter()
        default:
            return .count()
        }
    }
}

// MARK: - Workout Activity Type Display Names

extension HKWorkoutActivityType {
    var displayName: String {
        switch self {
        case .running: return "Running"
        case .walking: return "Walking"
        case .cycling: return "Cycling"
        case .swimming: return "Swimming"
        case .hiking: return "Hiking"
        case .yoga: return "Yoga"
        case .functionalStrengthTraining: return "Strength Training"
        case .traditionalStrengthTraining: return "Strength Training"
        case .highIntensityIntervalTraining: return "HIIT"
        case .elliptical: return "Elliptical"
        case .rowing: return "Rowing"
        case .dance: return "Dance"
        case .coreTraining: return "Core Training"
        case .pilates: return "Pilates"
        case .stairClimbing: return "Stair Climbing"
        default: return "Other"
        }
    }
}
