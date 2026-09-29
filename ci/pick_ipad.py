"""Prints the UDID of the best available iPad simulator: an iPad Pro 13-inch on the newest iOS if there is one."""
import json
import re
import sys

devices = json.load(sys.stdin)["devices"]
candidates = []
for runtime, runtime_devices in devices.items():
    match = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not match:
        continue
    version = (int(match.group(1)), int(match.group(2)))
    for device in runtime_devices:
        name = device["name"]
        if device.get("isAvailable") and name.startswith("iPad"):
            preference = 0 if "iPad Pro 13" in name else 1 if "iPad Pro" in name else 2
            candidates.append((preference, [-v for v in version], name, device["udid"]))

if not candidates:
    sys.exit("No iPad simulator available")
preference, version, name, udid = sorted(candidates)[0]
print(f"Using {name} on iOS {-version[0]}.{-version[1]}", file=sys.stderr)
print(udid)
