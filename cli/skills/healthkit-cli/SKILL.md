---
name: healthkit-cli
description: Use the user's `healthkit-cli` tool to query iPhone health data (steps, heart rate, sleep, HRV, SpO2, calories, distance, workouts) AND push custom structured workouts to their Apple Watch. Trigger whenever the user asks about their health, fitness, sleep, activity, heart rate, HRV, recovery, training load, body metrics — or when they want to create, schedule, queue, or push a custom workout to their watch. Use even if the user doesn't explicitly name the CLI.
argument-hint: [query or push]
---

# healthkit-cli

The user has `healthkit-cli` installed globally. It bridges to their iPhone via HTTP (fast, needs app foregrounded) with automatic BLE fallback (works when app is backgrounded). Two capabilities:

1. **Query** health data (read-only)
2. **Push** custom workouts to their Apple Watch

All commands output JSON to stdout. Parse it and present clearly.

## Decide the flow

| User intent | Flow |
|---|---|
| "How did I sleep?" "What's my HRV?" "Recent workouts" | Query |
| "Push this tempo run to my watch" "Queue tomorrow's track session" | Push |
| "Is my phone reachable?" | `healthkit-cli status` |

---

## Flow 1 — Query health data

### Commands

| Command | Purpose |
|---|---|
| `healthkit-cli health summary --days N` | Daily summary: steps, HR, sleep, calories, distance |
| `healthkit-cli health steps --days N` | Steps per day |
| `healthkit-cli health heart-rate --days N` | Avg HR per day (bpm) |
| `healthkit-cli health sleep --days N` | Sleep duration per day (hours) |
| `healthkit-cli health hrv --days N` | HRV per day (ms) |
| `healthkit-cli health spo2 --days N` | Blood oxygen per day (%) |
| `healthkit-cli health calories --days N` | Active calories per day (kcal) |
| `healthkit-cli health distance --days N` | Walking/running distance per day (km) |
| `healthkit-cli health workouts --days N` | Workouts with type, duration, HR, pace, splits |

Defaults: `--days 7` (30 for `workouts`). Valid range: 1-365.

### Reading the response

Every response has a `_source` field:

- `"live"` — fresh from the phone over HTTP
- `"ble"` — fetched over Bluetooth (app was backgrounded)
- `"cache"` — stale data from the last successful query; check `_cached_at` for age

If `error` is present:

- Unreachable → tell the user to open Data Hub on their iPhone; suggest `healthkit-cli discover` if the IP may have changed
- Authentication failed → tell them to run `healthkit-cli pair`

### Example

```bash
$ healthkit-cli health summary --days 3
```
```json
{
  "days_requested": 3,
  "daily": [
    {"date": "2026-04-22", "steps": 8432, "heart_rate_avg": 61, "sleep_hours": 7.1, "active_calories": 520, "distance_km": 6.2},
    {"date": "2026-04-23", "steps": 11204, "heart_rate_avg": 64, "sleep_hours": 6.8, "active_calories": 680, "distance_km": 8.4},
    {"date": "2026-04-24", "steps": 9876, "heart_rate_avg": 59, "sleep_hours": 7.9, "active_calories": 450, "distance_km": 5.1}
  ],
  "_source": "live"
}
```

Present as a small table or short prose. Emphasize trends (sleep direction, HRV shift, step consistency) when the user's question is open-ended. Don't dump raw JSON unless they asked for it.

---

## Flow 2 — Push custom workouts to Apple Watch

### Commands

| Command | Purpose |
|---|---|
| `healthkit-cli workout queue <file.json>` | Push a workout spec (or batch) to the iPhone queue |
| `healthkit-cli workout list` | Show what's currently queued on the phone |
| `healthkit-cli workout clear [id]` | Remove one queued workout by id, or clear all |

### End-to-end flow

1. CLI sends the JSON spec to the iPhone Data Hub app (HTTP or BLE)
2. Phone validates, enqueues under the Workouts tab
3. User opens Data Hub → taps Preview → Apple's native sheet renders the workout → taps "Save to Workout App"
4. Workout appears on their Apple Watch, ready to start whenever

The user must tap Preview + Save themselves — Apple doesn't expose a programmatic save-to-library API (verified from WorkoutKit swiftinterface: `workoutPreview(_:isPresented:)` is the only variant, no completion callback). The CLI pushes; the phone UI handles the Apple-gated consent.

### JSON spec shape

```json
{
  "displayName": "Tuesday Tempo 7km",
  "activity": "running",
  "location": "outdoor",
  "warmup":  { "goal": { "distance_km": 1.5 } },
  "blocks": [
    {
      "iterations": 1,
      "steps": [
        {
          "purpose": "work",
          "goal":  { "distance_km": 4 },
          "alert": { "type": "pace", "minPace": "5:10", "maxPace": "5:20" }
        }
      ]
    }
  ],
  "cooldown": { "goal": { "distance_km": 1.5 } }
}
```

Batch form: wrap in `{ "workouts": [...] }` — pushes all in one call.

### Field rules

**Activity**: `running` (default), `cycling`, `walking`, `hiit`, `strength`, `swimming`, `elliptical`, `rowing`.

