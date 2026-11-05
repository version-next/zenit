#!/usr/bin/env python3
"""Sequential release erasure scan and paired native mount comparison (no GPU)."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import shlex
import subprocess
import tarfile

from release_mount_budget import benchmark_value, measure

ROOT = Path(__file__).resolve().parents[1]
PATTERN = re.compile(r'node_tree\.[^\n]*(?:host|Host)|recording_host|renderer_host|host_generation|host_notifying|RecordingHost|renderer host (?:identity exhausted|callback reentry|already attached)')

def checked_process(argv, cwd, timeout=900, benchmark=False, on_result=None):
    result = subprocess.run(argv, cwd=cwd, capture_output=True, timeout=timeout)
    if on_result:
        on_result(result)
    if benchmark:
        benchmark_value(result)
    elif result.returncode:
        raise RuntimeError('command failed: ' + ' '.join(argv))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zig', default='zig')
    parser.add_argument('--baseline', default='1244a94a')
    parser.add_argument('--before-fast', type=Path, help='reuse a binary built with the current raw-sample harness')
    parser.add_argument('--evidence', required=True, type=Path)
    args = parser.parse_args()
    evidence = args.evidence.resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    report = dict(baseline=args.baseline, commands=[], passed=False)

    def run(argv, cwd, label, benchmark=False):
        def record(result):
            (evidence / (label + '.log')).write_bytes(('$ ' + shlex.join(argv) + '\n').encode() + result.stdout + result.stderr)
            report['commands'].append(dict(command=argv, exit_code=result.returncode))
        result = checked_process(argv, cwd, timeout=120 if benchmark else 900,
                                 benchmark=benchmark, on_result=record)
        return result.stdout

    try:
        report['harness_sha256'] = hashlib.sha256((ROOT / 'tools/lp3_mount_bench.zig').read_bytes()).hexdigest()
        report['baseline_commit'] = run(['git', 'rev-parse', args.baseline], ROOT, 'baseline-commit').decode().strip()
        report['zig_version'] = run([args.zig, 'version'], ROOT, 'zig-version').decode().strip()
        report['before_fast_reused'] = bool(args.before_fast)
        baseline = ROOT / '.zig-cache/web-release-baseline'
        if baseline.exists():
            shutil.rmtree(baseline)
        baseline.mkdir(parents=True)
        archive = evidence / 'baseline.tar'
        archive.write_bytes(run(['git', 'archive', '--format=tar', args.baseline], ROOT, 'archive'))
        with tarfile.open(archive) as tar:
            tar.extractall(baseline, filter='data')
        archive.unlink()
        shutil.copy2(ROOT / 'tools/lp3_mount_bench.zig', baseline / 'tools/lp3_mount_bench.zig')
        report['mount'] = {}
        report['symbols'] = {}
        for optimize in ('fast', 'safe'):
            bins = {}
            for mode, checkout in (('before', baseline), ('after', ROOT)):
                binary = evidence / (optimize + '-' + mode)
                if optimize == 'fast' and mode == 'before' and args.before_fast:
                    shutil.copy2(args.before_fast, binary)
                else:
                    run([args.zig, 'build', 'component-mount-bench', '-Doptimize=' + optimize,
                         '-Ddev-preview=false', '-j1', '--verbose', '--summary', 'all'], checkout, optimize + '-' + mode + '-build')
                    shutil.copy2(checkout / 'zig-out/bin/lp3-mount-bench', binary)
                bins[mode] = binary
            symbols = run(['nm', '-a', str(bins['after'])], ROOT, optimize + '-symbols').decode()
            # Symbol tables plus retained diagnostic strings. Only explicit seam
            # names are searched; ordinary native host entry points are unrelated.
            strings = run(['strings', '-a', str(bins['after'])], ROOT, optimize + '-strings').decode(errors='replace')
            if not symbols.strip():
                raise RuntimeError('symbol scan produced no evidence')
            matches = [line for line in (symbols + '\n' + strings).splitlines() if PATTERN.search(line)]
            report['symbols'][optimize] = dict(scanned=len(symbols.splitlines()), matches=matches)
            if matches:
                raise RuntimeError(optimize + ' retained renderer seam')
            report['mount'][optimize] = measure(bins, ROOT, evidence, optimize, pairs=9)
        report['passed'] = all(value['passed'] for value in report['mount'].values())
    except BaseException as exc:
        report['error'] = f'{type(exc).__name__}: {exc}'
    (evidence / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({k: v for k, v in report.items() if k != 'commands'}, indent=2))
    return 0 if report['passed'] else 1

if __name__ == '__main__':
    raise SystemExit(main())
