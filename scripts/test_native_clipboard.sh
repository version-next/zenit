#!/usr/bin/env bash
# Uses a private pasteboard; does not access the user's general clipboard.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d -t zenit-clipboard)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun clang -fobjc-arc -Wno-deprecated-declarations \
  "$ROOT/native/macos/tests/clipboard_test.m" \
  -framework Cocoa -framework Metal -framework QuartzCore -framework CoreVideo \
  -framework UniformTypeIdentifiers -o "$TEST_DIR/clipboard-test"
"$TEST_DIR/clipboard-test"
