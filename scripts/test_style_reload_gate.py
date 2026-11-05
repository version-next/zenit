#!/usr/bin/env python3
import unittest
from run_style_reload_gate import REQUIRED, assess
class Controller(unittest.TestCase):
    def setUp(self):
        self.good='\n'.join(name+'...OK' for name in REQUIRED)+'\nLP2 differential files=32, supported=159, frozen_checks=79, evaluations=121892, box_projections=156, text_hovers=2\nAll 73 tests passed.\n'
    def test_complete_evidence(self):self.assertTrue(assess(0,self.good))
    def test_marker_before_crash_or_timeout_is_failure(self):
        for code in (-11,-9,1,124):self.assertFalse(assess(code,self.good))
    def test_missing_case(self):
        for name in REQUIRED:self.assertFalse(assess(0,self.good.replace(name+'...OK','')))
    def test_leak_and_panic_after_success(self):
        for marker in ('error: memory address 0x123 leaked','[gpa] (err): memory leak','panic: bad','FAIL'):
            self.assertFalse(assess(0,self.good+marker))
    def test_missing_oracle_counts_and_short_success(self):
        for old, new in [('box_projections=156', 'box_projections=0'),
                         ('text_hovers=2', 'text_hovers=0'), ('supported=159', 'supported=158'),
                         ('All 73 tests', 'All 1 tests')]:
            self.assertFalse(assess(0, self.good.replace(old, new)))
    def test_mutation_kill_requires_a_behavioral_assertion(self):
        from test_style_reload_mutation import detected
        good = '4/73 style_reload_tests.test.case...FAIL (TestExpectedEqual)'
        self.assertTrue(detected(1, good))
        self.assertTrue(detected(1, '4/73 case...expected error, found value\nFAIL (TestExpectedError)'))
        for code, text in [(0, good), (-11, good), (1, 'error: 1 compilation errors'),
                           (1, good + '\nerror: 1 compilation errors'), (1, good + '\npanic: bad'),
                           (1, good + '\nerror: memory address 0x123 leaked'), (1, 'timeout')]:
            self.assertFalse(detected(code, text))
    def test_native_case_sets_fail_closed(self):
        from test_preview import acceptance_exit
        for required in ('abcde', 'fghij'):
            report = dict(source_restored=True, cases={k: dict(status='PASS') for k in required})
            self.assertEqual(0, acceptance_exit(report, required))
            for missing in required:
                incomplete = dict(report, cases={k:v for k,v in report['cases'].items() if k != missing})
                self.assertEqual(1, acceptance_exit(incomplete, required))
            for failure in ('FAIL', 'TIMEOUT', 'CRASH'):
                report['cases'][required[0]] = dict(status=failure)
                self.assertEqual(1, acceptance_exit(report, required))
    def test_native_exit_logs_reject_leaks_after_success(self):
        import tempfile
        from pathlib import Path
        from test_preview import assert_clean_app_logs
        with tempfile.TemporaryDirectory() as directory:
            session = Path(directory)
            log = session / 'generation-1/app.log'
            log.parent.mkdir()
            log.write_text('all cases passed\n')
            assert_clean_app_logs(session)
            for marker in ('error: memory address 0x123 leaked', '[gpa] (err): memory leak', 'panic: bad'):
                log.write_text('all cases passed\n' + marker)
                with self.assertRaises(AssertionError): assert_clean_app_logs(session)
if __name__=='__main__':unittest.main()
