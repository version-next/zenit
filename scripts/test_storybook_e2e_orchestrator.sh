#!/usr/bin/env bash
# Mutation test: a dead app must abort the runner promptly and emit evidence.
set -uo pipefail

cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d /tmp/zenit-e2e-orchestrator.XXXXXX)"
FAKE_BUN="$TEST_DIR/fake-bun"

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# File-RPC health is the runner's in-suite liveness probe. Its protocol must
# reject a visible partial response and accept only an atomically published,
# schema-valid response before the process-supervision mutation below matters.
bun scripts/test_e2e_health_contract.ts

printf '#!/bin/sh\nexec sleep 30\n' >"$FAKE_BUN"
chmod +x "$FAKE_BUN"

START=$SECONDS
ZENIT_E2E_SKIP_BUILD=1 \
ZENIT_E2E_APP=/usr/bin/false \
ZENIT_E2E_BUN="$FAKE_BUN" \
ZENIT_E2E_EVIDENCE_DIR="$TEST_DIR/evidence" \
bash scripts/run_storybook_e2e.sh >/dev/null 2>"$TEST_DIR/stderr.log"
RC=$?
ELAPSED=$((SECONDS - START))

if (( RC != 86 )); then
  echo "expected app-death exit 86, got $RC" >&2
  exit 1
fi
if (( ELAPSED >= 5 )); then
  echo "app-death detection took ${ELAPSED}s; expected <5s" >&2
  exit 1
fi
if ! grep -q '"failure_kind": "app_process_exited_1"' "$TEST_DIR/evidence/manifest.json"; then
  echo "manifest does not record the app exit" >&2
  exit 1
fi
if [[ ! -f "$TEST_DIR/evidence/gate.log" ]]; then
  echo "manifest points at a missing primary gate log" >&2
  exit 1
fi
zig build evidence-validate -- "$TEST_DIR/evidence/manifest.json" --require-artifacts

echo "storybook e2e orchestrator + health fail-closed: PASS (${ELAPSED}s)"
