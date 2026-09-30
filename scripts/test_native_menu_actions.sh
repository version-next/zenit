#!/usr/bin/env bash
# Exercises native legacy menu actions in process;
# no global keys, system input-source changes, or GUI window are needed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d -t zenit-input-pump)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun clang -fobjc-arc -Wno-deprecated-declarations \
  "$ROOT/native/macos/tests/menu_actions_test.m" \
  -framework Cocoa -framework Metal -framework QuartzCore -framework CoreVideo \
  -framework UniformTypeIdentifiers -o "$TEST_DIR/menu-actions-test"
for ((run = 0; run < ${ZENIT_INPUT_TEST_RUNS:-1}; run++)); do
  "$TEST_DIR/menu-actions-test" "$@"
done

xcrun clang -fobjc-arc -Wno-deprecated-declarations -DZENIT_MENU_ACTIONS_NO_MAIN \
  -c "$ROOT/native/macos/tests/menu_actions_test.m" -o "$TEST_DIR/bridge.o"
"${ZIG_BIN:-zig}" test "$TEST_DIR/bridge.o" --dep platform \
  -Mroot="$ROOT/native/macos/tests/menu_actions_test.zig" -Mplatform="$ROOT/src/platform.zig" \
  -framework Cocoa -framework Metal -framework QuartzCore -framework CoreVideo \
  -framework UniformTypeIdentifiers -lc
