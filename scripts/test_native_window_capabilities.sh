#!/usr/bin/env bash
# Window capability opt-outs exercised against the real AppKit bridge.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d -t zenit-window-capabilities)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun clang -fobjc-arc -Wno-deprecated-declarations \
  "$ROOT/native/macos/tests/window_capabilities_test.m" \
  -framework Cocoa -framework Metal -framework IOSurface -framework QuartzCore -framework CoreVideo \
  -framework UniformTypeIdentifiers -o "$TEST_DIR/window-capabilities-test"
"$TEST_DIR/window-capabilities-test"
