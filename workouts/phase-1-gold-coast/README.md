# Phase 1 · Gold Coast Half Marathon (May 3 – Jul 5, 2026)

9-week build to 1:45 half marathon PR. Matches `wiki/phase-1-gold-coast.md` in the life vault.

## Upload

```bash
# Upload a single week when ready (Sunday before new week)
healthkit-cli workout queue workouts/phase-1-gold-coast/week-1.json

# Or upload the whole phase in one shot
for f in workouts/phase-1-gold-coast/week-*.json; do
  healthkit-cli workout queue "$f"
done
```

## Flow

1. CLI pushes workouts → iPhone queues them (Bearer-auth'd HTTP POST)
2. Open Data Hub app → tap Workouts tab → see pending list
3. Tap any workout → Apple's native preview sheet → tap "Save" → workout appears in your Apple Watch's Workout app library
4. Start from your Watch whenever you're ready to run

## Week files

| File | Sessions | Total km | Notes |
|---|---|---|---|
| week-1.json | Easy 5k · Track 2x800+4x200 · Long 10k | 14 | Re-baseline post-India |
| week-2.json | Tempo 6k · Track 3x800+6x200 · Long 11k | 18 | |
| week-3.json | Tempo 7k · Track 4x800+4x200 · Long 13k | 22 | |
| week-4.json | Tempo 8k · Track 5x800 · Long 14k (4k goal pace) | 26 | Goal pace intro |
| week-5-cutback.json | Easy 5k · Track 6x400 · Long 12k easy | 22 | Cutback |
| week-6.json | Tempo 9k · Track 4x1km · Long 16k (5k goal) | 29 | |
| week-7-peak.json | Tempo 9k · Track 3x1.5km · Long 18k (last 4k @ 5:00) | 32 | **PEAK — money workout** |
| week-8-taper.json | Tempo 6k · Track 4x800 · Long 14k easy | 24 | Taper 1 |
| week-9-race.json | Race primer · Shakeout · **RACE SUN JUL 5** | 21.1 + easy | |

## Target paces (1:45 half = 4:58/km)

| Zone | Week 1-2 | Week 3-5 | Week 6-7 Peak | HR |
|---|---|---|---|---|
| Easy (E) | 6:00-6:15 | 5:45-6:00 | 5:45 | 130-145 |
| Threshold (T) | 5:20 | 5:10 | **4:55-5:00** | 165-172 |
| Interval (I) | 4:30 | 4:25 | 4:20 | 175-182 |
| Rep (R) | 4:05 | 4:00 | 3:55 | max |

## Notes

- Rest day: Wednesday
- Thu AM rest (track is Thu PM via KCTC — those sessions are already in Hevy, can still be saved to Watch for HR/lap tracking)
- Sat long run + 5 min tibialis/calf post-run
- Sun lower + full rehab block (separate — see Hevy "Phase 1 — Lower + Rehab")

## Why some workouts aren't here

Gym sessions (Mon Upper, Fri Mixed, Sun Lower) are in Hevy — see the `Phase 1 — *` routines. WorkoutKit doesn't represent strength training as well as Hevy does, so we split:

- **Running sessions** → WorkoutKit (pace/HR alerts, interval structure, Apple Watch native)
- **Lifting sessions** → Hevy (sets/reps/weight progression, superior lift tracking)
