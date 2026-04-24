import Foundation
import Combine

/// Persists queued workout specs. Backed by a JSON file in app support dir so
/// it survives relaunches. Observable so SwiftUI updates when new specs arrive
/// via HTTP.
final class WorkoutQueueStore: ObservableObject {

    static let shared = WorkoutQueueStore()

    @Published private(set) var queue: [QueuedWorkout] = []

    private let fileURL: URL
    private let ioQueue = DispatchQueue(label: "com.personaldatahub.workout-queue", qos: .utility)

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        self.fileURL = appSupport.appendingPathComponent("workout-queue.json")
        load()
    }

    // MARK: - Public

    func enqueue(_ spec: WorkoutSpec) {
        DispatchQueue.main.async {
            // Replace existing spec with same id (idempotent push)
            if let idx = self.queue.firstIndex(where: { $0.id == spec.id }) {
                self.queue[idx] = QueuedWorkout(spec: spec)
            } else {
                self.queue.append(QueuedWorkout(spec: spec))
            }
            self.sortQueue()
            self.persist()
        }
    }

    func remove(id: String) {
        DispatchQueue.main.async {
            self.queue.removeAll { $0.id == id }
            self.persist()
        }
    }

    func markSaved(id: String) {
        updateStatus(id: id, status: "saved")
    }

    func markDismissed(id: String) {
        updateStatus(id: id, status: "dismissed")
    }

    func clearAll() {
        DispatchQueue.main.async {
            self.queue.removeAll()
            self.persist()
        }
    }

    var pending: [QueuedWorkout] {
        queue.filter { $0.status == "pending" }
    }

    // MARK: - Private

    private func updateStatus(id: String, status: String) {
        DispatchQueue.main.async {
            guard let idx = self.queue.firstIndex(where: { $0.id == id }) else { return }
            self.queue[idx].status = status
            self.persist()
        }
    }

    private func sortQueue() {
        queue.sort { $0.receivedAt < $1.receivedAt }
    }

    private func load() {
        ioQueue.async { [weak self] in
            guard let self,
                  let data = try? Data(contentsOf: self.fileURL),
                  let decoded = try? JSONDecoder().decode([QueuedWorkout].self, from: data) else {
                return
            }
            DispatchQueue.main.async {
                self.queue = decoded.sorted { $0.receivedAt < $1.receivedAt }
            }
        }
    }

    private func persist() {
        let snapshot = self.queue
        ioQueue.async { [weak self] in
            guard let self,
                  let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: self.fileURL, options: .atomic)
        }
    }
}
