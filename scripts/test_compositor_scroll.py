#!/usr/bin/env python3
"""Visual scroll gates must wait for paint, not merely RPC acknowledgement."""
import importlib.util
from pathlib import Path
import sys
import subprocess
import tempfile
import time
import types
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('sprite_contract', Path(__file__).with_name('check_compositor_sprites.py'))
sprites = importlib.util.module_from_spec(spec)
# These tests need neither macOS process counters nor image dependencies.
with patch.dict(sys.modules, {'measure_usage': types.SimpleNamespace(Rpc=None),
                            'PIL': types.SimpleNamespace(Image=None, ImageChops=None)}):
    spec.loader.exec_module(sprites)

class App:
    def __init__(self, path='cpu_frames', stalled=False):
        self.counts = {'cpu_frames': 0, 'gpu_frames': 0, 'unchanged_frames': 0}
        self.pending = 0
        self.path, self.stalled = path, stalled
    def rpc(self, method, path, body):
        if path == '/scroll':
            self.pending = 3  # acknowledged now; draw completes after polling
        return {'ok': True}
    def patches(self, enabled=None):
        if enabled is False:
            self.counts['gpu_frames'] += 1
            self.disabled = True
        self.counts['unchanged_frames'] += 1
        if self.pending and not self.stalled:
            self.pending -= 1
            if not self.pending:
                self.counts[self.path] += 1
        return dict(self.counts, rects=[] if getattr(self, 'disabled', False) else [[0, 0, 10, 10]], shown=0)
    def capture(self, path):
        return object()
    def close(self):
        pass

class ScrollPresentation(unittest.TestCase):
    def test_full_visual_scenario_does_not_coalesce_its_24_steps(self):
        app = App()
        results = []
        with patch.object(sprites, 'App', return_value=app), patch.object(sprites.time, 'sleep'), patch.object(sprites, 'region_diff', return_value={'pixels': 0, 'max': 0, 'cells': 1}):
            sprites.patch_scroll('fake-app', '/tmp', results, 'virtuallist', (400, 260))
        self.assertTrue(all(r['ok'] for r in results), results)
        self.assertEqual(results[0]['cpu_frames'], 24)

    def test_each_acknowledged_step_reaches_its_paint_before_the_next(self):
        for path in ('cpu_frames', 'gpu_frames'):
            with self.subTest(path=path):
                app = App(path)
                for _ in range(24):
                    sprites.presented_scroll_step(app, 400, 260, -37)
                self.assertEqual(app.counts[path], 24)
                self.assertEqual(app.pending, 0)

    def test_unchanged_markers_do_not_hide_missing_paint(self):
        now = [0.0]
        def sleep(delay):
            now[0] += delay
        with patch.object(sprites.time, 'monotonic', side_effect=lambda: now[0]), patch.object(sprites.time, 'sleep', side_effect=sleep):
            with self.assertRaisesRegex(RuntimeError, 'did not produce'):
                sprites.presented_scroll_step(App(stalled=True), 400, 260, -37)

    def test_app_crash_is_not_a_completed_step(self):
        app = App()
        with patch.object(app, 'rpc', side_effect=RuntimeError('app exited during RPC')):
            with self.assertRaisesRegex(RuntimeError, 'app exited'):
                sprites.presented_scroll_step(app, 400, 260, -37)

class StartupContract(unittest.TestCase):
    def test_missing_story_cannot_silently_accept_the_first_story(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / 'fake-storybook'
            binary.write_text('#!' + sys.executable + '\nimport time,signal,sys\nsignal.signal(signal.SIGTERM, lambda *_: sys.exit(0))\nprint("warning: ZENIT_STORYBOOK_STORY=missing matches no story; opening the first one", flush=True)\ntime.sleep(60)\n')
            binary.chmod(0o755)
            processes = []
            def rpc(directory, proc):
                processes.append(proc)
                def ready(*args, **kwargs):
                    deadline = time.monotonic() + 5
                    while not (Path(directory).parent / 'missing.app.log').read_text():
                        if time.monotonic() > deadline:
                            raise TimeoutError('fake startup did not complete')
                        time.sleep(.01)
                    return {'ok': True}
                return ready
            with patch.object(sprites, 'Rpc', side_effect=rpc):
                with self.assertRaisesRegex(RuntimeError, 'story did not load'):
                    app = sprites.App(str(binary), 'missing', {}, directory)
                    app.close()
            self.assertEqual(len(processes), 1)
            self.assertIsNotNone(processes[0].poll())

class ExitContract(unittest.TestCase):
    def child(self, directory, program):
        app = sprites.App.__new__(sprites.App)
        app.log = open(Path(directory) / 'app.log', 'w')
        app.proc = subprocess.Popen([sys.executable, '-u', '-c', program], stdout=app.log, stderr=subprocess.STDOUT)
        return app

    def test_success_marker_does_not_hide_crash_or_leak(self):
        cases = [
            ("print('PASS'); import os,signal; os.kill(os.getpid(), signal.SIGKILL)", 'exited with status'),
            ("print('PASS'); print('error(gpa): memory address 0x1 leaked')", 'allocator leak'),
            ("print('PASS'); print('error(DebugAllocator): memory address 0x1 leaked')", 'allocator leak'),
        ]
        for program, error in cases:
            with self.subTest(error=error), tempfile.TemporaryDirectory() as directory:
                app = self.child(directory, program)
                app.proc.wait(timeout=5)
                with self.assertRaisesRegex(RuntimeError, error):
                    app.close()

    def test_success_marker_does_not_hide_shutdown_hang(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.child(directory, "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); print('PASS', flush=True); time.sleep(60)")
            deadline = time.monotonic() + 5
            while 'PASS' not in Path(app.log.name).read_text():
                self.assertLess(time.monotonic(), deadline)
                time.sleep(.01)
            wait = app.proc.wait
            try:
                with patch.object(app.proc, 'wait', side_effect=lambda timeout: wait(timeout=min(timeout, .1))):
                    with self.assertRaisesRegex(RuntimeError, 'shutdown timed out'):
                        app.close()
                self.assertIsNotNone(app.proc.poll())
            finally:
                if app.proc.poll() is None:
                    app.proc.kill()
                    wait(timeout=5)
                app.log.close()

    def test_missing_scenario_fails_without_launching_an_app(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(sys, 'argv', ['gate', 'fake-app', '--out', directory, '--only', 'missing-case']):
            with self.assertRaises(SystemExit) as result:
                sprites.main()
            self.assertEqual(result.exception.code, 2)


if __name__ == '__main__':
    unittest.main()
