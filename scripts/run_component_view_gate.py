#!/usr/bin/env python3
"""Fail-closed gate for LP3 component lifecycle regressions (not equivalence)."""
import re
import subprocess
import sys

CASES = (
    "service accounting rejects captured business signals",
    "generated template resources belong to the view",
    "nested single-root promotion supports both teardown orders",
    "separate owners close and recreate independently",
    "event-triggered reactive callback can destroy the instance twice",
    "failed renderer rolls back emitted nodes and view resources",
    "generated hooks and refs roll back at every allocation failure",
    "retained and hidden subtree keeps setup state and hooks",
    "portal cleanup releases view and instance once",
    "repeatable render preserves setup identity and live refs without growth",
    "external attrs effects events and root refs replay on the new root",
    "slots parts and typed result refs follow rebuilt insertion points",
    "promoted root rebuilds through its outer instance",
    "initialization callbacks can destroy or dispose without returning a dead root",
    "callback rebuild is refused and detach reentry cannot start another render",
    "detach destruction cancels rebuilding before using released setup",
    "failed rebuild clears the host root and requires explicit remount",
    "one shot node slot fails preflight without consuming the old view",
    "rebuilt parent retires nested external scopes before their records",
    "every rebuild allocation failure leaves no partial view or live ref",
    "portal ownership follows rebuilt roots and both final teardown orders",
    "retained detached rebuild preserves state and replays themed external style",
    "active and suspended overlay roots are refused before any teardown",
    "external setup decorators replay and initial destruction cancels render",
    "captures nested inside caller slots are one shot and never replayed",
    "slot children allocation failures retire scopes before stray nodes",
    "initial slotted components roll back every allocation failure",
    "window cache OOM retries keep root inventory unchanged",
    "deferred old node cleanup cannot return an orphan replacement",
    "lifetime ticket OOM leaves the old view intact",
    "node cleanup reentry is refused until all queues settle",
    "For leases follow rebuilt rows through reorder and removal",
    "native callback root bindings refuse migration before teardown",
    "root lease is cleared on consumed failure and outlives setup teardown",
    "native captured parts and imperative root snapshots reject inner refresh",
    "promoted root OOM clears all owner roots and leases",
    "promoted slotted native parts refuse inner migration",
    "native file upload caption and group pin retained button roots",
    "For remounts a failed refreshed row before keyed reuse",
    "For cannot reuse a root freed by deferred rebuild cancellation",
    "For reclaims scope-first retained roots before remounting",
    "legacy untracked For roots mount but refuse migration",
)


# check_orphan_tests.sh plants `ORPHAN-PROBE-HIT <path>` prints in the first test of each file.
# They can split a "name...OK" line; drop exactly those markers and nothing else.
ORPHAN_PROBE = re.compile(r"ORPHAN-PROBE-HIT [^\n]*\n")


def without_orphan_probes(output):
    return ORPHAN_PROBE.sub("", output)


def validate(returncode, output):
    if returncode != 0:
        raise ValueError(f"test process exited {returncode}")
    if re.search(r"leaked|segmentation fault|panic:|crash|timed?\s*out", output, re.I):
        raise ValueError("leak/crash/timeout diagnostic in test output")
    for case in CASES:
        # Only completed test lines count, not echoed names or success markers.
        # Zig writes synchronous diagnostics between the case prefix and OK.
        # Only the two expected OOM warnings in the allocation sweep may split
        # that line; a later test's OK cannot complete a missing/failed case.
        diagnostics = (r"(?:\[default\] \(warn\): ui\.view: style(?: layer)? update dropped \(out of memory\)\n)*"
                       if case == "every rebuild allocation failure leaves no partial view or live ref" else "")
        pattern = r"^\d+/\d+ [^\n]*test\.LP3 setup/view: " + re.escape(case) + r"\.\.\." + diagnostics + r"OK$"
        if len(re.findall(pattern, output, re.M)) != 1:
            raise ValueError(f"missing/duplicate completed case: {case}")
    if not re.search(r"^All \d+ tests passed\.$", output, re.M):
        raise ValueError("missing test-runner completion")


def main():
    if len(sys.argv) != 2:
        print("usage: run_component_view_gate.py TEST_BINARY", file=sys.stderr)
        return 64
    try:
        result = subprocess.run([sys.argv[1]], stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, timeout=120)
        sys.stdout.write(result.stdout)
        validate(result.returncode, without_orphan_probes(result.stdout))
    except (OSError, subprocess.TimeoutExpired, ValueError) as error:
        print(f"component view gate FAIL: {error}", file=sys.stderr)
        return 1
    print(f"component view gate PASS: {len(CASES)} required cases")
    return 0


if __name__ == "__main__":
    sys.exit(main())
