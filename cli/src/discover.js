import { Bonjour } from "bonjour-service";
import { setPhoneAddress } from "./config.js";

export async function discover(timeout = 5000) {
  return new Promise((resolve, reject) => {
    const bonjour = new Bonjour();
    let found = false;

    const browser = bonjour.find({ type: "personaldatahub" }, (service) => {
      if (found) return;
      found = true;

      const ip =
        service.addresses?.find((a) => a.includes(".")) || // prefer IPv4
        service.addresses?.[0];

      // Read HTTP port from TXT record, fall back to service port
      const httpPort =
        service.txt?.port ? parseInt(service.txt.port, 10) : service.port;

      if (ip && httpPort) {
        setPhoneAddress(ip, httpPort);
        browser.stop();
        bonjour.destroy();
        resolve({ ip, port: httpPort, name: service.name });
      }
    });

    setTimeout(() => {
      if (!found) {
        browser.stop();
        bonjour.destroy();
        reject(new Error("No PersonalDataHub device found on the network."));
      }
    }, timeout);
  });
}
