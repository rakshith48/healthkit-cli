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

    // Workout upload — Mac writes chunked JSON payload to push WorkoutSpec(s)
    // to the queue. Stays alive while app is backgrounded; unlike HTTP.
    static let workoutUploadUUID = CBUUID(string: "A1B2C3D4-00FD-7890-ABCD-EF1234567890")
}

class BLEPeripheral: NSObject, ObservableObject {
    @Published var isAdvertising = false
    @Published var connectedCentrals = 0

    private var peripheralManager: CBPeripheralManager!
    private var service: CBMutableService?
    private var responseCharacteristic: CBMutableCharacteristic?
    private var subscribedCentrals: [CBCentral] = []

    private var healthKit: HealthKitManager?
    var folderAccess: FolderAccessManager?
    var merkleTree: MerkleTreeBuilder?

    // Chunked transfer state
    private var pendingResponse: Data?
    private var pendingOffset = 0

    // Workout upload reassembly (writes from Mac)
    private var workoutUpload = WorkoutUploadAssembler()
    private let workoutUploadTimeout: TimeInterval = 10

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

        // Workout upload characteristic — Mac writes chunked JSON payloads
        let workoutUploadChar = CBMutableCharacteristic(
            type: BLEConstants.workoutUploadUUID,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )

        let service = CBMutableService(type: BLEConstants.serviceUUID, primary: true)
        service.characteristics = [requestChar, responseChar, statusChar, workoutUploadChar]
        self.service = service

        peripheralManager.add(service)
    }

    // MARK: - Workout upload handling

    private func handleWorkoutUpload(_ chunk: Data) {
        // Reset stale uploads before accepting new bytes so a crashed client
        // can recover on the next attempt.
        if workoutUpload.isStale(timeout: workoutUploadTimeout) {
            print("[BLE] Workout upload timed out — resetting buffer")
            workoutUpload.reset()
        }

        let result = workoutUpload.receive(chunk)

        switch result {
        case .idle:
            break
        case .inProgress(let received, let expected):
            print("[BLE] Workout upload progress: \(received)/\(expected)")
        case .error(let msg):
            print("[BLE] Workout upload error: \(msg)")
            sendResponse(["error": msg])
        case .complete(let payload):
            workoutUpload.reset()
            finalizeWorkoutUpload(payload: payload)
        }
    }

    private func finalizeWorkoutUpload(payload: Data) {
        print("[BLE] Workout upload complete: \(payload.count) bytes")

        if #available(iOS 17.0, *) {
            let decoder = JSONDecoder()
            var specs: [WorkoutSpec] = []
            if let single = try? decoder.decode(WorkoutSpec.self, from: payload) {
                specs = [single]
            } else if let batch = try? decoder.decode(WorkoutQueueBatch.self, from: payload) {
                specs = batch.workouts
            } else {
                sendResponse(["error": "Invalid workout spec JSON"])
                return
            }

            var accepted: [String] = []
            var rejected: [[String: String]] = []
            for spec in specs {
                do {
                    _ = try WorkoutBuilder.build(from: spec)
                    WorkoutQueueStore.shared.enqueue(spec)
                    accepted.append(spec.id)
                } catch {
                    rejected.append(["id": spec.id, "error": error.localizedDescription])
                }
            }

            sendResponse([
                "accepted": accepted,
                "rejected": rejected,
                "pending_count": WorkoutQueueStore.shared.pending.count + accepted.count,
                "_source": "ble"
            ] as [String: Any])
        } else {
            sendResponse(["error": "WorkoutKit requires iOS 17+"])
        }
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

                case "merkle_root":
                    if let mt = self.merkleTree, let root = mt.getRoot() {
                        var count = 0
                        func countFiles(_ n: MerkleNode) { if !n.isDir { count += 1 } else { n.children.forEach { countFiles($0) } } }
                        countFiles(root)
                        result = ["hash": root.hash, "count": count] as [String: Any]
                    } else {
                        result = ["error": "No vault linked"]
                    }

                case "merkle_node":
                    let nodePath = parts.count > 1 ? parts.dropFirst().joined(separator: ":") : ""
                    if let mt = self.merkleTree, let node = mt.findNode(path: String(nodePath)) {
                        result = node.shallowDict()
                    } else {
                        result = ["error": "Node not found"]
                    }

                case "vault_list":
                    if let fa = self.folderAccess, fa.hasAccess {
                        let files = fa.listFiles()
                        result = ["count": files.count, "files": files] as [String: Any]
                    } else {
                        result = ["error": "No vault linked"]
                    }

                case "vault_read":
                    // Command format: vault_read:relative/path.md
                    let readPath = parts.count > 1 ? parts.dropFirst().joined(separator: ":") : ""
                    if let fa = self.folderAccess, fa.hasAccess, !readPath.isEmpty {
                        if let content = fa.readFile(relativePath: String(readPath)) {
                            result = ["path": String(readPath), "content": content, "size": content.count] as [String: Any]
                        } else {
                            result = ["error": "File not found"]
                        }
                    } else {
                        result = ["error": "No vault linked or missing path"]
                    }

                default:
                    result = ["error": "Unknown command"]
                }

                self.sendResponse(result)
            } catch {
                print("[BLE] Query error: \(error)")
                self.sendResponse(["error": "Query failed"])
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
            } else if request.characteristic.uuid == BLEConstants.workoutUploadUUID {
                if let data = request.value {
                    handleWorkoutUpload(data)
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
