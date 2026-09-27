#!/bin/bash
# Runs the test suite.
#   ./test.sh          unit tests only: fast, no UI, fine with the screen off
#   ./test.sh full     unit + UI tests: drives the real app (moves the mouse,
#                      opens windows) — run before committing
set -euo pipefail

cd "$(dirname "$0")"

case "${1:-unit}" in
  unit) PLAN=Unit ;;
  full) PLAN=Full ;;
  *) echo "usage: $0 [unit|full]" >&2; exit 2 ;;
esac

# xcodebuild refuses to overwrite an existing result bundle.
RESULT="build/test-$PLAN.xcresult"
rm -rf "$RESULT"

set +e
xcodebuild test \
  -project Cheatsheet.xcodeproj \
  -scheme Cheatsheet \
  -testPlan "$PLAN" \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData \
  -resultBundlePath "$RESULT" \
  -quiet
STATUS=$?
set -e

xcrun xcresulttool get test-results summary --path "$RESULT" --compact 2>/dev/null \
  | python3 -c 'import json, sys; s = json.load(sys.stdin); print("\n%s: %d passed, %d failed, %d skipped" % (s["result"], s["passedTests"], s["failedTests"], s["skippedTests"]))' \
  || true
exit $STATUS
