#!/usr/bin/env python3
"""Serial probes of hole routing, paint and scroll relay retention; restore sources."""
import argparse
import hashlib
import json
import os
import signal
from pathlib import Path
import re
import subprocess
from test_component_view_mutation import is_compile_failure

ROOT = Path(__file__).resolve().parent.parent

def inventory(excluded):
    paths = [ROOT / 'build.zig', ROOT / 'build.zig.zon']
    for folder in ('src', 'tests', 'examples', 'scripts', 'tools'):
        paths.extend(p for p in (ROOT / folder).rglob('*') if p.suffix in ('.zig', '.yix', '.yss', '.py', '.json'))
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths if p.is_file() and p != excluded and not any(part in (".zig-cache", "zig-out", "node_modules", "__pycache__") for part in p.parts)}

def run(evidence, name):
    process = subprocess.Popen(['zig', 'build', 'test-template-equivalence', '-j1'], cwd=ROOT,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                               start_new_session=True)
    try:
        output, _ = process.communicate(timeout=600)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        output, _ = process.communicate()
        (evidence / (name + '.log')).write_text(output)
        raise RuntimeError(f'{name}: timed out; not counted as a detected mutation')
    (evidence / (name + '.log')).write_text(output)
    return process.returncode, output

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, default=ROOT / '.zig-cache/lp3a-round3-b-mutation')
    args = parser.parse_args()
    evidence = args.evidence.resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    results = {}
    code, _ = run(evidence, 'before')
    if code:
        raise RuntimeError('baseline gate failed')
    probes = [
        ('scroll_cell_retention', ROOT / 'src/ui/components/scroll_area/mod.zig',
         'return cc.ctx == null and cc.references == 0;',
         'return cc.ctx == null and cc.references == 0 and false;'),
        ('hole_route', ROOT / 'src/ui/template.zig',
         'const node = try factory.emit(@ptrCast(value), scope, cx, self.sink, op);',
         '''var routed = factory;
                if (cx.owner.template_builder == .runtime_template and op.kind == .emit) {
                    for (Schema(T).entries) |entry| if (entry.factory) |candidate| {
                        if (candidate.kind == .emit) { routed = candidate; break; }
                    };
                }
                const node = try routed.emit(@ptrCast(value), scope, cx, self.sink, op);'''),
        ('paint_projection', ROOT / 'src/ui/template_equivalence_tests.zig',
         'const snapshot = try env.snapshot();',
         '''const snapshot = poison: {
                const original = try env.snapshot();
                var poisoned = original;
                poisoned.paint ^= @as(u64, @intFromBool(pass == 2));
                break :poison poisoned;
            };'''),
    ]
    for name, source, old, new in probes:
        original = source.read_text()
        frozen = inventory(source)
        if original.count(old) != 1:
            raise RuntimeError(f'{name}: non-unique mutation anchor')
        mutated = original.replace(old, new)
        source.write_text(mutated)
        try:
            code, output = run(evidence, name)
        finally:
            if source.read_text() != mutated:
                raise RuntimeError('concurrent source edit; refusing to overwrite')
            source.write_text(original)
        if inventory(source) != frozen:
            raise RuntimeError('validation input drift; evidence invalid')
        if code == 0 or is_compile_failure(output):
            raise RuntimeError(f'{name}: not detected at runtime')
        if not re.search(r'LP3 differential mismatch|panic:|FAIL \(', output):
            raise RuntimeError(f'{name}: missing runtime failure evidence')
        results[name] = {'exit_code': code, 'runtime_failure_detected': True}
        print(f'{name}: detected at runtime (exit {code})', flush=True)
    code, _ = run(evidence, 'restored')
    if code:
        raise RuntimeError('restored gate failed')
    results['baseline_exit'] = 0
    results['restored_exit'] = 0
    (evidence / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    print(f'LP3 template probes: {len(probes)}/{len(probes)}, source restored')

if __name__ == '__main__':
    main()
