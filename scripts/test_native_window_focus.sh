#!/usr/bin/env bash
# No windows or application activation: executes actual bridge with message probes.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d -t zenit-window-focus)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun clang -fobjc-arc -Wno-deprecated-declarations \
  "$ROOT/native/macos/tests/window_focus_policy_test.m" \
  -framework Cocoa -framework IOSurface -framework Metal -framework QuartzCore -framework CoreVideo \
  -framework UniformTypeIdentifiers -o "$TEST_DIR/window-focus-test"
status=0
python3 "$ROOT/scripts/test_native_contract_runner.py"
for case in retry resign destroy handoff; do
  python3 "$ROOT/scripts/run_native_contract.py" --expect "PASS window focus policy $case" -- "$TEST_DIR/window-focus-test" "$case" || status=1
done
exit "$status"
