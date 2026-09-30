#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

FRAMES="${1:-36}"
echo "==> build console probe"
ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-/tmp/zenit-console-zig-cache}" zig build console-probe || exit 1

echo "==> run console probe (${FRAMES} ticks)"
LOG=$(ZENIT_SMOKE_FRAMES="$FRAMES" "./zig-out/Console Probe.app/Contents/MacOS/console_probe" 2>&1)
RC=$?
if [ "$RC" -ne 0 ]; then
  echo "$LOG" | tail -80
  exit "$RC"
fi
echo "$LOG" | grep -q "history + worker + idle-poll + filter + clear: ok" || { echo "$LOG"; echo "FAIL: missing console-chain marker"; exit 1; }
echo "$LOG" | grep -q "smoke ok" || { echo "$LOG"; echo "FAIL: missing smoke marker"; exit 1; }
echo "$LOG" | grep -E "console_probe.*(ok|smoke)"
echo "PASS: Console DevTools real-window smoke"
