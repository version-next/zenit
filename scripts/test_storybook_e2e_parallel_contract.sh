#!/usr/bin/env bash
# Contract test for the parallel e2e supervisor (e2e/parallel.ts), with a fake app and a
# fixture suite (e2e/fixtures/parallel_contract.test.ts) — no window server needed.
#  1. pass: every instance runs the preflight first and the final check last, every work test
#     runs exactly once, the serial lane starts only after every parallel instance exited, the
#     merged manifest validates.
#  2. one failing test fails the merged gate with exit 1 and names it.
#  3. a dead app in the instances turns into exit 86 promptly, as in the sequential gate.
#  4. one dead instance among failing ones still yields 86.
#  5. a seed shuffles deterministically: the same seed gives the same plans.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d /tmp/zenit-e2e-parallel-contract.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
cat >"$TEST_DIR/app" <<'APP'
#!/usr/bin/env bash
if [[ -n "${FIXTURE_CRASH_PORT:-}" && "$ZENIT_E2E_PORT" == "$FIXTURE_CRASH_PORT" ]]; then
  exit 3
fi
touch "$ZENIT_E2E_FILE_RPC_DIR/fixture-app-ready"
trap 'exit 0' TERM
while true; do sleep 0.1 & wait "$!"; done
APP
chmod +x "$TEST_DIR/app"

run_case() { # name expected_rc [env...]
  local name="$1" expected="$2"; shift 2
  local rc=0
  : >"$TEST_DIR/$name.trace"
  env ZENIT_E2E_SKIP_BUILD=1 ZENIT_E2E_APP="$TEST_DIR/app" \
    ZENIT_E2E_TEST_FILE=e2e/fixtures/parallel_contract.test.ts \
    ZENIT_E2E_OUT="$TEST_DIR/$name" ZENIT_E2E_DURATIONS="$TEST_DIR/durations.json" \
    ZENIT_CRASH_REPORT_DIR="$TEST_DIR/no-crash-reports" \
    FIXTURE_TRACE="$TEST_DIR/$name.trace" "$@" \
    bash scripts/run_storybook_e2e_parallel.sh >"$TEST_DIR/$name.log" 2>&1 || rc=$?
  if (( rc != expected )); then
    cat "$TEST_DIR/$name.log" >&2
    echo "$name: expected exit $expected, got $rc" >&2
    exit 1
  fi
}

START=$SECONDS
run_case pass 0 ZENIT_E2E_JOBS=3
bun -e '
const [traceFile, summaryFile] = process.argv.slice(1);
const lines = (await Bun.file(traceFile).text()).trim().split("\n").map((l) => {
  const [ms, pid, ...name] = l.split(" ");
  return { ms: Number(ms), pid, name: name.join(" ") };
});
const byPid = new Map();
for (const l of lines) byPid.set(l.pid, [...(byPid.get(l.pid) ?? []), l]);
const fail = (m) => { console.error("contract: " + m); process.exit(1); };
if (byPid.size !== 4) fail(`expected 3 shards + 1 serial lane, saw ${byPid.size} runner processes`);
for (const [pid, steps] of byPid) {
  if (steps[0].name !== "preflight") fail(`${pid} did not start with the preflight`);
  if (steps.at(-1).name !== "invariant") fail(`${pid} did not end with the final check`);
}
const work = lines.filter((l) => l.name.startsWith("work "));
if (work.length !== 12 || new Set(work.map((l) => l.name)).size !== 12) fail(`work tests ran ${work.length} times`);
const gate = lines.filter((l) => l.name === "timing gate");
if (gate.length !== 1) fail(`serial test ran ${gate.length} times`);
const serialPid = gate[0].pid;
const lastParallel = Math.max(...lines.filter((l) => l.pid !== serialPid).map((l) => l.ms));
const firstSerial = Math.min(...byPid.get(serialPid).map((l) => l.ms));
if (firstSerial <= lastParallel) fail("serial lane overlapped a parallel instance");
if (byPid.get(serialPid).some((l) => l.name.startsWith("work "))) fail("work test ran in the serial lane");
const s = await Bun.file(summaryFile).json();
if (s.failed !== 0 || s.not_run.length !== 0 || s.passed !== 12 + 1 + 4 * 2) fail(`merged counts: ${JSON.stringify(s)}`);
' "$TEST_DIR/pass.trace" "$TEST_DIR/pass/summary.json"
grep -q '"status": "PASS"' "$TEST_DIR/pass/manifest.json"
zig build evidence-validate -- "$TEST_DIR/pass/manifest.json" --require-artifacts
[[ -s "$TEST_DIR/durations.json" ]] || { echo "durations were not recorded" >&2; exit 1; }
echo "PASS: merged pass, placement, serial lane after parallel lanes"

run_case fail 1 ZENIT_E2E_JOBS=3 FIXTURE_FAIL="work 7"
grep -q '"status": "FAIL"' "$TEST_DIR/fail/manifest.json"
grep -q 'fixture failure: work 7' "$TEST_DIR/fail/summary.json"
echo "PASS: one failing test fails the merged gate"

run_case preflight 1 ZENIT_E2E_JOBS=2 FIXTURE_FAIL="preflight"
grep -q '"name": "work' "$TEST_DIR/preflight/summary.json" # listed as not run
if grep -q ' work ' "$TEST_DIR/preflight.trace"; then echo "work ran after a failed preflight" >&2; exit 1; fi
echo "PASS: a failed preflight aborts its instance and leaves its tests not run"

T0=$SECONDS
run_case dead 86 ZENIT_E2E_JOBS=3 ZENIT_E2E_APP=/usr/bin/false ZENIT_E2E_BUN="$TEST_DIR/app"
(( SECONDS - T0 < 10 )) || { echo "app death took $((SECONDS - T0))s" >&2; exit 1; }
grep -q 'app_process_exited_1' "$TEST_DIR/dead/manifest.json"
echo "PASS: dead app instances exit 86"

# One instance dies while the others fail an assertion: the dead app still decides the code.
run_case mixed 86 ZENIT_E2E_JOBS=3 FIXTURE_CRASH_PORT=19901 FIXTURE_FAIL="invariant"
grep -q 'shard-1:app_process_exited_3' "$TEST_DIR/mixed/manifest.json"
echo "PASS: one dead instance outranks assertion failures elsewhere"

run_case seed-a 0 ZENIT_E2E_JOBS=3 ZENIT_E2E_SHUFFLE_SEED=7
run_case seed-b 0 ZENIT_E2E_JOBS=3 ZENIT_E2E_SHUFFLE_SEED=7
run_case seed-c 0 ZENIT_E2E_JOBS=3 ZENIT_E2E_SHUFFLE_SEED=8
plans() { bun -e 'const s = await Bun.file(process.argv[1]).json(); console.log(JSON.stringify(s.shards.map((x) => x.tests)))' "$1"; }
[[ "$(plans "$TEST_DIR/seed-a/schedule.json")" == "$(plans "$TEST_DIR/seed-b/schedule.json")" ]] || { echo "same seed, different plans" >&2; exit 1; }
[[ "$(plans "$TEST_DIR/seed-a/schedule.json")" != "$(plans "$TEST_DIR/seed-c/schedule.json")" ]] || { echo "different seeds, same plans" >&2; exit 1; }
echo "PASS: shuffle seeds are deterministic"

echo "parallel e2e supervisor contract: 6/6 PASS ($((SECONDS - START))s)"
