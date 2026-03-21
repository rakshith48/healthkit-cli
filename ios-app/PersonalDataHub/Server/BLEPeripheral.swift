import Foundation
import CoreBluetooth
import UIKit

// Custom UUIDs for Personal Data Hub BLE service
struct BLEConstants {
    static let serviceUUID = CBUUID(string: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")

    // Characteristics — one per data type
    static let statusUUID = CBUUID(string: "A1B2C3D4-0001-7890-ABCD-EF1234567890")
    static let stepsUUID = CBUUID(string: "A1B2C3D4-0002-7890-ABCD-EF1234567890")
    static let heartRateUUID = CBUUID(string: "A1B2C3D4-0003-7890-ABCD-EF1234567890")
    static let sleepUUID = CBUUID(string: "A1B2C3D4-0004-7890-ABCD-EF1234567890")
    static let hrvUUID = CBUUID(string: "A1B2C3D4-0005-7890-ABCD-EF1234567890")
    static let workoutsUUID = CBUUID(string: "A1B2C3D4-0006-7890-ABCD-EF1234567890")
    static let summaryUUID = CBUUID(string: "A1B2C3D4-0007-7890-ABCD-EF1234567890")

    // Control characteristic — Mac writes a request, iPhone responds via notify
    static let requestUUID = CBUUID(string: "A1B2C3D4-00FF-7890-ABCD-EF1234567890")
    static let responseUUID = CBUUID(string: "A1B2C3D4-00FE-7890-ABCD-EF1234567890")
}

class BLEPeripheral: NSObject, ObservableObject {
    @Published var isAdvertising = false
    @Published var connectedCentrals = 0

    private var peripheralManager: CBPeripheralManager!
    private var service: CBMutableService?
    private var responseCharacteristic: CBMutableCharacteristic?
    private var subscribedCentrals: [CBCentral] = []

    private var healthKit: HealthKitManager?

    // Chunked transfer state
    private var pendingResponse: Data?
    private var pendingOffset = 0

    override init() {
        super.init()
        // Use restoration ID so iOS can relaunch us for BLE events
        peripheralManager = CBPeripheralManager(
            delegate: self,
            queue: DispatchQueue(label: "ble.peripheral"),
            options: [CBPeripheralManagerOptionRestoreIdentifierKey: "PersonalDataHubBLE"]
        )
    }

    func setHealthKit(_ hk: HealthKitManager) {
        self.healthKit = hk
    }

    func startAdvertising() {
        guard peripheralManager.state == .poweredOn else {
            print("[BLE] Cannot advertise — Bluetooth not powered on (state: \(peripheralManager.state.rawValue))")
            return
        }
        guard !isAdvertising else { return }

        setupService()

        peripheralManager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [BLEConstants.serviceUUID],
            CBAdvertisementDataLocalNameKey: "DataHub"
        ])
    }

    func stopAdvertising() {
        peripheralManager.stopAdvertising()
        DispatchQueue.main.async {
            self.isAdvertising = false
        }
    }

    private func setupService() {
        // Remove any existing services
        peripheralManager.removeAllServices()

        // Request characteristic — Mac writes a command here (e.g., "steps:7")
        let requestChar = CBMutableCharacteristic(
            type: BLEConstants.requestUUID,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )

        // Response characteristic — iPhone sends data back via notifications
        let responseChar = CBMutableCharacteristic(
            type: BLEConstants.responseUUID,
            properties: [.notify, .read],
            value: nil,
            permissions: [.readable]
        )
        self.responseCharacteristic = responseChar

        // Status characteristic — always readable, small payload
        let statusChar = CBMutableCharacteristic(
            type: BLEConstants.statusUUID,
            properties: [.read],
            value: nil,
            permissions: [.readable]
        )

        let service = CBMutableService(type: BLEConstants.serviceUUID, primary: true)
        service.characteristics = [requestChar, responseChar, statusChar]
        self.service = service

        peripheralManager.add(service)
    }

    // MARK: - Handle requests from Mac

    private func handleRequest(_ data: Data) {
        guard let command = String(data: data, encoding: .utf8) else { return }
        print("[BLE] Received request: \(command)")

        // Parse command: "metric:days" e.g., "steps:7", "sleep:3", "summary:7", "status"
        let parts = command.split(separator: ":")
        let metric = String(parts[0])
        let days = parts.count > 1 ? Int(parts[1]) ?? 7 : 7

        Task { @MainActor in
            guard let hk = self.healthKit else {
                self.sendResponse(["error": "HealthKit not initialized"])
                return
            }

            do {
                var result: Any

                switch metric {
                case "status":
                    result = [
                        "online": true,
                        "device": UIDevice.current.name,
                        "ios_version": UIDevice.current.systemVersion,
                        "healthkit_authorized": hk.isAuthorized,
                        "ble": true,
                        "timestamp": ISO8601DateFormatter().string(from: Date())
                    ] as [String: Any]

                case "steps":
                    let samples = try await hk.querySteps(days: days)
                    result = ["metric": "steps", "days_requested": days,
                              "samples": samples.map { ["date": $0.date, "value": $0.value, "unit": $0.unit] }] as [String: Any]

                case "heart_rate":
                    let samples = try await hk.queryHeartRate(days: days)
                    result = ["metric": "heart_rate", "days_requested": days,
                              "samples": samples.map { ["date": $0.date, "value": $0.value, "unit": $0.unit] }] as [String: Any]

                case "sleep":
                    let samples = try await hk.querySleep(days: days)
                    result = ["metric": "sleep", "days_requested": days,
                              "samples": samples.map { ["date": $0.date, "value": $0.value, "unit": $0.unit] }] as [String: Any]

                case "hrv":
                    let samples = try await hk.queryHRV(days: days)
                    result = ["metric": "hrv", "days_requested": days,
                              "samples": samples.map { ["date": $0.date, "value": $0.value, "unit": $0.unit] }] as [String: Any]

                case "workouts":
                    let workouts = try await hk.queryWorkouts(days: days)
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = .sortedKeys
                    if let jsonData = try? encoder.encode(WorkoutResponse(daysRequested: days, workouts: workouts)),
                       let jsonObj = try? JSONSerialization.jsonObject(with: jsonData) {
                        result = jsonObj
                    } else {
                        result = ["days_requested": days, "workouts": []] as [String: Any]
                    }

                case "summary":
                    let summaries = try await hk.querySummary(days: days)
                    result = ["days_requested": days,
                              "daily": summaries.map { [
                                "date": $0.date, "steps": $0.steps,
                                "heart_rate_avg": $0.heartRateAvg,
                                "sleep_hours": $0.sleepHours,
                                "active_calories": $0.activeCalories,
                                "distance_km": $0.distanceKm
                              ] }] as [String: Any]

                default:
                    result = ["error": "Unknown metric: \(metric)"]
                }

                self.sendResponse(result)
            } catch {
                self.sendResponse(["error": error.localizedDescription])
            }
        }
    }

    private func sendResponse(_ object: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys) else {
            print("[BLE] Failed to serialize response")
            return
        }

        guard let characteristic = responseCharacteristic else { return }

        // BLE has MTU limits (~512 bytes). We need to chunk large responses.
        // Protocol: [4 bytes total length] + [chunked data] + [4 bytes 0x00000000 = end]

        var lengthPrefix = UInt32(data.count).bigEndian
        let header = Data(bytes: &lengthPrefix, count: 4)

        let fullPayload = header + data

        // Send in chunks that fit the MTU (conservative: 180 bytes per chunk)
        let chunkSize = 180
        var offset = 0

        DispatchQueue(label: "ble.send").async {
            while offset < fullPayload.count {
                let end = min(offset + chunkSize, fullPayload.count)
                let chunk = fullPayload[offset..<end]

                let sent = self.peripheralManager.updateValue(
                    Data(chunk),
                    for: characteristic,
                    onSubscribedCentrals: nil
                )

                if !sent {
                    // Queue is full — wait for peripheralManagerIsReady callback
                    // For now, just retry after a small delay
                    Thread.sleep(forTimeInterval: 0.05)
                    continue
                }

                offset = end
            }

            // Send end marker
            var endMarker = UInt32(0).bigEndian
            let endData = Data(bytes: &endMarker, count: 4)
            self.peripheralManager.updateValue(endData, for: characteristic, onSubscribedCentrals: nil)

            print("[BLE] Sent response: \(data.count) bytes in \((fullPayload.count + chunkSize - 1) / chunkSize) chunks")
        }
    }
}

