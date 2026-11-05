#!/usr/bin/env python3
"""Exercise the real shell gate, including probe insertion and source restoration."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class OrphanGate(unittest.TestCase):
    def check_gate(self, mode, expected):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'scripts').mkdir()
            (root / 'src').mkdir()
            for name in ('check_orphan_tests.sh', 'run_orphan_probe.py'):
                shutil.copy2(ROOT / 'scripts' / name, root / 'scripts' / name)
            source = root / 'src/probe.zig'
            original = 'test "required contract" {\n}\n'
            source.write_text(original)
            (root / 'fake.py').write_text('''import os, signal, sys, time
from pathlib import Path
mode = os.environ['FAKE_MODE']
assert 'ORPHAN-PROBE-HIT' in Path('src/probe.zig').read_text()
if mode == 'cache':
    cache = Path(sys.argv[sys.argv.index('--cache-dir')+1]) if '--cache-dir' in sys.argv else Path('.git/probe-cache')
    cache.mkdir(parents=True, exist_ok=True)
    marker = cache / 'ran'
    if marker.exists(): raise SystemExit(0)
    marker.touch()
if mode != 'missing': print('ORPHAN-PROBE-HIT src/probe.zig', flush=True)
if mode == 'crash': os.kill(os.getpid(), signal.SIGKILL)
if mode == 'timeout': time.sleep(30)
if mode == 'leak': print('error: memory address 0x123 leaked')
if mode == 'gpa': print('[gpa] (err): memory leak')
if mode == 'panic': print('panic: after success')
raise SystemExit(1 if mode == 'failure' else 0)
''')
            subprocess.run(['git', 'init', '-q', directory], check=True)
            subprocess.run(['git', 'add', 'scripts', 'src', 'fake.py'], cwd=root, check=True)
            subprocess.run(['git', '-c', 'user.name=Gate Test', '-c', 'user.email=gate@example.invalid',
                            '-c', 'commit.gpgsign=false', 'commit', '-qm', 'test fixture'], cwd=root, check=True)
            env = dict(os.environ, FAKE_MODE=mode,
                       PROBE_CMD='missing-orphan-command' if mode == 'launch' else 'python3 fake.py',
                       ORPHAN_TIMEOUT='1' if mode == 'timeout' else '10')
            targets = [] if mode == 'global' else ['src/missing.zig' if mode == 'empty' else 'src/probe.zig']
            for _ in range(2 if mode == 'cache' else 1):
                result = subprocess.run(['bash', 'scripts/check_orphan_tests.sh', *targets],
                                        cwd=root, env=env, capture_output=True, text=True, timeout=15)
                self.assertEqual(expected, result.returncode, result.stdout + result.stderr)
                self.assertEqual(original, source.read_text())
                self.assertEqual('', subprocess.check_output(['git', 'status', '--porcelain'], cwd=root, text=True))

    def test_hits_and_clean_exit(self):
        self.check_gate('success', 0)

    def test_missing_probe(self):
        self.check_gate('missing', 1)

    def test_top_level_sources_are_discovered(self):
        self.check_gate('global', 0)

    def test_empty_file_set(self):
        self.check_gate('empty', 1)

    def test_repeated_runs_execute_again(self):
        self.check_gate('cache', 0)

    def test_success_markers_cannot_hide_failures(self):
        for mode in ('failure', 'crash', 'timeout', 'leak', 'gpa', 'panic', 'launch'):
            with self.subTest(mode=mode):
                self.check_gate(mode, 1)


if __name__ == '__main__':
    unittest.main()
