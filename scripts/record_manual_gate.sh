#!/usr/bin/env bash
# Record a supervised/physical gate using the same fail-closed manifest as CI.
set -euo pipefail

if (( $# < 4 )); then
  echo "usage: $0 EVIDENCE_DIR GATE PASS|FAIL|BLOCKED NOTES_FILE [ARTIFACT ...]" >&2
  exit 64
fi

EVIDENCE_DIR="$1"
GATE="$2"
STATUS="$3"
NOTES_FILE="$4"
shift 4

case "$STATUS" in
  PASS) EXIT_CODE=0; FAILURE_KIND=none ;;
  FAIL) EXIT_CODE=1; FAILURE_KIND=manual_acceptance_failed ;;
  BLOCKED) EXIT_CODE=2; FAILURE_KIND=manual_acceptance_blocked ;;
  *) echo "manual gate status must be PASS, FAIL, or BLOCKED" >&2; exit 64 ;;
esac
test -s "$NOTES_FILE" || { echo "non-empty operator notes are required" >&2; exit 64; }

mkdir -p "$EVIDENCE_DIR"
cp "$NOTES_FILE" "$EVIDENCE_DIR/gate.log"
for artifact in "$@"; do
  test -e "$artifact" || { echo "artifact does not exist: $artifact" >&2; exit 66; }
  cp -R "$artifact" "$EVIDENCE_DIR/"
done

COMMAND_TEXT="supervised manual gate: $GATE"
bash scripts/write_evidence_manifest.sh \
  "$EVIDENCE_DIR/manifest.json" "$GATE" "$STATUS" "$EXIT_CODE" \
  "$COMMAND_TEXT" "$EVIDENCE_DIR" "$FAILURE_KIND"

if [[ "$STATUS" != PASS ]]; then exit "$EXIT_CODE"; fi
