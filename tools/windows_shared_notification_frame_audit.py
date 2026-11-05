#!/usr/bin/env python3
"""Audit actual shared-renderer Notification frames; no desktop/FPS claim.
Uses explicit 33 ms logical frames with production animation durations. Only a uniform
bright body patch is a fade oracle; this does not prove textured backdrop blur.
"""
import argparse
import json
import math
from pathlib import Path
import re
import zipfile
from windows_modal_frame_audit import bitmap
from windows_shared_modal_frame_audit import find, fade, validate_viewport


def body_points(node):
    """Choose blank top padding from layout, before examining frame pixels."""
    rect = node['rect']
    top = rect['y']+rect['h']
    def visit(n):
        nonlocal top
        if n.get('visible') is False:
            return
        if n.get('tag') in ('text', 'image') and n.get('visible', True):
            top = min(top, n['rect']['y'])
        for child in n.get('children', []):
            visit(child)
    visit(node)
    dy = (top-rect['y'])/2 if top < rect['y']+rect['h'] else rect['h']*.4
    if dy < 4:
        raise ValueError('no blank body padding for strict fade oracle')
    return [(rect['w']*fraction, dy+offset) for fraction in (.2, .25, .3) for offset in (-1, 0, 1)]



def sample_point(node, dx, dy, scale):
    rect = node['rect']
    transform = node.get('world_transform')
    if transform is not None:
        if len(transform) != 6 or not all(math.isfinite(v) for v in transform):
            raise ValueError('invalid notification transform')
        a,b,c,d,tx,ty = transform
        return math.floor((a*dx+c*dy+tx)*scale), math.floor((b*dx+d*dy+ty)*scale)
    # Older frame archives retain the card's scale but not its affine matrix.
    sx,sy = node.get('scale_x',1),node.get('scale_y',1)
    return (math.floor((rect['x']+rect['w']/2+(dx-rect['w']/2)*sx)*scale),
            math.floor((rect['y']+rect['h']/2+(dy-rect['h']/2)*sy)*scale))


