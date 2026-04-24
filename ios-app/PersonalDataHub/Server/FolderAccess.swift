import Foundation
import SwiftUI
import UniformTypeIdentifiers

class FolderAccessManager: ObservableObject {
    @Published var hasAccess = false
    @Published var vaultPath: String = ""
    @Published var fileCount: Int = 0

    private let bookmarkKey = "obsidian_vault_bookmark"

    init() {
        restoreAccess()
    }

    // MARK: - Restore saved access on app launch

    func restoreAccess() {
        guard let bookmarkData = UserDefaults.standard.data(forKey: bookmarkKey) else { return }

        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: bookmarkData, bookmarkDataIsStale: &isStale)

            if isStale {
                // Re-save bookmark
                guard url.startAccessingSecurityScopedResource() else { return }
                let newBookmark = try url.bookmarkData(options: .minimalBookmark)
                UserDefaults.standard.set(newBookmark, forKey: bookmarkKey)
                url.stopAccessingSecurityScopedResource()
            }

            guard url.startAccessingSecurityScopedResource() else { return }
            hasAccess = true
            vaultPath = url.lastPathComponent
            countFiles(at: url)
            print("[FolderAccess] Restored access to: \(url.path)")
        } catch {
            print("[FolderAccess] Failed to restore bookmark: \(error)")
        }
    }

    // MARK: - Save access after user picks folder

    func saveAccess(to url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            print("[FolderAccess] Failed to start accessing security-scoped resource")
            return
        }

        do {
            let bookmarkData = try url.bookmarkData(options: .minimalBookmark)
            UserDefaults.standard.set(bookmarkData, forKey: bookmarkKey)
            hasAccess = true
            vaultPath = url.lastPathComponent
            countFiles(at: url)
            print("[FolderAccess] Saved access to: \(url.path)")
        } catch {
            print("[FolderAccess] Failed to create bookmark: \(error)")
        }
    }

    // MARK: - List vault files

    func listFiles() -> [[String: Any]] {
        guard let bookmarkData = UserDefaults.standard.data(forKey: bookmarkKey) else { return [] }

        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmarkData, bookmarkDataIsStale: &isStale) else { return [] }
        guard url.startAccessingSecurityScopedResource() else { return [] }
        defer { url.stopAccessingSecurityScopedResource() }

        return listFilesRecursive(at: url, relativeTo: url)
    }

    func readFile(relativePath: String) -> String? {
        guard let bookmarkData = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }

        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmarkData, bookmarkDataIsStale: &isStale) else { return nil }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }

        let fileURL = url.appendingPathComponent(relativePath)
        return try? String(contentsOf: fileURL, encoding: .utf8)
    }

    func writeFile(relativePath: String, content: String) -> Bool {
        guard let bookmarkData = UserDefaults.standard.data(forKey: bookmarkKey) else { return false }

        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmarkData, bookmarkDataIsStale: &isStale) else { return false }
        guard url.startAccessingSecurityScopedResource() else { return false }
        defer { url.stopAccessingSecurityScopedResource() }

        let fileURL = url.appendingPathComponent(relativePath)

        // Create parent directories if needed
        let parent = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            print("[FolderAccess] Write failed: \(error)")
            return false
        }
    }

    // MARK: - Private

    private func countFiles(at url: URL) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil) else { return }
        var count = 0
        while let fileURL = enumerator.nextObject() as? URL {
            if !fileURL.hasDirectoryPath && fileURL.pathExtension == "md" {
                count += 1
            }
        }
        fileCount = count
    }

    private func listFilesRecursive(at url: URL, relativeTo base: URL) -> [[String: Any]] {
        let fm = FileManager.default
        var files: [[String: Any]] = []

        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return [] }

        while let fileURL = enumerator.nextObject() as? URL {
            if fileURL.hasDirectoryPath { continue }
            if fileURL.lastPathComponent.hasPrefix(".") { continue }

            let relativePath = fileURL.path.replacingOccurrences(of: base.path + "/", with: "")
            let attrs = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])

            files.append([
                "path": relativePath,
                "size": attrs?.fileSize ?? 0,
                "modified": ISO8601DateFormatter().string(from: attrs?.contentModificationDate ?? Date()),
            ])
        }

        return files
    }
}

// MARK: - SwiftUI Document Picker

struct FolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder])
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}
