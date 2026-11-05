#!/usr/bin/env bash
# Scan for 'orphan tests': file has test blocks but is never compiled into any test target.
#
# -- why needed --
# Orphan tests are the deadliest false green: assertions exist, CI is green, but they never
# execute. Seen before:
#   - src/test_harness/http_server.zig (module only referenced by app, never addTest)
#   - src/test_harness/command_executor.zig (linking fails when added, so not added)
#   - src/ui/core/layout/adapter.zig (zero pub, zero references, dead code)
#
# -- criteria --
# Static inference of what gets collected is unreliable (`const x = @import(...)` vs
# `_ = @import(...)` differ in test collection, and the module graph needs build.zig). So use an
# **actual test**: plant a **runtime** probe in the first test block of each file that prints
# only that file's path, no return, doesn't fail. Plant in all files, run `zig build test`
# once (zig build prints stderr for passed tests too):
#   - path printed => test was collected and ran => normal
#   - no print     => test never executed => orphan
#
# WARNING probe runs `${PROBE_CMD}` (default `zig build test`). Some tests **intentionally** run
#   in another step, are not orphans, and must be excluded else all are false positives:
#     - src/render/metal_integration_tests.zig -> `test-metal` (needs real Metal device)
#     - src/platform/unsupported/**           -> cross-compile target, not compiled on macOS
#     - src/system_sdk/backends/{linux,windows}.zig -> check-system-sdk-cross (compile only)
#   See EXCLUDE list below. When adding such files, sync it and document which step.
#
# WARNING probe **can't early return**: many files' first test is a summary
# `test { _ = @import("a.zig"); ... }` that pulls in child file tests; `if (true) return ...;` is
# a comptime-known return, code after it is unreachable, and the entire child tree's tests
# vanish from the binary (bulk plant gave 120 false orphans).
#
# WARNING probe must be runtime, **can't** use @compileError: it fires when a file is
# @imported, and 'imported' != 'test collected'. E.g. src/render/svg.zig is imported by
# render_test_module but no addTest has svg as root, so its 10 tests never ran.
#
# Cost: one build + one test run (minutes). Compile-error probes can't be batched.
# Each invocation has an isolated local cache: cached Run results can otherwise
# suppress stderr from an already-executed identical runtime probe.
#
# Usage:
#   bash scripts/check_orphan_tests.sh                 # full (slow)
#   bash scripts/check_orphan_tests.sh src/a.zig ...   # specify files
set -uo pipefail
cd "$(dirname "$0")/.."

# Clean residual probes before starting, trap can't block SIGKILL or parent shell being killed
# (measured pkill entire tree, trap doesn't get time), so truly reliable defense is
# **self-heal each start**, not just exit cleanup.
STALE="$(grep -rlE 'ORPHAN-PROBE-HIT|error\.OrphanProbe' src/ 2>/dev/null || true)"
if [[ -n "$STALE" ]]; then
    echo "发现上次遗留的探针，正在还原：" >&2
    echo "$STALE" | sed 's/^/  /' >&2
    # Probe always script-inserted single line, delete line direct (leave other uncommitted changes)
    echo "$STALE" | while read -r f; do
        [[ -n "$f" ]] && sed -i '' -E '/ORPHAN-PROBE-HIT|error\.OrphanProbe/d' "$f"
    done
fi

if [[ -n "$(git status --porcelain)" ]]; then
    echo "ERROR: 工作树不干净。本脚本会临时改源文件，必须在干净树上跑。" >&2
    exit 2
fi

# Test files intentionally hung on other build step (not orphans).
# Each must document which step it actually hangs on, else can't tell exempt vs escaped.
EXCLUDE_RE='^(src/render/(metal_integration_tests|glass_material_tests|sdf_gpu_bench|tab_lens_gpu_bench|packed_glyph_tests)\.zig|src/ui/(style_reload_manifest|style_reload_tests|template_reload_tests|wasm_smoke)\.zig|src/platform/unsupported/|src/system_sdk/backends/(linux|windows)\.zig|src/system_sdk/windows_test\.zig)'
#            ^ test-metal (needs real Metal device); glass_material_tests / sdf_gpu_bench /
#            tab_lens_gpu_bench / packed_glyph_tests (probe-verified on host 2026-10-18,
#            tab_lens_gpu_bench 2026-11-01) @imported
#            by metal_integration_tests.zig, same test-metal
#            ^ cross-compile target, not compiled on macOS
#            ^ system_sdk Linux / Windows backends: check-system-sdk-cross cross-compile (compile
#            only no run)
#            ^ src/system_sdk/windows_test.zig: test-windows-sdk-unit (Windows SDK mock event test
#            run on host)
# LP2 manifest/tests: test-style-reload (called by check_clean_tree_gates.sh).
# Runtime probes on 2026-10-18 hit both paths; all 74 assertions passed. Instrumented
# manifest/output intentionally fail generator/controller checks; uninstrumented
# gate must also pass. wasm_smoke: check-wasm, native contract/OOM test probe hit,
# followed by wasm smoke PASS. Full probe logs are linked in GATEDEBT_REPORT.md.
# LP4 template_reload_tests: test-template-reload (called by check_clean_tree_gates.sh);
# PROBE_CMD="zig build test-template-reload -j1" hit it on 2026-10-19.

