import { existsSync, mkdirSync, readFileSync, writeFileSync } from "fs";
import { homedir } from "os";
import { join } from "path";

const CACHE_DIR = join(homedir(), ".datahub", "cache");

function ensureDir() {
  if (!existsSync(CACHE_DIR)) {
    mkdirSync(CACHE_DIR, { recursive: true });
  }
}

export function writeCache(key, data) {
  ensureDir();
  const entry = {
    _cached_at: new Date().toISOString(),
    ...data,
  };
  writeFileSync(join(CACHE_DIR, `${key}.json`), JSON.stringify(entry, null, 2));
}

export function readCache(key) {
  const file = join(CACHE_DIR, `${key}.json`);
  if (!existsSync(file)) {
    return null;
  }
  const data = JSON.parse(readFileSync(file, "utf-8"));
  data._source = "cache";
  return data;
}
