import { getPhoneAddress } from "./config.js";
import { writeCache, readCache } from "./cache.js";
import { queryBLE } from "./ble.js";

const TIMEOUT_MS = 3000;

async function fetchFromPhone(path) {
  const addr = getPhoneAddress();
  if (!addr) {
    throw new Error("Phone address not configured. Run 'datahub discover' first.");
  }

  const url = `http://${addr.ip}:${addr.port}${path}`;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);

  try {
    const res = await fetch(url, { signal: controller.signal });
    if (!res.ok) {
      throw new Error(`HTTP ${res.status}: ${res.statusText}`);
    }
    return await res.json();
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Query data with 3-tier fallback: HTTP → BLE → Cache
 */
export async function query(endpoint, params = {}, cacheKey = null, bleCommand = null) {
  const qs = Object.entries(params)
    .filter(([, v]) => v !== undefined)
    .map(([k, v]) => `${k}=${encodeURIComponent(v)}`)
    .join("&");
  const path = qs ? `${endpoint}?${qs}` : endpoint;

  // 1. Try HTTP (fastest, requires app in foreground)
  try {
    const data = await fetchFromPhone(path);
    data._source = "live";
    if (cacheKey) writeCache(cacheKey, data);
    return data;
  } catch {
    // HTTP failed — try BLE
  }

  // 2. Try BLE (works when app is backgrounded)
  if (bleCommand) {
    try {
      const data = await queryBLE(bleCommand);
      if (!data.error) {
        data._source = "ble";
        if (cacheKey) writeCache(cacheKey, data);
        return data;
      }
    } catch {
      // BLE failed — try cache
    }
  }

  // 3. Fall back to cache
  if (cacheKey) {
    const cached = readCache(cacheKey);
    if (cached) return cached;
  }

  return {
    error: "Phone unreachable via HTTP and BLE. No cached data available.",
    hint: "Open the Data Hub app on your iPhone, or run 'datahub discover'.",
    _source: "error",
  };
}

export async function status() {
  // Try HTTP first
  try {
    const data = await fetchFromPhone("/status");
    return { ...data, _source: "live", reachable: true };
  } catch {
    // Try BLE
  }

  try {
    const data = await queryBLE("status");
    if (!data.error) {
      return { ...data, _source: "ble", reachable: true };
    }
  } catch {
    // BLE failed too
  }

  const config = getPhoneAddress();
  return {
    reachable: false,
    configured_ip: config?.ip || null,
    configured_port: config?.port || null,
    hint: "Phone is not reachable via HTTP or BLE. Open the Data Hub app.",
    _source: "error",
  };
}
