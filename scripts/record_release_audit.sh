#!/usr/bin/env bash
# Validate all available gate evidence against one exact clean revision and
# render a human-readable audit snapshot beside the immutable manifests.
set -euo pipefail

if (( $# < 1 || $# > 2 )); then
  echo "usage: $0 EVIDENCE_ROOT [REVISION]" >&2
  exit 64
fi

cd "$(dirname "$0")/.."
EVIDENCE_ROOT="$1"
REVISION="${2:-$(git rev-parse HEAD)}"
CURRENT_REVISION="$(git rev-parse HEAD)"
OUTPUT="$EVIDENCE_ROOT/RELEASE_AUDIT.md"

if [[ ! "$REVISION" =~ ^[0-9a-f]{40}$ && ! "$REVISION" =~ ^[0-9a-f]{64}$ ]]; then
  echo "revision must be a full commit hash: $REVISION" >&2
  exit 64
fi
if [[ "$REVISION" != "$CURRENT_REVISION" ]]; then
  echo "audit must target the checked-out HEAD ($CURRENT_REVISION), got $REVISION" >&2
  exit 65
fi

MANIFESTS=()
while IFS= read -r manifest; do
  MANIFESTS+=("$manifest")
done < <(find "$EVIDENCE_ROOT" -mindepth 2 -maxdepth 2 -name manifest.json -type f | LC_ALL=C sort)
if (( ${#MANIFESTS[@]} == 0 )); then
  echo "no evidence manifests found under $EVIDENCE_ROOT" >&2
  exit 66
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required to render release evidence" >&2
  exit 69
fi

TMP_OUTPUT="${OUTPUT}.tmp.$$"
trap 'rm -f "$TMP_OUTPUT"' EXIT
{
  printf '# Release evidence audit\n\n'
  printf -- '- Revision: `%s`\n' "$REVISION"
  printf -- '- Generated: `%s`\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf -- '- Contract: every row below is schema-valid, artifact-backed, clean, and belongs to this exact revision.\n\n'
  printf '| Gate | Status | Command | Manifest |\n'
  printf '|---|---|---|---|\n'
} >"$TMP_OUTPUT"

for manifest in "${MANIFESTS[@]}"; do
  zig build evidence-validate -- "$manifest" \
    --require-artifacts --require-clean --expected-revision "$REVISION"
  # Parse JSON as JSON. A sed capture silently dropped valid commands containing
  # escaped quotes (for example an env assignment in a compound gate), causing
  # a schema-valid manifest to fail only at the report-rendering layer.
  gate="$(jq -er '.gate | strings | select(length > 0)' "$manifest")"
  status="$(jq -er '.status | strings | select(length > 0)' "$manifest")"
  command="$(jq -er '.command | strings | select(length > 0)' "$manifest")"
  directory="$(basename "$(dirname "$manifest")")"
  if [[ -z "$gate" || -z "$status" || -z "$command" || "$gate" != "$directory" ]]; then
    echo "manifest directory/name mismatch or missing summary fields: $manifest" >&2
    exit 65
  fi
  command="${command//|/\\|}"
  printf '| `%s` | `%s` | `%s` | `%s` |\n' \
    "$gate" "$status" "$command" "$manifest" >>"$TMP_OUTPUT"
done

mv "$TMP_OUTPUT" "$OUTPUT"
trap - EXIT
echo "$OUTPUT"
