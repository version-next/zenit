#!/usr/bin/env python3
"""LP1 a-e acceptance. File commands only, no pointer/keyboard automation.

--fixture runs the same supervisor scenarios against a headless protocol peer;
its PASS is explicitly not native GUI acceptance. Sources restore in finally.
"""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / 'tools'))
from preview import atomic_json, read_json


def wait_for(check, timeout, process=None, description='condition'):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        if process is not None and process.poll() is not None:
            raise RuntimeError(f'launcher exited {process.returncode}: {description}')
        time.sleep(.03)
    raise TimeoutError(description)


def alive(pid):
    if os.name == 'nt':
        import ctypes
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.OpenProcess.restype = ctypes.c_void_p
        handle = kernel.OpenProcess(0x1000, False, pid)
        if not handle:
            return False
        try:
            code = ctypes.c_ulong()
            kernel.GetExitCodeProcess(ctypes.c_void_p(handle), ctypes.byref(code))
            return code.value == 259
        finally:
            kernel.CloseHandle(ctypes.c_void_p(handle))
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def command(current, name, **fields):
    control = Path(current['directory']) / 'dev-control'
    request_id = str(time.time_ns())
    response = control / f'res-{request_id}.json'
    atomic_json(control / f'req-{request_id}.json', dict(command=name, timeout_ms=2000, **fields))
    result = wait_for(lambda: read_json(response), 5, description=name)
    response.unlink()
    if 'error' in result:
        raise RuntimeError(result)
    return result


def capture(current):
    pair = command(current, 'snapshot')
    data = Path(pair['path']).read_bytes()
    assert hashlib.sha256(data).hexdigest() == pair['hash'], pair
    return json.loads(data)


def route(snapshot):
    return next(e['data'] for e in snapshot['application'] if e['key'] == 'storybook.story')


def restore_source(source, original):
    try:
        source.write_bytes(original)
        return source.read_bytes() == original
    except OSError:
        return False


def native_screenshot(path):
    """Record the actual display at a transition (macOS acceptance worker)."""
    # Full-display captures include the developer's other windows. Only take them
    # when explicitly requested (dedicated acceptance worker).
    if os.environ.get('ZENIT_ACCEPTANCE_SCREENSHOTS') != '1':
        return
    if sys.platform != 'darwin':
        raise RuntimeError('native screenshots require the macOS GPU acceptance worker')
    subprocess.run(['/usr/sbin/screencapture', '-x', '-m', str(path)], check=True, timeout=10)
    if not path.read_bytes().startswith(b'\x89PNG\r\n\x1a\n'):
        raise RuntimeError('missing native PNG screenshot: ' + str(path))


def assert_clean_app_logs(session):
    """Success markers must not mask exit-time allocator failures or crashes."""
    for path in session.glob('generation-*/app.log'):
        text = path.read_text(errors='replace')
        if re.search(r'panic:|memory address .* leaked|\[gpa\].*leak|error:.*leak', text, re.I):
            raise AssertionError('native app panic/leak: ' + str(path))


def acceptance_exit(report, required='abcde'):
    cases = report.get('cases', {})
    complete = set(cases) == set(required)
    return 0 if report.get('source_restored') and complete and all(case.get('status') == 'PASS' for case in cases.values()) else 1


