#!/usr/bin/env bash
# [DLCT] Compiles the iOS plugin's real Swift sources (ios/Classes) against
# the Flutter stand-in here, for the simulator at the pod's deployment target
# (iOS 13.0), then runs main.swift's checks on the fixtures inside a fresh
# simulator of the newest and of the oldest installed iOS runtime (one run
# when they are the same). Each run covers every loading path its OS has
# (main.swift). Exits non-zero when a check fails, no check ran, no runtime
# is installed, or nothing could be built.
# Usage: native_tests/media_info/run_ios.sh [classes dir]  (default: ios/Classes)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
classes="${1:-$here/../../ios/Classes}"
target="$(uname -m)-apple-ios13.0-simulator"
build="$(mktemp -d)"
devices=()
cleanup() {
  for device in ${devices[@]+"${devices[@]}"}; do
    xcrun simctl shutdown "$device" >/dev/null 2>&1 || true
    xcrun simctl delete "$device" >/dev/null 2>&1 || true
  done
  rm -rf "$build"
}
trap cleanup EXIT

# Utility.swift imports nothing: in the pod it sees UIKit through the
# module's umbrella header, which this bridging header stands in for.
printf '#import <UIKit/UIKit.h>\n' > "$build/Bridge.h"

xcrun --sdk iphonesimulator swiftc -target "$target" -emit-module -emit-library -module-name Flutter \
  -emit-module-path "$build/Flutter.swiftmodule" \
  -o "$build/libFlutter.dylib" "$here/Flutter.swift"

xcrun --sdk iphonesimulator swiftc -target "$target" -import-objc-header "$build/Bridge.h" \
  -I "$build" -L "$build" -lFlutter \
  -Xlinker -rpath -Xlinker "$build" -o "$build/media_info" \
  "$here/main.swift" "$classes"/*.swift

# "<runtime id> <device type id>" for the newest and the oldest available iOS
# runtime, each with the first iPhone it supports.
runtimes="$(xcrun simctl list runtimes --json | python3 -c '
import json, sys
runtimes = [r for r in json.load(sys.stdin)["runtimes"]
            if r.get("platform") == "iOS" and r.get("isAvailable")]
runtimes.sort(key=lambda r: [int(p) for p in r["version"].split(".")])
for r in {r["identifier"]: r for r in (runtimes[-1:] + runtimes[:1])}.values():
    iphones = [t["identifier"] for t in r.get("supportedDeviceTypes", [])
               if t.get("productFamily") == "iPhone"]
    if iphones:
        print(r["identifier"], iphones[0])
')"
if [ -z "$runtimes" ]; then
  echo "No available iOS simulator runtime with an iPhone"
  exit 1
fi

while read -r runtime type; do
  device="$(xcrun simctl create "video_compress tests" "$type" "$runtime")"
  devices+=("$device")
  echo "Running on $runtime ($type)"
  xcrun simctl bootstatus "$device" -b </dev/null >/dev/null
  xcrun simctl spawn "$device" "$build/media_info" "$here/fixtures" </dev/null | tee "$build/out.txt"
  grep -q 'all [1-9][0-9]* checks passed' "$build/out.txt"
  xcrun simctl shutdown "$device"
done <<< "$runtimes"