PROBE_CMD="${PROBE_CMD:-zig build test}"

if [[ $# -gt 0 ]]; then
    FILES=("$@")
else
    # Git's ordinary '*' pathspec also matches slashes; '**/' here would miss
    # top-level src/*.zig (environment/time/reflection/SVG safety tests).
    mapfile -t FILES < <(git ls-files 'src/*.zig' | grep -v generated | xargs grep -l '^test ' 2>/dev/null)
fi

TMP="$(mktemp -d)"
LOG="$TMP/probe.log"

# On interrupt (Ctrl-C / kill) must restore all probes, else probe lines left in source.
# 2026-09-22 mixed probe line into unrelated commit because (used `git add -A`, scan was modifying
# source in background).
PROBED=()
restore_and_exit() {
    for f in "${PROBED[@]}"; do
        [[ -f "$TMP/bak/$f" ]] && cp "$TMP/bak/$f" "$f"
    done
    rm -rf "$TMP"
}
trap restore_and_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# WARNING source files in 'probe planted' intermediate state while script runs.
# Don't `git add -A` / `git commit -a` while it runs, else probes committed.

for f in "${FILES[@]}"; do
    grep -q '^test ' "$f" 2>/dev/null || continue
    if [[ "$f" =~ $EXCLUDE_RE ]]; then
        echo "skip (挂在其它 step): $f"
        continue
    fi
    mkdir -p "$TMP/bak/$(dirname "$f")"
    cp "$f" "$TMP/bak/$f"
    PROBED+=("$f")
done

if [[ ${#PROBED[@]} -eq 0 ]]; then
    echo "ERROR: no test files were probed; missing coverage cannot pass." >&2
    exit 1
fi

# Runtime probe, print only no return — see file head 'criteria' section. Path literal (@src().file
# is module-relative, wrong against repo)
python3 - "${PROBED[@]}" <<'PY'
import sys, re, pathlib
for name in sys.argv[1:]:
    p = pathlib.Path(name); s = p.read_text()
    m = re.search(r'^test .*\{$', s, re.M)
    if not m:
        continue
    probe = '\n    @import("std").debug.print("ORPHAN-PROBE-HIT %s\\n", .{});' % name
    p.write_text(s[:m.end()] + probe + s[m.end():])
PY

probe_status=0
# The probe builds and runs the whole suite in a fresh cache. Measured 2026-10-18 on an idle M-series
# host: 807 s, so 900 s left almost no headroom and concurrent builds tripped the timeout. Keep ~3x.
python3 scripts/run_orphan_probe.py "$LOG" "$PROBE_CMD" "${ORPHAN_TIMEOUT:-2400}" || probe_status=$?
# ORPHAN_LOG=path: keep full output of this test (debug criteria)
[[ -n "${ORPHAN_LOG:-}" ]] && cp "$LOG" "$ORPHAN_LOG"
if [[ "$probe_status" -ne 0 ]]; then
    echo "ERROR: probe command failed (exit/crash/timeout/leak); hits cannot make it pass." >&2
    tail -40 "$LOG" >&2
fi

orphans=()
for f in "${PROBED[@]}"; do
    grep -q "ORPHAN-PROBE-HIT $f\$" "$LOG" || { orphans+=("$f"); echo "ORPHAN: $f"; }
done

echo
echo "已检查 ${#PROBED[@]} 个含测试的文件，孤儿 ${#orphans[@]} 个。"
if [[ ${#orphans[@]} -gt 0 ]]; then
    echo "这些文件里的 test 从未被执行 —— 断言从未生效过。" >&2
    exit 1
fi
[[ "$probe_status" -eq 0 ]] || exit 1
