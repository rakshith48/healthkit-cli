import SwiftUI
import WorkoutKit

@available(iOS 17.0, *)
struct WorkoutQueueView: View {
    @ObservedObject private var store = WorkoutQueueStore.shared
    @State private var previewingSpec: WorkoutSpec?
    @State private var previewPlan: WorkoutPlan?
    @State private var showPreview = false
    @State private var buildError: String?

    var body: some View {
        List {
            if store.pending.isEmpty {
                Text("No pending workouts. Push from your Mac with `healthkit-cli workout queue`.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                Section("Pending (\(store.pending.count))") {
                    ForEach(store.pending) { q in
                        WorkoutRow(
                            queued: q,
                            onPreview: { openPreview(for: q.spec) },
                            onDismiss: { store.markDismissed(id: q.id) }
                        )
                    }
                }
            }

            let saved = store.queue.filter { $0.status == "saved" }
            if !saved.isEmpty {
                Section("Saved (\(saved.count))") {
                    ForEach(saved) { q in
                        HStack {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                            Text(q.spec.displayName).font(.subheadline)
                            Spacer()
                            Button(role: .destructive) {
                                store.remove(id: q.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                    }
                }
            }

            if let err = buildError {
                Section {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        }
        .navigationTitle("Workouts")
        .modifier(WorkoutPreviewSheet(plan: previewPlan, isPresented: $showPreview))
        .onChange(of: showPreview) { visible in
            // When the preview closes, mark the workout as saved.
            // (Apple doesn't expose a "was it actually saved?" callback —
            // user closing the sheet is the best signal we get.)
            if !visible, let spec = previewingSpec {
                store.markSaved(id: spec.id)
                previewingSpec = nil
                previewPlan = nil
            }
        }
    }

    private func openPreview(for spec: WorkoutSpec) {
        buildError = nil
        do {
            let workout = try WorkoutBuilder.build(from: spec)
            previewingSpec = spec
            previewPlan = WorkoutPlan(.custom(workout))
            showPreview = true
        } catch {
            buildError = "Failed to build '\(spec.displayName)': \(error.localizedDescription)"
        }
    }
}

/// Conditionally apply `.workoutPreview` — the modifier requires a non-optional
/// `WorkoutPlan`, so wrap it in a ViewModifier that only attaches once a plan
/// has been built.
@available(iOS 17.0, *)
private struct WorkoutPreviewSheet: ViewModifier {
    let plan: WorkoutPlan?
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        if let plan = plan {
            content.workoutPreview(plan, isPresented: $isPresented)
        } else {
            content
        }
    }
}

@available(iOS 17.0, *)
private struct WorkoutRow: View {
    let queued: QueuedWorkout
    let onPreview: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(queued.spec.displayName)
                .font(.headline)
            HStack {
                Text(summary).font(.caption).foregroundColor(.secondary)
                Spacer()
                Text(queued.receivedAt, style: .relative)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            HStack {
                Button(action: onPreview) {
                    Label("Preview + Save", systemImage: "arrow.up.forward.app")
                        .font(.footnote)
                }
                .buttonStyle(.borderedProminent)

                Button(role: .destructive, action: onDismiss) {
                    Label("Dismiss", systemImage: "xmark")
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
