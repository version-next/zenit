#!/usr/bin/env python3
"""Release erasure and paired 100-Yix-Checkbox mount check against LP3a main."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
from release_mount_budget import measure
ROOT = Path(__file__).resolve().parents[1]
def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zig', default='zig'); parser.add_argument('--baseline', default='511bb858')
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args(); args.evidence.mkdir(parents=True, exist_ok=True)
    evidence = args.evidence.resolve(); report = dict(commands=[], baseline=args.baseline, passed=False)
    def run(argv, cwd, label):
        with (evidence/(label+'.log')).open('w') as log:
            result = subprocess.run(argv, cwd=cwd, stdout=log, stderr=subprocess.STDOUT, timeout=900)
        report['commands'].append(dict(command=argv, cwd=str(cwd), exit_code=result.returncode))
        if result.returncode: raise RuntimeError(label+' failed')
    try:
        report['harness_sha256'] = hashlib.sha256((ROOT / 'tools/lp3_mount_bench.zig').read_bytes()).hexdigest()
        run([args.zig, 'build', 'template-probe-exe', '-Doptimize=safe', '-Ddev-preview=false', '-j1'], ROOT, 'release-build')
        run(['python3', 'scripts/check_template_reload_erasure.py', 'zig-out/bin/template_probe', '--output', str(evidence/'symbols.json')], ROOT, 'symbols')
        baseline = ROOT/'.zig-cache/lp4-release-baseline'
        if baseline.exists(): shutil.rmtree(baseline)
        baseline.mkdir(parents=True); archive = evidence/'baseline.tar'
        with archive.open('wb') as out: subprocess.run(['git', 'archive', '--format=tar', args.baseline], cwd=ROOT, stdout=out, check=True)
        with tarfile.open(archive) as tar: tar.extractall(baseline, filter='data')
        archive.unlink(); report['mount'] = {}
        shutil.copy2(ROOT/'tools/lp3_mount_bench.zig', baseline/'tools/lp3_mount_bench.zig')
        for optimize in ('fast', 'safe'):
            bins = {}
            for mode, checkout in (('before', baseline), ('after', ROOT)):
                run([args.zig, 'build', 'component-mount-bench', '-Doptimize='+optimize, '-j1'], checkout, optimize+'-'+mode+'-build')
                binary = evidence/(optimize+'-'+mode); shutil.copy2(checkout/'zig-out/bin/lp3-mount-bench', binary); bins[mode] = binary
            report['mount'][optimize] = measure(bins, ROOT, evidence, optimize)
        report['passed'] = all(value['passed'] for value in report['mount'].values())
    except BaseException as exc: report['error'] = f'{type(exc).__name__}: {exc}'
    (evidence/'result.json').write_text(json.dumps(report, indent=2)+'\n'); print(json.dumps(report, indent=2))
    return 0 if report['passed'] else 1
if __name__ == '__main__': raise SystemExit(main())
