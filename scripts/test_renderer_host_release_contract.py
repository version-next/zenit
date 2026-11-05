#!/usr/bin/env python3
"""The release controller must reject misleading success output."""
import json
from pathlib import Path
import subprocess
import sys
import unittest
import check_renderer_host_release as gate

VALUE = dict(samples=51, warmups=5, checkboxes=100, allocator='DebugAllocator',
             renderer='none', p50_ns=100, p95_ns=120, samples_ns=[100]*48+[120]*3)

class Contract(unittest.TestCase):
    def result(self, value=VALUE, code=0, stderr=b''):
        return subprocess.CompletedProcess([], code, json.dumps(value).encode(), stderr)

    def test_all_host_guard_diagnostics_are_scanned(self):
        for message in ('renderer host identity exhausted',
                        'renderer host callback reentry', 'renderer host already attached'):
            self.assertIsNotNone(gate.PATTERN.search(message))
        self.assertIsNone(gate.PATTERN.search('native window host'))

    def test_valid(self):
        self.assertEqual(VALUE, gate.benchmark_value(self.result()))

    def test_missing_and_empty_cases(self):
        for value in ({}, {**VALUE, 'samples': 0}, {**VALUE, 'checkboxes': 0},
                      {**VALUE, 'p50_ns': 0}, {**VALUE, 'p95_ns': float('nan')}):
            with self.assertRaises((RuntimeError, ValueError)):
                gate.benchmark_value(self.result(value))

    def test_crash_after_success(self):
        with self.assertRaises(RuntimeError):
            gate.benchmark_value(self.result(code=-11))

    def test_leak_after_success(self):
        with self.assertRaises(RuntimeError):
            gate.benchmark_value(self.result(stderr=b'error(gpa): memory address leaked\n'))

    def test_timeout_after_success(self):
        program = 'import time; print(' + repr(json.dumps(VALUE)) + ', flush=True); time.sleep(3)'
        with self.assertRaises(subprocess.TimeoutExpired):
            gate.checked_process([sys.executable, '-c', program], Path.cwd(), timeout=0.1, benchmark=True)

if __name__ == '__main__':
    unittest.main()
