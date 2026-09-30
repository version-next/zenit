#!/usr/bin/env bash
# Build and verify Zenit with one icon provider without modifying the worktree.
#
# Usage:
#   bash scripts/switch_icon_set.sh lucide
#   bash scripts/switch_icon_set.sh untitled
#
# The name is retained for existing developer muscle memory. Selection now
# happens in Zig's module graph through -Dicon-set; no generated source or
# callsite is rewritten.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ZIG_BIN="${ZIG:-$(command -v zig || echo zig)}"

TARGET="${1:-}"
case "$TARGET" in
  lucide)
    SVG_DIR="src/ui/icons_oss"
    GENERATED="src/ui/icons_lucide_generated.zig"
    EMBED_PREFIX='@embedFile("icons_oss/'
    MIN_COUNT=2000
    ;;
  untitled)
    SVG_DIR="private/zenit-icons-untitled/icons"
    GENERATED="private/zenit-icons-untitled/icons_generated.zig"
    EMBED_PREFIX='@embedFile("icons/'
    MIN_COUNT=1000
    ;;
  *)
    echo "usage: $0 <lucide|untitled>" >&2
    exit 1
    ;;
esac

if [[ ! -d "$SVG_DIR" || ! -s "$GENERATED" ]]; then
  echo "icon provider '$TARGET' is not installed in this checkout" >&2
  echo "expected $SVG_DIR and $GENERATED" >&2
  exit 1
fi

svg_count=$(find "$SVG_DIR" -maxdepth 1 -name '*.svg' | wc -l | tr -d ' ')
if [[ "$svg_count" -lt "$MIN_COUNT" ]]; then
  echo "icon provider '$TARGET' looks incomplete: ${svg_count} SVGs" >&2
  exit 1
fi
if ! grep -q "$EMBED_PREFIX" "$GENERATED"; then
  echo "$GENERATED does not embed the expected $TARGET assets" >&2
  exit 1
fi

echo "==> Verify icon profile: $TARGET (${svg_count} SVGs)"
"$ZIG_BIN" build -Dicon-set="$TARGET" test-headless
echo "    test-headless: PASS"
"$ZIG_BIN" build -Dicon-set="$TARGET" storybook
echo "    storybook build: PASS"
bash scripts/check_zig_format.sh >/dev/null
echo "    format gate: PASS"
echo "==> $TARGET is active for this command only; the worktree was not changed"
