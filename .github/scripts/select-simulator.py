#!/usr/bin/env python3
"""Select an installed iOS runtime and available iPhone model for a new CI device."""
import json
import sys

inventory = json.load(sys.stdin)
models = {model["identifier"]: model["name"] for model in inventory["devicetypes"]}
runtimes = sorted(
    (runtime for runtime in inventory["runtimes"]
     if runtime["isAvailable"] and runtime["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")),
    key=lambda runtime: tuple(map(int, runtime["version"].split("."))),
    reverse=True,
)
for runtime in runtimes:
    iphones = [device for device in inventory["devices"].get(runtime["identifier"], [])
               if device.get("isAvailable") and models.get(device.get("deviceTypeIdentifier"), "").startswith("iPhone")]
    if not iphones:
        continue
    # Prefer this model, but runners with other available iPhones remain supported.
    chosen = next((device for device in iphones if models[device["deviceTypeIdentifier"]] == "iPhone 17 Pro"), iphones[0])
    print(runtime["identifier"])
    print(chosen["deviceTypeIdentifier"])
    break
else:
    sys.exit("No available iPhone simulator on an installed iOS runtime.")
