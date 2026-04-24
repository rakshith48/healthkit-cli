import SwiftUI

struct ContentView: View {
    @EnvironmentObject var serverManager: ServerManager
    @ObservedObject private var workoutQueue = WorkoutQueueStore.shared
    @State private var showFolderPicker = false

    var body: some View {
        NavigationView {
            List {
                Section("Server") {
                    HStack {
                        Circle()
                            .fill(serverManager.isRunning ? .green : .red)
                            .frame(width: 10, height: 10)
                        Text(serverManager.isRunning ? "Running" : "Stopped")
                            .font(.headline)
                    }

                    if !serverManager.serverURL.isEmpty {
                        HStack {
                            Text(serverManager.serverURL)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary)
                            Spacer()
                            Button(action: {
                                UIPasteboard.general.string = serverManager.serverURL
                            }) {
                                Image(systemName: "doc.on.doc")
                            }
                        }
                    }
                }

                Section("Pairing") {
                    HStack {
                        Text("Pairing Code")
                        Spacer()
                        Text(serverManager.auth.pairingCode)
                            .font(.system(.title2, design: .monospaced))
                            .fontWeight(.bold)
                            .foregroundColor(.blue)
                    }

                    Button("Generate New Code") {
                        serverManager.auth.regeneratePairingCode()
                    }

                    if !serverManager.auth.pairedDevices.isEmpty {
                        ForEach(serverManager.auth.pairedDevices) { device in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(device.name)
                                        .font(.subheadline)
                                    Text(device.pairedAt, style: .relative)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    serverManager.auth.revokeDevice(device)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.red)
                                }
                            }
                        }
                    }
                }

                Section("Obsidian Vault") {
                    if serverManager.folderAccess.hasAccess {
                        HStack {
                            Text("Vault")
                            Spacer()
                            Text(serverManager.folderAccess.vaultPath)
                                .foregroundColor(.green)
                        }
                        HStack {
                            Text("Markdown files")
                            Spacer()
                            Text("\(serverManager.folderAccess.fileCount)")
                                .foregroundColor(.secondary)
                        }
                        Button("Change Vault") {
                            showFolderPicker = true
                        }
                    } else {
                        Button("Link Obsidian Vault") {
                            showFolderPicker = true
                        }
                        .font(.headline)
                    }
                }

                Section("Workouts") {
                    if #available(iOS 17.0, *) {
                        NavigationLink {
                            WorkoutQueueView()
                        } label: {
                            HStack {
                                Text("Pending")
                                Spacer()
                                if workoutQueue.pending.isEmpty {
                                    Text("0").foregroundColor(.secondary)
                                } else {
                                    Text("\(workoutQueue.pending.count)")
                                        .fontWeight(.bold)
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    } else {
                        Text("Requires iOS 17+").foregroundColor(.secondary)
                    }
                }

                Section("HealthKit") {
                    HStack {
                        Text("Authorization")
                        Spacer()
                        Text(serverManager.healthKit.isAuthorized ? "Granted" : "Not Granted")
                            .foregroundColor(serverManager.healthKit.isAuthorized ? .green : .orange)
                    }

                    if let lastBG = serverManager.healthKit.lastBackgroundDelivery {
                        HStack {
                            Text("Last Background Update")
                            Spacer()
                            Text(lastBG, style: .relative)
                                .foregroundColor(.secondary)
                        }
                    }

                    if let error = serverManager.healthKit.authorizationError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                Section("Bluetooth") {
                    HStack {
                        Text("BLE Peripheral")
                        Spacer()
                        Text(serverManager.isBLEAdvertising ? "Advertising" : "Off")
                            .foregroundColor(serverManager.isBLEAdvertising ? .green : .secondary)
                    }
                    HStack {
                        Text("Connected Centrals")
                        Spacer()
                        Text("\(serverManager.bleConnectedCentrals)")
                            .foregroundColor(serverManager.bleConnectedCentrals > 0 ? .green : .secondary)
                    }
                }

                Section {
                    Button(serverManager.isRunning ? "Stop Server" : "Start Server") {
                        if serverManager.isRunning {
                            serverManager.stop()
                        } else {
                            Task {
                                await serverManager.start()
                            }
                        }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Data Hub")
        }
        .sheet(isPresented: $showFolderPicker) {
            FolderPicker { url in
                serverManager.folderAccess.saveAccess(to: url)
            }
        }
        .task {
            await serverManager.start()
        }
    }
}
