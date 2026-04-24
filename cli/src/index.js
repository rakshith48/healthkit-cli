#!/usr/bin/env node

import { Command } from "commander";
import { discover } from "./discover.js";
import { discoverBLE } from "./ble.js";
import { query, status } from "./client.js";
import { pair } from "./auth.js";
import { sync, watchVault } from "./vault.js";
import { queueWorkout, listQueue, clearQueue } from "./workout.js";
import { existsSync, mkdirSync, copyFileSync, rmSync, readFileSync } from "fs";
import { homedir } from "os";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const program = new Command();

// Keep --version in sync with package.json so releases can't drift.
const PKG = JSON.parse(
  readFileSync(join(dirname(fileURLToPath(import.meta.url)), "..", "package.json"), "utf8")
);

function validateDays(value) {
  const n = parseInt(value, 10);
  if (isNaN(n) || n < 1 || n > 365) {
    console.log(JSON.stringify({ error: "days must be between 1 and 365" }));
    process.exit(1);
  }
  return String(n);
}

program
  .name("healthkit-cli")
  .description("Query Apple HealthKit data from your iPhone and push custom workouts to your Apple Watch")
  .version(PKG.version);

// --- install-skill ---
program
  .command("install-skill")
  .description("Install the healthkit-cli skill for Claude Code (covers both health queries and workout push)")
  .action(() => {
    const __dirname = dirname(fileURLToPath(import.meta.url));
    const source = join(__dirname, "..", "skills", "healthkit-cli", "SKILL.md");
    const destDir = join(homedir(), ".claude", "skills", "healthkit-cli");
    const dest = join(destDir, "SKILL.md");

    if (!existsSync(source)) {
      console.log(JSON.stringify({ error: "SKILL.md not found in package" }));
      process.exit(1);
    }

    mkdirSync(destDir, { recursive: true, mode: 0o700 });
    copyFileSync(source, dest);

    // Clean up the old `health` skill directory if it exists, since the
    // comprehensive `healthkit-cli` skill supersedes it.
    const oldSkillDir = join(homedir(), ".claude", "skills", "health");
    let removedOld = false;
    if (existsSync(oldSkillDir)) {
      try {
        rmSync(oldSkillDir, { recursive: true, force: true });
        removedOld = true;
      } catch {
        // Non-fatal — user can delete manually
      }
    }

    console.log(JSON.stringify({
      installed: true,
      path: dest,
      removed_old_health_skill: removedOld,
      message: "Claude Code skill installed. Covers health queries and workout push."
    }, null, 2));
  });

// --- pair ---
program
  .command("pair")
  .description("Pair with your iPhone using the 6-digit code shown in the app")
  .action(async () => {
    await pair();
  });

// --- discover ---
program
  .command("discover")
  .description("Find your phone on the network via Bonjour and BLE")
  .action(async () => {
    const results = {};

    // Try Bonjour
    try {
      const device = await discover();
      results.bonjour = { found: true, ...device };
    } catch {
      results.bonjour = { found: false };
    }

    // Try BLE
    try {
      const ble = await discoverBLE();
      results.ble = ble;
    } catch {
      results.ble = { found: false };
    }

    console.log(JSON.stringify(results, null, 2));
  });

// --- status ---
program
  .command("status")
  .description("Check if the phone is reachable (HTTP, BLE, or cache)")
  .action(async () => {
    const result = await status();
    console.log(JSON.stringify(result, null, 2));
  });

// --- health ---
const health = program
  .command("health")
  .description("Query health metrics from HealthKit");

health
  .command("summary")
  .description("Get daily health summary")
  .option("--days <n>", "Number of days", "7")
  .action(async (opts) => {
    const days = validateDays(opts.days);
    const result = await query(
      "/health/summary",
      { days },
      "summary",
      `summary:${days}`
    );
    console.log(JSON.stringify(result, null, 2));
  });

const METRICS = [
  ["steps", "Step counts per day", "steps"],
  ["heart-rate", "Average heart rate per day (bpm)", "heart_rate"],
  ["sleep", "Sleep duration per day (hours)", "sleep"],
  ["hrv", "Heart rate variability per day (ms)", "hrv"],
  ["spo2", "Blood oxygen per day (%)", "spo2"],
  ["calories", "Active calories per day (kcal)", "active_calories"],
  ["distance", "Walking/running distance per day (km)", "distance"],
];

for (const [name, desc, apiType] of METRICS) {
  health
    .command(name)
    .description(desc)
    .option("--days <n>", "Number of days", "7")
    .action(async (opts) => {
      const days = validateDays(opts.days);
      const result = await query(
        "/health/metrics",
        { type: apiType, days },
        name,
        `${apiType}:${days}`
      );
      console.log(JSON.stringify(result, null, 2));
    });
}

health
  .command("workouts")
  .description("Recent workouts (type, duration, calories)")
  .option("--days <n>", "Number of days", "30")
  .action(async (opts) => {
    const days = validateDays(opts.days);
    const result = await query(
      "/health/workouts",
      { days },
      "workouts",
      `workouts:${days}`
    );
    console.log(JSON.stringify(result, null, 2));
  });

// --- vault ---
const vault = program
  .command("vault")
  .description("Sync Obsidian vault between iPhone and Mac");

vault
  .command("sync")
  .description("One-time sync — pulls new notes from phone, pushes new notes from Mac")
  .action(async () => {
    await sync();
  });

vault
  .command("watch")
  .description("Watch for changes and auto-sync bidirectionally")
  .action(async () => {
    await watchVault();
  });

// --- workout ---
const workout = program
  .command("workout")
  .description("Push custom workouts to your iPhone — appear in 'Workouts' tab for one-tap save to Apple Watch");

workout
  .command("queue <file>")
  .description("Push a workout spec (JSON) or a batch plan to the iPhone queue")
  .action(async (file) => {
    await queueWorkout(file);
  });

workout
  .command("list")
  .description("Show the current iPhone workout queue (pending + saved)")
  .action(async () => {
    await listQueue();
  });

workout
  .command("clear [id]")
  .description("Remove a workout by id, or clear all if no id given")
  .action(async (id) => {
    await clearQueue(id);
  });

program.parse();
