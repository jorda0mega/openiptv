#!/usr/bin/env bash
# Creates and boots a simulator for the UI tests: the newest runtime of the
# platform (iOS or tvOS) and the device type named. Prints "udid=<id>" (for
# $GITHUB_OUTPUT). Usage: ci_simulator.sh <iOS|tvOS> "<device type name>"
set -euo pipefail
platform=${1:?platform}; device=${2:?device type}
read -r runtime type < <(xcrun simctl list -j | python3 -I -c '
import json, sys
platform, device = sys.argv[1], sys.argv[2]
data = json.load(sys.stdin)
runtimes = [r for r in data["runtimes"] if r["isAvailable"] and r["platform"] == platform]
runtime = max(runtimes, key=lambda r: [int(p) for p in r["version"].split(".")])
kind = next(t for t in data["devicetypes"] if t["name"] == device)
print(runtime["identifier"], kind["identifier"])' "$platform" "$device")
udid=$(xcrun simctl create "UI tests" "$type" "$runtime")
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b >/dev/null
echo "udid=$udid"
