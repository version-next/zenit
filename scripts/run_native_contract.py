#!/usr/bin/env python3
"""Fail-closed native test process: outcome, timeout, cases and leak diagnostics."""
import argparse
import os
import re
import signal
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--timeout', type=float, default=8)
    parser.add_argument('--expect', action='append', required=True)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command:
        parser.error('missing executable')
    child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             start_new_session=True, text=True)
    timed_out = False
    try:
        output, _ = child.communicate(timeout=args.timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        os.killpg(child.pid, signal.SIGKILL)
        output, _ = child.communicate()
    print(output, end='')
    missing = [case for case in args.expect if case not in output]
    leaks = re.search(r'error\((?:gpa|allocator)\)|memory address .* leaked|memory leak detected', output, re.I)
    if timed_out or child.returncode != 0 or missing or leaks:
        print(f'FAIL native contract: exit={child.returncode} timeout={timed_out} '
              f'missing={missing} allocator_leak={bool(leaks)}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
