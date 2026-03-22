# Privacy Policy

## Data Collection

HealthKit CLI does **not** collect, store, or transmit any data to external servers.

## How Your Data Flows

```
iPhone (HealthKit) → Local WiFi or Bluetooth → Your Mac → Claude (local)
```

All data stays on your local network. Nothing leaves your devices.

## What Data Is Accessed

The iOS app reads the following from Apple HealthKit (with your explicit permission):

- Step count
- Heart rate
- Heart rate variability (HRV)
- Blood oxygen (SpO2)
- Sleep analysis
- Active calories
- Walking/running distance
- Workouts (type, duration, distance, heart rate)

## Where Data Is Stored

| Location | What | Encrypted? |
|----------|------|-----------|
| iPhone Keychain | Paired device tokens | Yes (iOS encryption) |
| iPhone Documents/cache | Cached health data | Yes (FileProtectionType.complete) |
| Mac ~/.datahub/config.json | Phone IP + auth token | File permissions 0600 |
| Mac ~/.datahub/cache/ | Cached health data | File permissions 0600 |

## Authentication

- All HTTP requests require a Bearer token obtained through a 6-digit pairing code
- Pairing codes are single-use and regenerated after each pairing
- Tokens can be revoked from the iOS app

## No Analytics

No analytics, tracking, telemetry, crash reporting, or external network calls of any kind.

## No Cloud

No iCloud, no cloud sync, no remote servers. Everything is local.

## Contact

For privacy questions, open an issue on GitHub.
