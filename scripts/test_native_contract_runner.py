#!/usr/bin/env python3
"""Negative controls must reject failures even after a success marker."""
import pathlib
import subprocess
import sys

runner = pathlib.Path(__file__).with_name('run_native_contract.py')
cases = {
    'missing': "print('other case passed')",
    'exit': "print('PASS required'); raise SystemExit(1)",
    'crash': "import os,signal; print('PASS required',flush=True); os.kill(os.getpid(),signal.SIGTERM)",
    'timeout': "import time; print('PASS required',flush=True); time.sleep(10)",
    'leak': "print('PASS required'); print('error(gpa): memory address 0x1234 leaked')",
}
for name, source in cases.items():
    result = subprocess.run([sys.executable, str(runner), '--timeout', '0.2', '--expect',
                             'PASS required', '--', sys.executable, '-c', source], capture_output=True, text=True)
    if result.returncode != 1:
        raise SystemExit(f'negative control {name} accepted failure: {result.stdout} {result.stderr}')
result = subprocess.run([sys.executable, str(runner), '--expect', 'PASS required', '--',
                         sys.executable, '-c', "print('PASS required')"], capture_output=True, text=True)
if result.returncode:
    raise SystemExit(f'positive control failed: {result.stdout} {result.stderr}')
print('PASS native controller rejects missing cases, errors, crashes, timeouts and allocator leaks')
