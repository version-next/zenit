#!/usr/bin/env bash
# Mutation-test the aggregate RC validator: only a complete, clean, same-revision
# all-PASS matrix with intact artifacts may qualify.
set -euo pipefail

TEST_DIR="$(mktemp -d /tmp/zenit-release-candidate.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
REVISION="0123456789abcdef0123456789abcdef01234567"
GATES=(
  release-truth renderer-boundary capability-matrix test-headless
  package-consumer allocation-campaign performance-regression test-metal
  storybook-e2e soak-4h macos-current macos-previous display-transition
  menu-acceptance voiceover-acceptance finder-drag distribution-clean-install
)

zig_build() {
  local args=(build)
  if [[ -n "${ZENIT_ZIG_LIB_DIR:-}" ]]; then
    args+=(--zig-lib-dir "$ZENIT_ZIG_LIB_DIR")
  fi
  "${ZIG_BIN:-${ZIG:-zig}}" "${args[@]}" "$@"
}

for gate in "${GATES[@]}"; do
  evidence_dir="$TEST_DIR/$gate"
  mkdir -p "$evidence_dir"
  printf 'supervised fixture for %s\n' "$gate" >"$evidence_dir/gate.log"
  bash scripts/write_evidence_manifest.sh \
    "$evidence_dir/manifest.json" "$gate" PASS 0 "fixture $gate" \
    "$evidence_dir" none >/dev/null
  sed -i.bak -E \
    "s/\"revision\": \"[0-9a-f]+\"/\"revision\": \"$REVISION\"/; s/\"dirty\": (true|false)/\"dirty\": false/" \
    "$evidence_dir/manifest.json"
  rm "$evidence_dir/manifest.json.bak"
done

sed -i.bak 's/"macos_version": "[^"]*"/"macos_version": "26.0"/' \
  "$TEST_DIR/macos-current/manifest.json"
rm "$TEST_DIR/macos-current/manifest.json.bak"
sed -i.bak 's/"macos_version": "[^"]*"/"macos_version": "15.0"/' \
  "$TEST_DIR/macos-previous/manifest.json"
rm "$TEST_DIR/macos-previous/manifest.json.bak"

zig_build release-candidate-validate -- "$TEST_DIR" "$REVISION"

cp "$TEST_DIR/test-metal/manifest.json" "$TEST_DIR/test-metal/manifest.saved"
sed -i.bak 's/"status": "PASS"/"status": "BLOCKED"/' "$TEST_DIR/test-metal/manifest.json"
rm "$TEST_DIR/test-metal/manifest.json.bak"
if zig_build release-candidate-validate -- "$TEST_DIR" "$REVISION" >/dev/null 2>&1; then
  echo "aggregate validator accepted BLOCKED as PASS" >&2
  exit 1
fi
mv "$TEST_DIR/test-metal/manifest.saved" "$TEST_DIR/test-metal/manifest.json"

if zig_build release-candidate-validate -- "$TEST_DIR" \
  fedcba9876543210fedcba9876543210fedcba98 >/dev/null 2>&1; then
  echo "aggregate validator accepted cross-revision evidence" >&2
  exit 1
fi

mv "$TEST_DIR/voiceover-acceptance/gate.log" "$TEST_DIR/voiceover-acceptance/gate.log.missing"
if zig_build release-candidate-validate -- "$TEST_DIR" "$REVISION" >/dev/null 2>&1; then
  echo "aggregate validator accepted missing physical evidence" >&2
  exit 1
fi

echo "release candidate contract mutation tests: PASS"
