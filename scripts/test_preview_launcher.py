#!/usr/bin/env python3
"""Headless LP1 regressions beyond the a-e protocol smoke. No GUI or Zig builds."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
import copy
import types

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / 'tools'))
sys.path.insert(0, str(REPO / 'scripts'))
from preview import AppLock, Child, Inputs, Preview, parse_args, atomic_json, diagnostics, read_json
from test_preview import wait_for, alive, command, assert_handoff, acceptance_exit, restore_source


class PollingTests(unittest.TestCase):
    def test_atomic_save_add_delete_assets_theme_and_external_inputs(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            (root / 'src').mkdir()
            source = root / 'src' / 'view.zig'
            source.write_text('first')
            external = root / 'dependency'
            external.mkdir()
            watcher = Inputs(root, [external])
            previous = watcher.snapshot()
            self.assertEqual(previous, watcher.snapshot())
            for path, content in [(root / 'src' / 'theme.json', '{}'),
                                  (root / 'src' / 'image.png', 'asset'),
                                  (external / 'styles.yss', 'Button {}')]:
                path.write_text(content)
                changed = watcher.snapshot()
                self.assertNotEqual(previous, changed)
                previous = changed
                path.unlink()
                changed = watcher.snapshot()
                self.assertNotEqual(previous, changed)
                previous = changed
            temp = source.with_suffix('.tmp')
            temp.write_text('second')
            os.replace(temp, source)
            self.assertNotEqual(previous, watcher.snapshot())

    def test_snapshot_fallback_validates_hash_and_pins_copy_or_starts_stateless(self):
        import hashlib
        with tempfile.TemporaryDirectory() as name:
            root = Path(name).resolve()
            launcher = Preview(parse_args(['storybook', '--root', str(root)]))
            candidate = root / 'candidate'
            candidate.mkdir()
            old = root / 'old'
            control = old / 'dev-control'
            control.mkdir(parents=True)
            data = json.dumps(dict(revision='r', generation='1')).encode()
            path = control / 'snapshot-hash.json'
            path.write_bytes(data)
            pair = dict(path=str(path), hash=hashlib.sha256(data).hexdigest())
            atomic_json(control / 'latest.json', pair)
            def timeout(*_):
                raise TimeoutError('UI stopped')
            launcher.command = timeout
            generation = dict(directory=old, revision='r', generation='1')
            copied = launcher.snapshot(generation, candidate)
            self.assertEqual(copied.read_bytes(), data)
            path.unlink()
            self.assertEqual(copied.read_bytes(), data)
            self.assertIsNone(launcher.snapshot(generation, candidate))
            path.write_bytes(b'corrupt')
            self.assertIsNone(launcher.snapshot(generation, candidate))
            path.write_bytes(data)
            generation['revision'] = 'wrong'
            self.assertIsNone(launcher.snapshot(generation, candidate))

    def test_multiplatform_diagnostics(self):
        result = diagnostics('noise\n\x1b[31mC:\\src\\view.yix:12:8: error: bad value\x1b[0m\nfoo.yss:4:2: error: bad token\n')
        self.assertIn('C:\\src\\view.yix:12: bad value', result)
        self.assertIn('foo.yss:4: bad token', result)
        self.assertLessEqual(len(diagnostics('文' * 9000).encode()), 8000)


class RevisionTests(unittest.TestCase):
    def test_poll_digest_uses_content_and_paths_only_and_skips_special_files(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            (root / 'src').mkdir()
            source = root / 'src' / 'view.zig'
            source.write_text('same')
            watcher = Inputs(root)
            original = watcher.snapshot()
            info = source.stat()
            os.utime(source, ns=(info.st_atime_ns, info.st_mtime_ns + 1000000000))
            self.assertEqual(original, watcher.snapshot())
            replacement = source.with_suffix('.tmp')
            replacement.write_text('same')
            os.replace(replacement, source)
            self.assertEqual(original, watcher.snapshot())
            (source.parent / '.DS_Store').write_text('Finder metadata')
            if hasattr(os, 'mkfifo'):
                os.mkfifo(source.parent / 'pipe')
                (source.parent / 'device').symlink_to('/dev/null')
            self.assertEqual(original, watcher.snapshot())
            renamed = source.with_name('renamed.zig')
            source.rename(renamed)
            self.assertNotEqual(original, watcher.snapshot())
            changed = watcher.snapshot()
            renamed.write_text('different')
            self.assertNotEqual(changed, watcher.snapshot())

    def test_lock_detects_unlink_and_replacement_without_growing(self):
        with tempfile.TemporaryDirectory() as name:
            path = Path(name) / 'app.lock'
            lock = AppLock(path)
            try:
                lock.check()
                path.rename(path.with_suffix('.old'))
                path.write_bytes(b'new')
                with self.assertRaisesRegex(RuntimeError, 'removed or replaced'):
                    lock.check()
                path.unlink()
                with self.assertRaisesRegex(RuntimeError, 'removed or replaced'):
                    lock.check()
            finally:
                lock.close()
            # Exercise the real Windows open/write/seek code with a fake locking API.
            api = types.SimpleNamespace(LK_NBLCK=1, locking=mock.Mock())
            for _ in range(3):
                with mock.patch('preview.os.name', 'nt'), mock.patch.dict(sys.modules, msvcrt=api):
                    lock = AppLock(path)
                lock.check()
                lock.close()
                self.assertEqual(path.stat().st_size, 1)
            self.assertEqual(api.locking.call_count, 3)
            lock = AppLock(path)
            try:
                with mock.patch('preview.os.name', 'nt'), mock.patch('preview.os.fstat', return_value=types.SimpleNamespace(st_dev=0, st_ino=0)):
                    with self.assertRaisesRegex(RuntimeError, 'nonzero Windows file IDs'):
                        lock.check()
            finally:
                lock.close()

    def test_windows_close_waits_after_wm_close_before_terminating_job(self):
        child = Child.__new__(Child)
        child.closed = False
        child.job = 'job'
        order = []
        child.process = mock.Mock(pid=123)
        child.process.wait.side_effect = lambda **kw: order.append(('wait', kw['timeout']))
        child.kernel = mock.Mock()
        child.kernel.TerminateJobObject.side_effect = lambda *_: order.append(('kill', None))
        child.request_window_close = lambda: order.append(('WM_CLOSE', None))
        with mock.patch('preview.os.name', 'nt'):
            child.close(grace=.7)
        self.assertEqual(order, [('WM_CLOSE', None), ('wait', .7), ('kill', None), ('wait', 5)])
        self.assertTrue(child.closed)
        child.kernel.CloseHandle.assert_called_once_with('job')

    def test_session_root_rejects_other_application_and_checkout(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            shared = root / 'shared'
            first = Preview(parse_args(['storybook', '--root', name, '--session-root', str(shared)]))
            first.claim_session()
            first.claim_session()
            second = Preview(parse_args(['yix-counter', '--root', name, '--session-root', str(shared)]))
            with self.assertRaisesRegex(RuntimeError, 'another application/checkout'):
                second.claim_session()
            owner = read_json(shared / 'application.json')
            self.assertEqual(owner['app'], 'storybook')

    def test_test_mode_and_launcher_options_are_rejected(self):
        for option in ('-Dtest-mode=true', '-Dtest-mode=false', '-Dtest-mode', '-Dtarget=native', '-Ddev-preview=false'):
            with self.subTest(option=option), mock.patch('sys.stderr'), self.assertRaises(SystemExit) as exit:
                parse_args(['storybook', '--build-option=' + option])
            self.assertEqual(exit.exception.code, 2)

    def test_native_handoff_rejects_default_or_lost_state(self):
        initial = dict(application=[dict(key='storybook.story', data='input')], windows=[dict(
            frame=dict(x=0, y=0, w=1100, h=1000), focus=None,
            scroll=[dict(key='storybook.content', x=0, y=0)])])
        before = copy.deepcopy(initial)
        before['windows'][0].update(frame=dict(x=37, y=29, w=850, h=600), focus='storybook.search.input')
        before['windows'][0]['scroll'][0]['y'] = 120
        assert_handoff(before, copy.deepcopy(before), initial)
        for field in ('scroll', 'frame', 'focus'):
            invalid = copy.deepcopy(before)
            invalid['windows'][0][field] = initial['windows'][0][field]
            with self.subTest(field=field):
                with self.assertRaises(AssertionError):
                    assert_handoff(invalid, invalid, initial)
                with self.assertRaises(AssertionError):
                    assert_handoff(before, invalid, initial)

    def test_restore_failure_is_nonzero_even_when_all_cases_pass(self):
        report = dict(source_restored=True, cases={k: dict(status='PASS') for k in 'abcde'})
        self.assertEqual(acceptance_exit(report), 0)
        source = mock.Mock()
        source.write_bytes.side_effect = OSError('cannot restore')
        report['source_restored'] = restore_source(source, b'original')
        self.assertFalse(report['source_restored'])
        self.assertEqual(acceptance_exit(report), 1)
        source.write_bytes.side_effect = None
        source.read_bytes.return_value = b'wrong bytes'
        self.assertFalse(restore_source(source, b'original'))


@unittest.skipIf(os.name == 'nt', 'POSIX executable fixture; Windows launcher uses Job Objects')
class SupervisorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / 'examples/storybook').mkdir(parents=True)
        self.source = self.root / 'examples/storybook/stories.zig'
        self.source.write_text('// first')
        for filename, source in [('peer.py', 'preview_peer.py'), ('zig-fixture', 'preview_build.py')]:
            text = (REPO / 'scripts/fixtures' / source).read_text().split('\n', 1)[1]
            path = self.root / filename
            path.write_text('#!' + sys.executable + '\n' + text)
            path.chmod(0o755)
        self.session = self.root / 'session'
        self.argv = [sys.executable, str(REPO / 'tools/preview.py'), 'storybook', '--root', str(self.root),
                     '--zig', str(self.root / 'zig-fixture'), '--session-root', str(self.session),
                     '--poll', '.02', '--debounce', '.05', '--ready-timeout', '.5', '--quit-timeout', '.2']
        self.process = None
        self.log = (self.root / 'launcher.log').open('w')

    def tearDown(self):
        if self.process and self.process.poll() is None:
            self.process.terminate()
            self.assertEqual(self.process.wait(timeout=10), 0)
        self.log.close()
        self.temp.cleanup()

    def start(self, **kwargs):
        self.process = subprocess.Popen(self.argv, stdout=self.log, stderr=subprocess.STDOUT, **kwargs)

    def state(self):
        return read_json(self.session / 'state.json') or {}

    def events(self):
        path = self.session / 'events.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def wait(self, check, description):
        # Generous upper bound: these supervisor tests share the machine with real builds,
        # and a slow fake build under load is not a protocol failure. Each check still fails
        # fast if the launcher exits.
        try:
            return wait_for(check, 30, self.process, description)
        except TimeoutError:
            details = {'state': self.state(), 'launcher': (self.root / 'launcher.log').read_text()}
            details['apps'] = {str(p.relative_to(self.root)): p.read_text() for p in self.session.glob('generation-*/app.log')}
            self.fail('supervisor timeout: ' + description + '\n' + json.dumps(details, indent=2))

    def test_edits_during_build_discard_old_revision_and_debounce_saves(self):
        (self.root / 'hold-build').touch()
        self.start()
        self.wait(lambda: (self.root / 'build-started').exists(), 'compiler started')
        for i in range(4):
            self.source.write_text(f'// edit {i}')
            time.sleep(.01)
        (self.root / 'hold-build').unlink()
        self.wait(lambda: self.state().get('current'), 'ready')
        events = self.events()
        self.assertEqual([e['event'] for e in events].count('discarded'), 1, events)
        self.assertEqual([e['event'] for e in events].count('ready'), 1, events)
        self.assertTrue(self.state()['current']['revision'].startswith('2-'))
        # The revision really identifies the latest complete source snapshot.
        self.assertTrue(self.state()['current']['revision'].endswith(Inputs(self.root.resolve()).snapshot()))

    def test_session_outputs_inside_watched_tree_do_not_trigger_rebuilds(self):
        self.session = self.root / 'examples' / 'preview-sessions'
        self.argv[self.argv.index('--session-root') + 1] = str(self.session)
        self.start()
        self.wait(lambda: self.state().get('current'), 'ready without watching own outputs')
        time.sleep(.3)
        self.assertEqual(self.state()['sequence'], 1, self.events())

    def test_single_instance_lock_ignores_session_root_override(self):
        self.start()
        self.wait(lambda: self.state().get('current'), 'ready')
        other = self.argv + ['--session-root', str(self.root / 'another-session')]
        result = subprocess.run(other, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 1, result)
        self.assertIn(b'another preview launcher', result.stderr)
        self.assertTrue(alive(self.state()['current']['pid']))

    def test_cross_app_session_collision_does_not_write_state_or_events(self):
        self.start()
        self.wait(lambda: self.state().get('current'), 'ready')
        before_state = (self.session / 'state.json').read_bytes()
        before_events = (self.session / 'events.jsonl').read_bytes()
        other = list(self.argv)
        other[other.index('storybook')] = 'yix-counter'
        result = subprocess.run(other, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 1)
        self.assertIn(b'another application/checkout', result.stderr)
        self.assertEqual(before_state, (self.session / 'state.json').read_bytes())
        self.assertEqual(before_events, (self.session / 'events.jsonl').read_bytes())
        self.assertIsNone(self.process.poll())

    def test_term_during_build_reaps_compiler(self):
        (self.root / 'hold-build').touch()
        self.start()
        self.wait(lambda: (self.root / 'build-started').exists(), 'compiler started')
        # Fixture records its own identity: does not depend on OS process-list permission.
        child_pid = int((self.root / 'build-started').read_text())
        self.process.terminate()
        self.assertEqual(self.process.wait(timeout=10), 0)
        self.assertFalse(alive(child_pid))

    def test_wrong_identity_ready_times_out_and_reclaims_candidate(self):
        self.start(env=dict(os.environ, ZENIT_FIXTURE_WRONG_READY='1'))
        self.wait(lambda: self.state().get('event') == 'error', 'candidate deadline')
        self.assertIsNone(self.state()['current'])
        self.assertFalse(alive(self.state()['candidate_pid']))

    def test_cache_removal_does_not_remove_application_lock(self):
        import shutil
        self.start()
        self.wait(lambda: self.state().get('current'), 'ready')
        shutil.rmtree(self.root / '.zig-cache', ignore_errors=True)
        other = self.argv + ['--session-root', str(self.root / 'other')]
        result = subprocess.run(other, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 1)
        self.assertIn(b'another preview launcher', result.stderr)
        self.assertIsNone(self.process.poll())

    def test_replaced_lock_during_build_aborts_and_reaps(self):
        self.start()
        old = self.wait(lambda: self.state().get('current'), 'ready')
        (self.root / 'hold-build').touch()
        (self.root / 'build-started').unlink()
        self.source.write_text('// next')
        self.wait(lambda: self.state()['sequence'] == 2 and self.state()['event'] == 'building', 'second build')
        self.wait(lambda: (self.root / 'build-started').exists(), 'second compiler pid')
        compiler = int((self.root / 'build-started').read_text())
        lock = self.root / '.preview-locks/storybook.lock'
        lock.rename(lock.with_suffix('.old'))
        lock.touch()
        self.assertEqual(self.process.wait(timeout=10), 1)
        self.assertFalse(alive(old['pid']))
        self.assertFalse(alive(compiler))
        self.assertIn('removed or replaced', (self.root / 'launcher.log').read_text())

    def test_current_exit_during_build_cancels_handoff(self):
        self.start()
        old = self.wait(lambda: self.state().get('current'), 'ready')
        (self.root / 'hold-build').touch()
        (self.root / 'build-started').unlink()
        self.source.write_text('// next')
        self.wait(lambda: (self.root / 'build-started').exists(), 'held second build')
        compiler = int((self.root / 'build-started').read_text())
        command(old, 'quit')
        self.assertEqual(self.process.wait(timeout=10), 1)
        self.assertFalse(alive(compiler))
        self.assertEqual(len([e for e in self.events() if e['event'] == 'ready']), 1)
        self.assertTrue(any(e['event'] == 'current_exited' for e in self.events()))

    def test_current_exit_during_ready_wait_reaps_candidate(self):
        self.start()
        old = self.wait(lambda: self.state().get('current'), 'ready')
        (self.root / 'hold-ready').touch()
        self.source.write_text('// next')
        self.wait(lambda: self.state().get('event') == 'starting' and self.state()['sequence'] == 2, 'candidate waiting for ready')
        candidate = self.state()['candidate_pid']
        command(old, 'quit')
        self.assertEqual(self.process.wait(timeout=10), 1)
        self.assertFalse(alive(candidate))
        self.assertEqual(len([e for e in self.events() if e['event'] == 'ready']), 1)

    def test_max_delay_starts_build_during_continuous_saves(self):
        self.argv += ['--debounce', '2', '--max-delay', '.2']
        self.start()
        self.wait(lambda: self.state().get('current'), 'initial ready')
        (self.root / 'hold-build').touch()
        deadline = time.monotonic() + 1.5
        edits = 0
        while self.state()['sequence'] < 2 and time.monotonic() < deadline:
            edits += 1
            self.source.write_text('// continuous edit ' + str(edits))
            time.sleep(.015)
        self.assertGreater(edits, 5)
        self.assertEqual(self.state()['sequence'], 2, self.events())
        self.assertLess(time.monotonic(), deadline)

    def test_retention_keeps_latest_and_bounded_snapshots(self):
        self.start()
        current = self.wait(lambda: self.state().get('current'), 'ready')
        control = Path(current['directory']) / 'dev-control'
        for i in range(45):
            (control / f'snapshot-fake-{i}.json').write_text('{}')
        latest = read_json(control / 'latest.json')['path']
        self.wait(lambda: len(list(control.glob('snapshot-*.json'))) <= 33, 'snapshot pruning')
        self.assertTrue(Path(latest).exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
