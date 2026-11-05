#!/usr/bin/env python3
"""Controller sensitivity: completion does not excuse missing state/evidence."""
import contextlib
import io
import json
import shlex
import subprocess
import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch
from run_template_equivalence_gate import (run, validate, compare, projections, trees, finals, validate_goldens,
    candidate_matrix, golden_document, PROJECTIONS, PROFILES, STAGES, LIFE_STAGES, LIFECYCLE_CASE, MARKER)
from gen_template_manifest import discover

CASES = [LIFECYCLE_CASE, 'fixture:B']
VALUES = ' '.join(str(i+1) for i in range(len(PROJECTIONS)))
TREE = json.dumps([dict(tag='box', children=0, component=None, test_id=None, text=None, focusable=False)])

def passing():
    lines=[]
    for case in CASES:
        for profile in PROFILES:
            lines += [f'LP3_PROJ {case} {profile} {stage} {VALUES}' for stage in STAGES]
            lines += [f'LP3_TREE {case} {profile} {TREE}', f'LP3_FINAL {case} {profile} a']
            if case == LIFECYCLE_CASE:
                lines += [f'LP3_LIFEPROJ {case} {profile} {stage} {VALUES}' for stage in LIFE_STAGES]
                lines += [f'LP3_LIFE {case} {profile} {mode} OK' for mode in ('release_tree','comptime_template','runtime_template')]
        lines.append(f'LP3_EQ {case} {MARKER} OK')
    return '\n'.join(lines) + '\nAll 1 tests passed.\n'
GOOD=passing()

class ControllerTests(unittest.TestCase):
    def test_complete(self):
        validate(0, GOOD, CASES)
        compare(GOOD, GOOD, CASES)

    def test_missing_duplicate_unknown_and_malformed_records(self):
        lines=GOOD.splitlines()
        for prefix in ('LP3_PROJ','LP3_LIFEPROJ','LP3_TREE','LP3_FINAL','LP3_LIFE','LP3_EQ'):
            target=next(line for line in lines if line.startswith(prefix+' '))
            for output in (GOOD.replace(target+'\n','',1), GOOD+target+'\n', GOOD.replace(target,target.replace(CASES[0],'unknown'),1)):
                with self.subTest(prefix=prefix,output=output),self.assertRaises(ValueError):
                    validate(0,output,CASES)
        for output in (GOOD.replace('All 1 tests passed.',''), GOOD.replace('StyleDecl ', '',1),GOOD+'LP3_PROJ malformed\n', GOOD+'LP3_PROJ\n', GOOD+'LP3_UNKNOWN all passed\n'):
            with self.assertRaises(ValueError): validate(0,output,CASES)

    def test_diagnostics_and_abnormal_exit_after_completion(self):
        for code,suffix in ((1,''),(-11,''),(0,'memory leaked'),(0,'panic: done'),(0,'timed out')):
            with self.subTest(code=code,suffix=suffix),self.assertRaises(ValueError): validate(code,GOOD+suffix,CASES)

    def test_real_exit_and_timeout_after_flushed_success(self):
        with tempfile.TemporaryDirectory() as temp:
            binary=Path(temp)/'fixture'
            for tail in ('exit 9','exec /bin/sleep 30'):
                binary.write_text("#!/bin/sh\nprintf '%s' "+shlex.quote(GOOD)+'\n'+tail+'\n')
                binary.chmod(0o700)
                exception=ValueError if tail=='exit 9' else subprocess.TimeoutExpired
                with self.subTest(tail=tail),contextlib.redirect_stdout(io.StringIO()):
                    with self.assertRaises(exception) as caught: run(binary,CASES,timeout=10 if tail=='exit 9' else 5)
                    if exception is subprocess.TimeoutExpired:
                        output=caught.exception.stdout
                        if isinstance(output,bytes): output=output.decode()
                        self.assertIn(GOOD,output)

    def test_missing_twin_is_a_manifest_failure(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            (root/'tests/yix').mkdir(parents=True)
            (root/'tests/yix/new.yix').write_text('pub fn New() View { return <box/>; }')
            with self.assertRaisesRegex(ValueError,'missing generated twin'): discover(root)

    def test_all_nine_cross_build_and_lifetime_projections_are_required(self):
        for prefix in ('LP3_PROJ','LP3_LIFEPROJ'):
            line=next(line for line in GOOD.splitlines() if line.startswith(prefix+' '))
            for index in range(len(PROJECTIONS)):
                changed=VALUES.split();changed[index]='f'
                with self.subTest(prefix=prefix,index=index),self.assertRaises(ValueError):
                    compare(GOOD,GOOD.replace(line,line.replace(VALUES,' '.join(changed)),1),CASES)
        with self.assertRaises(ValueError): compare(GOOD,GOOD.replace('LP3_FINAL '+CASES[0]+' 0 a','LP3_FINAL '+CASES[0]+' 0 b'),CASES)

    def test_golden_missing_drift_unknown_and_tree_shape_are_failures(self):
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/'trees.json'
            with self.assertRaises(OSError): validate_goldens(GOOD,CASES,path)
            for value in ({}, {'unknown':{}}, {**golden_document(GOOD,CASES), 'unexpected':{}}):
                path.write_text(json.dumps(value))
                with self.assertRaises(ValueError): validate_goldens(GOOD,CASES,path)
            path.write_text(json.dumps(golden_document(GOOD,CASES)))
            validate_goldens(GOOD,CASES,path)
            invalid = golden_document(GOOD, CASES)
            invalid[CASES[0]]['0'][0]['focusable'] = 0
            path.write_text(json.dumps(invalid))
            with self.assertRaises(ValueError): validate_goldens(GOOD, CASES, path)
            invalid = golden_document(GOOD, CASES)
            invalid[CASES[0]]['0'][0]['children'] = False
            path.write_text(json.dumps(invalid))
            with self.assertRaises(ValueError): validate_goldens(GOOD, CASES, path)
            path.write_text('{"duplicate": 1, "duplicate": 1}')
            with self.assertRaises(ValueError): validate_goldens(GOOD,CASES,path)
        for changed in ('[]', TREE.replace('"focusable": false', '"focusable": 0'), TREE.replace('"children": 0','"children": 1'), TREE[:-1]+','+TREE[1:]):
            with self.assertRaises(ValueError): trees(GOOD.replace(TREE,changed,1),CASES)

    def test_candidate_matrix_requires_every_case_and_real_commit(self):
        good = ''.join(f'LP4_MATRIX {case} cancel commit clean\n' for case in CASES)
        candidate_matrix(good, CASES)
        for bad in ('', good.splitlines()[0], good + good.splitlines()[0],
                    good.replace(CASES[0], 'unknown'), good.replace('cancel commit clean', 'rejected clean'),
                    good + 'LP4_MATRIX malformed\n'):
            with self.subTest(output=bad), self.assertRaises(ValueError):
                candidate_matrix(bad, CASES)

    def test_os_error_propagates(self):
        with patch('run_template_equivalence_gate.subprocess.run',side_effect=OSError('missing binary')):
            with self.assertRaises(OSError): run('missing',CASES)

if __name__=='__main__': unittest.main()
