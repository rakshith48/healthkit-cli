# HealthKit CLI

Query Apple HealthKit data from your iPhone via command line. Works over WiFi and Bluetooth — even when the app is in the background.

Built for [Claude Code](https://claude.ai/claude-code) as an AI health data bridge, but works standalone too.

```
$ healthkit-cli health summary --days 3

{
  "daily": [
    { "date": "2026-03-21", "steps": 9743, "heart_rate_avg": 58, "sleep_hours": 8.1, ... },
    { "date": "2026-03-20", "steps": 6197, "heart_rate_avg": 52, "sleep_hours": 9.3, ... },
    { "date": "2026-03-19", "steps": 12008, "heart_rate_avg": 63, "sleep_hours": 7.2, ... }
  ]
}
```

## How It Works

```
iPhone App                          Mac CLI
┌─────────────────────┐            ┌──────────────┐
│ HealthKit reader    │  HTTP/BLE  │ healthkit-cli │
│ HTTP server (:8765) │◄──────────►│              │──► stdout (JSON)
│ BLE peripheral      │            │ Local cache   │
│ Background delivery  │            └──────────────┘
└─────────────────────┘                   │
        ▲                                 ▼
   Apple Watch                     Claude Code / scripts
   syncs health data
```

- **App in foreground** → CLI connects via HTTP (fastest)
- **App in background** → CLI connects via Bluetooth LE (BLE peripheral stays alive)
- **Phone unreachable** → CLI serves from local cache

## Setup

### 1. Install the iOS app

```bash
git clone https://github.com/rakshith48/healthkit-cli.git
cd healthkit-cli/ios-app
xcodegen generate
open PersonalDataHub.xcodeproj
```

In Xcode:
- Sign in with your Apple ID (Settings → Accounts)
- Select your team under Signing & Capabilities
- Change Bundle Identifier to something unique (e.g., `com.yourname.healthkit`)
- Enable HealthKit capability (check "HealthKit" under Signing & Capabilities)
- Select your iPhone and hit Cmd+R

Grant HealthKit permissions when prompted.

### 2. Install the CLI

```bash
npm install -g healthkit-cli
```

### 3. Discover and pair

```bash
# Find your phone on the network
healthkit-cli discover

# Pair using the 6-digit code shown in the iOS app
healthkit-cli pair
```

### 4. Query your health data

```bash
healthkit-cli health steps --days 7
healthkit-cli health heart-rate --days 7
healthkit-cli health sleep --days 7
healthkit-cli health hrv --days 7
healthkit-cli health workouts --days 30
healthkit-cli health summary --days 7
healthkit-cli status
```

## Available Commands

| Command | Description |
|---------|-------------|
| `healthkit-cli discover` | Find phone via Bonjour + BLE |
| `healthkit-cli pair` | Pair with phone using 6-digit code |
| `healthkit-cli status` | Check phone connectivity |
| `healthkit-cli health summary --days N` | Daily summary (steps, HR, sleep, calories, distance) |
| `healthkit-cli health steps --days N` | Step counts per day |
| `healthkit-cli health heart-rate --days N` | Average heart rate per day (bpm) |
| `healthkit-cli health sleep --days N` | Sleep duration per day (hours) |
| `healthkit-cli health hrv --days N` | Heart rate variability per day (ms) |
| `healthkit-cli health spo2 --days N` | Blood oxygen per day (%) |
| `healthkit-cli health calories --days N` | Active calories per day (kcal) |
| `healthkit-cli health distance --days N` | Walking/running distance per day (km) |
| `healthkit-cli health workouts --days N` | Workouts with distance, HR, pace, splits |
| `healthkit-cli workout queue <file>` | Push a custom workout spec (JSON) to the iPhone queue |
| `healthkit-cli workout list` | Show the queue (pending + saved) |
| `healthkit-cli workout clear [id]` | Remove one queued workout or clear all |

### Custom Workouts (WorkoutKit)

The `workout` subcommand pushes a structured workout spec to the iPhone. It appears under the app's **Workouts** tab. Tap "Preview + Save" and Apple's native preview sheet lets you save the workout directly to the Workout app on your Apple Watch.

Example spec (`tempo.json`):

```json
{
  "displayName": "Wk 3 Tempo 7km",
  "activity": "running",
  "location": "outdoor",
  "warmup": { "goal": { "distance_km": 1.5 } },
  "blocks": [
    {
      "iterations": 1,
      "steps": [
        {
          "purpose": "work",
          "goal": { "distance_km": 4 },
          "alert": { "type": "pace", "minPace": "5:10", "maxPace": "5:20" }
        }
      ]
    }
  ],
  "cooldown": { "goal": { "distance_km": 1.5 } }
}
```

Batch form (wrap in `{ "workouts": [...] }`). Supported goals: `distance_m`, `distance_km`, `time_s`, `time_min`, `energy_kcal`. Supported alerts: `pace` (minPace/maxPace), `speed_mps`, `heart_rate` (min/max bpm), `heart_rate_zone` (1-5).

Requires iOS 17+ on the iPhone (WorkoutKit minimum).

#### Transport fallback: HTTP → BLE

`workout queue` tries HTTP first (needs the app foregrounded) and falls back to BLE (works when the app is backgrounded; only requires Bluetooth). The BLE path chunks the JSON payload into ~180-byte frames written to a dedicated characteristic, reassembled on the phone, then the same accept/reject ACK is returned over the notification channel. The CLI prints `"_source": "http"` or `"_source": "ble"` so you can tell which path succeeded.

## Claude Code Integration

Install the `/health` skill:

```bash
healthkit-cli install-skill
```

Then ask Claude: *"How did I sleep this week?"* — it will use `healthkit-cli` automatically.

## Data Sources

The CLI reads from Apple HealthKit, which aggregates data from:
- Apple Watch
- Ultrahuman Ring
- Strava
- Nike Run Club
- MyFitnessPal
- Any app that writes to HealthKit

## Security

- All requests require a Bearer token (obtained via 6-digit pairing code)
- Tokens stored in iOS Keychain + Mac filesystem (0600 permissions)
- Rate limited (60 req/min)
- Input validation on all parameters
- No data leaves your local network

See [PRIVACY.md](PRIVACY.md) for full details.

## Requirements

- iPhone with iOS 16+
- Mac with Node.js 18+
- Python 3.10+ (for BLE — `pip install bleak`)
- Xcode (to build the iOS app)
- Apple Developer account (free works, paid removes 7-day re-sign)

## Architecture

**iOS App (Swift)**
- `HealthKitManager` — reads steps, HR, sleep, HRV, SpO2, workouts from HealthKit
- `LocalHTTPServer` — Swifter-based HTTP server on port 8765
- `BLEPeripheral` — Core Bluetooth peripheral, survives app backgrounding
- `AuthManager` — pairing codes + Bearer token validation via Keychain
- `BonjourAdvertiser` — mDNS service discovery
- HealthKit background delivery — auto-caches when Apple Watch syncs new data

**CLI (Node.js)**
- 3-tier fallback: HTTP → BLE → local cache
- Bonjour discovery for zero-config phone finding
- Bearer token auth
- All output is JSON

## License

MIT
