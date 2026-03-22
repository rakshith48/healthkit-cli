---
name: health
description: Query health data from the user's iPhone — steps, heart rate, sleep, workouts, HRV, and more. Use when the user asks about their health, fitness, activity, or body metrics.
argument-hint: [query]
---

# Health Data Access

You have access to the user's real-time health data from their iPhone via the `healthkit-cli` CLI.

Run commands with: `healthkit-cli <command>`

## Available Commands

- `healthkit-cli status` — Check if the phone is reachable
- `healthkit-cli health summary --days N` — Daily summary (steps, HR, sleep, calories, distance)
- `healthkit-cli health steps --days N` — Step counts per day
- `healthkit-cli health heart-rate --days N` — Average heart rate per day (bpm)
- `healthkit-cli health sleep --days N` — Sleep duration per day (hours)
- `healthkit-cli health hrv --days N` — Heart rate variability per day (ms)
- `healthkit-cli health spo2 --days N` — Blood oxygen per day (%)
- `healthkit-cli health calories --days N` — Active calories per day (kcal)
- `healthkit-cli health distance --days N` — Walking/running distance per day (km)
- `healthkit-cli health workouts --days N` — Recent workouts (type, duration, calories, HR, pace, distance)

## Usage

1. Run the appropriate command based on what the user is asking about
2. Parse the JSON output and present it clearly to the user
3. Check the `_source` field: `"live"` means real-time data, `"ble"` means via Bluetooth, `"cache"` means cached data
4. If `_source` is `"cache"`, mention when it was cached (`_cached_at` field)
5. If the response has an `error` field, tell the user to open the Data Hub app on their iPhone

## Notes

- All commands output JSON to stdout
- Default is 7 days if --days not specified (30 for workouts)
- Data comes from Apple HealthKit (includes Apple Watch data)
- The phone must be on the same WiFi network or within Bluetooth range
- When phone is unreachable, cached data from the last successful query is returned
