#!/usr/bin/env bash
# run_storybook_e2e.sh — build → launch(test-mode) → run TS → teardown
#
# The app and runner are supervised as one unit. If the app exits before the
# runner, the suite stops immediately with exit 86 instead of spending minutes
# turning one process failure into dozens of RPC timeouts.
set -uo pipefail

cd "$(dirname "$0")/.."

PORT="${ZENIT_E2E_PORT:-19816}"
case "$PORT" in
  ''|*[!0-9]*) echo "invalid ZENIT_E2E_PORT: $PORT" >&2; exit 64 ;;
esac
if (( PORT < 1 || PORT > 65535 )); then
  echo "invalid ZENIT_E2E_PORT: $PORT" >&2
  exit 64
fi

# Each run uses a new exclusive dir: concurrent runs / leaked instances must not answer each
# other's queries (a shared fixed dir makes queries hit another instance's tree, showing as
# wide "nav.X not found" false failures).
# An explicit ZENIT_E2E_FILE_RPC_DIR override is respected (uniqueness is the caller's
# responsibility; the server still has the owner.json single-master lock as fallback).
if [[ -n "${ZENIT_E2E_FILE_RPC_DIR:-}" ]]; then
  RPCDIR="$ZENIT_E2E_FILE_RPC_DIR"
  RPCDIR_AUTO=0
else
  RPCDIR="$(mktemp -d "/tmp/zenit_e2e_rpc.${PORT}.XXXXXX")" || { echo "mktemp failed" >&2; exit 71; }
  RPCDIR_AUTO=1
fi
APP="${ZENIT_E2E_APP:-zig-out/zenit Storybook.app/Contents/MacOS/storybook}"
BUN="${ZENIT_E2E_BUN:-bun}"
APP_LOG="${ZENIT_E2E_APP_LOG:-/tmp/zenit_storybook_app.log}"
EVIDENCE_DIR="${ZENIT_E2E_EVIDENCE_DIR:-/tmp/zenit_e2e_evidence}"
MANIFEST="${ZENIT_E2E_MANIFEST:-${EVIDENCE_DIR}/manifest.json}"
CRASH_REPORT_DIR="${ZENIT_CRASH_REPORT_DIR:-${HOME}/Library/Logs/DiagnosticReports}"

APP_PID=""
LAUNCHED_APP_PID=""
RUNNER_PID=""
GATE_STATUS="FAIL"
GATE_RC=1
FAILURE_KIND="not_started"

process_is_running() {
  local pid="$1"
  local running_pid
  # `kill -0` also succeeds for an unreaped zombie. Bash's job table reports
  # only running children, so it detects a crashed app without waiting for the
  # runner's first RPC timeout. It also works on the stock macOS Bash 3.2.
  while IFS= read -r running_pid; do
    if [[ "$running_pid" == "$pid" ]]; then return 0; fi
  done < <(jobs -pr)
  return 1
}

cleanup() {
  local pid
  for pid in "$RUNNER_PID" "$APP_PID"; do
    if [[ -n "$pid" ]] && process_is_running "$pid"; then
      kill "$pid" 2>/dev/null || true
    fi
  done
  for pid in "$RUNNER_PID" "$APP_PID"; do
    if [[ -n "$pid" ]]; then
      wait "$pid" 2>/dev/null || true
    fi
  done

  # The app quits gracefully on SIGTERM, so GPA's deinit leak report is in the
  # log. A passing suite that leaked is still a failing gate.
  local leak_gate_failed=0
  if [[ "$GATE_STATUS" == "PASS" && -f "$APP_LOG" ]] && grep -Eq 'error\((gpa|DebugAllocator)\):.*leaked' "$APP_LOG"; then
    echo "FAIL: GPA reported leaked allocations at app exit:" >&2
    grep -EA6 'error\((gpa|DebugAllocator)\):.*leaked' "$APP_LOG" | head -40 >&2
    GATE_STATUS="FAIL"
    GATE_RC=87
    FAILURE_KIND="gpa_leak_at_exit"
    leak_gate_failed=1
  fi

  mkdir -p "$EVIDENCE_DIR"
  if [[ -f "$APP_LOG" ]]; then
    cp "$APP_LOG" "$EVIDENCE_DIR/app.log"
    # The normalized evidence schema names gate.log as the required primary
    # log. Preserve the app-specific filename for humans while also satisfying
    # the machine-validated artifact contract.
    cp "$APP_LOG" "$EVIDENCE_DIR/gate.log"
  fi
  if [[ -d "$RPCDIR" ]]; then
    find "$RPCDIR" -maxdepth 1 -type f \( -name 'req-*.json' -o -name 'res-*.json' \) \
      -exec cp {} "$EVIDENCE_DIR/" \; 2>/dev/null || true
  fi
  if [[ -d "$CRASH_REPORT_DIR" && -n "$LAUNCHED_APP_PID" ]]; then
    # Only this run's app: parallel instances share the report directory, and a report
    # names its process ("pid" : N in an .ips body, "Process: storybook [N]" in a .crash file).
    local report
    while IFS= read -r report; do
      if grep -Eq "\"pid\" *: *${LAUNCHED_APP_PID}[^0-9]|\[${LAUNCHED_APP_PID}\]" "$report" 2>/dev/null; then
        cp "$report" "$EVIDENCE_DIR/" 2>/dev/null || true
      fi
    done < <(find "$CRASH_REPORT_DIR" -maxdepth 1 -type f \
      \( -name 'storybook*.ips' -o -name 'storybook*.crash' \) -mmin -15 2>/dev/null)
  fi
  if [[ "${RPCDIR_AUTO:-0}" == "1" && -d "$RPCDIR" ]]; then
    rm -rf "$RPCDIR"
  fi
  bash scripts/write_evidence_manifest.sh \
    "$MANIFEST" \
    "storybook-e2e" \
    "$GATE_STATUS" \
    "$GATE_RC" \
    "bash scripts/run_storybook_e2e.sh" \
    "$EVIDENCE_DIR" \
    "$FAILURE_KIND" || echo "warning: failed to write evidence manifest" >&2
  if (( leak_gate_failed )); then exit "$GATE_RC"; fi
}
trap cleanup EXIT INT TERM

