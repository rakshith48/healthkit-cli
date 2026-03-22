import { existsSync, mkdirSync, readFileSync, writeFileSync } from "fs";
import { homedir } from "os";
import { join } from "path";

const CONFIG_DIR = join(homedir(), ".datahub");
const CONFIG_FILE = join(CONFIG_DIR, "config.json");

function ensureDir() {
  if (!existsSync(CONFIG_DIR)) {
    mkdirSync(CONFIG_DIR, { recursive: true, mode: 0o700 });
  }
}

export function loadConfig() {
  ensureDir();
  if (!existsSync(CONFIG_FILE)) {
    return {};
  }
  return JSON.parse(readFileSync(CONFIG_FILE, "utf-8"));
}

export function saveConfig(config) {
  ensureDir();
  writeFileSync(CONFIG_FILE, JSON.stringify(config, null, 2), { mode: 0o600 });
}

export function getPhoneAddress() {
  const config = loadConfig();
  if (config.ip && config.port) {
    return { ip: config.ip, port: config.port };
  }
  return null;
}

export function setPhoneAddress(ip, port) {
  const config = loadConfig();
  config.ip = ip;
  config.port = port;
  config.discoveredAt = new Date().toISOString();
  saveConfig(config);
}