def audit(folder):
    log = (folder / 'windows-e2e-stderr.log').read_text()
    finish = log.find('[test_harness] frame capture finished')
    if finish >= 0 and '[windows-shared-capture]' in log[finish:]:
        raise ValueError('frame archive continued after finish acknowledgement')
    if '[windows-shared-capture-error]' in log:
        raise ValueError('native frame capture failed')
    logged = [tuple(map(int, m)) for m in re.findall(r'\[windows-shared-capture\] window=(\d+) index=(\d+) serial=(\d+)', log)]
    expected = set(logged)
    if len(logged) != len(expected):
        raise ValueError('duplicate capture log record')
    with zipfile.ZipFile(folder / 'windows-presented-frames.zip') as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError('duplicate archive files')
        records, committed, seen = [], set(), set()
        for name in names:
            if not re.fullmatch(r'shared-\d+-frame-\d+\.json', name):
                continue
            meta = json.loads(archive.read(name))
            key = (meta['window_id'], meta['index'], meta['frame_serial'])
            if key in seen or meta['backend'] not in ('d3d11', 'd3d12'):
                raise ValueError('duplicate or non-D3D12 frame')
            seen.add(key)
            if name != f"shared-{meta['window_id']}-frame-{meta['index']:04d}.json":
                raise ValueError('frame filename/metadata mismatch')
            stem = name[:-5]
            if meta['image'] != stem + '.bmp' or meta['tree'] != stem + '.tree.json':
                raise ValueError('frame identity mismatch')
            committed.update((name, meta['image'], meta['tree']))
            width, height, _ = bitmap(archive.read(meta['image']))
            if (width, height) != (meta['width'], meta['height']) or not math.isfinite(meta['scale']) or meta['scale'] <= 0:
                raise ValueError('invalid frame dimensions')
            tree = json.loads(archive.read(meta['tree']))
            validate_viewport(meta, tree)
            node = find(tree, 'story.notify.warning')
            alpha = node.get('effective_opacity') if node else 0
            if not isinstance(alpha, (int, float)) or not math.isfinite(alpha) or not 0 <= alpha <= 1:
                raise ValueError('missing or invalid opacity')
            records.append((meta, node, alpha, find(tree, 'story.notify.btn.warning') is not None))
        if not seen or seen != expected or committed != set(names):
            raise ValueError('missing/orphan artifacts or log mismatch')
        if len({r[0]['window_id'] for r in records}) != 1:
            raise ValueError('requires one recorded window')
        records.sort(key=lambda r: r[0]['index'])
        if [r[0]['index'] for r in records] != list(range(len(records))) or [r[0]['frame_serial'] for r in records] != list(range(1, len(records)+1)):
            raise ValueError('frame index/serial gap')
        first = next((i for i,r in enumerate(records) if r[1] is not None), None)
        if first is None or first == 0 or not records[first-1][3]:
            raise ValueError('missing notification-page baseline')
        records = records[first-1:]
        settled = next((r for r in records if r[2] >= .999), None)
        if settled is None:
            raise ValueError('missing opaque reference')
        sm, sn, _, _ = settled
        if sm.get('animation_clock_step_ms') != 33:
            raise ValueError('missing deterministic clock evidence')
        scale = sm['scale']
        width, height, reference = bitmap(archive.read(sm['image']))
        bw, bh, baseline = bitmap(archive.read(records[0][0]['image']))
        if (bw,bh) != (width,height):
            raise ValueError('baseline size mismatch')
        rect = sn['rect']
        points = body_points(sn)
        # Select the patch before reading animated pixels. Its bright, locally
        # uniform reference tolerates the notification's small scale transform.
        for dx,dy in points:
            x,y = sample_point(sn, dx, dy, scale)
            if not (4 <= x < width-4 and 4 <= y < height-4):
                raise ValueError('reference patch outside drawable')
            values = [reference(px,py) for px in range(x-4,x+5) for py in range(y-4,y+5)]
            if min(min(v) for v in values) < 230 or any(max(v[c] for v in values)-min(v[c] for v in values)>4 for c in range(3)):
                raise ValueError('reference patch is not uniformly bright')
        starts = closes = entering = exiting = 0
        prior = 0
        results = []
        for meta,node,alpha,_ in records:
            if node is not None and meta.get('animation_clock_step_ms') != 33:
                raise ValueError('animation clock changed while card existed')
            if (meta['width'],meta['height'],meta['scale']) != (width,height,scale):
                raise ValueError('viewport changed during fade')
            _,_,pixel = bitmap(archive.read(meta['image']))
            starts += prior == 0 and alpha > 0
            closes += prior > 0 and alpha == 0
            error = 0
            if .001 < alpha < .999:
                entering += alpha > prior
                exiting += alpha < prior
                current = node['rect']
                if any(abs(current[k]-rect[k])>.05 for k in ('w','h')):
                    raise ValueError('card layout changed')
                for dx,dy in points:
                    x,y = sample_point(node, dx, dy, scale)
                    rx,ry = sample_point(sn, dx, dy, scale)
                    if not (0 <= x < width and 0 <= y < height):
                        raise ValueError('animated patch outside drawable')
                    bg,fg = baseline(x,y),reference(rx,ry)
                    expected_pixel = [fade(b, f, b, alpha) for b,f in zip(bg,fg)]
                    error = max(error,max(abs(a-e) for a,e in zip(pixel(x,y),expected_pixel)))
            residual = 0
            if alpha == 0:
                cursor = meta['cursor']
                for y in range(max(0,math.floor((rect['y']-64)*scale)),min(height,math.ceil((rect['y']+rect['h']+64)*scale))):
                    for x in range(max(0,math.floor((rect['x']-64)*scale)),min(width,math.ceil((rect['x']+rect['w']+64)*scale))):
                        if cursor['visible'] and abs(x/scale-cursor['x'])<=32 and abs(y/scale-cursor['y'])<=32:
                            continue
                        residual = max(residual,max(abs(a-b) for a,b in zip(pixel(x,y),baseline(x,y))))
            results.append({'index':meta['index'],'alpha':alpha,'max_channel_error':error,'closed_max_channel_error':residual})
            prior = alpha
        report = {'passed':starts==3 and closes==3 and entering>=3 and exiting>=3 and prior==0 and all(r['max_channel_error']<=4 and r['closed_max_channel_error']<=3 for r in results),
                  'capture_source':'Direct3D retained submitted surface','animation_clock_step_ms':33,'archive_frames':len(seen),'starts':starts,'closes':closes,
                  'entry_intermediates':entering,'exit_intermediates':exiting,'max_channel_error':max(r['max_channel_error'] for r in results),
                  'closed_max_channel_error':max(r['closed_max_channel_error'] for r in results),'frames':results}
        return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('job',type=Path)
    args = parser.parse_args()
    try:
        report = audit(args.job)
    except (OSError,ValueError,KeyError,StopIteration,zipfile.BadZipFile) as error:
        report = {'passed':False,'error':str(error)}
    (args.job/'notification-frame-audit.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k!='frames'}))
    raise SystemExit(0 if report['passed'] else 1)
