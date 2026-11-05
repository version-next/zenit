#!/usr/bin/env python3
"""Run compiling behavioral mutants through the required LP2 gate, serially."""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess

ROOT = Path(__file__).resolve().parents[1]
# Each replacement must match exactly; a stale mutation is a failed experiment.
MUTANTS = (
    ('basis_keyword', 'src/ui/style_reload.zig',
     'out.flex_basis = @field(core.FlexBasis, name);',
     'out.flex_basis = core.FlexBasis.auto;'),
    ('box_property', 'src/ui/style_reload.zig', '    return out;\n}\npub fn evaluateConditional(',
     '    out.gap = null;\n    return out;\n}\npub fn evaluateConditional('),
    ('box_projection', 'src/ui/style_reload.zig',
     'if (!box_projection or !@hasField(core.TextStyle, text_name)) {',
     'if (!box_projection or @hasField(core.TextStyle, text_name)) {'),
    ('token_ambiguity', 'src/ui/style_reload.zig',
     'if (has_hyphen and exact != null and normalized != null) return error.InvalidValue;',
     'if (has_hyphen and exact != null and normalized != null) return exact.?;'),
    ('text_set_flags', 'src/ui/style_reload.zig',
     '@field(out, f.name ++ "_set") = true;', '@field(out, f.name ++ "_set") = false;'),
    ('diff_withdrawal', 'src/ui/view.zig',
     '(a != null or b != null) and !styleEql(a, b)', 'b != null and !styleEql(a, b)'),
    ('theme_subscription', 'src/ui/view.zig',
     'if (comptime specThemed(Spec)) try cx.themeSignal() else null;',
     'if (comptime false and specThemed(Spec)) try cx.themeSignal() else null;'),
)


def detected(code, data):
    # Crashes, timeouts, compilation errors, or a broken controller are not kills.
    return (code > 0 and re.search(r'(?:\.\.\.|^)FAIL \(Test\w+\)', data, re.M) is not None
            and re.search(r'compilation errors?|error:.*(?:undeclared|unused|expected type)', data) is None
            and re.search(r'panic:|test crashed|timed out|memory address .* leaked|\[gpa\].*leak', data, re.I) is None)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zig', default='zig')
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    args.evidence.mkdir(parents=True, exist_ok=True)
    originals = {ROOT / path: (ROOT / path).read_bytes() for _, path, _, _ in MUTANTS}
    report = dict(mutants=[], source_restored=False)
    child = None
    previous = {}

    def interrupted(signum, _):
        raise KeyboardInterrupt(f'signal {signum}')

    def run(name):
        nonlocal child
        path = args.evidence / (name + '.log')
        with path.open('w') as log:
            child = subprocess.Popen([args.zig, 'build', '-Ddev-preview=true', 'test-style-reload'],
                                     cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            code = child.wait(timeout=600)
        return code, path.read_text()

    for name in ('SIGTERM', 'SIGHUP'):
        if hasattr(signal, name):
            sig = getattr(signal, name)
            previous[sig] = signal.signal(sig, interrupted)
    try:
        code, _ = run('baseline')
        report['baseline_exit'] = code
        if code != 0:
            raise RuntimeError('unmutated required gate failed')
        for name, relative, needle, replacement in MUTANTS:
            path = ROOT / relative
            source = originals[path].decode()
            expected = 2 if name == 'text_set_flags' else 1
            if source.count(needle) != expected:
                raise RuntimeError(f'{name}: stale anchor')
            path.write_text(source.replace(needle, replacement))
            code, data = run(name)
            killed = detected(code, data)
            report['mutants'].append(dict(name=name, mutant_exit=code, detected=killed,
                failures=re.findall(r'\d+/\d+ (.*?)\.\.\.FAIL \((Test\w+)\)', data),
                assertion_errors=re.findall(r'FAIL \((Test\w+)\)', data)))
            print(json.dumps(report['mutants'][-1]), flush=True)
            path.write_bytes(originals[path])
        code, _ = run('restored')
        report['restored_gate_exit'] = code
    except BaseException as exc:
        report['error'] = f'{type(exc).__name__}: {exc}'
    finally:
        try:
            if child is not None and child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait()
        except BaseException as exc:
            report['cleanup_error'] = f'{type(exc).__name__}: {exc}'
        try:
            for path, data in originals.items():
                path.write_bytes(data)
            report['source_restored'] = all(p.read_bytes() == data for p, data in originals.items())
        finally:
            for sig, handler in previous.items():
                signal.signal(sig, handler)
            (args.evidence / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
            print(json.dumps(report), flush=True)
    return 0 if (report['source_restored'] and len(report['mutants']) == len(MUTANTS)
                 and all(m['detected'] for m in report['mutants'])
                 and report.get('restored_gate_exit') == 0 and 'error' not in report) else 1


if __name__ == '__main__':
    raise SystemExit(main())