// MARK: - CBPeripheralManagerDelegate

extension BLEPeripheral: CBPeripheralManagerDelegate {

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        print("[BLE] State changed: \(peripheral.state.rawValue)")
        if peripheral.state == .poweredOn {
            startAdvertising()
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        // State restoration — iOS relaunched us for a BLE event
        print("[BLE] State restored")
        if let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] {
            for service in services {
                if let chars = service.characteristics {
                    for char in chars {
                        if char.uuid == BLEConstants.responseUUID {
                            self.responseCharacteristic = char as? CBMutableCharacteristic
                        }
                    }
                }
            }
        }
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        DispatchQueue.main.async {
            if let error {
                let nsError = error as NSError
                if nsError.domain == CBErrorDomain && nsError.code == 9 {
                    // "Advertising has already started" — this is fine, treat as success
                    print("[BLE] Advertising already active (restored from background)")
                    self.isAdvertising = true
                } else {
                    print("[BLE] Advertising failed: \(error)")
                    self.isAdvertising = false
                }
            } else {
                print("[BLE] Advertising started")
                self.isAdvertising = true
            }
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            print("[BLE] Failed to add service: \(error)")
        } else {
            print("[BLE] Service added: \(service.uuid)")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        print("[BLE] Central subscribed to \(characteristic.uuid)")
        if !subscribedCentrals.contains(where: { $0.identifier == central.identifier }) {
            subscribedCentrals.append(central)
        }
        DispatchQueue.main.async {
            self.connectedCentrals = self.subscribedCentrals.count
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        print("[BLE] Central unsubscribed from \(characteristic.uuid)")
        subscribedCentrals.removeAll { $0.identifier == central.identifier }
        DispatchQueue.main.async {
            self.connectedCentrals = self.subscribedCentrals.count
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            if request.characteristic.uuid == BLEConstants.requestUUID {
                if let data = request.value {
                    handleRequest(data)
                }
                peripheral.respond(to: request, withResult: .success)
            } else {
                peripheral.respond(to: request, withResult: .requestNotSupported)
            }
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        if request.characteristic.uuid == BLEConstants.statusUUID {
            let status: [String: Any] = [
                "online": true,
                "device": "iPhone",
                "ble": true
            ]
            if let data = try? JSONSerialization.data(withJSONObject: status) {
                request.value = data[request.offset..<min(request.offset + (request.central.maximumUpdateValueLength), data.count)]
                peripheral.respond(to: request, withResult: .success)
            } else {
                peripheral.respond(to: request, withResult: .unlikelyError)
            }
        } else {
            peripheral.respond(to: request, withResult: .requestNotSupported)
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        // Queue cleared — can resume sending chunks
        print("[BLE] Ready to update subscribers")
    }
}
