#!/usr/bin/env node

import { Command } from "commander";
import { discover } from "./discover.js";
import { discoverBLE } from "./ble.js";
import { query, status } from "./client.js";

const program = new Command();

program
  .name("datahub")
  .description("Query health data from your iPhone via Personal Data Hub")
  .version("0.1.0");

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
    const result = await query(
      "/health/summary",
      { days: opts.days },
      "summary",
      `summary:${opts.days}`
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
      const result = await query(
        "/health/metrics",
        { type: apiType, days: opts.days },
        name,
        `${apiType}:${opts.days}`
      );
      console.log(JSON.stringify(result, null, 2));
    });
}

health
  .command("workouts")
  .description("Recent workouts (type, duration, calories)")
  .option("--days <n>", "Number of days", "30")
  .action(async (opts) => {
    const result = await query(
      "/health/workouts",
      { days: opts.days },
      "workouts",
      `workouts:${opts.days}`
    );
    console.log(JSON.stringify(result, null, 2));
  });

program.parse();
