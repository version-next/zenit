#!/usr/bin/env bash
# Requires WindowServer/Metal. Uses hidden own window; no activation or input.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d -t zenit-resize-phase)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun clang -fobjc-arc -Wno-deprecated-declarations \
  "$ROOT/native/macos/tests/window_resize_phase_test.m" \
  -framework Cocoa -framework IOSurface -framework Metal -framework QuartzCore -framework CoreVideo \
  -framework UniformTypeIdentifiers -o "$TEST_DIR/test"
python3 "$ROOT/scripts/run_native_contract.py" --expect 'PASS resize generation, final frame, four native geometries, top-left placement and closed callback' -- "$TEST_DIR/test"
