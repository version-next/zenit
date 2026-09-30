#!/usr/bin/env bash
# Write the normalized machine-readable manifest used by release gates.
set -uo pipefail

if (( $# != 7 )); then
  echo "usage: $0 OUTPUT GATE STATUS EXIT_CODE COMMAND ARTIFACT_DIR FAILURE_KIND" >&2
  exit 64
fi

OUTPUT="$1"
GATE="$2"
STATUS="$3"
EXIT_CODE="$4"
COMMAND="$5"
ARTIFACT_DIR="$6"
FAILURE_KIND="$7"

case "$STATUS" in
  PASS|FAIL|BLOCKED|"NOT RUN"|"N/A") ;;
  *) echo "invalid evidence status: $STATUS" >&2; exit 64 ;;
esac
case "$EXIT_CODE" in
  ''|*[!0-9]*) echo "invalid exit code: $EXIT_CODE" >&2; exit 64 ;;
esac

json_escape() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

command_value() {
  "$@" 2>/dev/null || true
}

REVISION="$(command_value git rev-parse HEAD)"
DIRTY="false"
if [[ -n "$(command_value git status --porcelain)" ]]; then DIRTY="true"; fi
OS_VERSION="$(command_value sw_vers -productVersion)"
OS_BUILD="$(command_value sw_vers -buildVersion)"
ARCH="$(command_value uname -m)"
CPU="$(command_value sysctl -n machdep.cpu.brand_string)"
GPU="$(command_value system_profiler SPDisplaysDataType | awk -F': ' '/Chipset Model:|Chip:/{print $2; exit}')"
ZIG_VERSION="$(command_value zig version)"
BUN_VERSION="$(command_value bun --version)"
TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
DURATION_MS="${ZENIT_EVIDENCE_DURATION_MS:-0}"
TEST_SEED="${ZENIT_TEST_SEED:-}"
DISPLAY_SCALE="${ZENIT_DISPLAY_SCALE:-unknown}"
OUTPUT_DIR="$(dirname "$OUTPUT")"
mkdir -p "$OUTPUT_DIR"
TMP_OUTPUT="${OUTPUT}.tmp.$$"

{
  printf '{\n'
  printf '  "schema_version": 1,\n'
  printf '  "gate": "%s",\n' "$(json_escape "$GATE")"
  printf '  "status": "%s",\n' "$(json_escape "$STATUS")"
  printf '  "exit_code": %s,\n' "$EXIT_CODE"
  printf '  "duration_ms": %s,\n' "$DURATION_MS"
  printf '  "failure_kind": "%s",\n' "$(json_escape "$FAILURE_KIND")"
  printf '  "command": "%s",\n' "$(json_escape "$COMMAND")"
  printf '  "timestamp_utc": "%s",\n' "$(json_escape "$TIMESTAMP")"
  printf '  "repository": {"revision": "%s", "dirty": %s},\n' "$(json_escape "$REVISION")" "$DIRTY"
  printf '  "environment": {\n'
  printf '    "macos_version": "%s",\n' "$(json_escape "$OS_VERSION")"
  printf '    "macos_build": "%s",\n' "$(json_escape "$OS_BUILD")"
  printf '    "architecture": "%s",\n' "$(json_escape "$ARCH")"
  printf '    "cpu": "%s",\n' "$(json_escape "$CPU")"
  printf '    "gpu": "%s",\n' "$(json_escape "$GPU")"
  printf '    "display_scale": "%s",\n' "$(json_escape "$DISPLAY_SCALE")"
  printf '    "zig": "%s",\n' "$(json_escape "$ZIG_VERSION")"
  printf '    "bun": "%s"\n' "$(json_escape "$BUN_VERSION")"
  printf '  },\n'
  printf '  "test_seed": "%s",\n' "$(json_escape "$TEST_SEED")"
  printf '  "artifacts": {"directory": "%s", "log": "%s"}\n' \
    "$(json_escape "$ARTIFACT_DIR")" "$(json_escape "$ARTIFACT_DIR/gate.log")"
  printf '}\n'
} >"$TMP_OUTPUT"

mv "$TMP_OUTPUT" "$OUTPUT"
echo "$OUTPUT"