def assert_handoff(before, after, initial):
    b, a, i = (snap['windows'][0] for snap in (before, after, initial))
    assert route(before) == route(after) == 'input', (before, after)
    scroll = lambda w: next(e for e in w['scroll'] if e['key'] == 'storybook.content')
    assert scroll(i)['y'] == 0, initial
    assert scroll(b)['y'] > 0, ('scroll setup has no discriminating offset', before)
    assert scroll(a) == scroll(b), (before, after)
    assert b['frame'] != i['frame'], ('frame setup did not change native geometry', initial, before)
    assert b['frame'] == a['frame'], (before, after)
    assert b['focus'] == 'storybook.search.input' and b['focus'] != i['focus'], (initial, before)
    assert a['focus'] == b['focus'], (before, after)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zig', default='zig')
    parser.add_argument('--mapper', type=Path)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--fixture', action='store_true')
    args = parser.parse_args()
    args.evidence.mkdir(parents=True, exist_ok=True)
    evidence = Path(tempfile.mkdtemp(prefix='lp1-', dir=args.evidence.resolve()))
    root = REPO
    zig = args.zig
    if args.fixture:
        if os.name == 'nt':
            parser.error('--fixture uses POSIX executable scripts; run native acceptance on Windows')
        root = evidence / 'fixture-root'
        (root / 'examples/storybook').mkdir(parents=True)
        (root / 'build.zig').write_text('// fixture')
        (root / 'build.zig.zon').write_text('// fixture')
        (root / 'examples/storybook/stories.zig').write_text('// fixture story')
        # Keep Python's actual interpreter in the shebang (no PATH assumptions).
        for filename, source in [('peer.py', 'preview_peer.py'), ('zig-fixture', 'preview_build.py')]:
            content = (REPO / 'scripts/fixtures' / source).read_text().split('\n', 1)[1]
            path = root / filename
            path.write_text('#!' + sys.executable + '\n' + content)
            path.chmod(0o755)
        zig = str(root / 'zig-fixture')
    source = root / 'examples/storybook/stories.zig'
    original = source.read_bytes()
    session = evidence / 'session'
    session.mkdir()
    argv = [sys.executable, str(REPO / 'tools/preview.py'), 'storybook', '--stories', 'button,input', '--story', 'button',
            '--root', str(root), '--zig', zig, '--session-root', str(session), '--keep', '3', '--ready-timeout', '15']
    if args.mapper:
        argv += ['--mapper', str(args.mapper.resolve())]
    process = None
    seen_pids = set()
    results = {name: {'status': 'FAIL', 'reason': 'case not reached'} for name in 'abcde'}
    active_case = 'a'
    start = time.monotonic()
    log = (evidence / 'launcher.log').open('w')
    previous = {}
    def interrupted(signum, _):
        raise KeyboardInterrupt(f'signal {signum}')
    for name in ('SIGTERM', 'SIGHUP'):
        if hasattr(signal, name):
            sig = getattr(signal, name)
            previous[sig] = signal.signal(sig, interrupted)
    try:
        process = subprocess.Popen(argv, stdout=log, stderr=subprocess.STDOUT)
        def current():
            value = (read_json(session / 'state.json') or {}).get('current')
            if value:
                seen_pids.add(value['pid'])
            return value
        def next_generation(old=None):
            def check():
                value = current()
                state = read_json(session / 'state.json') or {}
                if not old and state.get('event') == 'error':
                    raise RuntimeError('initial app failed: ' + state.get('error', 'unknown'))
                return value if value and (not old or value['generation'] != old['generation']) else None
            return wait_for(check, 180, process, 'new ready generation')
        def retired(old, stopped=False):
            wait_for(lambda: not alive(old['pid']), 10, process, 'old process retired')
            records = wait_for(lambda: [json.loads(line) for line in (session / 'events.jsonl').read_text().splitlines()
                                       if json.loads(line)['event'] == 'retired' and json.loads(line)['pid'] == old['pid']],
                               5, process, 'retirement exit code')
            expected_codes = (-signal.SIGTERM, -signal.SIGKILL) if stopped else (0,)
            assert records[-1]['exit_code'] in expected_codes, records
        def edit(tag):
            # Change a placeholder on exactly one line of the selected story.
            marker = f'{tag}-{time.time_ns()}'
            needle = b'"Your name"'
            if not args.fixture:
                assert original.count(needle) == 1, 'input source placeholder changed; update acceptance edit'
                source.write_bytes(original.replace(needle, f'"Your name [{marker}]"'.encode()))
            else:
                source.write_bytes(original + f'\n// LP1 acceptance {marker}\n'.encode())
        first = next_generation()
        assert route(capture(first)) == 'button'
        command(first, 'set_persist', text=json.dumps({'key': 'storybook.story', 'schema_version': 1, 'data': 'input'}))
        wait_for(lambda: route(capture(first)) == 'input', 5, process, 'navigate to tall input story')
        # Route decoders can update the model before the dynamic tree mounts.
        # Resolve a visible input-story node to prove the target layout exists.
        def input_mounted():
            try:
                return command(first, 'set_focus', text=json.dumps(dict(key='storybook.main', id='story.input.name.input')))
            except RuntimeError as exc:
                if 'UnknownFocusId' in str(exc):
                    return None
                raise
        wait_for(input_mounted, 5, process, 'input story mounted and visible')
        initial = capture(first)
        window = initial['windows'][0]
        # Input contains enough rows to exceed even the original 1000pt window.
        # A 600pt outer frame makes scrollability independent of a large display.
        frame = dict(window['frame'], x=window['frame']['x'] + 37, y=window['frame']['y'] + 29, w=850, h=600)
        command(first, 'set_frame', text=json.dumps(dict(key=window['key'], frame=frame)))
        wait_for(lambda: capture(first)['windows'][0]['frame'] != window['frame'], 5, process, 'native frame changed')
        command(first, 'set_scroll', text=json.dumps(dict(key='storybook.content', x=0, y=120)))
        command(first, 'set_focus', text=json.dumps(dict(key=window['key'], id='storybook.search.input')))
        before = capture(first)
        # Check setup now; the test must never count 0==0/null==null as coverage.
        atomic_json(evidence / 'a-initial.json', initial)
        atomic_json(evidence / 'a-before.json', before)
        if not args.fixture: native_screenshot(evidence / 'a-before.png')
        assert_handoff(before, before, initial)
        edit('a')
        second = next_generation(first)
        after = capture(second)
        atomic_json(evidence / 'a-after.json', after)
        if not args.fixture: native_screenshot(evidence / 'a-after.png')
        assert_handoff(before, after, initial)
        retired(first)
        results['a'] = dict(status='PASS', generation=second['generation'], checked=['route changed', 'nonzero content scroll', 'changed native frame', 'explicit visible focus'])

        active_case = 'b'
        source.write_bytes(original + b'\ncomptime { @compileError("LP1 deliberate compile failure"); }\n')
        wait_for(lambda: command(second, 'health').get('error_overlay'), 180, process, 'compile error overlay')
        assert alive(second['pid']) and current()['generation'] == second['generation']
        errors = wait_for(lambda: [json.loads(line) for line in (session / 'events.jsonl').read_text().splitlines() if json.loads(line)['event'] == 'overlay'], 5, process, 'overlay acknowledgement')
        assert errors and 'stories.zig:' in errors[-1]['error'], errors
        if not args.fixture: native_screenshot(evidence / 'b-error.png')
        edit('b-fixed')
        third = next_generation(second)
        assert not command(third, 'health')['error_overlay']
        retired(second)
        if not args.fixture: native_screenshot(evidence / 'b-fixed.png')
        results['b'] = dict(status='PASS', generation=third['generation'])

        active_case = 'c'
        # Snapshot immediately before stopping the UI also covers SIGSTOP stopping
        # the transport worker: the launcher must enforce its own RPC deadline.
        stable = capture(third)
        if os.name == 'nt':
            raise RuntimeError('SIGSTOP scenario requires POSIX; Windows use a dev UI-stall fixture before acceptance')
        os.kill(third['pid'], signal.SIGSTOP)
        edit('c-stopped')
        fourth = next_generation(third)
        retired(third, stopped=True)
        assert route(capture(fourth)) == route(stable)
        events = [json.loads(line) for line in (session / 'events.jsonl').read_text().splitlines()]
        assert any(e['event'] == 'snapshot' and e['source'] == 'latest' for e in events), events
        if not args.fixture: native_screenshot(evidence / 'c-recovered.png')
        results['c'] = dict(status='PASS', generation=fourth['generation'])

        active_case = 'd'
        (session / 'fail-next-start').write_text('1')
        edit('d-crash')
        wait_for(lambda: command(fourth, 'health').get('error_overlay'), 180, process, 'candidate startup failure overlay')
        assert current()['generation'] == fourth['generation'] and alive(fourth['pid'])
        wait_for(lambda: (read_json(session / 'state.json') or {}).get('event') == 'overlay', 5, process, 'startup error acknowledgement')
        state = read_json(session / 'state.json')
        failed_pid = state['candidate_pid']
        seen_pids.add(failed_pid)
        wait_for(lambda: not alive(failed_pid), 5, process, 'failed candidate reclaimed')
        if not args.fixture: native_screenshot(evidence / 'd-candidate-failed.png')
        edit('d-recover')
        fifth = next_generation(fourth)
        assert not command(fifth, 'health')['error_overlay']
        retired(fourth)
        wait_for(lambda: len(list(session.glob('generation-*'))) <= 3, 5, process, 'generation retention')
        if not args.fixture: native_screenshot(evidence / 'd-recovered.png')
        results['d'] = dict(status='PASS', generation=fifth['generation'])

        active_case = 'e'
        process.terminate()
        assert process.wait(timeout=15) == 0
        for pid in seen_pids:
            wait_for(lambda: not alive(pid), 5, description=f'child {pid} reclaimed')
        assert_clean_app_logs(session)
        results['e'] = dict(status='PASS', child_pids=sorted(seen_pids))
    except BaseException as exc:
        results[active_case] = dict(status='FAIL', reason=f'{type(exc).__name__}: {exc}')
    finally:
        # Always restore, including interruption during compiler errors or startup.
        source_restored = restore_source(source, original)
        if process and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        for sig, handler in previous.items():
            signal.signal(sig, handler)
        log.close()
        events_path = session / 'events.jsonl'
        if events_path.exists():
            for line in events_path.read_text().splitlines():
                event = json.loads(line)
                if event.get('candidate_pid'):
                    seen_pids.add(event['candidate_pid'])
        residual = [pid for pid in seen_pids if alive(pid)]
        if residual:
            results['e'] = dict(status='FAIL', reason=f'residual children: {residual}')
        try:
            assert_clean_app_logs(session)
        except AssertionError as exc:
            results['e'] = dict(status='FAIL', reason=str(exc))
        report = dict(mode='headless protocol fixture (NOT GUI)' if args.fixture else 'native storybook',
                      cases=results, source_restored=source_restored,
                      seconds=time.monotonic() - start, command=argv, evidence=str(evidence))
        atomic_json(evidence / 'result.json', report)
        print(json.dumps(report, indent=2))
    return acceptance_exit(report)


if __name__ == '__main__':
    sys.exit(main())
