---
name: health
description: Query health data from the user's iPhone — steps, heart rate, sleep, workouts, HRV, and more. Use when the user asks about their health, fitness, activity, or body metrics.
argument-hint: [query]
---

# Health Data Access

You have access to the user's real-time health data from their iPhone via the `datahub` CLI.

The CLI is located at: `/Users/rakshithramprakash/Desktop/AI Experiments/apple-health/personal-data-hub/cli/src/index.js`

Run commands with: `node /Users/rakshithramprakash/Desktop/AI\ Experiments/apple-health/personal-data-hub/cli/src/index.js <command>`

## Available Commands

- `datahub status` — Check if the phone is reachable
- `datahub health summary --days N` — Daily summary (steps, HR, sleep, calories, distance)
- `datahub health steps --days N` — Step counts per day
- `datahub health heart-rate --days N` — Average heart rate per day (bpm)
- `datahub health sleep --days N` — Sleep duration per day (hours)
- `datahub health hrv --days N` — Heart rate variability per day (ms)
- `datahub health spo2 --days N` — Blood oxygen per day (%)
- `datahub health calories --days N` — Active calories per day (kcal)
- `datahub health distance --days N` — Walking/running distance per day (km)
- `datahub health workouts --days N` — Recent workouts (type, duration, calories)

## Usage

1. Run the appropriate command based on what the user is asking about
2. Parse the JSON output and present it clearly to the user
3. Check the `_source` field: `"live"` means real-time data, `"cache"` means the phone was unreachable and cached data was used
4. If `_source` is `"cache"`, mention when it was cached (`_cached_at` field)
5. If the response has an `error` field, tell the user to open the Data Hub app on their iPhone

## Notes

- All commands output JSON to stdout
- Default is 7 days if --days not specified (30 for workouts)
- Data comes from Apple HealthKit (includes Apple Watch data)
- The phone must be on the same WiFi network and the app must be running for live data
- When phone is unreachable, cached data from the last successful query is returned