**Location**: `outdoor` (default), `indoor`, `unknown`.

**Goal** — pick one per step:

- `distance_m` or `distance_km` — distance target
- `time_s` or `time_min` — duration target (typical for recovery)
- `energy_kcal` — calorie target
- Omit all → open goal (user decides when to advance)

**Alert** (optional per step):

- `{"type": "pace", "minPace": "5:10", "maxPace": "5:20"}` — pace range in min:sec/km
- `{"type": "heart_rate", "min": 140, "max": 160}` — bpm range
- `{"type": "heart_rate_zone", "zone": 2}` — zone 1-5
- `{"type": "speed_mps", "min": 3.0, "max": 4.0}` — raw m/s

**Purpose** for interval steps: `work` (effort) or `recovery` (rest, usually `time_s` goal, no alert).

**Iterations**: how many times the block's steps repeat (e.g., `2` for 2×800m + recovery).

### Workflow

1. **Draft the spec.** If the user describes a workout in words, translate it into JSON using the schema above. Write to a temp file like `/tmp/workout.json`. For intervals, include warmup + blocks + cooldown.
2. **Push:**
   ```bash
   healthkit-cli workout queue /tmp/workout.json
   ```
3. **Read the response:**
   - `"_source": "http"` — app was foregrounded; push was instant
   - `"_source": "ble"` — fell back to BLE (backgrounded or Wi-Fi issue); took ~15s
   - `"accepted": [uuids]` — how many landed
   - `"rejected": [{id, error}]` — validation failures with reason
   - `error` field — tell the user to open Data Hub (HTTP) or keep Bluetooth on (BLE)
4. **Tell the user what to do next:** "Open Data Hub on your iPhone, tap Workouts, Preview, then Save to Watch. The workout syncs to your Apple Watch."

### Examples

**Easy run (single block, pace-capped):**

```json
{
  "displayName": "Easy 5km",
  "activity": "running",
  "location": "outdoor",
  "blocks": [{
    "iterations": 1,
    "steps": [{
      "purpose": "work",
      "goal":  {"distance_km": 5},
      "alert": {"type": "pace", "minPace": "6:00", "maxPace": "6:30"}
    }]
  }]
}
```

**Track intervals (2×800 + 4×200, nested blocks):**

```json
{
  "displayName": "KCTC 2x800 + 4x200",
  "activity": "running",
  "location": "outdoor",
  "warmup": {"goal": {"distance_km": 1.5}},
  "blocks": [
    {
      "iterations": 2,
      "steps": [
        {"purpose": "work", "goal": {"distance_m": 800}, "alert": {"type": "pace", "minPace": "4:10", "maxPace": "4:20"}},
        {"purpose": "recovery", "goal": {"time_s": 120}}
      ]
    },
    {
      "iterations": 4,
      "steps": [
        {"purpose": "work", "goal": {"distance_m": 200}, "alert": {"type": "pace", "minPace": "3:20", "maxPace": "3:30"}},
        {"purpose": "recovery", "goal": {"time_s": 90}}
      ]
    }
  ],
  "cooldown": {"goal": {"distance_km": 1}}
}
```

**Batch push a whole week:**

```json
{
  "workouts": [
    { /* Tue easy */ },
    { /* Thu track */ },
    { /* Sat long */ }
  ]
}
```

---

## Transport layer (HTTP ↔ BLE)

The CLI tries HTTP first (~50 ms round-trip). If HTTP fails, it falls through to BLE via a Python subprocess — total ~15s including BLE discovery + chunked writes + ACK. You don't trigger the fallback manually; it's automatic.

- **HTTP works** when the iPhone Data Hub app is foregrounded and on the same Wi-Fi as the Mac
- **Only BLE works** when the app is backgrounded or Wi-Fi is flaky. Requires Bluetooth on, phone within ~10m

The `_source` field tells you which path succeeded. Surface it to the user only if it matters (e.g., "took longer — pushed over BLE").

## Pairing + discovery

If commands fail with 401 or timeouts:

```bash
healthkit-cli discover   # finds phone on local network + BLE
healthkit-cli pair       # enters 6-digit code shown in the app
```

If `discover` returns `bonjour: {"found": false}` but `ble: {"found": true}`, the phone's BLE is alive but HTTP/Bonjour isn't advertising — usually the app isn't foregrounded. BLE queries still work; HTTP ones won't until the app is opened.

If `discover` found a different IP than what's stored, the stored config is stale. Write the new IP:

```bash
python3 -c "
import json, pathlib
from datetime import datetime, timezone
p = pathlib.Path.home() / '.datahub' / 'config.json'
c = json.loads(p.read_text())
c['ip'] = 'NEW.IP.HERE'
c['discoveredAt'] = datetime.now(timezone.utc).isoformat()
p.write_text(json.dumps(c, indent=2))
"
```

## Don't fabricate

If the CLI returns no data or an error, don't guess numbers. Surface the error and suggest the fix. The user can always open the Data Hub app on their phone and retry.

## Privacy

All data stays on the user's local network — no cloud. Don't store or log health data outside the current conversation, and don't send it anywhere except when the user explicitly asks for an action involving it.
