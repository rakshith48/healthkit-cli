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
        // Observe key types to keep the app alive via background delivery.
        // Callbacks only update the timestamp — no expensive queries.
        let backgroundTypes: [(HKObjectType, HKUpdateFrequency)] = [
            (HKQuantityType.quantityType(forIdentifier: .stepCount)!, .hourly),
            (HKQuantityType.quantityType(forIdentifier: .heartRate)!, .hourly),
            (HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!, .hourly),
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

                // Just update the timestamp — don't run queries here.
                // BLE and HTTP serve live data on demand. The observer
                // keeps the app alive; no need to eagerly cache.
                DispatchQueue.main.async { [weak self] in
                    self?.lastBackgroundDelivery = Date()
                }

                // MUST call completion handler or iOS stops delivering
                completionHandler()
            }

            healthStore.execute(query)
            observerQueries.append(query)
        }
    }
}
