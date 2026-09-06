#!/usr/bin/env python3
import json
import os
import sys

from midea_beautiful import connect_to_cloud
from midea_beautiful.lan import appliance_state


def output(value):
    print(json.dumps(value, separators=(",", ":")))


def cloud_client():
    account = os.environ.get("PAPERGIF_NETHOME_ACCOUNT", "")
    password = os.environ.get("PAPERGIF_NETHOME_PASSWORD", "")
    if not account or not password:
        raise ValueError("NetHome credentials are missing")
    return connect_to_cloud(account=account, password=password, appname="NetHome Plus")


def appliances(cloud):
    return [item for item in cloud.list_appliances(force=True) if str(item.get("type", "")).lower() in ("172", "ac", "0xac")]


def find_appliance(cloud, name):
    matches = [item for item in appliances(cloud) if item.get("name", "").casefold() == name.casefold()]
    if not matches:
        raise ValueError(f"No NetHome air conditioner named '{name}'")
    return matches[0]


def device_state(cloud, item):
    return appliance_state(
        cloud=cloud,
        use_cloud=True,
        appliance_id=str(item["id"]),
        appliance_type=item["type"],
    )


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else "list"
    cloud = cloud_client()
    if command == "list":
        output({"ok": True, "devices": [{"name": item["name"], "id": str(item["id"])} for item in appliances(cloud)]})
        return

    if len(sys.argv) < 4 or command != "set":
        raise ValueError("Expected: set <unit-name> <power|temperature|mode|fan> [value]")
    item = find_appliance(cloud, sys.argv[2])
    device = device_state(cloud, item)
    action = sys.argv[3]
    value = sys.argv[4] if len(sys.argv) > 4 else ""
    values = {}
    if action == "power":
        values["running"] = not device.state.running if value == "toggle" else value == "on"
    elif action == "temperature":
        values["target_temperature"] = min(max(float(value), 16), 30)
    elif action == "mode":
        values["mode"] = {"auto": 1, "cool": 2, "dry": 3, "heat": 4, "fan": 5}[value]
    elif action == "fan":
        values["fan_speed"] = min(max(int(value), 20), 100)
    elif action == "climate":
        if len(sys.argv) < 7:
            raise ValueError("Expected climate <cool|heat> <temperature> <fan>")
        values["mode"] = {"cool": 2, "heat": 4}[value]
        values["target_temperature"] = min(max(float(sys.argv[5]), 16), 30)
        values["fan_speed"] = min(max(int(sys.argv[6]), 20), 100)
        values["running"] = True
    else:
        raise ValueError(f"Unsupported action '{action}'")
    changed = any(getattr(device.state, key) != requested for key, requested in values.items())
    if not changed:
        output({"ok": True, "changed": False, "device": item["name"]})
        return
    device.set_state(cloud=cloud, **values)
    output({"ok": True, "changed": True, "device": item["name"]})


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        output({"ok": False, "error": str(error)})
        sys.exit(1)