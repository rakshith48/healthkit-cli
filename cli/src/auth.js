import { loadConfig, saveConfig, getPhoneAddress } from "./config.js";
import { createInterface } from "readline";

export function getToken() {
  const config = loadConfig();
  return config.token || null;
}

export function saveToken(token) {
  const config = loadConfig();
  config.token = token;
  saveConfig(config);
}

export function clearToken() {
  const config = loadConfig();
  delete config.token;
  saveConfig(config);
}

export async function pair() {
  const addr = getPhoneAddress();
  if (!addr) {
    console.log(
      JSON.stringify({
        error: "Phone not discovered. Run 'datahub discover' first.",
      })
    );
    process.exit(1);
  }

  // Prompt for pairing code
  const code = await promptInput("Enter the 6-digit pairing code from your iPhone: ");

  if (!/^\d{6}$/.test(code)) {
    console.log(JSON.stringify({ error: "Pairing code must be 6 digits." }));
    process.exit(1);
  }

  // Get device name
  const { hostname } = await import("os");
  const deviceName = hostname();

  // Send pairing request
  const url = `http://${addr.ip}:${addr.port}/pair`;
  try {
    const res = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code, device_name: deviceName }),
    });

    const data = await res.json();

    if (res.ok && data.token) {
      saveToken(data.token);
      console.log(
        JSON.stringify({ paired: true, device_name: deviceName })
      );
    } else {
      console.log(
        JSON.stringify({ paired: false, error: data.error || "Pairing failed" })
      );
      process.exit(1);
    }
  } catch {
    console.log(
      JSON.stringify({
        paired: false,
        error: "Could not reach phone. Make sure the app is open.",
      })
    );
    process.exit(1);
  }
}

function promptInput(question) {
  return new Promise((resolve) => {
    const rl = createInterface({
      input: process.stdin,
      output: process.stderr, // Use stderr so JSON on stdout stays clean
    });
    rl.question(question, (answer) => {
      rl.close();
      resolve(answer.trim());
    });
  });
}
