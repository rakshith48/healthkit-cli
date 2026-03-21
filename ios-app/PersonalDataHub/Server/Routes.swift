import Foundation
import HealthKit
import Swifter
import UIKit

class Routes {
    let healthKit: HealthKitManager

    init(healthKit: HealthKitManager) {
        self.healthKit = healthKit
    }

    func register(on server: HttpServer) {
        server["/status"] = statusHandler
        server["/health/summary"] = healthSummaryHandler
        server["/health/metrics"] = healthMetricsHandler
        server["/health/workouts"] = workoutsHandler
        server["/sync/bulk"] = syncBulkHandler
        server["/debug/sleep-raw"] = sleepRawHandler
    }

    // MARK: - /debug/sleep-raw (dumps every raw sleep sample from HealthKit)

    private var sleepRawHandler: ((HttpRequest) -> HttpResponse) {
        { [weak self] request in
            guard let self else { return .internalServerError }
            let days = self.intParam(request, "days") ?? 3

            let semaphore = DispatchSemaphore(value: 0)
            var result: [[String: Any]] = []
            var queryError: Error?

            Task { @MainActor in
                do {
                    let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
                    let start = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
                    let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)

                    result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[[String: Any]], Error>) in
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

                            let isoFormatter = ISO8601DateFormatter()
                            isoFormatter.formatOptions = [.withInternetDateTime]

                            let rawSamples: [[String: Any]] = samples.map { sample in
                                let sleepValue: String
                                switch HKCategoryValueSleepAnalysis(rawValue: sample.value) {
                                case .inBed: sleepValue = "inBed"
                                case .asleepUnspecified: sleepValue = "asleepUnspecified"
                                case .awake: sleepValue = "awake"
                                case .asleepCore: sleepValue = "asleepCore"
                                case .asleepDeep: sleepValue = "asleepDeep"
                                case .asleepREM: sleepValue = "asleepREM"
                                default: sleepValue = "unknown(\(sample.value))"
                                }

                                let durationMin = sample.endDate.timeIntervalSince(sample.startDate) / 60

                                return [
                                    "start": isoFormatter.string(from: sample.startDate),
                                    "end": isoFormatter.string(from: sample.endDate),
                                    "type": sleepValue,
                                    "duration_min": round(durationMin * 10) / 10,
                                    "source": sample.sourceRevision.source.name,
                                    "source_bundle": sample.sourceRevision.source.bundleIdentifier,
                                ]
                            }
                            continuation.resume(returning: rawSamples)
                        }
                        self.healthKit.healthStore.execute(query)
                    }
                } catch {
                    queryError = error
                }
                semaphore.signal()
            }
            semaphore.wait()

            if let error = queryError {
                return self.errorResponse(error.localizedDescription)
            }
            guard let data = try? JSONSerialization.data(withJSONObject: ["days": days, "count": result.count, "samples": result], options: [.prettyPrinted, .sortedKeys]) else {
                return .internalServerError
            }
            return .raw(200, "OK", ["Content-Type": "application/json"]) { writer in
                try writer.write(data)
            }
        }
    }

    // MARK: - /status

    private var statusHandler: ((HttpRequest) -> HttpResponse) {
        { _ in
            let device = UIDevice.current
            let response = StatusResponse(
                online: true,
                device: device.name,
                iosVersion: device.systemVersion,
                healthKitAuthorized: true,
                timestamp: ISO8601DateFormatter().string(from: Date())
            )
            return self.jsonResponse(response)
        }
    }

    // MARK: - /health/summary

    private var healthSummaryHandler: ((HttpRequest) -> HttpResponse) {
        { [weak self] request in
            guard let self else { return .internalServerError }
            let days = self.intParam(request, "days") ?? 7

            let semaphore = DispatchSemaphore(value: 0)
            var result: HealthSummaryResponse?
            var queryError: Error?

            Task { @MainActor in
                do {
                    let summaries = try await self.healthKit.querySummary(days: days)
                    result = HealthSummaryResponse(daysRequested: days, daily: summaries)
                } catch {
                    queryError = error
                }
                semaphore.signal()
            }
            semaphore.wait()

            if let error = queryError {
                return self.errorResponse(error.localizedDescription)
            }
            return self.jsonResponse(result!)
        }
    }

    // MARK: - /health/metrics

    private var healthMetricsHandler: ((HttpRequest) -> HttpResponse) {
        { [weak self] request in
            guard let self else { return .internalServerError }
            let metricType = self.stringParam(request, "type") ?? "steps"
            let days = self.intParam(request, "days") ?? 7

            let semaphore = DispatchSemaphore(value: 0)
            var samples: [HealthSample] = []
            var queryError: Error?

            Task { @MainActor in
                do {
                    switch metricType {
                    case "steps": samples = try await self.healthKit.querySteps(days: days)
                    case "heart_rate": samples = try await self.healthKit.queryHeartRate(days: days)
                    case "sleep": samples = try await self.healthKit.querySleep(days: days)
                    case "hrv": samples = try await self.healthKit.queryHRV(days: days)
                    case "spo2": samples = try await self.healthKit.querySpO2(days: days)
                    case "active_calories": samples = try await self.healthKit.queryActiveCalories(days: days)
                    case "distance": samples = try await self.healthKit.queryDistance(days: days)
                    default:
                        queryError = NSError(domain: "Routes", code: 400, userInfo: [
                            NSLocalizedDescriptionKey: "Unknown metric: \(metricType). Valid: steps, heart_rate, sleep, hrv, spo2, active_calories, distance"
                        ])
                    }
                } catch {
                    queryError = error
                }
                semaphore.signal()
            }
            semaphore.wait()

            if let error = queryError {
                return self.errorResponse(error.localizedDescription)
            }
            let response = HealthMetricResponse(metric: metricType, daysRequested: days, samples: samples)
            return self.jsonResponse(response)
        }
    }

    // MARK: - /health/workouts

    private var workoutsHandler: ((HttpRequest) -> HttpResponse) {
        { [weak self] request in
            guard let self else { return .internalServerError }
            let days = self.intParam(request, "days") ?? 30

            let semaphore = DispatchSemaphore(value: 0)
            var workouts: [WorkoutSample] = []
            var queryError: Error?

            Task { @MainActor in
                do {
                    workouts = try await self.healthKit.queryWorkouts(days: days)
                } catch {
                    queryError = error
                }
                semaphore.signal()
            }
            semaphore.wait()

            if let error = queryError {
                return self.errorResponse(error.localizedDescription)
            }
            let response = WorkoutResponse(daysRequested: days, workouts: workouts)
            return self.jsonResponse(response)
        }
    }

    // MARK: - /sync/bulk

    private var syncBulkHandler: ((HttpRequest) -> HttpResponse) {
        { [weak self] request in
            guard let self else { return .internalServerError }
            let since = self.stringParam(request, "since")
            let days = self.intParam(request, "days") ?? 1

            let semaphore = DispatchSemaphore(value: 0)
            var healthSummary: HealthSummaryResponse?
            var workoutResponse: WorkoutResponse?
            var queryError: Error?

            Task { @MainActor in
                do {
                    let summaries = try await self.healthKit.querySummary(days: days)
                    healthSummary = HealthSummaryResponse(daysRequested: days, daily: summaries)
                    let workouts = try await self.healthKit.queryWorkouts(days: days)
                    workoutResponse = WorkoutResponse(daysRequested: days, workouts: workouts)
                } catch {
                    queryError = error
                }
                semaphore.signal()
            }
            semaphore.wait()

            if let error = queryError {
                return self.errorResponse(error.localizedDescription)
            }
            let response = SyncBulkResponse(
                since: since,
                health: healthSummary!,
                workouts: workoutResponse!,
                timestamp: ISO8601DateFormatter().string(from: Date())
            )
            return self.jsonResponse(response)
        }
    }

    // MARK: - Helpers

    private func jsonResponse<T: Encodable>(_ value: T) -> HttpResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else {
            return .internalServerError
        }
        return .raw(200, "OK", ["Content-Type": "application/json"]) { writer in
            try writer.write(data)
        }
    }

    private func errorResponse(_ message: String, code: Int = 400) -> HttpResponse {
        let body: [String: String] = ["error": message]
        guard let data = try? JSONEncoder().encode(body) else {
            return .internalServerError
        }
        return .raw(code, "Error", ["Content-Type": "application/json"]) { writer in
            try writer.write(data)
        }
    }

    private func intParam(_ request: HttpRequest, _ name: String) -> Int? {
        guard let value = request.queryParams.first(where: { $0.0 == name })?.1 else {
            return nil
        }
        return Int(value)
    }

    private func stringParam(_ request: HttpRequest, _ name: String) -> String? {
        request.queryParams.first(where: { $0.0 == name })?.1
    }
}
