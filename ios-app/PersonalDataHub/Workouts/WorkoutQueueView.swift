import SwiftUI
import WorkoutKit
import os

@available(iOS 17.0, *)
private let log = Logger(subsystem: "com.personaldatahub.app", category: "workout-preview")

@available(iOS 17.0, *)
struct WorkoutQueueView: View {
    @ObservedObject private var store = WorkoutQueueStore.shared

    // Non-optional plan so `.workoutPreview` can be attached stably. Initialised
    // with a tiny placeholder that never gets shown — replaced before
    // `showPreview` flips to true.
    @State private var previewPlan: WorkoutPlan = WorkoutQueueView.placeholderPlan()
    @State private var previewingSpec: WorkoutSpec?
    @State private var showPreview = false
    @State private var buildError: String?

    private static func placeholderPlan() -> WorkoutPlan {
        WorkoutPlan(
            .custom(
                CustomWorkout(
                    activity: .running,
                    location: .outdoor,
                    displayName: "Loading…",
                    blocks: []
                )
            )
        )
    }

    var body: some View {
        List {
            if store.pending.isEmpty {
                Text("No workouts queued. Push from your Mac with `healthkit-cli workout queue`.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                Section("Queued (\(store.pending.count))") {
                    ForEach(store.pending) { q in
                        WorkoutRow(
                            queued: q,
                            onPreview: { openPreview(for: q.spec) },
                            onDismiss: { store.remove(id: q.id) }
                        )
                    }
                }
            }

            if let err = buildError {
                Section("Error") {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Workouts")
        .workoutPreview(previewPlan, isPresented: $showPreview)
        .onChange(of: showPreview) { _, visible in
            log.info("showPreview changed to \(visible)")
            // Apple doesn't expose a "did user actually save?" callback, so we
            // keep the workout in pending. The user taps "Mark Saved" explicitly
            // once they've confirmed the workout landed on their Watch.
            if !visible {
                previewingSpec = nil
            }
        }
    }

    private func openPreview(for spec: WorkoutSpec) {
        buildError = nil
        log.info("openPreview tapped for: \(spec.displayName)")
        do {
            let workout = try WorkoutBuilder.build(from: spec)
            let name = workout.displayName ?? "<no name>"
            log.info("Built CustomWorkout '\(name)' with \(workout.blocks.count) blocks")
            previewingSpec = spec
            previewPlan = WorkoutPlan(.custom(workout))
            showPreview = true
            log.info("showPreview set to true")
        } catch {
            let msg = "Failed to build '\(spec.displayName)': \(error.localizedDescription)"
            log.error("\(msg)")
            buildError = msg
        }
    }
}

@available(iOS 17.0, *)
private struct WorkoutRow: View {
    let queued: QueuedWorkout
    let onPreview: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(queued.spec.displayName)
                .font(.headline)
            HStack {
                Text(summary).font(.caption).foregroundColor(.secondary)
                Spacer()
                Text(queued.receivedAt, style: .relative)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 8) {
                Button(action: onPreview) {
                    Label("Preview + Save", systemImage: "arrow.up.forward.app")
                        .font(.footnote)
                }
                .buttonStyle(.borderedProminent)

                Spacer()

                Button(role: .destructive, action: onDismiss) {
                    Image(systemName: "xmark.circle")
                        .font(.footnote)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }

    private var summary: String {
        let activity = queued.spec.activity ?? "running"
        let blocks = queued.spec.blocks.count
        let stepsTotal = queued.spec.blocks.reduce(0) { $0 + $1.steps.count * max($1.iterations, 1) }
        return "\(activity) · \(blocks) block\(blocks == 1 ? "" : "s") · \(stepsTotal) step\(stepsTotal == 1 ? "" : "s")"
    }
}
