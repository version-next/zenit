#!/usr/bin/env bash
# Requires a macOS GUI session. Events stay inside the test's NSApplication;
# this gate never posts global keys or changes the user's input source.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d -t zenit-input-pump)"
trap 'rm -rf "$TEST_DIR"' EXIT
APP_DIR="$TEST_DIR/InputPumpTest.app"
mkdir -p "$APP_DIR/Contents/MacOS"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.zenit.input-pump-test</string>
<key>CFBundleExecutable</key><string>input-pump-test</string>
<key>CFBundleName</key><string>Input Pump Test</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
xcrun clang -fobjc-arc -Wno-deprecated-declarations \
  "$ROOT/native/macos/tests/input_pump_test.m" \
  -framework Cocoa -framework Metal -framework QuartzCore -framework CoreVideo \
  -framework UniformTypeIdentifiers -o "$APP_DIR/Contents/MacOS/input-pump-test"
codesign --force --sign - "$APP_DIR" >/dev/null 2>&1
for ((run = 0; run < ${ZENIT_INPUT_TEST_RUNS:-1}; run++)); do
  "$APP_DIR/Contents/MacOS/input-pump-test" "$@"
done
