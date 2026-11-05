#!/usr/bin/env python3
"""LP4 required case controller: process status and complete runtime evidence."""
import re
import subprocess
import sys
REQUIRED = (
    "LP4 LP5 external Portal initial mount OOM releases partial host leases",
    "LP4 LP5 external Portal queued callbacks retain lease ownership on child destruction",
    "LP4 LP5 external Portal leases follow new roots across owners and A B A",
    "LP4 LP5 external Portal candidate OOM and cancellation preserve live leases",
    "LP4 LP5 external Portal active input and callback reentry reject safely",
    "LP4 LP5 branch set and new receiver L3 preserve both owners across repeated attempts",
    "LP4 LP5 branch set and new receiver classifier OOM never execute factories",
    "LP4 LP5 retained captures cannot borrow a retiring view ref",
    "LP4 LP5 retained captures reject borrowed view storage recursively",
    "LP4 LP5 stored nested controller rejects derived getters before evaluation",
    "LP4 LP5 relocation callback reentry and retained child destruction require remount",
    "LP4 LP5 scope migration preserves distinct allocator provenance",
    "LP4 LP5 imperative attachment replay rejects without shared writes",
    "LP4 LP5 selected nondefault branches retain selection and later switch correctly",
    "LP4 LP5 two children and owners match by complete hole identity",
    "LP4 LP5 ambiguous instances keys and slot shape reject before mutation",
    "LP4 LP5 moved child root replay keeps ref and lease on later child edits",
    "LP4 LP5 relocation and region OOM preserve all old ownership before commit",
    "LP4 LP5 default and named slot bodies update without rerunning setup",
    "LP4 LP5 active branch and keyed row structure retain controller and row state",
    "LP4 LP5 controller key and dormant region edits use L3 before publication",
    'LP4 supported text layout literals preserve setup across A B A',
    'LP4 classifier rejects hole changes and non-template code',
    'LP4 parse errors preserve exact tree state and generation',
    'LP4 whole batch rollback keeps both owners and generation unchanged',
    'LP4 safe point rejection and owner closure recreation',
    'LP4 candidate allocation failures retain old tree and setup',
    'LP4 static style references select compiled factories and scalar styles are bounded',
    'LP4 full hole multiset rejects every perturbed identity field',
    'LP4 candidate rejects custom formatting before user code can run',
    'LP4 unchanged component syntax stays stable after a sibling edit',
    'LP4 preparation allocation failures never publish or change setup',
    'LP4 embedded byte dependencies cannot silently change capture types',
    'LP4 derived captures are rejected before expression evaluation',
    'LP4 active press cannot notify external watchers during commit',
    'LP4 descendant overlay aliases reject before old nodes are freed',
    'LP4 portal aliases into descendants reject before publication',
    'LP4 module catalog includes unmounted box and text styles',
    'LP4 interpolation fragments and factory literals retain typed holes',
    'LP4 template generations plateau and stale preparations cannot publish',
    'LP4 unchanged views own literals after their template arena retires',
    'LP4 snapshots carry untouched modules across bounded generations',
    'LP4 style catalogs reject incompatible receivers without executing factories',
    'LP4 literal words do not create dynamic captures',
    'LP4 long interpolation retains the visible buffer on update OOM',
    'LP4 descendants and For Show Match remount while parent setup survives',
    'LP4 descendant candidate OOM has no lifecycle or ref residue',
    'LP4 unknown child setup is rejected before external code executes',
    'LP4 generated proofs check builder and mount function identity',
    'LP4 every descendant commit action failure requests L3 without rollback',
    'LP4 callback reentry and owner destruction request remount safely',
    'LP4 mount queue preserves normal child ref parent order and cancels scopes',
    'LP4 timers subscriptions global writes and registrations wait for commit',
    'LP4 portal candidate never attaches to the external overlay host',
    'LP4 every external effect failure crosses the publication boundary',
    'LP4 parent and child batch uses one descriptor snapshot',
    'LP4 candidate cannot create Cx services outside its scope',
    'LP4 window hook subscriptions are deferred and dispose cleanly',
    'LP4 discarded root never invokes user blur or detach callbacks',
    'LP4 candidate hook allocation failures leave no external registrations',
    'LP4 every exported widget builder checks candidate admission',
    'LP4 queued hooks tolerate target destruction before publication',
    'LP4 real external onMount failures require remount and clean resources',
    'LP4 LP5 child relocation preserves setup ref and attachments across A B A',
    'LP4 deferred ref and cleanup preserve ordinary disposal registration order',
    'LP4 owner scope aliases reject before candidate construction',
)
def assess(code, output):
    if code != 0 or re.search(r'\bFAIL\b|panic:|memory address .* leaked|\[gpa\].*leak|\[SafeAllocator\].*leak|error:.*leak', output, re.I):
        return False
    total = re.search(r'All (\d+) tests passed\.', output)
    if not total or int(total[1]) < len(REQUIRED):
        return False
    # These expected negative paths log diagnostics between the case name and OK.
    # Accept only known warnings; retain every other byte for fail-closed parsing.
    output = re.sub(r'\[default\] \(warn\): (?:\[reactive\.(?:Signal|Memo)\] graph.trackRead failed: error.OutOfMemory|\[preview\] L3 required after template commit: [A-Za-z0-9_]+)\n', '', output)
    return all(output.count(name + '...OK') == 1 for name in REQUIRED)
def main():
    try:
        run = subprocess.run([sys.argv[1]], capture_output=True, text=True, timeout=180)
        raw = run.stdout + run.stderr
        # Echo the raw output so check_orphan_tests.sh can see its probe markers;
        # validate without them, since they split a "name...OK" line.
        print(raw, end='')
        output = re.sub(r'ORPHAN-PROBE-HIT [^\n]*\n', '', raw)
        return 0 if assess(run.returncode, output) else 1
    except (OSError, subprocess.TimeoutExpired) as exc:
        print('LP4 gate failed: ' + str(exc), file=sys.stderr)
        return 1
if __name__ == '__main__':
    raise SystemExit(main())
