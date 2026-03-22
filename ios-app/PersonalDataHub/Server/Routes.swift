import Foundation
import HealthKit
import Swifter
import UIKit

private let VALID_METRICS: Set<String> = ["steps", "heart_rate", "sleep", "hrv", "spo2", "active_calories", "distance"]
private let MAX_DAYS = 365
private let RATE_LIMIT_PER_MIN = 60

class Routes {
    let healthKit: HealthKitManager
    let auth: AuthManager
    private var requestCounts: [String: (count: Int, resetAt: Date)] = [:]

    init(healthKit: HealthKitManager, auth: AuthManager) {
        self.healthKit = healthKit
        self.auth = auth
    }

    func register(on server: HttpServer) {
        // Public — no auth required
        server["/pair"] = pairHandler

        // Protected — require Bearer token
        server["/status"] = authenticated(statusHandler)
        server["/health/summary"] = authenticated(healthSummaryHandler)
        server["/health/metrics"] = authenticated(healthMetricsHandler)
        server["/health/workouts"] = authenticated(workoutsHandler)
        server["/sync/bulk"] = authenticated(syncBulkHandler)

        #if DEBUG
        server["/debug/sleep-raw"] = authenticated(sleepRawHandler)
        #endif
    }

    // MARK: - Auth Middleware

    private func authenticated(_ handler: @escaping (HttpRequest) -> HttpResponse) -> ((HttpRequest) -> HttpResponse) {
        return { [weak self] request in
            guard let self else { return .internalServerError }

            // Extract Bearer token from Authorization header
            let authHeader = request.headers.first(where: { $0.0.lowercased() == "authorization" })?.1 ?? ""
            let token: String
            if authHeader.lowercased().hasPrefix("bearer ") {
                token = String(authHeader.dropFirst(7))
            } else {
                return self.unauthorizedResponse()
            }

            guard self.auth.validateToken(token) else {
                return self.unauthorizedResponse()
            }

            return handler(request)
        }
    }

    private func unauthorizedResponse() -> HttpResponse {
        let body: [String: String] = ["error": "Unauthorized. Run 'datahub pair' to authenticate."]
        guard let data = try? JSONEncoder().encode(body) else { return .internalServerError }
        return .raw(401, "Unauthorized", ["Content-Type": "application/json", "WWW-Authenticate": "Bearer"]) { writer in
            try writer.write(data)
        }
    }

    // MARK: - /pair (public endpoint)

