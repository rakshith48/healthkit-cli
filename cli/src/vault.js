import { existsSync, readFileSync, writeFileSync, mkdirSync, statSync, watch, readdirSync, unlinkSync } from "fs";
import { join, relative, dirname } from "path";
import { homedir } from "os";
import { getToken } from "./auth.js";
import { getPhoneAddress } from "./config.js";
import { queryBLE } from "./ble.js";
import { buildTree, findNode, diffNodes, countFiles, saveTree, loadTree, updateFileInTree } from "./merkle.js";

const VAULT_DIR = join(homedir(), "Obsidian");
const SYNC_STATE_FILE = join(homedir(), ".datahub", "vault_sync.json");

function getBaseUrl() {
  const addr = getPhoneAddress();
  if (!addr) throw new Error("Phone not discovered. Run 'healthkit-cli discover'.");
  return `http://${addr.ip}:${addr.port}`;
}

function getHeaders() {
  const token = getToken();
  if (!token) throw new Error("Not paired. Run 'healthkit-cli pair'.");
  return { Authorization: `Bearer ${token}` };
}

// --- Sync state ---

function loadSyncState() {
  if (!existsSync(SYNC_STATE_FILE)) return { lastSyncHashes: {} };
  try { return JSON.parse(readFileSync(SYNC_STATE_FILE, "utf-8")); } catch { return { lastSyncHashes: {} }; }
}

function saveSyncState(state) {
  mkdirSync(dirname(SYNC_STATE_FILE), { recursive: true, mode: 0o700 });
  writeFileSync(SYNC_STATE_FILE, JSON.stringify(state, null, 2), { mode: 0o600 });
}

// --- Remote calls (HTTP → BLE fallback) ---

async function fetchJSON(path, options = {}) {
  const baseUrl = getBaseUrl();
  const headers = getHeaders();
  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 3000);
    const res = await fetch(`${baseUrl}${path}`, { ...options, headers: { ...headers, ...options.headers }, signal: controller.signal });
    clearTimeout(timer);
    if (res.ok) return await res.json();
  } catch {}
  return null;
}

async function remoteMerkleRoot() {
  const http = await fetchJSON("/vault/merkle/root");
  if (http) return http;
  return await queryBLE("merkle_root");
}

async function remoteMerkleNode(path) {
  const http = await fetchJSON(`/vault/merkle/node?path=${encodeURIComponent(path)}`);
  if (http) return http;
  return await queryBLE(`merkle_node:${path}`);
}

async function remoteMerkleDiff(path, childHashes) {
  const http = await fetchJSON("/vault/merkle/diff", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ path, children: childHashes }),
  });
  if (http) return http;
  // BLE fallback: can't do POST, use node command and compare client-side
  const node = await queryBLE(`merkle_node:${path}`);
  if (node && node.children) {
    const remoteMap = {};
    for (const c of node.children) remoteMap[c.path] = c.hash;
    const differs = [], added = [], deleted = [];
    for (const [p, h] of Object.entries(remoteMap)) {
      if (!(p in childHashes)) added.push(p);
      else if (childHashes[p] !== h) differs.push(p);
    }
    for (const p of Object.keys(childHashes)) {
      if (!(p in remoteMap)) deleted.push(p);
    }
    return { path, differs, added, deleted };
  }
  return null;
}

async function pullFile(remotePath) {
  const http = await fetchJSON(`/vault/read?path=${encodeURIComponent(remotePath)}`);
  if (http && http.content !== undefined) return http.content;
  const ble = await queryBLE(`vault_read:${remotePath}`);
  if (ble && ble.content !== undefined) return ble.content;
  return null;
}

async function pushFile(remotePath, content) {
  const baseUrl = getBaseUrl();
  const headers = getHeaders();
  try {
    const res = await fetch(`${baseUrl}/vault/write`, {
      method: "POST",
      headers: { ...headers, "Content-Type": "application/json" },
      body: JSON.stringify({ path: remotePath, content }),
    });
    const data = await res.json();
    return data.written;
  } catch { return false; }
}

// --- Find vault ---

