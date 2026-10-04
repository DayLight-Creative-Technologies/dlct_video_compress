#!/usr/bin/env bash
# [DLCT] Fails unless the last connectedDebugAndroidTest run reported every
# @Test of VideoCompressPluginTest (counted in its source; with
# --without-video-encoder, every one not marked @RequiresVideoEncoder), with
# no failure, error or skip; then moves the report to
# example/build/instrumentation/<label> so the next run cannot be mistaken
# for this one.
# Usage: native_tests/android/check_instrumentation_results.sh <label> [--without-video-encoder]
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
label="$1"
source_file="$root/example/android/app/src/androidTest/kotlin/com/example/video_compress_example/VideoCompressPluginTest.kt"
results="$root/example/build/app/outputs/androidTest-results/connected/debug"
expected="$(grep -c '^ *@Test$' "$source_file")"
if [ "${2:-}" = "--without-video-encoder" ]; then
  expected=$((expected - $(grep -c '^ *@RequiresVideoEncoder$' "$source_file")))
fi

shopt -s nullglob
reports=("$results"/TEST-*.xml)
if [ "${#reports[@]}" -ne 1 ]; then
  echo "$label: expected one instrumentation report in $results, found ${#reports[@]}"
  exit 1
fi
report="${reports[0]}"
suite="$(grep -o '<testsuite [^>]*>' "$report")"
echo "$label: $suite"
attribute() { echo "$suite" | grep -o "$1=\"[0-9]*\"" | grep -o '[0-9]*'; }
tests="$(attribute tests)"
failures="$(attribute failures)"
errors="$(attribute errors)"
skipped="$(attribute skipped)"
ran="$(grep -c '<testcase [^>]*classname="com.example.video_compress_example.VideoCompressPluginTest"' "$report")"
if [ "$expected" -lt 1 ] || [ "$tests" != "$expected" ] || [ "$ran" != "$expected" ] \
   || [ "$failures" != 0 ] || [ "${errors:-0}" != 0 ] || [ "${skipped:-0}" != 0 ]; then
  echo "$label: expected $expected tests of VideoCompressPluginTest to pass; report: tests=$tests ran=$ran failures=$failures errors=${errors:-0} skipped=${skipped:-0}"
  exit 1
fi
mkdir -p "$root/example/build/instrumentation/$label"
mv "$report" "$root/example/build/instrumentation/$label/"
echo "$label: all $expected tests passed"
