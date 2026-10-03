#!/usr/bin/env bash
# [DLCT] Compiles the macOS plugin's real sources (macos/Classes) against the
# FlutterMacOS stand-in here, then runs main.swift's getMediaInfo checks on
# the fixtures. Exits non-zero when a check fails or nothing could be built.
# Usage: macos/Tests/media_info/run.sh [classes dir]  (default: macos/Classes)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
classes="${1:-$here/../../Classes}"
build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT

# Utility.swift imports nothing: in the pod it sees Cocoa through the
# module's umbrella header, which this bridging header stands in for.
printf '#import <Cocoa/Cocoa.h>\n' > "$build/Bridge.h"

swiftc -emit-module -emit-library -module-name FlutterMacOS \
  -emit-module-path "$build/FlutterMacOS.swiftmodule" \
  -o "$build/libFlutterMacOS.dylib" "$here/FlutterMacOS.swift"

swiftc -import-objc-header "$build/Bridge.h" -I "$build" -L "$build" -lFlutterMacOS \
  -Xlinker -rpath -Xlinker "$build" -o "$build/media_info" \
  "$here/main.swift" "$classes"/*.swift

"$build/media_info" "$here/fixtures"
