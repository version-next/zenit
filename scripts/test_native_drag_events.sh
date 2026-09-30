#!/usr/bin/env bash
# Exercises native drag queues in process;
# no global keys, system input-source changes, or GUI window are needed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d -t zenit-input-pump)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun clang -fobjc-arc -Wno-deprecated-declarations \
  "$ROOT/native/macos/tests/drag_events_test.m" \
  -framework Cocoa -framework Metal -framework QuartzCore -framework CoreVideo \
  -framework UniformTypeIdentifiers -o "$TEST_DIR/drag-events-test"
for ((run = 0; run < ${ZENIT_INPUT_TEST_RUNS:-1}; run++)); do
  "$TEST_DIR/drag-events-test" "$@"
done

# Link the actual Zig Window wrapper to the same bridge for allocator-failure
# verification, rather than replacing the native read with a Zig mock.
xcrun clang -fobjc-arc -Wno-deprecated-declarations -DZENIT_DRAG_EVENTS_NO_MAIN \
  -c "$ROOT/native/macos/tests/drag_events_test.m" -o "$TEST_DIR/bridge.o"
"${ZIG_BIN:-zig}" test "$TEST_DIR/bridge.o" --dep platform --dep events \
  -Mroot="$ROOT/native/macos/tests/drag_events_test.zig" \
  -Mplatform="$ROOT/src/platform.zig" -Mevents="$ROOT/src/system_sdk/events.zig" \
  -framework Cocoa -framework Metal -framework QuartzCore -framework CoreVideo \
  -framework UniformTypeIdentifiers -lc
