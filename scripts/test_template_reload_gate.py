#!/usr/bin/env python3
import subprocess
import sys
import unittest
from run_template_reload_gate import REQUIRED, assess
class Controller(unittest.TestCase):
    def setUp(self): self.good = '\n'.join(name+'...OK' for name in REQUIRED)+f'\nAll {len(REQUIRED)} tests passed.\n'
    def test_complete(self): self.assertTrue(assess(0, self.good))
    def test_missing_duplicate_skipped_and_short_evidence(self):
        for name in REQUIRED:
            self.assertFalse(assess(0, self.good.replace(name+'...OK', '')))
            self.assertFalse(assess(0, self.good+name+'...OK'))
            self.assertFalse(assess(0, self.good.replace(name+'...OK', name+'...SKIP')))
        self.assertFalse(assess(0, self.good.replace(f'{len(REQUIRED)} tests', '1 tests')))
    def test_markers_before_failure_crash_timeout_or_leak(self):
        for code in (1, -11, -9, 124): self.assertFalse(assess(code, self.good))
        for marker in ('panic: bad', 'memory address 0x12 leaked', '[gpa] (err): leak', '[SafeAllocator] (err): leaked', 'FAIL'):
            self.assertFalse(assess(0, self.good+marker))
        run = subprocess.run([sys.executable, '-c', 'import sys; print(sys.argv[1], flush=True); sys.exit(9)', self.good], capture_output=True, text=True)
        self.assertFalse(assess(run.returncode, run.stdout))
        with self.assertRaises(subprocess.TimeoutExpired) as context:
            subprocess.run([sys.executable, '-c', 'import sys,time; print(sys.argv[1],flush=True); time.sleep(10)', self.good], capture_output=True, timeout=2)
        self.assertFalse(assess(124, context.exception.stdout.decode()))
    def test_native_cases_fail_closed(self):
        from test_preview import acceptance_exit
        report = dict(source_restored=True, cases={k:dict(status='PASS') for k in 'klmnopqrstuvwxyz'})
        self.assertEqual(0, acceptance_exit(report, 'klmnopqrstuvwxyz'))
        for key in 'klmnopqrstuvwxyz':
            copy = dict(report, cases={k:v for k,v in report['cases'].items() if k != key})
            self.assertEqual(1, acceptance_exit(copy, 'klmnopqrstuvwxyz'))
    def test_generation_requires_real_completion_and_exact_restoration(self):
        from test_template_reload_generation import assess as generation, complete
        good = 'LP3 equivalence PASS: complete\n'
        self.assertTrue(generation(0, good, True, True))
        attempts = [dict(attempt=i, passed=True, regenerated=True, inputs_unchanged=True, exit_code=0) for i in range(2)]
        report = dict(passed=True, source_restored=True, attempts=attempts)
        self.assertTrue(complete(report))
        self.assertFalse(complete(dict(report, attempts=attempts[:1])))
        self.assertFalse(complete(dict(report, attempts=[attempts[0], attempts[0]])))
        self.assertFalse(complete(dict(report, source_restored=False)))
        self.assertFalse(complete(dict(report, attempts=[dict(attempts[0], exit_code=9), attempts[1]])))
        for code in (1, -11, 124): self.assertFalse(generation(code, good, True, True))
        for regenerated, unchanged in ((False, True), (True, False)):
            self.assertFalse(generation(0, good, regenerated, unchanged))
        for text in ('', good+good, good+'panic: bad', good+'memory address 0x12 leaked'):
            self.assertFalse(generation(0, text, True, True))
        run = subprocess.run([sys.executable, '-c', 'import sys; print(sys.argv[1],flush=True); sys.exit(9)', good], capture_output=True, text=True)
        self.assertFalse(generation(run.returncode, run.stdout, True, True))
        with self.assertRaises(subprocess.TimeoutExpired) as context:
            subprocess.run([sys.executable, '-c', 'import sys,time; print(sys.argv[1],flush=True); time.sleep(10)', good], capture_output=True, timeout=.25)
        self.assertFalse(generation(124, context.exception.stdout.decode(), True, True))
if __name__ == '__main__': unittest.main()
