import BackgroundTasks
import Foundation

enum BackgroundSync {
    static let taskIdentifier = "com.personaldatahub.app.refresh"

    // Populated from ServerManager once the manager is available.
    // Stays nil until then — the handler no-ops safely in that window.
    static weak var healthKit: HealthKitManager?

    /// Call once at app launch. Registers the handler iOS invokes when it
    /// decides to run our background task.
    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            guard let task = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handleRefresh(task: task)
        }
    }

    /// Ask iOS to run our task "no sooner than" the specified delay.
    /// iOS may run it later (or not at all) based on battery, network, usage patterns.
    static func schedule() {
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        // TODO (user): tune this. Shorter = more frequent attempts but iOS may throttle.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60) // 1 hour

        do {
            try BGTaskScheduler.shared.submit(request)
            print("[BGSync] Scheduled next refresh")
        } catch {
            print("[BGSync] Failed to schedule: \(error)")
        }
    }

    // MARK: - Task handler

    private static func handleRefresh(task: BGProcessingTask) {
        // ALWAYS reschedule first so the cadence continues even if this run fails.
        schedule()

        // iOS gives us limited time. If it expires, we must cancel gracefully.
        task.expirationHandler = {
            // TODO (user): cancel any in-flight work here if needed.
            task.setTaskCompleted(success: false)
        }

        guard let healthKit else {
            task.setTaskCompleted(success: false)
            return
        }

        Task { @MainActor in
            let success = await performBackgroundWork(healthKit: healthKit)
            task.setTaskCompleted(success: success)
        }
    }

    /// Snapshot the last 24h of HealthKit data and persist it so the CLI
    /// can serve it from disk even if the phone is force-quit or unreachable.
    @MainActor
    private static func performBackgroundWork(healthKit: HealthKitManager) async -> Bool {
        do {
            let summary = try await healthKit.querySummary(days: 1)
            let payload = OfflineSnapshot(
                capturedAt: ISO8601DateFormatter().string(from: Date()),
                daily: summary
            )
            try writeSnapshot(payload)
            print("[BGSync] Cached \(summary.count) day(s) of summary data")
            return true
        } catch {
            print("[BGSync] Background work failed: \(error)")
            return false
        }
    }

    // MARK: - Offline cache

    struct OfflineSnapshot: Codable {
        let capturedAt: String
        let daily: [HealthDaySummary]
    }

    static var snapshotURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("offline_snapshot.json")
    }

    private static func writeSnapshot(_ snapshot: OfflineSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: snapshotURL, options: .atomic)
    }

    /// Read the last persisted snapshot, if any. Safe to call from any actor.
    static func readSnapshot() -> OfflineSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        return try? JSONDecoder().decode(OfflineSnapshot.self, from: data)
    }
}
