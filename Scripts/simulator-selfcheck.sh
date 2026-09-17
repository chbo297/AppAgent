#!/bin/bash
#
# Build AppAgentDemo for the iOS Simulator, run the headless capability
# self-check, and print the report.
#
# Every step is wrapped in a hard timeout so a hung xcodebuild / simctl can
# never wedge the run — it fails loudly instead. Requires `gtimeout`
# (brew install coreutils).
#
# Usage:
#   Scripts/simulator-selfcheck.sh                 # auto-pick a booted iPhone sim
#   Scripts/simulator-selfcheck.sh <device-udid>
#   SKIP_BUILD=1 Scripts/simulator-selfcheck.sh    # reuse the last build
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID="com.appagent.demo"
DERIVED="${DERIVED_DATA:-/tmp/appagent-dd}"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-900}"
LAUNCH_TIMEOUT="${LAUNCH_TIMEOUT:-60}"
REPORT_TIMEOUT="${REPORT_TIMEOUT:-60}"

command -v gtimeout >/dev/null || { echo "need gtimeout (brew install coreutils)"; exit 1; }

SIM="${1:-}"
if [ -z "$SIM" ]; then
    SIM=$(xcrun simctl list devices available | awk '/\(Booted\)/ && /iPhone/ {match($0, /\(([0-9A-F-]{36})\)/, m); print m[1]; exit}')
fi
if [ -z "$SIM" ]; then
    SIM=$(xcrun simctl list devices available | awk '/^ *iPhone/ {match($0, /\(([0-9A-F-]{36})\)/, m); print m[1]; exit}')
fi
[ -n "$SIM" ] || { echo "no iPhone simulator found"; exit 1; }
echo "==> simulator $SIM"

APP="$DERIVED/Build/Products/Debug-iphonesimulator/AppAgentDemo.app"
if [ -z "${SKIP_BUILD:-}" ]; then
    echo "==> building (timeout ${BUILD_TIMEOUT}s)"
    gtimeout "$BUILD_TIMEOUT" xcodebuild \
        -project "$REPO_ROOT/Examples/iOS/AppAgentDemo.xcodeproj" \
        -scheme AppAgentDemo -configuration Debug \
        -destination "platform=iOS Simulator,id=$SIM" \
        -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO build \
        > /tmp/appagent-build.log 2>&1
    case $? in
        0) ;;
        124) echo "BUILD TIMED OUT after ${BUILD_TIMEOUT}s — see /tmp/appagent-build.log"; exit 124 ;;
        *) echo "BUILD FAILED:"; grep -E "error:" /tmp/appagent-build.log | head -20; exit 1 ;;
    esac
fi
[ -d "$APP" ] || { echo "app bundle missing: $APP"; exit 1; }

echo "==> booting + installing"
gtimeout 120 xcrun simctl bootstatus "$SIM" -b > /dev/null 2>&1
gtimeout 120 xcrun simctl install "$SIM" "$APP" || { echo "INSTALL FAILED"; exit 1; }

# Clear the previous report so a stale file cannot be mistaken for a fresh run.
CONTAINER=$(gtimeout 30 xcrun simctl get_app_container "$SIM" "$BUNDLE_ID" data 2>/dev/null)
REPORT="$CONTAINER/Documents/selfcheck-report.txt"
[ -n "$CONTAINER" ] && rm -f "$REPORT"

echo "==> launching with -run-selfcheck"
gtimeout "$LAUNCH_TIMEOUT" xcrun simctl launch --terminate-running-process \
    "$SIM" "$BUNDLE_ID" -run-selfcheck || { echo "LAUNCH FAILED"; exit 1; }

CONTAINER=$(gtimeout 30 xcrun simctl get_app_container "$SIM" "$BUNDLE_ID" data)
REPORT="$CONTAINER/Documents/selfcheck-report.txt"
for i in $(seq 1 "$REPORT_TIMEOUT"); do
    [ -f "$REPORT" ] && break
    sleep 1
done
if [ ! -f "$REPORT" ]; then
    echo "NO REPORT after ${REPORT_TIMEOUT}s — the self-check hung or crashed."
    echo "Recent app log:"
    gtimeout 20 xcrun simctl spawn "$SIM" log show --last 1m \
        --predicate "processImagePath CONTAINS \"AppAgentDemo\"" --style compact 2>/dev/null | tail -30
    exit 124
fi

cp "$REPORT" /tmp/selfcheck-report.txt
echo "==> report: /tmp/selfcheck-report.txt"
grep -E "^✗" /tmp/selfcheck-report.txt || echo "(no failing checks)"
tail -4 /tmp/selfcheck-report.txt
grep -q "fail=0" /tmp/selfcheck-report.txt
