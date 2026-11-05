#!/usr/bin/env python3
"""Fail closed on missing LP2 cases, crashes, timeouts and allocator leaks."""
import re
import subprocess
import sys
REQUIRED=(
 'LP2 all repository YSS evaluation manifest',
 'LP2 flex basis keywords and numeric pixels share the compiled contract',
 'LP2 real Cx A B A deletion dynamic recipe text and subscriptions',
 'LP2 literal token swaps follow application setTheme after applied',
 'LP2 whole batch syntax shape and OOM preserve published generation',
 'LP2 shape needs_ext reflection stays aligned',
 'LP2 mutation oracle rejects a missing runtime property',
 'LP2 manual resolve and style generation outlives its first subscriber',
 'LP2 token adapter values modes shape diagnostics and allocation failure',
 'LP2 partial allocation failures preserve every published value',
 'LP2 duplicate border shorthand and capability change oracle',
 'LP2 exact token spelling and hyphen ambiguity',
 'LP2 shape lock all signatures transitions dependencies and thunks',
 'LP2 staged inline allocation stays independent of generation buffers',
 'LP2 theme callback unmount defers node and scope destruction',
 'LP2 malformed numeric syntax returns a located diagnostic',
 'LP2 lazy generation partial initialization OOM has no orphan signal',
 'LP2 reentrant theme hook supersedes the remaining outer replay',
 'LP2 theme signal reentry supersedes replay before the first root hook',
 'LP2 borrowed token pointers survive later commits and collection',
 'LP2 retained token versions survive reentry and window recreation',
 'LP2 preview CSS remains live inside recipe base variant compound and slot layers',
)
def assess(code, output):
    if code!=0:return False
    for name in REQUIRED:
        if name+'...OK' in output:continue
        if name==REQUIRED[0] and re.search(re.escape(name)+r'\.\.\.LP2 differential [^\n]+\nOK',output):continue
        if name=='LP2 borrowed token pointers survive later commits and collection' and re.search(re.escape(name)+r'\.\.\.LP2 token retention versions=2, bytes=\d+, first_bytes=\d+\nOK',output):continue
        if name in ('LP2 theme signal reentry supersedes replay before the first root hook', 'LP2 retained token versions survive reentry and window recreation') and re.search(re.escape(name)+r'\.\.\.(?:\[default\] \(warn\): \[reactive\] [^\n]+\n)+OK',output):continue
        return False
    passed = re.search(r'All (\d+) tests passed\.', output)
    if not passed or int(passed.group(1)) < len(REQUIRED):return False
    if 'LP2 differential files=32, supported=159, frozen_checks=79, evaluations=121892, box_projections=156, text_hovers=2' not in output:return False
    if re.search(r'\bFAIL\b|panic:|memory address .* leaked|\[gpa\].*leak|error:.*leak',output,re.I):return False
    return True

def main():
    try:
        run=subprocess.run([sys.argv[1]],capture_output=True,text=True,timeout=180)
        # check_orphan_tests.sh probe markers can split a "name...OK" line; drop only those.
        output=re.sub(r"ORPHAN-PROBE-HIT [^\n]*\n","",run.stdout+run.stderr)
        # A diagnostic printed inside a running test can separate its name and OK.
        sys.stdout.write(output)
        return 0 if assess(run.returncode,output) else 1
    except (OSError,subprocess.TimeoutExpired) as exc:
        print(f'LP2 gate failed: {exc}',file=sys.stderr);return 1
if __name__=='__main__':raise SystemExit(main())
