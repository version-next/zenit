#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

MEDIA_DIR="$PWD/docs-site/public/media"
RAW_DIR="$(mktemp -d /tmp/zenit-docs-media.XXXXXX)"
ACTIVE_PID=""

mkdir -p "$MEDIA_DIR"

cleanup_process() {
  if [[ -n "$ACTIVE_PID" ]] && kill -0 "$ACTIVE_PID" 2>/dev/null; then
    kill "$ACTIVE_PID" 2>/dev/null || true
    wait "$ACTIVE_PID" 2>/dev/null || true
  fi
  ACTIVE_PID=""
}
trap cleanup_process EXIT INT TERM

run_capture() {
  local scenario="$1"
  local app="$2"
  local rpc_dir
  rpc_dir="$(mktemp -d "/tmp/zenit-docs-${scenario}.XXXXXX")"
  test -x "$app"

  ZENIT_E2E_FILE_RPC_DIR="$rpc_dir" "$app" >"$RAW_DIR/${scenario}.log" 2>&1 &
  ACTIVE_PID=$!
  ZENIT_E2E_FILE_RPC_DIR="$rpc_dir" ZENIT_DOCS_RAW_DIR="$RAW_DIR" \
    bun docs-site/e2e/capture-docs.ts "$scenario"
  cleanup_process
}

zig build -Dtest-mode=true console-probe devtools-probe storybook hello-button counter-reactive

run_capture console "$PWD/zig-out/Console Probe.app/Contents/MacOS/console_probe"
run_capture performance "$PWD/zig-out/DevTools Probe.app/Contents/MacOS/devtools_probe"
run_capture storybook "$PWD/zig-out/zenit Storybook.app/Contents/MacOS/storybook"
run_capture components "$PWD/zig-out/zenit Storybook.app/Contents/MacOS/storybook"
run_capture icons "$PWD/zig-out/zenit Storybook.app/Contents/MacOS/storybook"
run_capture hello "$PWD/zig-out/Hello Button.app/Contents/MacOS/hello_button"
run_capture reactive "$PWD/zig-out/Reactive Counter.app/Contents/MacOS/counter_reactive"

ffmpeg -hide_banner -loglevel error -y -i "$RAW_DIR/devtools-console.raw.mp4" \
  -vf "scale='min(1440,iw)':-2" -c:v libx264 -preset slow -crf 24 -movflags +faststart \
  -an "$MEDIA_DIR/devtools-console.mp4"
ffmpeg -hide_banner -loglevel error -y -i "$RAW_DIR/e2e-text-ime.raw.mp4" \
  -vf "scale='min(1440,iw)':-2" -c:v libx264 -preset slow -crf 24 -movflags +faststart \
  -an "$MEDIA_DIR/e2e-text-ime.mp4"

node docs-site/scripts/crop-recordings.mjs "$RAW_DIR/icon-crops.json"

ffmpeg -hide_banner -loglevel error -y -i "$RAW_DIR/hello-button.raw.mp4" \
  -vf "scale='min(1120,iw)':-2" -c:v libx264 -preset slow -crf 24 -movflags +faststart \
  -an "$MEDIA_DIR/hello-button.mp4"

ffmpeg -hide_banner -loglevel error -y -i "$RAW_DIR/reactive-counter.raw.mp4" \
  -vf "scale='min(1120,iw)':-2" -c:v libx264 -preset slow -crf 24 -movflags +faststart \
  -an "$MEDIA_DIR/reactive-counter.mp4"

node docs-site/scripts/crop-recordings.mjs "$RAW_DIR/component-crops.json"

echo "Docs media captured in $MEDIA_DIR"
echo "Raw capture and logs retained in $RAW_DIR"
