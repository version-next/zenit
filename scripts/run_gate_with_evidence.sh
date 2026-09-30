#!/usr/bin/env bash
# Run one gate, tee its log, and always emit a normalized evidence manifest.
set -uo pipefail

if (( $# < 3 )); then
  echo "usage: $0 EVIDENCE_DIR GATE COMMAND [ARG ...]" >&2
  exit 64
fi

EVIDENCE_DIR="$1"
GATE="$2"
shift 2
mkdir -p "$EVIDENCE_DIR"
LOG="$EVIDENCE_DIR/gate.log"
MANIFEST="$EVIDENCE_DIR/manifest.json"

COMMAND_TEXT=""
for arg in "$@"; do
  printf -v quoted '%q' "$arg"
  if [[ -n "$COMMAND_TEXT" ]]; then COMMAND_TEXT+=" "; fi
  COMMAND_TEXT+="$quoted"
done

START_SECONDS=$SECONDS
set +e
"$@" 2>&1 | tee "$LOG"
RC=${PIPESTATUS[0]}
set -e
DURATION_MS=$(((SECONDS - START_SECONDS) * 1000))
STATUS="FAIL"
FAILURE_KIND="command_failed"
if (( RC == 0 )); then
  STATUS="PASS"
  FAILURE_KIND="none"
fi

ZENIT_EVIDENCE_DURATION_MS="$DURATION_MS" \
bash scripts/write_evidence_manifest.sh \
  "$MANIFEST" "$GATE" "$STATUS" "$RC" "$COMMAND_TEXT" \
  "$EVIDENCE_DIR" "$FAILURE_KIND"

exit "$RC"
