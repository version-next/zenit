#!/usr/bin/env bash
# Requires a macOS GUI session. Deterministic: the window-server query is replaced, the cursor
# is never moved and no global events are posted. `--live` adds the real window-server check.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d -t zenit-pointer-presence)"
trap 'rm -rf "$TEST_DIR"' EXIT
APP_DIR="$TEST_DIR/PointerPresenceTest.app"
mkdir -p "$APP_DIR/Contents/MacOS"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.zenit.pointer-presence-test</string>
<key>CFBundleExecutable</key><string>pointer-presence-test</string>
<key>CFBundleName</key><string>Pointer Presence Test</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
xcrun clang -fobjc-arc -Wno-deprecated-declarations \
  "$ROOT/native/macos/tests/pointer_presence_test.m" \
  -framework Cocoa -framework IOSurface -framework Metal -framework QuartzCore -framework CoreVideo \
  -framework UniformTypeIdentifiers -o "$APP_DIR/Contents/MacOS/pointer-presence-test"
codesign --force --sign - "$APP_DIR" >/dev/null 2>&1
for ((run = 0; run < ${ZENIT_POINTER_TEST_RUNS:-1}; run++)); do
  "$APP_DIR/Contents/MacOS/pointer-presence-test" "$@"
done
