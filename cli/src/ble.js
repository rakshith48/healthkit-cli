import { execFile, spawn } from "child_process";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const BLE_CLIENT = join(__dirname, "ble_client.py");
import { execFileSync } from "child_process";

function findPython() {
  if (process.env.PYTHON_PATH) return process.env.PYTHON_PATH;
  // Try common paths where bleak might be installed
  for (const p of ["python3", "python3.11", "python3.12", "python3.13", "/opt/homebrew/bin/python3.11", "/opt/homebrew/bin/python3"]) {
    try {
      execFileSync(p, ["-c", "import bleak"], { timeout: 5000, stdio: "ignore" });
      return p;
    } catch {}
  }
  return "python3";
}

const PYTHON = findPython();

/**
 * Query health data via BLE.
 * Falls back to this when HTTP is unreachable.
 * @param {string} command - e.g., "steps:7", "status", "summary:7"
 * @returns {Promise<object>} Parsed JSON response
 */
export function queryBLE(command) {
  return new Promise((resolve, reject) => {
    execFile(PYTHON, [BLE_CLIENT, command], { timeout: 20000 }, (err, stdout, stderr) => {
      if (err) {
        resolve({
          error: "BLE query failed",
          _source: "ble_error",
        });
        return;
      }
      try {
        resolve(JSON.parse(stdout));
      } catch {
        resolve({
          error: "BLE returned invalid response",
          _source: "ble_error",
        });
      }
    });
  });
}

/**
 * Discover the BLE peripheral.
 * @returns {Promise<object>} { found: bool, name?, address? }
 */
export function discoverBLE() {
  return queryBLE("discover");
}

/**
 * Upload a workout JSON payload over BLE.
 * Works when the iPhone app is backgrounded (HTTP server is down, BLE stays alive).
 * @param {string|Buffer} payload - JSON string or Buffer to send
 * @returns {Promise<object>} ACK from phone
 */
export function uploadWorkoutBLE(payload) {
  return new Promise((resolve) => {
    const proc = spawn(PYTHON, [BLE_CLIENT, "workout_upload"], {
      stdio: ["pipe", "pipe", "pipe"],
    });

    let stdout = "";
    let stderr = "";
    const killTimer = setTimeout(() => {
      proc.kill("SIGKILL");
    }, 30_000);

    proc.stdout.on("data", (c) => (stdout += c.toString("utf8")));
    proc.stderr.on("data", (c) => (stderr += c.toString("utf8")));

    proc.on("close", (code) => {
      clearTimeout(killTimer);
      if (code !== 0 && !stdout.trim()) {
        resolve({
          error: stderr.trim() || `BLE uploader exited ${code}`,
          _source: "ble_error",
        });
        return;
      }
      try {
        resolve(JSON.parse(stdout));
      } catch {
        resolve({
          error: "BLE uploader returned invalid JSON",
          _source: "ble_error",
        });
      }
    });

    proc.stdin.write(payload);
    proc.stdin.end();
  });
}
