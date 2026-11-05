#!/usr/bin/env python3
"""Native LP4/LP5 k-z acceptance; Metal, a visible desktop and --screenshots required.

Uses dev-control programmatic actions; does not claim native pointer/IME coverage.
Missing cases, display evidence, crashes/leaks or failed restoration fail the run.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
from test_preview import wait_for, alive, command, capture, restore_source, native_screenshot, assert_clean_app_logs, acceptance_exit
from preview import read_json, atomic_json
ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zig', default='zig')
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--screenshots', action='store_true')
    args = parser.parse_args()
    if not args.screenshots or sys.platform != 'darwin':
        parser.error('native acceptance requires macOS and explicit --screenshots on the GPU worker')
    os.environ['ZENIT_ACCEPTANCE_SCREENSHOTS'] = '1'
    args.evidence.mkdir(parents=True, exist_ok=True)
    evidence = Path(tempfile.mkdtemp(prefix='lp4-', dir=args.evidence.resolve()))
    session = evidence/'session'
    source = ROOT/'examples/template_probe/view.yix'
    twin = source.with_name('_view.yix.zig')
    remount = ROOT/'examples/template_probe/remount.yix'
    remount_twin = remount.with_name('_remount.yix.zig')
    regions = ROOT/'examples/template_probe/regions.yix'
    regions_twin = regions.with_name('_regions.yix.zig')
    originals = {p:p.read_bytes() for p in (source, twin, remount, remount_twin, regions, regions_twin)}
    cases = {k:dict(status='FAIL', reason='case not reached') for k in 'klmnopqrstuvwxyz'}
    process = None; active = 'k'; seen = set(); restore_ok = True
    log = (evidence/'launcher.log').open('w')
    previous = {}
    def interrupted(signum, _): raise KeyboardInterrupt(f'signal {signum}')
    for name in ('SIGTERM', 'SIGHUP'):
        sig = getattr(signal, name); previous[sig] = signal.signal(sig, interrupted)
    def records():
        path = session/'events.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
    try:
        process = subprocess.Popen([sys.executable, str(ROOT/'tools/preview.py'), 'template-probe',
            '--root', str(ROOT), '--zig', args.zig, '--session-root', str(session), '--poll', '.01'],
            stdout=log, stderr=subprocess.STDOUT, env=dict(os.environ, ZENIT_GLASS_CLOCK_TRACE='1'))
        def current():
            state = read_json(session/'state.json') or {}; value = state.get('current')
            if value: seen.add(value['pid'])
            if not value and state.get('event') == 'error': raise RuntimeError(state.get('error'))
            return value
        first = wait_for(current, 240, process, 'two-window native startup')
        def query(test_id, **options): return command(current(), 'query_template', test_id=test_id, **options)
        def snap(tag):
            value = capture(current()); atomic_json(evidence/(tag+'.json'), value)
            native_screenshot(evidence/(tag+'.png')); return value
        def event_after(index, name):
            return wait_for(lambda:next((r for r in records()[index:] if r['event'] == name), None), 240, process, name)
        def presented_latency(event, keys):
            health = wait_for(lambda:command(current(), 'health'), 5, process, 'template submitted frames')
            def submitted():
                frames = command(current(), 'health').get('template_frames', [])
                selected = [f for f in frames if f['key'] in keys and f['generation'] == event['generation'] and f['frame'] > 0]
                return selected if len(selected) == len(keys) else None
            frames = wait_for(submitted, 5, process, 'all owner template frames')
            app_log = Path(current()['directory'])/'app.log'
            def display():
                trace = []
                for line in app_log.read_text(errors='replace').splitlines():
                    if '[glass-clock] {' in line:
                        try: trace.append(json.loads(line.split('[glass-clock] ', 1)[1]))
                        except ValueError: pass
                # Frame numbers alone are ambiguous across owners. Demand a native
                # window id in both health and trace, never accept the other window.
                chosen = []
                for frame in frames:
                    if 'window_id' not in frame: raise RuntimeError('health lacks native window identity')
                    item = next((e for e in trace if e.get('kind') == 'presented' and e.get('window') == frame['window_id']
                        and e.get('frame', -1) >= frame['frame'] and e.get('presented_time', 0) > 0), None)
                    if item is None: return None
                    chosen.append(item)
                return chosen
            traces = wait_for(display, 5, process, 'per-window Metal presented callbacks')
            latencies = [(e['presented_time']-event['detected_monotonic_s'])*1000 for e in traces]
            assert all(0 <= ms < 300 for ms in latencies), latencies
            atomic_json(evidence/(str(event['generation'])+'-presented.json'), dict(frames=frames, traces=traces, detected_to_presented_ms=latencies,
                parse_ms=event.get('parse_ms'), apply_ms=event.get('apply_ms')))
            return latencies
        assert command(first, 'health')['windows'] == 2
        for key, x in (('lp4.a', 40), ('lp4.b', 500)):
            command(first, 'set_frame', text=json.dumps(dict(key=key, frame=dict(x=x, y=100, w=420, h=300))))
        def separated():
            windows = {w['key']:w['frame'] for w in capture(first)['windows']}
            a, b = windows['lp4.a'], windows['lp4.b']
            return a['x'] + a['w'] <= b['x'] or b['x'] + b['w'] <= a['x']
        wait_for(separated, 5, process, 'non-overlapping visible native windows')
        command(first, 'activate_template', test_id='lp4.increment')
        command(first, 'activate_template', test_id='lp4.increment.b')
        assert query('lp4.count')['text'] == 'value 8'
        assert query('lp4.count.b')['text'] == 'value 20'
        snap('k-before')
        index = len(records()); edited = originals[source].replace(b'>Original<', b'>Changed<')
        source.write_bytes(edited); applied = event_after(index, 'templates_applied')
        wait_for(lambda:query('lp4.label')['text'] == query('lp4.label.b')['text'] == 'Changed', 5, process)
        assert current()['pid'] == first['pid']
        latency = presented_latency(applied, ['lp4.a', 'lp4.b']); snap('k-applied')
        cases['k'] = dict(status='PASS', detected_to_applied_ms=applied['detected_to_applied_ms'], detected_to_presented_ms=latency)
        active = 'l'
        assert query('lp4.count')['text'] == 'value 8' and query('lp4.count.b')['text'] == 'value 20'
        command(first, 'activate_template', test_id='lp4.increment')
        assert query('lp4.count')['text'] == 'value 9'; snap('l-state')
        cases['l'] = dict(status='PASS', counts=[9, 20])
        active = 'm'; index = len(records()); source.write_bytes(edited.replace(b'</col>', b'</row>'))
        error = event_after(index, 'templates_error')
        assert command(first, 'health')['error_overlay']
        assert query('lp4.label')['text'] == 'Changed'; snap('m-error')
        assert current()['pid'] == first['pid']; assert query('lp4.count')['text'] == 'value 9'
        index = len(records()); source.write_bytes(edited)
        event_after(index, 'templates_applied'); snap('m-repaired')
        cases['m'] = dict(status='PASS', diagnostic=error['diagnostic'])
        active = 'n'
        # Directly submit a candidate failure without racing the watcher: the
        # source is unchanged, but a distinct edit must reach candidate construction.
        # Freeze launcher via SIGSTOP while the UI keeps pumping file commands.
        os.kill(process.pid, signal.SIGSTOP)
        source.write_bytes(edited.replace(b'Changed', b'Candidate'))
        before_generation = query('lp4.label')['generation']
        reply = command(first, 'reload_templates', files=['examples/template_probe/view.yix'], fail_after=2)
        assert reply['result'] == 'fallback' and reply['reason'] == 'TemplateInjectedFailure', reply
        assert query('lp4.label')['text'] == query('lp4.label.b')['text'] == 'Changed'
        assert query('lp4.label')['generation'] == before_generation
        assert query('lp4.count')['text'] == 'value 9' and query('lp4.count.b')['text'] == 'value 20'
        snap('n-rollback'); command(first, 'clear_error'); source.write_bytes(edited)
        os.kill(process.pid, signal.SIGCONT)
        cases['n'] = dict(status='PASS', response=reply)
        active = 'q'
        retained = []
        for iteration in range(20):
            index = len(records())
            selected = edited.replace(b'style={S.A}', b'style={S.Unused}') if iteration % 2 == 0 else edited
            source.write_bytes(selected)
            event = event_after(index, 'templates_applied')
            assert current()['pid'] == first['pid'], 'style reference edit restarted the app'
            assert query('lp4.style')['style_gap'] == query('lp4.style.b')['style_gap'] == (19 if iteration % 2 == 0 else 3)
            assert query('lp4.count')['text'] == 'value 9' and query('lp4.count.b')['text'] == 'value 20'
            health = command(current(), 'health')
            assert health['retained_template_versions'] == 2, health
            retained.append(health['retained_template_bytes'])
            if iteration in (0, 19):
                presented_latency(event, {'lp4.a', 'lp4.b'})
                snap('q-generation-'+str(iteration))
        assert len(set(retained[4:])) == 1, retained
        cases['q'] = dict(status='PASS', rounds=20, retained_template_bytes=retained,
            memory_contract='immutable template arenas; not process RSS or GPU memory')
        active = 'r'
        command(first, 'set_frame', text=json.dumps(dict(key='lp4.a', frame=dict(x=40, y=40, w=420, h=800))))
        command(first, 'activate_template', test_id='r3.parent.button')
        command(first, 'activate_template', test_id='r3.child.button')
        assert query('r3.parent')['text'] == 'parent 8'
        assert query('r3.child')['text'] == 'child 4'
        snap('r-before')
        index = len(records())
        child_edit = originals[remount].replace(b'RemountOriginal', b'RemountChanged')
        remount.write_bytes(child_edit)
        applied = event_after(index, 'templates_applied')
        assert current()['pid'] == first['pid']
        assert query('r3.parent')['text'] == 'parent 8'
        assert query('r3.child')['text'] == 'child 3'
        # remount.yix is mounted only in window A (main.zig mountA); B has no affected owner, so it never submits a frame for this generation.
        latency = presented_latency(applied, ['lp4.a']); snap('r-remounted')
        cases['r'] = dict(status='PASS', detected_to_presented_ms=latency, parent=8, child_before=4, child_after=3)
        active = 's'
        command(first, 'activate_template', test_id='r3.list.add')
        command(first, 'activate_template', test_id='r3.row.button', occurrence=0)
        assert query('r3.row', occurrence=0)['text'] == 'child 4'
        assert query('r3.row', occurrence=0)['matches'] == 3
        command(first, 'activate_template', test_id='r3.child.button')
        snap('s-inserted-before')
        index = len(records())
        list_edit = child_edit.replace(b'ListOriginal', b'ListChanged')
        remount.write_bytes(list_edit); applied = event_after(index, 'templates_applied')
        assert current()['pid'] == first['pid']
        assert query('r3.list.title')['text'] == 'ListChanged'
        assert query('r3.row', occurrence=0)['text'] == 'child 3' and query('r3.row', occurrence=0)['matches'] == 3
        assert query('r3.parent')['text'] == 'parent 8' and query('r3.child')['text'] == 'child 3'
        latency = presented_latency(applied, ['lp4.a']); snap('s-list-remounted')
        command(first, 'activate_template', test_id='r3.list.remove')
        assert query('r3.row', occurrence=0)['matches'] == 1
        snap('s-removed')
        cases['s'] = dict(status='PASS', detected_to_presented_ms=latency, parent=8, child_after=3)
        active = 'u'
        command(first, 'set_frame', text=json.dumps(dict(key='lp4.a', frame=dict(x=40, y=40, w=520, h=1000))))
        command(first, 'activate_template', test_id='lp5.slot.button')
        assert query('lp5.slot.value')['text'] == 'slot setup 12'
        snap('u-slot-before')
        slot_edit = originals[regions].replace(b'style={S.A}', b'style={S.B}').replace(b'<text>DefaultOriginal</text>', b'<row><text>DefaultChanged</text></row>').replace(b'<text>HeaderOriginal</text>', b'<col><text>HeaderChanged</text></col>')
        slot_latencies = []
        for round_index in range(3):
            selected = slot_edit if round_index % 2 == 0 else originals[regions]
            index = len(records()); regions.write_bytes(selected)
            applied = event_after(index, 'templates_applied')
            assert current()['pid'] == first['pid']
            assert query('lp5.slot.value')['text'] == 'slot setup 12'
            assert query('lp5.slot.body')['style_gap'] == (17 if round_index % 2 == 0 else 3)
            slot_latencies.append(presented_latency(applied, ['lp4.a']))
            snap('u-slot-'+str(round_index))
        cases['u'] = dict(status='PASS', detected_to_presented_ms=slot_latencies, state=12)
        active = 'v'
        command(first, 'activate_template', test_id='lp5.row.button', occurrence=0)
        assert query('lp5.row.value', occurrence=0)['text'] == 'row 6'
        snap('v-control-before')
        control_edit = slot_edit.replace(b'<text>RowOriginal</text>', b'<row><text>RowChanged</text></row>').replace(b'<text testId="lp5.if">IfOriginal</text>', b'<col><text testId="lp5.if">IfChanged</text></col>').replace(b'<text testId="lp5.match">MatchOriginal</text>', b'<box><text testId="lp5.match">MatchChanged</text></box>')
        index = len(records()); regions.write_bytes(control_edit)
        applied = event_after(index, 'templates_applied')
        assert current()['pid'] == first['pid']
        assert query('lp5.row.value', occurrence=0)['text'] == 'row 6'
        assert query('lp5.if')['text'] == 'IfChanged' and query('lp5.match')['text'] == 'MatchChanged'
        latency = presented_latency(applied, ['lp4.a']); snap('v-control-after')
        command(first, 'activate_template', test_id='lp5.list.add')
        assert query('lp5.row.value', occurrence=0)['matches'] == 3
        assert query('lp5.row.value', occurrence=0)['text'] == 'row 6'
        snap('v-keyed-add')
        command(first, 'activate_template', test_id='lp5.list.remove')
        assert query('lp5.row.value', occurrence=0)['matches'] == 1
        snap('v-keyed-remove')
        cases['v'] = dict(status='PASS', detected_to_presented_ms=latency, row_state=6)
        active = 'w'
        for _ in range(2): command(first, 'activate_template', test_id='lp5.left.button')
        command(first, 'activate_template', test_id='lp5.right.button')
        assert query('lp5.left')['text'] == 'row 7' and query('lp5.right')['text'] == 'row 6'
        snap('w-move-before')
        moved = control_edit.replace(b'<Row id="lp5.left" button="lp5.left.button"/><text>MoveDivider</text><Row id="lp5.right" button="lp5.right.button"/>', b'<row><Row id="lp5.right" button="lp5.right.button"/><box><Row id="lp5.left" button="lp5.left.button"/></box></row><text>MoveDivider</text>')
        move_latencies = []
        for round_index in range(3):
            index = len(records()); regions.write_bytes(moved if round_index % 2 == 0 else control_edit)
            applied = event_after(index, 'templates_applied')
            assert current()['pid'] == first['pid']
            assert query('lp5.left')['text'] == 'row 7' and query('lp5.right')['text'] == 'row 6'
            move_latencies.append(presented_latency(applied, ['lp4.a']))
            snap('w-move-'+str(round_index))
        cases['w'] = dict(status='PASS', detected_to_presented_ms=move_latencies, left=7, right=6)
        active = 'x'
        command(first, 'activate_template', test_id='lp5.portal.button')
        assert query('lp5.portal.value')['text'] == 'row 6'
        snap('x-portal-before')
        portal_latencies = []
        for round_index in range(3):
            selected = moved.replace(b'row {value}', b'portal {value}') if round_index % 2 == 0 else moved
            index = len(records()); regions.write_bytes(selected)
            applied = event_after(index, 'templates_applied')
            assert current()['pid'] == first['pid']
            assert query('lp5.portal.value')['text'] == ('portal 6' if round_index % 2 == 0 else 'row 6')
            portal_latencies.append(presented_latency(applied, ['lp4.a']))
            snap('x-portal-'+str(round_index))
        cases['x'] = dict(status='PASS', detected_to_presented_ms=portal_latencies, state=6)
        # Unsupported typed dispatcher/factory additions must report L3 before
        # mutation. Keep the launcher paused to observe the unchanged old process.
        for case, old_text, new_text in (
            ('y', b'{if (shown) <text>SingleBranch</text>}', b'{if (shown) <text>SingleBranch</text> else <text>AddedElse</text>}'),
            ('z', b'<text>MoveDivider</text>', b'<text>MoveDivider</text><Row id="new.receiver"/>')):
            active = case
            os.kill(process.pid, signal.SIGSTOP)
            baseline = regions.read_bytes()
            selected = baseline.replace(old_text, new_text)
            assert selected != baseline
            regions.write_bytes(selected)
            before_generation = query('lp5.portal.value')['generation']
            reply = command(first, 'reload_templates', files=['examples/template_probe/regions.yix'])
            assert reply['result'] == 'fallback', reply
            assert query('lp5.portal.value')['text'] == 'portal 6'
            assert query('lp5.portal.value')['generation'] == before_generation
            assert current()['pid'] == first['pid']
            snap(case+'-fallback-unchanged')
            regions.write_bytes(baseline)
            command(first, 'clear_error')
            os.kill(process.pid, signal.SIGCONT)
            cases[case] = dict(status='PASS', response=reply, old_tree_preserved=True)
        active = 't'
        os.kill(process.pid, signal.SIGSTOP)
        index = len(records())
        remount.write_bytes(list_edit.replace(b'RemountChanged', b'CommitFailure'))
        reply = command(first, 'reload_templates', files=['examples/template_probe/remount.yix'], fail_commit_at=0)
        assert reply['result'] == 'fallback' and reply['reason'] == 'TemplateCommitInjectedFailure', reply
        health = command(first, 'health')
        assert health['template_needs_remount'] and health['template_remount_reason'] == 'TemplateCommitInjectedFailure', health
        assert query('r3.parent')['text'] == 'parent 8'
        snap('t-needs-remount')
        old = first
        os.kill(process.pid, signal.SIGCONT)
        fallback = event_after(index, 'templates_fallback')
        first = wait_for(lambda:current() if current()['pid'] != old['pid'] else None, 240, process, 'commit failure L3')
        wait_for(lambda:not alive(old['pid']), 10, process, 'failed commit app retired')
        assert query('r3.parent')['text'] == 'parent 8'
        assert query('lp4.count')['text'] == 'value 9' and query('lp4.count.b')['text'] == 'value 20'
        assert not command(first, 'health')['template_needs_remount']
        snap('t-restored')
        cases['t'] = dict(status='PASS', response=reply, fallback=fallback['reason'], old_pid=old['pid'], new_pid=first['pid'], persist_restored=True)
        active = 'o'; command(first, 'close_preview_window', text=json.dumps(dict(key='lp4.a')))
        wait_for(lambda:command(first, 'health')['windows'] == 1, 5, process, 'owner A closed')
        index = len(records()); source.write_bytes(edited.replace(b'Changed', b'Survivor'))
        event_after(index, 'templates_applied')
        assert query('lp4.label.b')['text'] == 'Survivor' and query('lp4.count.b')['text'] == 'value 20'
        snap('o-survivor'); cases['o'] = dict(status='PASS', windows=1)
        active = 'p'; index = len(records())
        source.write_bytes(edited.replace(b'count += 1', b'count += 2'))
        fallback = event_after(index, 'templates_fallback')
        second = wait_for(lambda:current() if current()['pid'] != first['pid'] else None, 240, process, 'L3 unsupported edit')
        wait_for(lambda:not alive(first['pid']), 10, process, 'old app retired')
        snap('p-handoff'); command(second, 'quit')
        wait_for(lambda:not alive(second['pid']), 10, description='final graceful app exit')
        assert_clean_app_logs(session)
        cases['p'] = dict(status='PASS', reason=fallback['reason'], old_pid=first['pid'], new_pid=second['pid'])
    except BaseException as exc:
        cases[active] = dict(status='FAIL', reason=f'{type(exc).__name__}: {exc}')
    finally:
        if process and process.poll() is None:
            try:
                os.kill(process.pid, signal.SIGCONT)
                process.terminate(); process.wait(timeout=20)
            except BaseException:
                process.kill(); process.wait(timeout=5)
                cases[active] = dict(status='FAIL', reason='launcher cleanup failed')
        for path, data in originals.items(): restore_ok = restore_source(path, data) and restore_ok
        for sig, handler in previous.items(): signal.signal(sig, handler)
        log.close()
        try:
            assert_clean_app_logs(session)
            assert not [pid for pid in seen if alive(pid)], 'residual native child'
            assert all(e['exit_code'] == 0 for e in records() if e['event'] == 'retired')
        except BaseException as exc: cases[active] = dict(status='FAIL', reason=str(exc))
        report = dict(native=True, cases=cases, source_restored=restore_ok, seen_pids=sorted(seen),
            input='programmatic dev-control handlers; no native pointer/IME claim')
        atomic_json(evidence/'result.json', report); print(json.dumps(dict(evidence=str(evidence), **report), indent=2))
    return acceptance_exit(report, 'klmnopqrstuvwxyz')
if __name__ == '__main__': raise SystemExit(main())
