#!/usr/bin/env bash
set -euo pipefail

if (( $# != 3 )); then
  echo "usage: $0 MANIFEST BASELINE_DIR CURRENT_DIR" >&2
  exit 64
fi

cd "$(dirname "$0")/.."
exec bun e2e/golden_compare.ts "$1" "$2" "$3"
