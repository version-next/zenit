#!/usr/bin/env python3
"""Sequential release erasure and before/after mount measurements, no GPU.

The baseline archive lives inside this worktree's cache. No branch/worktree mutation.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
from release_mount_budget import measure
ROOT=Path(__file__).resolve().parents[1]

def main():
    p=argparse.ArgumentParser();p.add_argument('--zig',default='zig');p.add_argument('--evidence',type=Path,required=True)
    p.add_argument('--baseline',default='76491d80');args=p.parse_args();args.evidence.mkdir(parents=True,exist_ok=True)
    evidence=args.evidence.resolve();report={'baseline':args.baseline,'commands':[]}
    def run(argv,cwd,label):
        with (evidence/(label+'.log')).open('w') as log:r=subprocess.run(argv,cwd=cwd,stdout=log,stderr=subprocess.STDOUT,timeout=300)
        report['commands'].append(dict(command=argv,cwd=str(cwd),exit_code=r.returncode))
        if r.returncode:raise RuntimeError(label+' failed; see '+str(evidence/(label+'.log')))
    try:
        report['harness_sha256'] = hashlib.sha256((ROOT / 'tools/lp2_mount_bench.zig').read_bytes()).hexdigest()
        run([args.zig,'build','hello-button-exe','-Doptimize=safe','-Ddev-preview=false'],ROOT,'release-build')
        run(['python3','scripts/check_style_reload_erasure.py','zig-out/bin/hello_button','--output',str(evidence/'symbols.json')],ROOT,'symbols')
        baseline=ROOT/'.zig-cache/lp2-mount-baseline'
        if baseline.exists():shutil.rmtree(baseline)
        baseline.mkdir(parents=True)
        archive=evidence/'baseline.tar'
        with archive.open('wb') as out:subprocess.run(['git','archive','--format=tar',args.baseline],cwd=ROOT,stdout=out,check=True)
        with tarfile.open(archive) as tar:tar.extractall(baseline,filter='data')
        archive.unlink()
        shutil.copy2(ROOT/'tools/lp2_mount_bench.zig',baseline/'tools/lp2_mount_bench.zig')
        current=(ROOT/'build.zig').read_text();start=current.index('        const style_mount_bench_root =');end=current.index('        const yix_counter_module =',start)
        b=baseline/'build.zig';old=b.read_text();needle='        const yix_counter_module =';i=old.index(needle);b.write_text(old[:i]+current[start:end]+old[i:])
        binaries = {}
        for name,checkout in [('before',baseline),('after',ROOT)]:
            run([args.zig,'build','style-mount-bench','-Doptimize=fast','-j1'],checkout,name+'-build')
            binary=evidence/('fast-'+name)
            shutil.copy2(checkout/'zig-out/bin/lp2-mount-bench',binary)
            binaries[name]=binary
        report['mount']=measure(binaries,ROOT,evidence,'fast',workload=('nodes_per_mount',1001))
        report['before']=report['mount']['aggregate']['before']
        report['after']=report['mount']['aggregate']['after']
        report['p50_change_percent']=report['mount']['changes_percent']['p50_ns']
        report['p95_change_percent']=report['mount']['changes_percent']['p95_ns']
        report['passed']=report['mount']['passed']
    except BaseException as exc:report.update(passed=False,error=f'{type(exc).__name__}: {exc}')
    (evidence/'result.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
    return 0 if report['passed'] else 1
if __name__=='__main__':raise SystemExit(main())
