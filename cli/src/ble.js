import { execFile } from "child_process";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const BLE_CLIENT = join(__dirname, "ble_client.py");
const PYTHON = "/opt/homebrew/bin/python3.11";

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
          error: `BLE query failed: ${err.message}`,
          _source: "ble_error",
        });
        return;
      }
      try {
        resolve(JSON.parse(stdout));
      } catch {
        resolve({
          error: `BLE returned invalid JSON: ${stdout.slice(0, 200)}`,
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