function findVaultDir() {
  if (!existsSync(VAULT_DIR)) return null;
  const entries = readdirSync(VAULT_DIR, { withFileTypes: true });
  for (const e of entries) {
    if (e.isDirectory() && !e.name.startsWith(".")) return join(VAULT_DIR, e.name);
  }
  return VAULT_DIR;
}

function findVaultName() {
  if (!existsSync(VAULT_DIR)) return null;
  const entries = readdirSync(VAULT_DIR, { withFileTypes: true });
  for (const e of entries) {
    if (e.isDirectory() && !e.name.startsWith(".")) return e.name;
  }
  return null;
}

// --- Merkle-based sync ---

export async function sync() {
  console.error("Syncing vault...");

  const vaultDir = findVaultDir();
  const vaultName = findVaultName();
  if (!vaultDir) {
    console.log(JSON.stringify({ error: "No local vault found at ~/Obsidian/" }));
    return;
  }

  // Step 1: Get remote root hash
  const remoteRoot = await remoteMerkleRoot();
  if (!remoteRoot || remoteRoot.error) {
    console.log(JSON.stringify({ error: "Phone unreachable. Open the Data Hub app.", _detail: remoteRoot?.error }));
    return;
  }

  // Step 2: Build local tree from ~/Obsidian/ (same level as remote Documents root)
  const localTree = buildTree(VAULT_DIR);
  saveTree(localTree);

  // Step 3: Compare root hashes
  if (localTree.hash === remoteRoot.hash) {
    console.log(JSON.stringify({ synced: true, pulled: 0, pushed: 0, skipped: countFiles(localTree), total: countFiles(localTree), method: "merkle" }));
    return;
  }

  // Step 4: Drill down to find differences
  const syncState = loadSyncState();
  const lastSyncHashes = syncState.lastSyncHashes || {};
  let pulled = 0, pushed = 0, skipped = 0;

  // remotePath is relative to the vault folder on the phone (e.g., "Rak's thoughts /Nightly thoughts")
  // localPath is relative to the vault root on Mac (e.g., "Nightly thoughts")
  async function syncDir(localNode, localPath, remotePath) {
    // Get child hashes from local tree
    const childHashes = {};
    if (localNode && localNode.isDir) {
      for (const c of localNode.children) childHashes[c.path] = c.hash;
    }

    // Diff with remote
    const diff = await remoteMerkleDiff(remotePath, childHashes);
    if (!diff) { console.error(`  Failed to diff: ${remotePath}`); return; }

    // Handle children that differ
    for (const name of (diff.differs || [])) {
      const localChild = localNode?.children.find(c => c.path === name);
      const childLocalPath = localPath ? `${localPath}/${name}` : name;
      const childRemotePath = remotePath ? `${remotePath}/${name}` : name;

      const localFullPath = join(VAULT_DIR, childLocalPath);
      const isDir = localChild ? localChild.isDir : (existsSync(localFullPath) && statSync(localFullPath).isDirectory());

      if (isDir) {
        await syncDir(localChild, childLocalPath, childRemotePath);
      } else {
        const remoteFilePath = childLocalPath;
        const lastHash = lastSyncHashes[childLocalPath];

        if (localChild && localChild.hash !== lastHash) {
          const content = readFileSync(localFullPath, "utf-8");
          if (await pushFile(remoteFilePath, content)) {
            lastSyncHashes[childLocalPath] = localChild.hash;
            console.error(`  → Push: ${childLocalPath}`);
            pushed++;
          }
        } else {
          const content = await pullFile(remoteFilePath);
          if (content !== null) {
            mkdirSync(dirname(localFullPath), { recursive: true });
            writeFileSync(localFullPath, content);
            updateFileInTree(localTree, vaultDir, childLocalPath);
            lastSyncHashes[childLocalPath] = findNode(localTree, childLocalPath)?.hash || "";
            console.error(`  ← Pull: ${childLocalPath}`);
            pulled++;
          }
        }
      }
    }

    // Handle added (on remote, not local)
    for (const name of (diff.added || [])) {
      const childLocalPath = localPath ? `${localPath}/${name}` : name;
      const childRemotePath = remotePath ? `${remotePath}/${name}` : name;
      const remoteFilePath = childLocalPath;

      const remoteNode = await remoteMerkleNode(childRemotePath);
      if (remoteNode && remoteNode.isDir) {
        for (const child of (remoteNode.children || [])) {
          if (!child.isDir) {
            const filePath = `${vaultName}/${childLocalPath}/${child.path}`;
            const content = await pullFile(filePath);
            if (content !== null) {
              const dest = join(VAULT_DIR, childLocalPath, child.path);
              mkdirSync(dirname(dest), { recursive: true });
              writeFileSync(dest, content);
              console.error(`  ← Pull: ${childLocalPath}/${child.path}`);
              pulled++;
            }
          }
        }
      } else {
        const content = await pullFile(remoteFilePath);
        if (content !== null) {
          const dest = join(VAULT_DIR, childLocalPath);
          mkdirSync(dirname(dest), { recursive: true });
          writeFileSync(dest, content);
          console.error(`  ← Pull: ${childLocalPath}`);
          pulled++;
        }
      }
    }

    // Handle deleted (on local, not remote)
    for (const name of (diff.deleted || [])) {
      const childLocalPath = localPath ? `${localPath}/${name}` : name;
      const lastHash = lastSyncHashes[childLocalPath];
      const localChild = localNode?.children.find(c => c.path === name);

      if (localChild && localChild.hash === lastHash) {
        const localFilePath = join(VAULT_DIR, childLocalPath);
        if (existsSync(localFilePath)) {
          unlinkSync(localFilePath);
          delete lastSyncHashes[childLocalPath];
          console.error(`  ✕ Delete: ${childLocalPath}`);
        }
      } else if (localChild) {
        const remoteFilePath = childLocalPath;
        const content = readFileSync(join(VAULT_DIR, childLocalPath), "utf-8");
        if (await pushFile(remoteFilePath, content)) {
          lastSyncHashes[childLocalPath] = localChild.hash;
          console.error(`  → Push (restore): ${childLocalPath}`);
          pushed++;
        }
      }
    }
  }

  // Start recursive diff from root (both sides have vault name as first child)
  await syncDir(localTree, "", "");

  // Rebuild and save tree after sync
  const updatedTree = buildTree(vaultDir);
  saveTree(updatedTree);

  // Update sync state with current hashes
  function collectHashes(node, prefix) {
    if (!node.isDir) {
      lastSyncHashes[prefix ? `${prefix}/${node.path}` : node.path] = node.hash;
      return;
    }
    for (const child of node.children) {
      collectHashes(child, prefix ? `${prefix}/${child.path}` : child.path);
    }
  }
  // Only update hashes for files that were synced (not all files)
  saveSyncState({ lastSync: new Date().toISOString(), lastSyncHashes });

  const total = countFiles(updatedTree);
  skipped = total - pulled - pushed;
  console.log(JSON.stringify({ synced: true, pulled, pushed, skipped, total, method: "merkle" }));
}

// --- Watch mode ---

export async function watchVault() {
  const vaultDir = findVaultDir();
  if (!vaultDir) {
    console.log(JSON.stringify({ error: "No vault found. Run 'healthkit-cli vault pull' first." }));
    return;
  }

  console.error(`Watching ${vaultDir} for changes...`);
  console.error("Press Ctrl+C to stop.\n");

  // Initial sync
  await sync();

  // Watch for local changes
  let debounceTimer = null;
  watch(vaultDir, { recursive: true }, (eventType, filename) => {
    if (!filename || filename.startsWith(".obsidian")) return;

    if (debounceTimer) clearTimeout(debounceTimer);
    debounceTimer = setTimeout(async () => {
      console.error(`\nChange detected: ${filename}`);
      await sync();
    }, 2000);
  });

  // Poll for remote changes every 5 minutes
  setInterval(async () => {
    try { await sync(); } catch (e) { console.error(`Sync error: ${e.message}`); }
  }, 300000);

  await new Promise(() => {});
}
