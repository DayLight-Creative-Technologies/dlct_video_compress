#!/usr/bin/env bash
# [DLCT] Compiles the macOS plugin's real sources (macos/Classes) against the
# FlutterMacOS stand-in here, at the pod's deployment target (macOS 10.15),
# then runs main.swift's checks on the fixtures. Exits non-zero when a check
# fails, no check ran, or nothing could be built.
# Usage: native_tests/media_info/run_macos.sh [classes dir]  (default: macos/Classes)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
classes="${1:-$here/../../macos/Classes}"
target="$(uname -m)-apple-macos10.15"
build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT

# Utility.swift imports nothing: in the pod it sees Cocoa through the
# module's umbrella header, which this bridging header stands in for.
printf '#import <Cocoa/Cocoa.h>\n' > "$build/Bridge.h"

swiftc -target "$target" -emit-module -emit-library -module-name FlutterMacOS \
  -emit-module-path "$build/FlutterMacOS.swiftmodule" \
  -o "$build/libFlutterMacOS.dylib" "$here/FlutterMacOS.swift"

swiftc -target "$target" -import-objc-header "$build/Bridge.h" \
  -I "$build" -L "$build" -lFlutterMacOS \
  -Xlinker -rpath -Xlinker "$build" -o "$build/media_info" \
  "$here/main.swift" "$classes"/*.swift

"$build/media_info" "$here/fixtures" | tee "$build/out.txt"
grep -q 'all [1-9][0-9]* checks passed' "$build/out.txt"
