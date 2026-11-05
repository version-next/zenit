#!/usr/bin/env bash
# Static fail-closed contract for the required GitHub Actions workflow.
set -euo pipefail

cd "$(dirname "$0")/.."
WORKFLOW=.github/workflows/ci.yml
test -s "$WORKFLOW"

require() {
  if ! rg -q "$1" "$WORKFLOW"; then
    echo "CI contract missing: $2" >&2
    exit 1
  fi
}

# v1 reverses the archive platform/architecture and cannot install modern releases.
if rg -q 'uses: mlugg/setup-zig@v1([[:space:]]|$)' "$WORKFLOW"; then
  echo "CI must use a release-aware Zig installer, not setup-zig v1" >&2
  exit 1
fi
require 'test "\$\(zig version\)" = "0\.17\.0"' 'installed compiler version smoke check'

require '^  push:$' 'push trigger'
require '^  pull_request:$' 'pull-request trigger'
require '^permissions:$' 'explicit least-privilege permissions'
require '^concurrency:$' 'workflow concurrency policy'
require 'cancel-in-progress:.*pull_request' 'main runs must not be auto-cancelled'
require '^  required:$' 'aggregate required job'
require 'needs: \[oss-boundary, storybook-e2e, windows-build\]' 'aggregate dependencies'
require '^    if: always\(\)$' 'aggregate must run after failed/skipped dependencies'
require 'test "\$CORE_RESULT" = success' 'core dependency fail-closed assertion'
require 'test "\$E2E_RESULT" = success' 'E2E dependency fail-closed assertion'
require 'test "\$WINDOWS_RESULT" = success' 'Windows build dependency fail-closed assertion'
require 'test -s src/bench/baselines/main\.json' 'benchmark baseline must exist'
require 'bun e2e/golden_compare\.ts --self-test' 'visual comparator contract test'
require 'bash scripts/test_bench_regression_contract\.sh' 'benchmark comparison contract test'
require 'python3 tools/generate_grapheme_data\.py --check' 'generated Unicode data must be reproducible'
require 'bash scripts/check_icon_architecture\.sh' 'icon provider architecture gate'
require 'zig build gen-icons-lucide' 'Lucide generated module reproducibility gate'
require 'zig build gen-component-index' 'component source index regeneration gate'
require 'git diff --exit-code -- src/ui/component_index_generated\.zig' 'component source index drift must fail CI'
require 'gen-icons-common' 'common Lucide icon reproducibility gate'
require 'bash scripts/check_version_contract\.sh' 'version/tag/package identity contract'
require 'zig build test-package-consumer' 'downstream package consumer gate'
require 'bash scripts/check_v04_deletions\.sh all' 'architecture migration invariant gate'
require 'bash scripts/check_template_builds\.sh' 'minimal-app template + README example gate'
# This contract itself must run in CI too — else anyone deletes any require-protected
# CI step above and nothing will catch it (guardrail not present isn't a guardrail).
require 'bash scripts/check_ci_contract\.sh' 'the CI contract itself must run in CI'
require 'bash scripts/test_oss_boundary_contract\.sh' 'boundary gate failure handling tests'
require 'zig build test-native' 'native macOS ObjC bridge tests (native/macos/tests)'
require 'ZENIT_E2E_TEST_FILE: "e2e/interaction-lifecycle\.test\.ts"' 'interaction lifecycle native E2E'

require 'python3 tools/window_lifetime_gate\.py --self-test' 'lifetime gate must reject incomplete, leaking and hung exits'
require 'zig build window-chrome -Doptimize=Debug' 'lifetime fixture must use DebugAllocator'
require 'python3 tools/window_lifetime_gate\.py \\' 'native window lifetime gate'
require 'ZENIT_E2E_TEST_FILE: "e2e/multi-window-screenshot\.test\.ts"' 'explicit multi-window screenshot E2E'

if rg -q "if:.*hashFiles\('src/bench/baselines/main.json'\)" "$WORKFLOW"; then
  echo "benchmark comparison may not silently skip when its baseline is missing" >&2
  exit 1
fi

echo "CI fail-closed contract: PASS"
