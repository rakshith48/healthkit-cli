#!/usr/bin/env python3
"""BLE client for Personal Data Hub — connects to iPhone BLE peripheral and queries health data."""

import asyncio
import json
import struct
import sys

from bleak import BleakClient, BleakScanner

# Must match BLEConstants in iOS app
SERVICE_UUID = "A1B2C3D4-E5F6-7890-ABCD-EF1234567890"
REQUEST_UUID = "A1B2C3D4-00FF-7890-ABCD-EF1234567890"
RESPONSE_UUID = "A1B2C3D4-00FE-7890-ABCD-EF1234567890"
STATUS_UUID = "A1B2C3D4-0001-7890-ABCD-EF1234567890"
WORKOUT_UPLOAD_UUID = "A1B2C3D4-00FD-7890-ABCD-EF1234567890"


async def discover(timeout=10.0):
    """Discover the PersonalDataHub BLE peripheral."""
    devices = await BleakScanner.discover(timeout=timeout, return_adv=True)

    # First try: match by service UUID in advertisement
    for device, adv_data in devices.values():
        if SERVICE_UUID.lower() in [str(u).lower() for u in (adv_data.service_uuids or [])]:
            return device
        if device.name and "DataHub" in device.name:
            return device

    # Second try: connect to iPhones and check for our service
    # iOS strips custom UUIDs from BLE advertisements, so we need to connect to discover
    candidates = [d for d, _ in devices.values() if d.name and ("iPhone" in d.name or "iPad" in d.name)]
    for device in candidates:
        try:
            async with BleakClient(device, timeout=5.0) as client:
                services = [str(s.uuid).lower() for s in client.services]
                if SERVICE_UUID.lower() in services:
                    return device
        except Exception:
            continue

    return None


async def query_ble(command: str, timeout=15.0):
    """Send a command to the iPhone via BLE and receive the JSON response."""

    # Discover device
    device = await discover(timeout=5.0)
    if not device:
        return {"error": "No DataHub BLE device found. Is the app running on your iPhone?", "_source": "ble_error"}

    response_data = bytearray()
    total_length = None
    done_event = asyncio.Event()

    def notification_handler(sender, data: bytearray):
        nonlocal response_data, total_length

        if total_length is None and len(data) >= 4:
            # First chunk — extract total length from header
            total_length = struct.unpack(">I", data[:4])[0]
            response_data.extend(data[4:])
        elif len(data) == 4 and struct.unpack(">I", data)[0] == 0:
            # End marker
            done_event.set()
        else:
            response_data.extend(data)

        # Check if we've received all data
        if total_length is not None and len(response_data) >= total_length:
            done_event.set()

    try:
        async with BleakClient(device, timeout=10.0) as client:
            # Subscribe to response notifications
            await client.start_notify(RESPONSE_UUID, notification_handler)

            # Send the command
            await client.write_gatt_char(REQUEST_UUID, command.encode("utf-8"))

            # Wait for complete response
            try:
                await asyncio.wait_for(done_event.wait(), timeout=timeout)
            except asyncio.TimeoutError:
                if response_data:
                    pass  # Try to parse what we have
                else:
                    return {"error": "BLE response timeout", "_source": "ble_error"}

            # Parse JSON response
            try:
                result = json.loads(response_data.decode("utf-8"))
                result["_source"] = "ble"
                return result
            except json.JSONDecodeError:
                return {"error": "Invalid response from device", "_source": "ble_error"}

    except Exception:
        return {"error": "BLE connection failed", "_source": "ble_error"}


def validate_command(command: str) -> bool:
    """Validate command format to prevent injection."""
    import re
    if command == 'workout_upload':
        return True
    return bool(re.match(r'^[a-z_]+:\d{1,3}$', command) or command in ('status', 'discover'))


async def upload_workout(payload: bytes, timeout: float = 20.0) -> dict:
    """Upload a JSON workout spec (bytes) to the iPhone via BLE.

    Wire format matches iOS `WorkoutUploadAssembler`:
        First write: [4-byte BE uint32 total_length][first chunk of data]
        Subsequent writes: [chunk of data]
    Phone replies via the response characteristic with the same chunked framing
    used for health queries.
    """
    device = await discover(timeout=5.0)
    if not device:
        return {"error": "No DataHub BLE device found. Is the app installed on your iPhone?",
                "_source": "ble_error"}

    response_data = bytearray()
    response_length = None
    response_done = asyncio.Event()

    def notification_handler(sender, data: bytearray):
        nonlocal response_data, response_length
        if response_length is None and len(data) >= 4:
            response_length = struct.unpack(">I", data[:4])[0]
            response_data.extend(data[4:])
        elif len(data) == 4 and struct.unpack(">I", data)[0] == 0:
            response_done.set()
            return
        else:
            response_data.extend(data)
        if response_length is not None and len(response_data) >= response_length:
            response_done.set()

    try:
        async with BleakClient(device, timeout=10.0) as client:
            await client.start_notify(RESPONSE_UUID, notification_handler)

            # Conservative chunk size. BLE MTU defaults to 23 but iOS negotiates
            # higher — 180 bytes fits all ATT MTU configurations we've seen.
            chunk_size = 180

            # First write: 4-byte length prefix + as much data as fits
            header = struct.pack(">I", len(payload))
            first = header + payload[: chunk_size - 4]
            await client.write_gatt_char(WORKOUT_UPLOAD_UUID, first, response=True)

            # Continuation writes
            offset = chunk_size - 4
            while offset < len(payload):
                end = min(offset + chunk_size, len(payload))
                await client.write_gatt_char(WORKOUT_UPLOAD_UUID, payload[offset:end], response=True)
                offset = end

            # Await ACK
            try:
                await asyncio.wait_for(response_done.wait(), timeout=timeout)
            except asyncio.TimeoutError:
                return {"error": "No ACK from phone within timeout", "_source": "ble_error"}

            raw = bytes(response_data[:response_length]) if response_length else bytes(response_data)
            try:
                result = json.loads(raw.decode("utf-8", errors="replace"))
                result.setdefault("_source", "ble")
                return result
            except json.JSONDecodeError:
                return {"error": "Invalid ACK payload from device", "_source": "ble_error"}

    except Exception as e:
        return {"error": f"BLE upload failed: {e}", "_source": "ble_error"}


async def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "Usage: ble_client.py <command>"}))
        sys.exit(1)

    command = sys.argv[1]

    if not validate_command(command):
        print(json.dumps({"error": "Invalid command format", "_source": "ble_error"}))
        sys.exit(1)

    if command == "discover":
        device = await discover()
        if device:
            print(json.dumps({"found": True, "name": device.name, "address": device.address}))
        else:
            print(json.dumps({"found": False, "error": "No DataHub BLE device found"}))
            sys.exit(1)
    elif command == "workout_upload":
        payload = sys.stdin.buffer.read()
        if not payload:
            print(json.dumps({"error": "No payload on stdin", "_source": "ble_error"}))
            sys.exit(1)
        if len(payload) > 256 * 1024:
            print(json.dumps({"error": "Payload exceeds 256 KB limit", "_source": "ble_error"}))
            sys.exit(1)
        result = await upload_workout(payload)
        print(json.dumps(result, indent=2))
    else:
        result = await query_ble(command)
        print(json.dumps(result, indent=2))


if __name__ == "__main__":
    asyncio.run(main())
