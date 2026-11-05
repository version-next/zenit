#!/usr/bin/env python3
"""Run the orphan probe with bounded lifetime and fail closed on diagnostics."""
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys


def clean_exit(code, output):
    return code == 0 and re.search(
        r'panic:|memory address .* leaked|\[gpa\].*leak|error:.*leak',
        output, re.I,
    ) is None


def run(log_path, command, timeout):
    child = None
    try:
        # A previous focused probe can have the identical test binary. Zig may
        # reuse its Run result without replaying the probe's stderr; only a fresh
        # local cache proves this invocation actually executed every test root.
        cache = log_path.parent / 'cache'
        cache.mkdir()
        with log_path.open('w') as log:
            child = subprocess.Popen(shlex.split(command) + ['--summary', 'none', '--cache-dir', str(cache)],
                                     stdout=log, stderr=subprocess.STDOUT,
                                     start_new_session=True)
            try:
                code = child.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                log.write('\nORPHAN probe timed out\n')
                return 1
        return 0 if clean_exit(code, log_path.read_text(errors='replace')) else 1
    except OSError as exc:
        with log_path.open('a') as log:
            log.write(f'\nORPHAN probe failed: {exc}\n')
        return 1
    finally:
        if child is not None and child.poll() is None:
            os.killpg(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()


if __name__ == '__main__':
    def interrupted(signum, _):
        raise KeyboardInterrupt(f'signal {signum}')

    signal.signal(signal.SIGTERM, interrupted)
    raise SystemExit(run(Path(sys.argv[1]), sys.argv[2], float(sys.argv[3])))
