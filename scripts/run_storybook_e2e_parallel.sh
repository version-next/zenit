#!/usr/bin/env bash
# run_storybook_e2e_parallel.sh — one build, N background storybook instances, merged gate.
#
# Each instance is a full scripts/run_storybook_e2e.sh unit (own RPC dir, app log, evidence,
# manifest, session dir, app-death watchdog and leak gate). Tests tagged `serial` run after the
# parallel instances have exited. See e2e/parallel.ts for the scheduling and environment.
#
#   ZENIT_E2E_JOBS=6 bash scripts/run_storybook_e2e_parallel.sh
#   ZENIT_E2E_SHUFFLE_SEED=42 bash scripts/run_storybook_e2e_parallel.sh   # randomized order
#
# The sequential gate (bash scripts/run_storybook_e2e.sh) is unchanged.
set -uo pipefail

cd "$(dirname "$0")/.."

APP="${ZENIT_E2E_APP:-zig-out/zenit Storybook.app/Contents/MacOS/storybook}"
BUN="${ZENIT_E2E_BUN:-bun}"

if [[ "${ZENIT_E2E_SKIP_BUILD:-0}" != "1" ]]; then
  echo "==> build storybook (-Dtest-mode=true), shared by every instance"
  if ! zig build -Dtest-mode=true storybook; then
    echo "build failed" >&2
    exit 1
  fi
fi
if [[ ! -x "$APP" ]]; then
  echo "storybook app is not executable: $APP" >&2
  exit 66
fi
# The supervisor itself always needs a real bun; ZENIT_E2E_BUN is what each shard runs.
if ! command -v bun >/dev/null 2>&1 || ! command -v "$BUN" >/dev/null 2>&1; then
  echo "e2e runner is not available: $BUN" >&2
  exit 69
fi

exec bun e2e/parallel.ts
