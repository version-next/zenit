#!/usr/bin/env python3
"""Headless protocol peer. It is NOT a renderer or native GUI acceptance."""
import hashlib
import json
import os
from pathlib import Path
import sys
import time

if os.environ.get('ZENIT_DEV_FAIL_START') == '1':
    sys.exit(73)
root = Path(os.environ['ZENIT_DEV_SESSION_DIR']) / 'dev-control'
root.mkdir()
revision = os.environ['ZENIT_DEV_REVISION']
generation = os.environ['ZENIT_DEV_GENERATION']
overlay = False
saved = {'schema_version': 1, 'application': [{'key': 'storybook.story', 'schema_version': 1, 'data': os.environ.get('ZENIT_STORYBOOK_STORY', 'button')}],
         'windows': [{'key': 'storybook.main', 'frame': {'x': 10, 'y': 20, 'w': 1100, 'h': 1000},
                      'scroll': [{'key': 'storybook.sidebar', 'x': 0, 'y': 0}, {'key': 'storybook.content', 'x': 0, 'y': 0}], 'focus': None}]}
if os.environ.get('ZENIT_DEV_RESTORE'):
    saved = json.loads(Path(os.environ['ZENIT_DEV_RESTORE']).read_text())
saved.update(revision=revision, generation=generation)

def write(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value))
    os.replace(temporary, path)

def health():
    return dict(ready=True, revision=revision, generation=generation, error_overlay=overlay)

def snapshot():
    data = json.dumps(saved).encode()
    digest = hashlib.sha256(data).hexdigest()
    path = root / f'snapshot-{digest}.json'
    path.write_bytes(data)
    pair = dict(path=str(path), hash=digest)
    write(root / 'latest.json', pair)
    return pair

snapshot()
ready = health()
if os.environ.get('ZENIT_FIXTURE_WRONG_READY'):
    ready['revision'] = 'wrong-revision'
while (Path.cwd() / 'hold-ready').exists():
    time.sleep(.01)
write(root / 'ready', ready)
while True:
    for request in root.glob('req-*.json'):
        payload = json.loads(request.read_text())
        name = payload['command']
        result = {'ok': True}
        if name == 'health':
            result = health()
        elif name == 'snapshot':
            result = snapshot()
        elif name == 'show_error':
            overlay = True
        elif name == 'clear_error':
            overlay = False
        elif name == 'set_persist':
            entry = json.loads(payload['text'])
            saved['application'] = [entry]
            snapshot()
        elif name == 'set_scroll':
            value = json.loads(payload['text'])
            entry = next(e for e in saved['windows'][0]['scroll'] if e['key'] == value['key'])
            entry.update(x=value['x'], y=value['y'])
        elif name == 'set_frame':
            saved['windows'][0]['frame'] = json.loads(payload['text'])['frame']
        elif name == 'set_focus':
            saved['windows'][0]['focus'] = json.loads(payload['text'])['id']
        write(root / request.name.replace('req-', 'res-'), result)
        request.unlink()
        if name == 'quit':
            sys.exit(0)
    time.sleep(.01)
