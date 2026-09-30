#!/usr/bin/env bash
# Mutation tests for evidence schema and artifact completeness.
set -euo pipefail

cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d /tmp/zenit-evidence-contract.XXXXXX)"

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

zig_build() {
  local args=(build)
  if [[ -n "${ZENIT_ZIG_LIB_DIR:-}" ]]; then
    args+=(--zig-lib-dir "$ZENIT_ZIG_LIB_DIR")
  fi
  "${ZIG:-zig}" "${args[@]}" "$@"
}

bash scripts/run_gate_with_evidence.sh "$TEST_DIR/pass" evidence-pass /usr/bin/true
zig_build evidence-validate -- "$TEST_DIR/pass/manifest.json" --require-artifacts
REVISION="$(git rev-parse HEAD)"
zig_build evidence-validate -- "$TEST_DIR/pass/manifest.json" \
  --require-artifacts --expected-revision "$REVISION"

if zig_build evidence-validate -- "$TEST_DIR/pass/manifest.json" \
  --expected-revision 0123456789abcdef0123456789abcdef01234567 >/dev/null 2>&1; then
  echo "validator accepted evidence from another revision" >&2
  exit 1
fi

cp "$TEST_DIR/pass/manifest.json" "$TEST_DIR/invalid-status.json"
sed -i '' 's/"exit_code": 0/"exit_code": 9/' "$TEST_DIR/invalid-status.json"
if zig_build evidence-validate -- "$TEST_DIR/invalid-status.json" >/dev/null 2>&1; then
  echo "validator accepted PASS with non-zero exit code" >&2
  exit 1
fi

cp "$TEST_DIR/pass/manifest.json" "$TEST_DIR/missing-log.json"
sed -i '' "s#${TEST_DIR}/pass/gate.log#${TEST_DIR}/pass/missing.log#" "$TEST_DIR/missing-log.json"
if zig_build evidence-validate -- "$TEST_DIR/missing-log.json" --require-artifacts >/dev/null 2>&1; then
  echo "validator accepted a missing declared artifact" >&2
  exit 1
fi

cp "$TEST_DIR/pass/manifest.json" "$TEST_DIR/dirty.json"
sed -i '' 's/"dirty": false/"dirty": true/' "$TEST_DIR/dirty.json"
if zig_build evidence-validate -- "$TEST_DIR/dirty.json" --require-clean >/dev/null 2>&1; then
  echo "validator accepted dirty evidence when clean evidence was required" >&2
  exit 1
fi

set +e
bash scripts/run_gate_with_evidence.sh "$TEST_DIR/fail" evidence-fail /usr/bin/false
FAIL_RC=$?
set -e
if (( FAIL_RC == 0 )); then
  echo "failing gate was reported as success" >&2
  exit 1
fi
zig_build evidence-validate -- "$TEST_DIR/fail/manifest.json" --require-artifacts

mkdir -p "$TEST_DIR/audit/evidence-pass"
cp "$TEST_DIR/pass/manifest.json" "$TEST_DIR/audit/evidence-pass/manifest.json"
sed -i '' 's/"dirty": true/"dirty": false/' "$TEST_DIR/audit/evidence-pass/manifest.json"
mkdir -p "$TEST_DIR/audit/quoted-command"
printf 'quoted command fixture\n' >"$TEST_DIR/audit/quoted-command/gate.log"
bash scripts/write_evidence_manifest.sh \
  "$TEST_DIR/audit/quoted-command/manifest.json" quoted-command PASS 0 \
  'bash -lc value="quoted"' "$TEST_DIR/audit/quoted-command" none >/dev/null
sed -i '' 's/"dirty": true/"dirty": false/' "$TEST_DIR/audit/quoted-command/manifest.json"
bash scripts/record_release_audit.sh "$TEST_DIR/audit" "$REVISION" >/dev/null
test -s "$TEST_DIR/audit/RELEASE_AUDIT.md"
grep -q "$REVISION" "$TEST_DIR/audit/RELEASE_AUDIT.md"
grep -q 'quoted-command' "$TEST_DIR/audit/RELEASE_AUDIT.md"

if bash scripts/record_release_audit.sh "$TEST_DIR/audit" \
  0123456789abcdef0123456789abcdef01234567 >/dev/null 2>&1; then
  echo "release audit accepted a revision other than checked-out HEAD" >&2
  exit 1
fi

echo "evidence contract mutation tests: PASS"
