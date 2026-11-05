#!/usr/bin/env bash
# Explicit attended acceptance: only own windows/helper, no global input.
set -euo pipefail
if [[ "${1:-}" != "--allow-foreground" || -z "${2:-}" ]]; then
  echo 'usage: test_native_window_focus_live.sh --allow-foreground ABSOLUTE_ARTIFACT_DIR' >&2
  exit 2
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACTS="$2"
[[ "$ARTIFACTS" = /* ]] || exit 2
mkdir -p "$ARTIFACTS"
xcrun clang -fobjc-arc -Wno-deprecated-declarations \
  "$ROOT/native/macos/tests/window_focus_live_test.m" \
  -framework Cocoa -framework IOSurface -framework Metal -framework QuartzCore -framework CoreVideo \
  -framework UniformTypeIdentifiers -o "$ARTIFACTS/window-focus-test"
python3 "$ROOT/scripts/run_native_contract.py" --timeout 25 \
  --expect 'PASS live same-app handoff, external-app retry/close isolation, owner recovery' \
  -- "$ARTIFACTS/window-focus-test" "$ARTIFACTS" 2>&1 | tee "$ARTIFACTS/run.log"
