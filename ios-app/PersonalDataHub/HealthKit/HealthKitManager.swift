import Foundation
import HealthKit

@MainActor
class HealthKitManager: ObservableObject {
    let healthStore = HKHealthStore()

    @Published var isAuthorized = false
    @Published var authorizationError: String?

    private let readTypes: Set<HKObjectType> = {
        var types = Set<HKObjectType>()
        // Quantity types
        let quantityTypes: [HKQuantityTypeIdentifier] = [
            .stepCount,
            .heartRate,
            .heartRateVariabilitySDNN,
            .oxygenSaturation,
            .activeEnergyBurned,
            .distanceWalkingRunning,
        ]
        for id in quantityTypes {
            if let t = HKQuantityType.quantityType(forIdentifier: id) {
                types.insert(t)
            }
        }
        // Category types
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            types.insert(sleep)
        }
        // Workout type
        types.insert(HKObjectType.workoutType())
        return types
    }()

    @Published var lastBackgroundDelivery: Date?

    private var observerQueries: [HKObserverQuery] = []

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            authorizationError = "HealthKit not available on this device"
            return
        }
        do {
            try await healthStore.requestAuthorization(toShare: [], read: readTypes)
            isAuthorized = true
            enableBackgroundDelivery()
        } catch {
            authorizationError = error.localizedDescription
            isAuthorized = false
        }
    }

    // MARK: - Background Delivery

    private func enableBackgroundDelivery() {
        // Enable background delivery for key metrics
        // iOS will wake the app when new data arrives from Apple Watch, Ultrahuman, etc.
        let backgroundTypes: [(HKObjectType, HKUpdateFrequency)] = [
            (HKQuantityType.quantityType(forIdentifier: .heartRate)!, .immediate),
            (HKQuantityType.quantityType(forIdentifier: .stepCount)!, .hourly),
            (HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!, .hourly),
            (HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!, .immediate),
            (HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!, .immediate),
            (HKObjectType.workoutType(), .immediate),
        ]

        for (type, frequency) in backgroundTypes {
            healthStore.enableBackgroundDelivery(for: type, frequency: frequency) { success, error in
                if let error {
                    print("[HealthKit] Background delivery failed for \(type.identifier): \(error)")
                } else if success {
                    print("[HealthKit] Background delivery enabled for \(type.identifier)")
                }
            }

            // Set up observer query — this is what actually fires when new data arrives
            let query = HKObserverQuery(sampleType: type as! HKSampleType, predicate: nil) { [weak self] _, completionHandler, error in
                if let error {
                    print("[HealthKit] Observer error for \(type.identifier): \(error)")
                    completionHandler()
                    return
                }

                print("[HealthKit] Background delivery fired for \(type.identifier) at \(Date())")

                // Update the cache with latest data
                Task { @MainActor [weak self] in
                    self?.lastBackgroundDelivery = Date()
                    await self?.updateCache()
                }

                // MUST call completion handler or iOS stops delivering
                completionHandler()
            }

            healthStore.execute(query)
            observerQueries.append(query)
        }
    }

    // Called during background delivery windows to cache fresh data
    func updateCache() async {
        let cacheDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cache")

        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let timestamp = ISO8601DateFormatter().string(from: Date())

        func cacheMetric(_ name: String, samples: [HealthSample]) {
            let dict: [[String: Any]] = samples.map { ["date": $0.date, "value": $0.value, "unit": $0.unit] }
            let payload: [String: Any] = ["metric": name, "samples": dict, "_cached_at": timestamp]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted) {
                try? data.write(to: cacheDir.appendingPathComponent("\(name).json"))
            }
        }

        do { cacheMetric("steps", samples: try await self.querySteps(days: 7)) } catch { print("[Cache] steps: \(error)") }
        do { cacheMetric("heart_rate", samples: try await self.queryHeartRate(days: 7)) } catch { print("[Cache] heart_rate: \(error)") }
        do { cacheMetric("sleep", samples: try await self.querySleep(days: 7)) } catch { print("[Cache] sleep: \(error)") }
        do { cacheMetric("hrv", samples: try await self.queryHRV(days: 7)) } catch { print("[Cache] hrv: \(error)") }

        print("[Cache] Updated at \(timestamp)")
    }
}
