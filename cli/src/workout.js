import { readFileSync } from "fs";
import { randomUUID } from "crypto";
import { getPhoneAddress } from "./config.js";
import { getToken } from "./auth.js";
import { uploadWorkoutBLE } from "./ble.js";

const TIMEOUT_MS = 5000;

function buildUrl(path) {
  const addr = getPhoneAddress();
  if (!addr) throw new Error("Phone not configured. Run 'healthkit-cli discover' first.");
  return `http://${addr.ip}:${addr.port}${path}`;
}

function authHeaders() {
  const token = getToken();
  if (!token) throw new Error("Not paired. Run 'healthkit-cli pair' first.");
  return { Authorization: `Bearer ${token}`, "Content-Type": "application/json" };
}

async function httpJson(method, path, body) {
  const url = buildUrl(path);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    const res = await fetch(url, {
      method,
      headers: authHeaders(),
      body: body ? JSON.stringify(body) : undefined,
      signal: controller.signal,
    });
    const text = await res.text();
    let json;
    try { json = JSON.parse(text); } catch { json = { raw: text }; }
    if (!res.ok) {
      throw new Error(json.error || `HTTP ${res.status}`);
    }
    return json;
  } finally {
    clearTimeout(timer);
  }
}

// --- Spec normalisation -----------------------------------------------------

/**
 * Accept either a single JSON/YAML spec, or a "plan" file with workouts: [...].
 * Ensures every workout has an `id` (stable UUID) and well-formed block/step keys.
 */
function loadSpecs(filePath) {
  const raw = readFileSync(filePath, "utf8");
  let doc;
  try {
    doc = JSON.parse(raw);
  } catch (err) {
    throw new Error(`Failed to parse JSON from ${filePath}: ${err.message}`);
  }

  let workouts;
  if (Array.isArray(doc)) {
    workouts = doc;
  } else if (Array.isArray(doc.workouts)) {
    workouts = doc.workouts;
  } else {
    workouts = [doc]; // single spec
  }

  return workouts.map(normaliseSpec);
}

function normaliseSpec(w) {
  if (!w.displayName) {
    throw new Error(`Workout missing displayName: ${JSON.stringify(w).slice(0, 80)}`);
  }
  const spec = {
    id: w.id || randomUUID(),
    displayName: w.displayName,
    activity: w.activity || "running",
    location: w.location || "outdoor",
    warmup: w.warmup ? normaliseStep(w.warmup) : null,
    blocks: (w.blocks || []).map(normaliseBlock),
    cooldown: w.cooldown ? normaliseStep(w.cooldown) : null,
    notes: w.notes || null,
  };
  return spec;
}

function normaliseStep(s) {
  return {
    goal: normaliseGoal(s.goal || {}),
    alert: s.alert ? normaliseAlert(s.alert) : null,
    displayName: s.displayName || null,
  };
}

function normaliseBlock(b) {
  return {
    iterations: Number.isInteger(b.iterations) ? b.iterations : 1,
    steps: (b.steps || []).map((s) => ({
      purpose: (s.purpose || "work").toLowerCase(),
      goal: normaliseGoal(s.goal || {}),
      alert: s.alert ? normaliseAlert(s.alert) : null,
      displayName: s.displayName || null,
    })),
  };
}

function normaliseGoal(g) {
  return {
    distance_m: g.distance_m ?? (g.distance_km != null ? g.distance_km * 1000 : null),
    time_s: g.time_s ?? (g.time_min != null ? g.time_min * 60 : null),
    energy_kcal: g.energy_kcal ?? null,
  };
}

function normaliseAlert(a) {
  return {
    type: a.type,
    min: a.min ?? null,
    max: a.max ?? null,
    minPace: a.minPace ?? a.min_pace ?? null,
    maxPace: a.maxPace ?? a.max_pace ?? null,
    zone: a.zone ?? null,
    metric: a.metric ?? "current",
  };
}

// --- Commands --------------------------------------------------------------

export async function queueWorkout(filePath) {
  const specs = loadSpecs(filePath);

  const payload = specs.length === 1
    ? specs[0]
    : { workouts: specs };
  const jsonPayload = JSON.stringify(payload);

  // 1. Try HTTP first — fastest path, requires app foregrounded
  try {
    const result = await httpJson("POST", "/workouts/queue", payload);
    console.log(JSON.stringify({
      sent: specs.length,
      accepted: result.accepted ?? [],
      rejected: result.rejected ?? [],
      pending_count: result.pending_count,
      _source: "http",
    }, null, 2));
    return;
  } catch (httpErr) {
    // 2. HTTP failed — fall through to BLE (works even when app backgrounded)
    process.stderr.write(`[workout] HTTP unreachable (${httpErr.message}); trying BLE…\n`);
  }

  const bleResult = await uploadWorkoutBLE(jsonPayload);
  if (bleResult.error) {
    console.log(JSON.stringify({
      error: bleResult.error,
      hint: "Open Data Hub on your iPhone and/or keep Bluetooth on. For best throughput, foreground the app so HTTP can be used.",
      _source: bleResult._source ?? "ble_error",
    }, null, 2));
    process.exit(1);
  }

  console.log(JSON.stringify({
    sent: specs.length,
    accepted: bleResult.accepted ?? [],
    rejected: bleResult.rejected ?? [],
    pending_count: bleResult.pending_count,
    _source: "ble",
  }, null, 2));
}

export async function listQueue() {
  try {
    const result = await httpJson("GET", "/workouts/queue");
    console.log(JSON.stringify(result, null, 2));
  } catch (err) {
    console.log(JSON.stringify({ error: err.message }));
    process.exit(1);
  }
}

export async function clearQueue(id) {
  try {
    const path = id ? `/workouts/queue?id=${encodeURIComponent(id)}` : "/workouts/queue";
    const result = await httpJson("DELETE", path);
    console.log(JSON.stringify(result, null, 2));
  } catch (err) {
    console.log(JSON.stringify({ error: err.message }));
    process.exit(1);
  }
}
