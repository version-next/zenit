#!/usr/bin/env python3
"""Native LP0 smoke: file commands only; never moves the OS pointer or types keys."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


def wait_file(path, process, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            return path.read_bytes()
        if process.poll() is not None:
            raise RuntimeError(f'app exited {process.returncode} while waiting for {path}')
        time.sleep(.01)
    raise TimeoutError(str(path))


def command(directory, process, name, **fields):
    request_id = str(time.time_ns())
    temp = directory / f'req-{request_id}.tmp'
    temp.write_text(json.dumps({'command': name, 'timeout_ms': 2000, **fields}))
    temp.rename(directory / f'req-{request_id}.json')
    response = directory / f'res-{request_id}.json'
    result = json.loads(wait_file(response, process, 5))
    response.unlink()
    if 'error' in result:
        raise RuntimeError(result)
    return result


def generation(exe, root, number, restore=None, harness=False):
    directory = root / f'generation-{number}'
    directory.mkdir()
    env = {**os.environ, 'ZENIT_DEV_SESSION_DIR': str(directory), 'ZENIT_DEV_REVISION': 'lp0-smoke',
           'ZENIT_DEV_GENERATION': str(number), 'ZENIT_STORYBOOK_STORY': 'tabs',
           'ZENIT_E2E_ISOLATE_POINTER': '1', 'ZENIT_E2E_FILE_RPC_DIR': str(directory)}
    env.pop('ZENIT_DEV_RESTORE', None)
    if restore:
        env['ZENIT_DEV_RESTORE'] = str(restore)
    log_path = directory / 'app.log'
    with log_path.open('w') as log:
        process = subprocess.Popen([str(exe)], env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            control = directory / 'dev-control'
            ready = json.loads(wait_file(control / 'ready', process))
            assert ready['ready'] and ready['generation'] == str(number), ready
            assert command(control, process, 'health')['revision'] == 'lp0-smoke'
            first = command(control, process, 'snapshot')
            data = Path(first['path']).read_bytes()
            assert hashlib.sha256(data).hexdigest() == first['hash']
            snapshot = json.loads(data)
            expected_story = 'checkbox' if restore else 'tabs'
            story = next(v for v in snapshot['application'] if v['key'] == 'storybook.story')
            assert story['data'] == expected_story, story
            assert snapshot['windows'][0]['key'] == 'storybook.main'
            # Generation 2 restores from a snapshot whose frame was moved to (99999, 99999);
            # this asserts the restored native window was clamped back onto a visible screen.
            assert snapshot['windows'][0]['frame']['x'] < 9999
            assert snapshot['windows'][0]['frame']['y'] < 9999
            if harness:
                wait_file(directory / 'owner.json', process)
            command(control, process, 'show_error', text='stories.zig:42\n' + 'multiline diagnostic\n' * 180)
            command(control, process, 'clear_error')
            command(control, process, 'quit')
            assert process.wait(timeout=10) == 0
            assert not (control / 'ready').exists()
            assert json.loads((control / 'health').read_text())['status'] == 'stopped'
            assert 'leaked' not in log_path.read_text(), log_path
            return snapshot
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe', type=Path, default=Path('zig-out/bin/storybook'))
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--harness', action='store_true')
    args = parser.parse_args()
    args.evidence.mkdir(parents=True, exist_ok=True)
    # Unique roots retained as evidence; no reused process-generation directories.
    root = Path(tempfile.mkdtemp(prefix='lp0-', dir=args.evidence.resolve()))
    snapshot = generation(args.exe.resolve(), root, 1, harness=args.harness)
    snapshot['application'][0]['data'] = 'checkbox'
    snapshot['windows'][0]['frame']['x'] = 99999
    snapshot['windows'][0]['frame']['y'] = 99999
    restore = root / 'restore.json'
    restore.write_text(json.dumps(snapshot))
    generation(args.exe.resolve(), root, 2, restore=restore, harness=args.harness)
    print(json.dumps({'status': 'PASS', 'generations': 2, 'harness': args.harness, 'evidence': str(root)}))


if __name__ == '__main__':
    main()
