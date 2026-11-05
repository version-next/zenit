#!/usr/bin/env python3
"""Require generation before the isolated LP3 cache adapter; restore its twin exactly."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
from test_component_view_mutation import inventory
ROOT = Path(__file__).resolve().parents[1]
MARKER = 'LP3 equivalence PASS:'

def assess(code, output, regenerated, unchanged):
    return code == 0 and regenerated and unchanged and output.count(MARKER) == 1 and not re.search(
        r'panic:|memory address .* leaked|\[gpa\].*leak|\[SafeAllocator\].*leak', output, re.I)

def complete(report):
    attempts = report.get('attempts', [])
    return (report.get('passed') is True and report.get('source_restored') is True and 'error' not in report and
        [a.get('attempt') for a in attempts] == [0, 1] and
        all(a.get('passed') is True and a.get('regenerated') is True and a.get('inputs_unchanged') is True and a.get('exit_code') == 0 for a in attempts))

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zig', default='zig'); parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args(); args.evidence.mkdir(parents=True, exist_ok=True)
    target = ROOT/'tests/yix/lsp/_fixture.yix.zig'
    original = target.read_bytes(); mode = stat.S_IMODE(target.stat().st_mode)
    frozen = inventory(ROOT, target); child = None; removed = False; previous = {}
    report = dict(passed=False, source_restored=False, attempts=[])
    def interrupted(signum, _): raise KeyboardInterrupt(f'signal {signum}')
    for name in ('SIGTERM', 'SIGHUP'):
        sig = getattr(signal, name); previous[sig] = signal.signal(sig, interrupted)
    try:
        argv = [args.zig, 'build', '-Dyix-gen=off', 'test-template-generation', '-Ddev-preview=true', '-j1']
        report['command'] = argv
        # Repeat after the adapter has a cache entry: the original defect could
        # succeed cold, then fail while checking cached input paths.
        for attempt in range(2):
            target.unlink(); removed = True
            log_path = args.evidence/f'generation-{attempt}.log'
            with log_path.open('w') as log:
                child = subprocess.Popen(argv, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                code = child.wait(timeout=900)
            output = log_path.read_text()
            regenerated = target.exists() and target.read_bytes() == original
            unchanged = inventory(ROOT, target) == frozen
            passed = assess(code, output, regenerated, unchanged)
            report['attempts'].append(dict(attempt=attempt, exit_code=code, regenerated=regenerated, inputs_unchanged=unchanged, passed=passed))
            if not passed: raise RuntimeError(f'generation attempt {attempt} failed')
        report['inputs_sha256'] = hashlib.sha256(json.dumps(frozen, sort_keys=True).encode()).hexdigest()
        report['passed'] = True
    except BaseException as exc:
        report['error'] = f'{type(exc).__name__}: {exc}'
    finally:
        if child is not None and child.poll() is None:
            os.killpg(child.pid, signal.SIGKILL); child.wait()
        if removed:
            if not target.exists(): target.write_bytes(original)
            if target.read_bytes() == original: target.chmod(mode)
            else: report['restore_error'] = 'unexpected/concurrent twin bytes preserved'
        report['source_restored'] = target.exists() and target.read_bytes() == original and stat.S_IMODE(target.stat().st_mode) == mode
        for sig, handler in previous.items(): signal.signal(sig, handler)
        (args.evidence/'result.json').write_text(json.dumps(report, indent=2)+'\n'); print(json.dumps(report))
    return 0 if complete(report) else 1
if __name__ == '__main__': raise SystemExit(main())
