#!/usr/bin/env bash
# Regenerate capability truth and require the committed matrix to match exactly.
set -euo pipefail

cd "$(dirname "$0")/.."
GENERATED="$(mktemp /tmp/zenit-macos-capabilities.XXXXXX)"
cleanup() {
  rm -f "$GENERATED"
}
trap cleanup EXIT

ZIG_BUILD_ARGS=(build)
if [[ -n "${ZENIT_ZIG_LIB_DIR:-}" ]]; then
  ZIG_BUILD_ARGS+=(--zig-lib-dir "$ZENIT_ZIG_LIB_DIR")
fi
zig "${ZIG_BUILD_ARGS[@]}" capability-matrix >"$GENERATED"
if ! diff -u docs/internal/MACOS_CAPABILITY_MATRIX.md "$GENERATED"; then
  echo "macOS capability matrix is stale or contradicts backend CAPS" >&2
  exit 1
fi
echo "macOS capability matrix: PASS"
