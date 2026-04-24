import SwiftUI

@main
struct PersonalDataHubApp: App {
    @StateObject private var serverManager = ServerManager()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Must register BEFORE the app finishes launching.
        // The HealthKitManager is attached later by ServerManager.
        BackgroundSync.register()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(serverManager)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                BackgroundSync.schedule()
            }
        }
    }
}
