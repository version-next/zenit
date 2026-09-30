#!/usr/bin/env bash
# Ratchet the inherited formatting debt: allowlisted files may remain, but no
# new unformatted Zig file can enter the tree. Remove entries as files are fixed.
set -euo pipefail

cd "$(dirname "$0")/.."
ALLOWLIST="scripts/zig_fmt_allowlist.txt"
RAW="$(mktemp /tmp/zenit-zig-fmt-raw.XXXXXX)"
CURRENT="$(mktemp /tmp/zenit-zig-fmt-current.XXXXXX)"
NEW="$(mktemp /tmp/zenit-zig-fmt-new.XXXXXX)"

cleanup() {
  rm -f "$RAW" "$CURRENT" "$NEW"
}
trap cleanup EXIT

zig fmt --check build.zig src examples tools >"$RAW" 2>&1 || true
sort -u "$RAW" >"$CURRENT"
comm -13 "$ALLOWLIST" "$CURRENT" >"$NEW"

if [[ -s "$NEW" ]]; then
  echo "new unformatted Zig files (format them; do not extend the allowlist):" >&2
  cat "$NEW" >&2
  exit 1
fi

echo "zig fmt ratchet: PASS ($(wc -l <"$CURRENT" | tr -d ' ') inherited files; no growth)"
