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
    let folderAccess: FolderAccessManager
    let merkleTree: MerkleTreeBuilder
    private var requestCounts: [String: (count: Int, resetAt: Date)] = [:]

    init(healthKit: HealthKitManager, auth: AuthManager, folderAccess: FolderAccessManager) {
        self.healthKit = healthKit
        self.auth = auth
        self.folderAccess = folderAccess
        self.merkleTree = MerkleTreeBuilder(folderAccess: folderAccess)
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

        // Vault endpoints
        server["/vault/list"] = authenticated(vaultListHandler)
        server["/vault/read"] = authenticated(vaultReadHandler)
        server["/vault/write"] = authenticated(vaultWriteHandler)

        // Merkle tree endpoints
        server["/vault/merkle/root"] = authenticated(merkleRootHandler)
        server["/vault/merkle/node"] = authenticated(merkleNodeHandler)
        server["/vault/merkle/diff"] = authenticated(merkleDiffHandler)

        // Workout queue endpoints (WorkoutKit, iOS 17+)
        server.POST["/workouts/queue"] = authenticated(workoutQueuePostHandler)
        server.GET["/workouts/queue"] = authenticated(workoutQueueListHandler)
        server.DELETE["/workouts/queue"] = authenticated(workoutQueueDeleteHandler)

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

    // MARK: - /vault/list

    private var vaultListHandler: ((HttpRequest) -> HttpResponse) {
        { [weak self] request in
            guard let self, self.checkRateLimit(for: request.address ?? "unknown") else {
                return self?.rateLimitResponse() ?? .internalServerError
            }
            guard self.folderAccess.hasAccess else {
                return self.errorResponse("No vault linked. Open the app and tap 'Link Obsidian Vault'.")
            }
            let files = self.folderAccess.listFiles()
            guard let data = try? JSONSerialization.data(withJSONObject: ["files": files, "count": files.count], options: .sortedKeys) else {
                return .internalServerError
            }
            return .raw(200, "OK", ["Content-Type": "application/json"]) { writer in
                try writer.write(data)
            }
        }
    }

    // MARK: - /vault/read?path=relative/path.md

    private var vaultReadHandler: ((HttpRequest) -> HttpResponse) {
        { [weak self] request in
            guard let self, self.checkRateLimit(for: request.address ?? "unknown") else {
                return self?.rateLimitResponse() ?? .internalServerError
            }
            guard self.folderAccess.hasAccess else {
                return self.errorResponse("No vault linked.")
            }
            guard let rawPath = self.stringParam(request, "path"), !rawPath.isEmpty else {
                return self.errorResponse("Missing 'path' parameter", code: 400)
            }
            let path = rawPath.removingPercentEncoding ?? rawPath
            // Prevent directory traversal
            guard !path.contains("..") else {
                return self.errorResponse("Invalid path", code: 400)
            }
            guard let content = self.folderAccess.readFile(relativePath: path) else {
                return self.errorResponse("File not found", code: 404)
            }
            let response: [String: Any] = ["path": path, "content": content, "size": content.count]
            guard let data = try? JSONSerialization.data(withJSONObject: response, options: .sortedKeys) else {
                return .internalServerError
            }
            return .raw(200, "OK", ["Content-Type": "application/json"]) { writer in
                try writer.write(data)
            }
        }
    }

    // MARK: - /vault/write (POST, JSON body: {"path": "...", "content": "..."})

    private var vaultWriteHandler: ((HttpRequest) -> HttpResponse) {
        { [weak self] request in
            guard let self, self.checkRateLimit(for: request.address ?? "unknown") else {
                return self?.rateLimitResponse() ?? .internalServerError
            }
            guard self.folderAccess.hasAccess else {
                return self.errorResponse("No vault linked.")
            }
            let bodyData = Data(request.body.map { UInt8($0) })
            guard let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: String],
                  let path = json["path"], !path.isEmpty,
                  let content = json["content"] else {
                return self.errorResponse("Missing 'path' or 'content' in body", code: 400)
            }
            guard !path.contains("..") else {
                return self.errorResponse("Invalid path", code: 400)
            }
            let success = self.folderAccess.writeFile(relativePath: path, content: content)
            let response: [String: Any] = ["path": path, "written": success]
            guard let data = try? JSONSerialization.data(withJSONObject: response, options: .sortedKeys) else {
                return .internalServerError
            }
            return .raw(success ? 200 : 500, success ? "OK" : "Error", ["Content-Type": "application/json"]) { writer in
                try writer.write(data)
            }
        }
    }

    // MARK: - /workouts/queue (POST) — push a new workout spec

    private var workoutQueuePostHandler: ((HttpRequest) -> HttpResponse) {
        { [weak self] request in
            guard let self, self.checkRateLimit(for: request.address ?? "unknown") else {
                return self?.rateLimitResponse() ?? .internalServerError
            }

            let bodyData = Data(request.body.map { UInt8($0) })

            // Accept either a single spec or an array of specs under {"workouts": [...]}
            let decoder = JSONDecoder()
            var specs: [WorkoutSpec] = []

            if let single = try? decoder.decode(WorkoutSpec.self, from: bodyData) {
                specs = [single]
            } else if let wrapped = try? decoder.decode(WorkoutQueueBatch.self, from: bodyData) {
                specs = wrapped.workouts
            } else {
                return self.errorResponse("Invalid workout spec JSON", code: 400)
            }

            if #available(iOS 17.0, *) {
                // Validate each spec builds before persisting — catch errors early
                var errors: [[String: String]] = []
                var accepted: [String] = []
                for spec in specs {
                    do {
                        _ = try WorkoutBuilder.build(from: spec)
                        WorkoutQueueStore.shared.enqueue(spec)
                        accepted.append(spec.id)
                    } catch {
                        errors.append(["id": spec.id, "error": error.localizedDescription])
                    }
                }
                let response: [String: Any] = [
                    "accepted": accepted,
                    "rejected": errors,
                    "pending_count": WorkoutQueueStore.shared.pending.count + accepted.count
                ]
                guard let data = try? JSONSerialization.data(withJSONObject: response, options: .sortedKeys) else {
                    return .internalServerError
                }
                return .raw(200, "OK", ["Content-Type": "application/json"]) { writer in
                    try writer.write(data)
                }
            } else {
                return self.errorResponse("WorkoutKit requires iOS 17+", code: 400)
            }
        }
    }

    // MARK: - /workouts/queue (GET) — list queued workouts

    private var workoutQueueListHandler: ((HttpRequest) -> HttpResponse) {
        { [weak self] request in
            guard let self, self.checkRateLimit(for: request.address ?? "unknown") else {
                return self?.rateLimitResponse() ?? .internalServerError
            }
            if #available(iOS 17.0, *) {
                let queue = WorkoutQueueStore.shared.queue
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                guard let data = try? encoder.encode(["queue": queue]) else {
                    return .internalServerError
                }
                return .raw(200, "OK", ["Content-Type": "application/json"]) { writer in
                    try writer.write(data)
                }
            } else {
                return self.errorResponse("WorkoutKit requires iOS 17+", code: 400)
            }
        }
    }

    // MARK: - /workouts/queue (DELETE) — clear or remove one by ?id=

    private var workoutQueueDeleteHandler: ((HttpRequest) -> HttpResponse) {
        { [weak self] request in
            guard let self, self.checkRateLimit(for: request.address ?? "unknown") else {
                return self?.rateLimitResponse() ?? .internalServerError
            }
            if #available(iOS 17.0, *) {
                if let id = self.stringParam(request, "id") {
                    WorkoutQueueStore.shared.remove(id: id)
                    let body: [String: Any] = ["removed": id]
                    guard let data = try? JSONSerialization.data(withJSONObject: body) else { return .internalServerError }
                    return .raw(200, "OK", ["Content-Type": "application/json"]) { writer in
                        try writer.write(data)
                    }
                } else {
                    WorkoutQueueStore.shared.clearAll()
                    let body: [String: Any] = ["cleared": true]
                    guard let data = try? JSONSerialization.data(withJSONObject: body) else { return .internalServerError }
                    return .raw(200, "OK", ["Content-Type": "application/json"]) { writer in
                        try writer.write(data)
                    }
                }
            } else {
                return self.errorResponse("WorkoutKit requires iOS 17+", code: 400)
            }
        }
    }

    // MARK: - /vault/merkle/root

    private var merkleRootHandler: ((HttpRequest) -> HttpResponse) {
        { [weak self] request in
            guard let self, self.checkRateLimit(for: request.address ?? "unknown") else {
                return self?.rateLimitResponse() ?? .internalServerError
            }
            guard let root = self.merkleTree.getRoot() else {
                return self.errorResponse("No vault linked")
            }
            let count = self.countNodes(root)
            let response: [String: Any] = ["hash": root.hash, "count": count]
            guard let data = try? JSONSerialization.data(withJSONObject: response, options: .sortedKeys) else {
                return .internalServerError
            }
            return .raw(200, "OK", ["Content-Type": "application/json"]) { writer in
                try writer.write(data)
            }
        }
    }

    // MARK: - /vault/merkle/node?path=

    private var merkleNodeHandler: ((HttpRequest) -> HttpResponse) {
        { [weak self] request in
            guard let self, self.checkRateLimit(for: request.address ?? "unknown") else {
                return self?.rateLimitResponse() ?? .internalServerError
            }
            let rawPath = self.stringParam(request, "path") ?? ""
            let path = rawPath.removingPercentEncoding ?? rawPath
            guard let node = self.merkleTree.findNode(path: path) else {
                return self.errorResponse("Node not found", code: 404)
            }
            guard let data = try? JSONSerialization.data(withJSONObject: node.shallowDict(), options: .sortedKeys) else {
                return .internalServerError
            }
            return .raw(200, "OK", ["Content-Type": "application/json"]) { writer in
                try writer.write(data)
            }
        }
    }

    // MARK: - /vault/merkle/diff (POST)

    private var merkleDiffHandler: ((HttpRequest) -> HttpResponse) {
        { [weak self] request in
            guard let self, self.checkRateLimit(for: request.address ?? "unknown") else {
                return self?.rateLimitResponse() ?? .internalServerError
            }
            let bodyData = Data(request.body.map { UInt8($0) })
            guard let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
                  let path = json["path"] as? String,
                  let children = json["children"] as? [String: String] else {
                return self.errorResponse("Invalid request", code: 400)
            }
            let result = self.merkleTree.diff(path: path, clientHashes: children)
            guard let data = try? JSONSerialization.data(withJSONObject: result, options: .sortedKeys) else {
                return .internalServerError
            }
            return .raw(200, "OK", ["Content-Type": "application/json"]) { writer in
                try writer.write(data)
            }
        }
    }

    private func countNodes(_ node: MerkleNode) -> Int {
        if !node.isDir { return 1 }
        return node.children.reduce(0) { $0 + countNodes($1) }
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
