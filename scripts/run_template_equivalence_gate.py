#!/usr/bin/env python3
"""Fail-closed controller for template, interaction and lifetime differentials."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
GOLDENS = ROOT / 'tests/yix/template_equivalence_trees.json'
PROFILES = range(2)
STAGES = range(9)
LIFE_STAGES = range(7)
LIFECYCLE_CASE = 'tests/yix/equivalence_sequence.yix:Sequence'
PROJECTIONS = ('tree', 'StyleDecl', 'layout', 'a11y', 'paint', 'behavior', 'subscriptions', 'scopes', 'hooks')
MARKER = ' '.join(PROJECTIONS)

def required():
    rows = json.loads((ROOT / 'tests/yix/template_equivalence_manifest.json').read_text())
    cases = [row['source'] + ':' + name for row in rows for name in row['components']]
    if not cases or len(set(cases)) != len(cases) or LIFECYCLE_CASE not in cases:
        raise ValueError('empty/duplicate/incomplete manifest')
    return cases

def life_cases(cases):
    return [case for case in cases if case == LIFECYCLE_CASE]

# check_orphan_tests.sh plants `ORPHAN-PROBE-HIT <path>` prints in the first test of each file.
# They can split a "name...OK" line; drop exactly those markers and nothing else.
ORPHAN_PROBE = re.compile(r"ORPHAN-PROBE-HIT [^\n]*\n")


def without_orphan_probes(output):
    return ORPHAN_PROBE.sub("", output)


def validate(returncode, output, cases):
    if returncode:
        raise ValueError(f'equivalence process exited {returncode}')
    if re.search(r'leaked|segmentation fault|panic:|crash|timed?\s*out', output, re.I):
        raise ValueError('leak/crash/timeout diagnostic')
    prefixes = ('LP3_EQ', 'LP3_PROJ', 'LP3_LIFEPROJ', 'LP3_TREE', 'LP3_FINAL', 'LP3_LIFE')
    for line in output.splitlines():
        if line.startswith('LP3_') and not any(line.startswith(prefix + ' ') for prefix in prefixes):
            raise ValueError('unknown/malformed LP3 record')
    completed = [line.removeprefix('LP3_EQ ') for line in output.splitlines() if line.startswith('LP3_EQ ')]
    if sorted(completed) != sorted(case + ' ' + MARKER + ' OK' for case in cases):
        raise ValueError('missing/duplicate/unknown projection case')
    if not re.search(r'^All \d+ tests passed\.$', output, re.M):
        raise ValueError('missing runner completion')
    projections(output, cases)
    projections(output, cases, lifetime=True)
    trees(output, cases)
    finals(output, cases)
    life = [line.removeprefix('LP3_LIFE ') for line in output.splitlines() if line.startswith('LP3_LIFE ')]
    # Zig compares three builders internally. Each must finish its full lifecycle.
    expected = [f'{case} {profile} {mode} OK' for case in life_cases(cases) for profile in PROFILES for mode in ('release_tree', 'comptime_template', 'runtime_template')]
    if sorted(life) != sorted(expected):
        raise ValueError('missing/duplicate/unknown lifecycle completion')

def projections(output, cases, lifetime=False):
    prefix = 'LP3_LIFEPROJ' if lifetime else 'LP3_PROJ'
    active = life_cases(cases) if lifetime else cases
    stages = LIFE_STAGES if lifetime else STAGES
    records = {}
    for line in output.splitlines():
        if not line.startswith(prefix + ' '):
            continue
        parts = line.split()
        if len(parts) != 4 + len(PROJECTIONS) or not all(re.fullmatch('[0-9a-f]+', x) for x in parts[4:]):
            raise ValueError('malformed projection record')
        key = (parts[1], int(parts[2]), int(parts[3]))
        if key in records:
            raise ValueError(f'duplicate projection record: {key}')
        records[key] = parts[4:]
    if set(records) != {(case, profile, stage) for case in active for profile in PROFILES for stage in stages}:
        raise ValueError('missing/unknown input profile or interaction/lifetime stage')
    return records

def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate JSON field')
        result[key] = value
    return result

def trees(output, cases):
    records = {}
    for line in output.splitlines():
        if not line.startswith('LP3_TREE '):
            continue
        _, case, profile, data = line.split(' ', 3)
        key = (case, int(profile))
        if key in records:
            raise ValueError('duplicate golden tree')
        rows = json.loads(data, object_pairs_hook=unique_object)
        if not isinstance(rows, list) or not rows:
            raise ValueError('empty/non-tree golden')
        # Preorder child arity must consume exactly one connected root.
        pending = 1
        for row in rows:
            if set(row) != {'tag', 'children', 'component', 'test_id', 'text', 'focusable'} or pending == 0:
                raise ValueError('malformed/disconnected golden tree')
            if type(row['children']) is not int or row['children'] < 0:
                raise ValueError('invalid child arity')
            if type(row['tag']) is not str or not row['tag'] or type(row['focusable']) is not bool:
                raise ValueError('invalid tree field type')
            for field in ('component', 'test_id', 'text'):
                if row[field] is not None and type(row[field]) is not str:
                    raise ValueError('invalid optional tree field')
            pending += row['children'] - 1
        if pending:
            raise ValueError('truncated golden tree')
        records[key] = rows
    if set(records) != {(case, profile) for case in cases for profile in PROFILES}:
        raise ValueError('missing/unknown fixture golden tree')
    return records

def finals(output, cases):
    records = {}
    for line in output.splitlines():
        if not line.startswith('LP3_FINAL '):
            continue
        parts = line.split()
        if len(parts) != 4 or not re.fullmatch('[0-9a-f]+', parts[3]):
            raise ValueError('malformed final hook record')
        key = parts[1], int(parts[2])
        if key in records:
            raise ValueError('duplicate final hook record')
        records[key] = parts[3]
    if set(records) != {(case, profile) for case in cases for profile in PROFILES}:
        raise ValueError('missing/unknown final hook record')
    return records

def compare(reference, candidate, cases):
    for lifetime in (False, True):
        left, right = projections(reference, cases, lifetime), projections(candidate, cases, lifetime)
        for key, expected in left.items():
            for name, a, b in zip(PROJECTIONS, expected, right[key], strict=True):
                if a != b:
                    raise ValueError(f'release/preview differential {key} {name}: {a} != {b}')
    if trees(reference, cases) != trees(candidate, cases):
        raise ValueError('release/preview golden tree differential')
    if finals(reference, cases) != finals(candidate, cases):
        raise ValueError('release/preview final hook differential')

def golden_document(output, cases):
    return {case: {str(profile): tree for (key, profile), tree in trees(output, cases).items() if key == case} for case in sorted(cases)}

def validate_goldens(output, cases, path=GOLDENS):
    expected = json.loads(path.read_text(), object_pairs_hook=unique_object)
    # Python equality aliases False/0 and True/1. Canonical JSON preserves
    # schema types while remaining insensitive to object key ordering.
    if json.dumps(expected, sort_keys=True) != json.dumps(golden_document(output, cases), sort_keys=True):
        raise ValueError('fixture golden drift; review changes and explicitly regenerate baseline')

def run(binary, cases, timeout=180):
    process = subprocess.run([str(binary)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=timeout)
    sys.stdout.write(process.stdout)
    output = without_orphan_probes(process.stdout)
    validate(process.returncode, output, cases)
    return output

def candidate_matrix(output, cases):
    records = {}
    for line in output.splitlines():
        if not line.startswith('LP4_MATRIX'):
            continue
        parts = line.split()
        if len(parts) not in (4, 5) or parts[0] != 'LP4_MATRIX' or ' '.join(parts[2:]) not in ('rejected clean', 'cancel commit clean'):
            raise ValueError('malformed candidate matrix record')
        if parts[1] in records:
            raise ValueError('duplicate candidate matrix case')
        records[parts[1]] = ' '.join(parts[2:])
    if set(records) != set(cases):
        raise ValueError('missing/unknown candidate matrix case')
    if not any(result == 'cancel commit clean' for result in records.values()):
        raise ValueError('candidate matrix never reached commit')
    return records

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write-goldens', action='store_true')
    parser.add_argument('release')
    parser.add_argument('preview')
    args = parser.parse_args()
    try:
        subprocess.run([sys.executable, str(ROOT / 'scripts/gen_template_manifest.py')], check=True)
        cases = required()
        release = run(args.release, cases)
        preview = run(args.preview, cases)
        candidate_matrix(preview, cases)
        compare(release, preview, cases)
        if args.write_goldens:
            GOLDENS.write_text(json.dumps(golden_document(release, cases), indent=2, ensure_ascii=False) + '\n')
        validate_goldens(release, cases)
        validate_goldens(preview, cases)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f'LP3 equivalence FAIL: {error}', file=sys.stderr)
        if isinstance(error, subprocess.TimeoutExpired) and error.stdout:
            data = error.stdout
            print(data.decode(errors='replace') if isinstance(data, bytes) else data, file=sys.stderr)
        return 1
    print(f'LP3 equivalence PASS: {len(cases)} cases, 2 inputs, 9 stages, 9 cross-build projections + raw layers, A/B/A lifecycle, golden trees')
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
