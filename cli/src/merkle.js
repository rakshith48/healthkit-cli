import { createHash } from "crypto";
import { existsSync, readFileSync, writeFileSync, readdirSync, statSync, mkdirSync } from "fs";
import { join, relative, dirname } from "path";
import { homedir } from "os";

const MERKLE_FILE = join(homedir(), ".datahub", "vault_merkle.json");

// Truncate SHA-256 to 16 hex chars (64 bits) — collision-safe for 100K+ files
function sha256Short(input) {
  return createHash("sha256").update(input).digest("hex").slice(0, 16);
}

export class MerkleNode {
  constructor(path, isDir, hash = "", children = [], size = 0) {
    this.path = path;
    this.isDir = isDir;
    this.hash = hash;
    this.children = children; // sorted by path
    this.size = size;
  }

  toJSON() {
    const obj = { path: this.path, hash: this.hash, isDir: this.isDir };
    if (this.isDir) {
      obj.children = this.children.map((c) => c.toJSON());
    } else {
      obj.size = this.size;
    }
    return obj;
  }

  static fromJSON(obj) {
    const children = (obj.children || []).map((c) => MerkleNode.fromJSON(c));
    return new MerkleNode(obj.path, obj.isDir, obj.hash, children, obj.size || 0);
  }
}

// Build a Merkle tree from a local directory
export function buildTree(dir) {
  if (!existsSync(dir)) return new MerkleNode("", true, sha256Short(""), []);
  return buildNode(dir, dir, "");
}

function buildNode(baseDir, currentDir, name) {
  const entries = readdirSync(currentDir, { withFileTypes: true })
    .filter((e) => !e.name.startsWith("."))
    .sort((a, b) => a.name.localeCompare(b.name));

  const children = [];

  for (const entry of entries) {
    const fullPath = join(currentDir, entry.name);

    if (entry.isDirectory()) {
      children.push(buildNode(baseDir, fullPath, entry.name));
    } else {
      const relPath = relative(baseDir, fullPath);
      const content = readFileSync(fullPath, "utf-8");
      const hash = sha256Short(relPath + "\0" + content);
      const stat = statSync(fullPath);
      children.push(new MerkleNode(entry.name, false, hash, [], stat.size));
    }
  }

  // Directory hash = SHA256 of all children hashes concatenated
  const dirHash = sha256Short(children.map((c) => c.hash).join(""));
  return new MerkleNode(name, true, dirHash, children);
}

// Find a node by path (e.g., "Nightly thoughts" or "Nightly thoughts/subfolder")
export function findNode(root, path) {
  if (!path || path === "" || path === "/") return root;

  const parts = path.split("/").filter(Boolean);
  let current = root;

  for (const part of parts) {
    if (!current.isDir) return null;
    const child = current.children.find((c) => c.path === part);
    if (!child) return null;
    current = child;
  }

  return current;
}

// Diff two trees at a given path — returns which children differ, were added, or deleted
export function diffNodes(localNode, remoteChildren) {
  // remoteChildren: [{path, hash}]
  const localMap = {};
  if (localNode && localNode.isDir) {
    for (const child of localNode.children) {
      localMap[child.path] = child.hash;
    }
  }

  const remoteMap = {};
  for (const child of remoteChildren) {
    remoteMap[child.path] = child.hash;
  }

  const differs = [];
  const added = []; // on remote but not local
  const deleted = []; // on local but not remote

  // Check remote children against local
  for (const [path, hash] of Object.entries(remoteMap)) {
    if (!(path in localMap)) {
      added.push(path);
    } else if (localMap[path] !== hash) {
      differs.push(path);
    }
  }

  // Check for deletions (local has it, remote doesn't)
  for (const path of Object.keys(localMap)) {
    if (!(path in remoteMap)) {
      deleted.push(path);
    }
  }

  return { differs, added, deleted };
}

// Incrementally update a single file's hash in the tree
export function updateFileInTree(root, baseDir, relPath) {
  const parts = relPath.split("/").filter(Boolean);
  const fileName = parts.pop();

  // Navigate to parent directory
  let current = root;
  for (const part of parts) {
    let child = current.children.find((c) => c.path === part && c.isDir);
    if (!child) {
      // Create missing directory node
      child = new MerkleNode(part, true, "", []);
      current.children.push(child);
      current.children.sort((a, b) => a.path.localeCompare(b.path));
    }
    current = child;
  }

  // Update or add the file node
  const fullPath = join(baseDir, relPath);
  const existingIdx = current.children.findIndex((c) => c.path === fileName);

  if (existsSync(fullPath)) {
    const content = readFileSync(fullPath, "utf-8");
    const hash = sha256Short(relPath + "\0" + content);
    const stat = statSync(fullPath);
    const fileNode = new MerkleNode(fileName, false, hash, [], stat.size);

    if (existingIdx >= 0) {
      current.children[existingIdx] = fileNode;
    } else {
      current.children.push(fileNode);
      current.children.sort((a, b) => a.path.localeCompare(b.path));
    }
  } else {
    // File deleted
    if (existingIdx >= 0) {
      current.children.splice(existingIdx, 1);
    }
  }

  // Recompute hashes up to root
  recomputeHashes(root);
}

function recomputeHashes(node) {
  if (!node.isDir) return;
  for (const child of node.children) {
    recomputeHashes(child);
  }
  node.hash = sha256Short(node.children.map((c) => c.hash).join(""));
}

// Count total files in tree
export function countFiles(node) {
  if (!node.isDir) return 1;
  return node.children.reduce((sum, c) => sum + countFiles(c), 0);
}

// Persistence
export function saveTree(tree) {
  const dir = dirname(MERKLE_FILE);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const data = { version: 1, builtAt: new Date().toISOString(), root: tree.toJSON() };
  writeFileSync(MERKLE_FILE, JSON.stringify(data), { mode: 0o600 });
}

export function loadTree() {
  if (!existsSync(MERKLE_FILE)) return null;
  try {
    const data = JSON.parse(readFileSync(MERKLE_FILE, "utf-8"));
    return MerkleNode.fromJSON(data.root);
  } catch {
    return null;
  }
}