if [[ "${ZENIT_E2E_SKIP_BUILD:-0}" != "1" ]]; then
  echo "==> build storybook (-Dtest-mode=true)"
  if ! zig build -Dtest-mode=true storybook; then
    GATE_RC=1
    FAILURE_KIND="build_failed"
    echo "build failed" >&2
    exit "$GATE_RC"
  fi
fi

if [[ ! -x "$APP" ]]; then
  GATE_RC=66
  FAILURE_KIND="app_not_executable"
  echo "storybook app is not executable: $APP" >&2
  exit "$GATE_RC"
fi
if ! command -v "$BUN" >/dev/null 2>&1; then
  GATE_RC=69
  FAILURE_KIND="runner_not_available"
  echo "e2e runner is not available: $BUN" >&2
  exit "$GATE_RC"
fi

if [[ "$RPCDIR_AUTO" == "1" ]]; then
  echo "==> RPC dir $RPCDIR (fresh per-run)"
else
  echo "==> reset RPC dir $RPCDIR"
  rm -rf "$RPCDIR"
  mkdir -p "$RPCDIR"
fi

echo "==> launch app"
mkdir -p "$(dirname "$APP_LOG")"
# Isolate real mouse: developer uses computer while running, system pointer
# events no longer override harness-injected input. Set
# ZENIT_E2E_ISOLATE_POINTER=0 when real mouse needed.
# The app clipboard lives on a private named pasteboard (native/macos/clipboard_pasteboard.h):
# parallel instances cannot read each other's copies and the run leaves the developer's
# clipboard alone. ZENIT_E2E_PASTEBOARD= (empty) uses the system pasteboard.
PASTEBOARD="${ZENIT_E2E_PASTEBOARD-zenit.e2e.$(basename "$RPCDIR")}"
ZENIT_E2E_PASTEBOARD="$PASTEBOARD" \
ZENIT_E2E_ISOLATE_POINTER="${ZENIT_E2E_ISOLATE_POINTER:-1}" ZENIT_E2E_FILE_RPC_DIR="$RPCDIR" "$APP" >"$APP_LOG" 2>&1 &
APP_PID=$!
LAUNCHED_APP_PID=$APP_PID
echo "    app pid=$APP_PID  log=$APP_LOG"

TEST_FILE="${ZENIT_E2E_TEST_FILE:-e2e/storybook.test.ts}"
echo "==> run e2e ($BUN $TEST_FILE)"
# The runner learns the pasteboard name so a test can prove the system clipboard stayed untouched.
ZENIT_E2E_PASTEBOARD="$PASTEBOARD" ZENIT_E2E_FILE_RPC_DIR="$RPCDIR" "$BUN" "$TEST_FILE" &
RUNNER_PID=$!

while true; do
  if ! process_is_running "$APP_PID"; then
    wait "$APP_PID" 2>/dev/null
    APP_RC=$?
    if process_is_running "$RUNNER_PID"; then
      kill "$RUNNER_PID" 2>/dev/null || true
    fi
    wait "$RUNNER_PID" 2>/dev/null || true
    RUNNER_PID=""
    APP_PID=""
    GATE_RC=86
    FAILURE_KIND="app_process_exited_${APP_RC}"
    echo "storybook app exited before the e2e runner (app rc=$APP_RC)" >&2
    echo "app log tail:" >&2
    tail -20 "$APP_LOG" >&2 || true
    exit "$GATE_RC"
  fi

  if ! process_is_running "$RUNNER_PID"; then
    wait "$RUNNER_PID"
    GATE_RC=$?
    RUNNER_PID=""
    if (( GATE_RC == 0 )); then
      GATE_STATUS="PASS"
      FAILURE_KIND="none"
    else
      FAILURE_KIND="test_assertion_or_timeout"
    fi
    break
  fi
  sleep 0.1
done

echo "==> done (rc=$GATE_RC). app log tail:"
tail -20 "$APP_LOG" || true
exit "$GATE_RC"