    private var pairHandler: ((HttpRequest) -> HttpResponse) {
        { [weak self] request in
            guard let self, self.checkRateLimit(for: request.address ?? "unknown") else {
                return self?.rateLimitResponse() ?? .internalServerError
            }

            // Parse JSON body: {"code": "123456", "device_name": "My Mac"}
            let bodyData = Data(request.body.map { UInt8($0) })
            guard let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: String],
                  let code = json["code"],
                  let deviceName = json["device_name"] else {
                return self.errorResponse("Invalid request", code: 400)
            }

            guard let token = self.auth.validatePairingCode(code, deviceName: deviceName) else {
                return self.errorResponse("Invalid pairing code", code: 403)
            }

            let response: [String: String] = ["token": token]
            guard let data = try? JSONEncoder().encode(response) else { return .internalServerError }
            return .raw(200, "OK", ["Content-Type": "application/json"]) { writer in
                try writer.write(data)
            }
        }
    }

    // MARK: - Rate Limiting

    private func checkRateLimit(for clientIP: String) -> Bool {
        let now = Date()
        if let entry = requestCounts[clientIP] {
            if now >= entry.resetAt {
                requestCounts[clientIP] = (count: 1, resetAt: now.addingTimeInterval(60))
                return true
            } else if entry.count >= RATE_LIMIT_PER_MIN {
                return false
            } else {
                requestCounts[clientIP] = (count: entry.count + 1, resetAt: entry.resetAt)
                return true
            }
        } else {
            requestCounts[clientIP] = (count: 1, resetAt: now.addingTimeInterval(60))
            return true
        }
    }

    // MARK: - Input Validation

    private func validatedDays(_ request: HttpRequest) -> Int? {
        let raw = intParam(request, "days") ?? 7
        guard raw >= 1, raw <= MAX_DAYS else { return nil }
        return raw
    }

    // MARK: - /status

    private var statusHandler: ((HttpRequest) -> HttpResponse) {
        { [weak self] request in
            guard let self, self.checkRateLimit(for: request.address ?? "unknown") else {
                return self?.rateLimitResponse() ?? .internalServerError
            }
            let response: [String: Any] = [
                "online": true,
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: response, options: .sortedKeys) else {
                return .internalServerError
            }
            return .raw(200, "OK", ["Content-Type": "application/json"]) { writer in
                try writer.write(data)
            }
        }
    }

    // MARK: - /health/summary

    private var healthSummaryHandler: ((HttpRequest) -> HttpResponse) {
        { [weak self] request in
            guard let self, self.checkRateLimit(for: request.address ?? "unknown") else {
                return self?.rateLimitResponse() ?? .internalServerError
            }
            guard let days = self.validatedDays(request) else {
                return self.errorResponse("Invalid request", code: 400)
            }

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

            if queryError != nil {
                print("[Routes] Summary query error: \(queryError!)")
                return self.errorResponse("Query failed")
            }
            return self.jsonResponse(result!)
        }
    }

    // MARK: - /health/metrics

    private var healthMetricsHandler: ((HttpRequest) -> HttpResponse) {
        { [weak self] request in
            guard let self, self.checkRateLimit(for: request.address ?? "unknown") else {
                return self?.rateLimitResponse() ?? .internalServerError
            }
            let metricType = self.stringParam(request, "type") ?? "steps"
            guard VALID_METRICS.contains(metricType) else {
                return self.errorResponse("Invalid request", code: 400)
            }
            guard let days = self.validatedDays(request) else {
                return self.errorResponse("Invalid request", code: 400)
            }

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
                    default: break
                    }
                } catch {
                    queryError = error
                }
                semaphore.signal()
            }
            semaphore.wait()

            if queryError != nil {
                print("[Routes] Metric query error: \(queryError!)")
                return self.errorResponse("Query failed")
            }
            let response = HealthMetricResponse(metric: metricType, daysRequested: days, samples: samples)
            return self.jsonResponse(response)
        }
    }

    // MARK: - /health/workouts

    private var workoutsHandler: ((HttpRequest) -> HttpResponse) {
        { [weak self] request in
            guard let self, self.checkRateLimit(for: request.address ?? "unknown") else {
                return self?.rateLimitResponse() ?? .internalServerError
            }
            guard let days = self.validatedDays(request) else {
                return self.errorResponse("Invalid request", code: 400)
            }

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

            if queryError != nil {
                print("[Routes] Workout query error: \(queryError!)")
                return self.errorResponse("Query failed")
            }
            let response = WorkoutResponse(daysRequested: days, workouts: workouts)
            return self.jsonResponse(response)
        }
    }

    // MARK: - /sync/bulk

    private var syncBulkHandler: ((HttpRequest) -> HttpResponse) {
        { [weak self] request in
            guard let self, self.checkRateLimit(for: request.address ?? "unknown") else {
                return self?.rateLimitResponse() ?? .internalServerError
            }
            let since = self.stringParam(request, "since")
            guard let days = self.validatedDays(request) else {
                return self.errorResponse("Invalid request", code: 400)
            }

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

            if queryError != nil {
                print("[Routes] Sync query error: \(queryError!)")
                return self.errorResponse("Query failed")
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

    // MARK: - /debug/sleep-raw (DEBUG only)

    #if DEBUG
    private var sleepRawHandler: ((HttpRequest) -> HttpResponse) {
        { [weak self] request in
            guard let self, self.checkRateLimit(for: request.address ?? "unknown") else {
                return self?.rateLimitResponse() ?? .internalServerError
            }
            guard let days = self.validatedDays(request) else {
                return self.errorResponse("Invalid request", code: 400)
            }

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
                                default: sleepValue = "unknown"
                                }

                                return [
                                    "start": isoFormatter.string(from: sample.startDate),
                                    "end": isoFormatter.string(from: sample.endDate),
                                    "type": sleepValue,
                                    "duration_min": round(sample.endDate.timeIntervalSince(sample.startDate) / 60 * 10) / 10,
                                    "source": sample.sourceRevision.source.name,
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

            if queryError != nil {
                return self.errorResponse("Query failed")
            }
            guard let data = try? JSONSerialization.data(withJSONObject: ["days": days, "count": result.count, "samples": result], options: .sortedKeys) else {
                return .internalServerError
            }
            return .raw(200, "OK", ["Content-Type": "application/json"]) { writer in
                try writer.write(data)
            }
        }
    }
    #endif

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

    private func rateLimitResponse() -> HttpResponse {
        let body: [String: String] = ["error": "Too many requests"]
        guard let data = try? JSONEncoder().encode(body) else {
            return .internalServerError
        }
        return .raw(429, "Too Many Requests", ["Content-Type": "application/json"]) { writer in
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
