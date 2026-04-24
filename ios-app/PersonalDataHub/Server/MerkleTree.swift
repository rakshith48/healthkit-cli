import Foundation
import CryptoKit

struct MerkleNode {
    let path: String
    let isDir: Bool
    var hash: String
    var children: [MerkleNode]
    let size: Int

    func toDict() -> [String: Any] {
        var dict: [String: Any] = ["path": path, "hash": hash, "isDir": isDir]
        if isDir {
            dict["children"] = children.map { $0.toDict() }
        } else {
            dict["size"] = size
        }
        return dict
    }

    // Shallow dict — children include hash only, not their children
    func shallowDict() -> [String: Any] {
        var dict: [String: Any] = ["path": path, "hash": hash, "isDir": isDir]
        if isDir {
            dict["children"] = children.map { child -> [String: Any] in
                var c: [String: Any] = ["path": child.path, "hash": child.hash, "isDir": child.isDir]
                if !child.isDir { c["size"] = child.size }
                return c
            }
        }
        return dict
    }
}

class MerkleTreeBuilder {
    private let folderAccess: FolderAccessManager

    // In-memory cache with TTL
    private var cachedTree: MerkleNode?
    private var cacheTime: Date?
    private let cacheTTL: TimeInterval = 60

    init(folderAccess: FolderAccessManager) {
        self.folderAccess = folderAccess
    }

    func getRoot() -> MerkleNode? {
        if let cached = cachedTree, let time = cacheTime, Date().timeIntervalSince(time) < cacheTTL {
            return cached
        }
        guard let tree = buildTree() else { return nil }
        cachedTree = tree
        cacheTime = Date()
        return tree
    }

    func invalidateCache() {
        cachedTree = nil
        cacheTime = nil
    }

    // MARK: - Tree Building

    private func buildTree() -> MerkleNode? {
        guard folderAccess.hasAccess else { return nil }

        guard let bookmarkData = UserDefaults.standard.data(forKey: "obsidian_vault_bookmark") else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmarkData, bookmarkDataIsStale: &isStale) else { return nil }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }

        return buildNode(at: url, relativeTo: url, name: "")
    }

    private func buildNode(at url: URL, relativeTo baseURL: URL, name: String) -> MerkleNode {
        let fm = FileManager.default

        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return MerkleNode(path: name, isDir: true, hash: sha256Short(""), children: [], size: 0)
        }

        let sorted = contents.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var children: [MerkleNode] = []

        for itemURL in sorted {
            let itemName = itemURL.lastPathComponent
            let isDir = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false

            if isDir {
                children.append(buildNode(at: itemURL, relativeTo: baseURL, name: itemName))
            } else {
                // Stream-hash: read file, hash it, release memory immediately
                let relPath = itemURL.path.replacingOccurrences(of: baseURL.path + "/", with: "")
                let fileSize = (try? itemURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0

                autoreleasepool {
                    let content = (try? String(contentsOf: itemURL, encoding: .utf8)) ?? ""
                    let hash = sha256Short(relPath + "\0" + content)
                    children.append(MerkleNode(path: itemName, isDir: false, hash: hash, children: [], size: fileSize))
                }
            }
        }

        let dirHash = sha256Short(children.map { $0.hash }.joined())
        return MerkleNode(path: name, isDir: true, hash: dirHash, children: children, size: 0)
    }

    // MARK: - Node Lookup

    func findNode(path: String) -> MerkleNode? {
        guard let root = getRoot() else { return nil }
        if path.isEmpty { return root }

        let parts = path.split(separator: "/").map(String.init)
        var current = root

        for part in parts {
            guard current.isDir else { return nil }
            guard let child = current.children.first(where: { $0.path == part }) else { return nil }
            current = child
        }

        return current
    }

    // MARK: - Diff

    func diff(path: String, clientHashes: [String: String]) -> [String: Any] {
        guard let node = findNode(path: path), node.isDir else {
            return ["error": "Node not found"]
        }

        let serverMap = Dictionary(node.children.map { ($0.path, $0.hash) }, uniquingKeysWith: { a, _ in a })

        var differs: [String] = []
        var added: [String] = []    // on server but not client
        var deleted: [String] = []  // on client but not server

        for child in node.children {
            if let clientHash = clientHashes[child.path] {
                if clientHash != child.hash {
                    differs.append(child.path)
                }
            } else {
                added.append(child.path)
            }
        }

        for clientPath in clientHashes.keys {
            if !serverMap.keys.contains(clientPath) {
                deleted.append(clientPath)
            }
        }

        return ["path": path, "differs": differs, "added": added, "deleted": deleted]
    }

    // MARK: - Helpers

    private func sha256Short(_ input: String) -> String {
        let data = Data(input.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}
