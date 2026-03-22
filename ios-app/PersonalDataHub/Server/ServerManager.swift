import Foundation
import Combine
import UIKit

@MainActor
class ServerManager: ObservableObject {
    @Published var isRunning = false
    @Published var serverURL = ""
    @Published var isBonjourAdvertising = false
    @Published var isBLEAdvertising = false
    @Published var bleConnectedCentrals = 0

    let healthKit = HealthKitManager()
    let httpServer = LocalHTTPServer()
    let bonjour = BonjourAdvertiser()
    let blePeripheral = BLEPeripheral()
    let auth = AuthManager()

    private var cancellables = Set<AnyCancellable>()
    private var routes: Routes?

    init() {
        httpServer.$isRunning
            .receive(on: DispatchQueue.main)
            .assign(to: &$isRunning)

        httpServer.$serverURL
            .receive(on: DispatchQueue.main)
            .assign(to: &$serverURL)

        bonjour.$isAdvertising
            .receive(on: DispatchQueue.main)
            .assign(to: &$isBonjourAdvertising)

        blePeripheral.$isAdvertising
            .receive(on: DispatchQueue.main)
            .assign(to: &$isBLEAdvertising)

        blePeripheral.$connectedCentrals
            .receive(on: DispatchQueue.main)
            .assign(to: &$bleConnectedCentrals)

        // Auto-restart HTTP server when app returns to foreground
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.restart()
            }
        }
    }

    func start() async {
        await healthKit.requestAuthorization()

        routes = Routes(healthKit: healthKit, auth: auth)
        httpServer.start(routes: routes!)
        bonjour.start()

        // Start BLE — this survives backgrounding
        blePeripheral.setHealthKit(healthKit)
        blePeripheral.startAdvertising()
    }

    func stop() {
        httpServer.stop()
        bonjour.stop()
        blePeripheral.stopAdvertising()
    }

    private func restart() {
        guard let routes else { return }
        httpServer.stop()
        bonjour.stop()
        httpServer.start(routes: routes)
        bonjour.start()
        // BLE doesn't need restart — it survives backgrounding
    }
}
