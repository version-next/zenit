#!/usr/bin/env python3
"""Native LP2 f-j acceptance using dev-control file commands exclusively.

Requires Metal/window server. No fixture mode: startup failure is a failure.
Every changed source and generated companion is restored byte-for-byte in finally.
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
from test_preview import wait_for, alive, command, capture, route, restore_source, native_screenshot, assert_clean_app_logs, acceptance_exit
from preview import read_json, atomic_json
ROOT=Path(__file__).resolve().parents[1]

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zig',default='zig');parser.add_argument('--evidence',type=Path,required=True)
    args=parser.parse_args();args.evidence.mkdir(parents=True,exist_ok=True)
    evidence=Path(tempfile.mkdtemp(prefix='lp2-',dir=args.evidence.resolve()))
    style=ROOT/'src/ui/components/card/styles.yss';theme=ROOT/'examples/theme.json'
    paths=[style,style.with_name('_styles.yss.zig'),theme]
    originals={p:p.read_bytes() for p in paths}
    cases={k:dict(status='FAIL',reason='case not reached') for k in 'fghij'}
    session=evidence/'session';session.mkdir();process=None;active='f';seen=set();start=time.monotonic()
    log=(evidence/'launcher.log').open('w');restore_ok=True
    previous={}
    def records():
        path=session/'events.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
    def interrupted(signum,_): raise KeyboardInterrupt(f'signal {signum}')
    for name in ('SIGTERM','SIGHUP'):
        if hasattr(signal,name):
            sig=getattr(signal,name);previous[sig]=signal.signal(sig,interrupted)
    try:
        process=subprocess.Popen([sys.executable,str(ROOT/'tools/preview.py'),'storybook','--root',str(ROOT),
            '--stories','card','--story','card','--zig',args.zig,'--session-root',str(session),
            '--ready-timeout','15','--poll','.01'],stdout=log,stderr=subprocess.STDOUT,env=dict(os.environ,ZENIT_GLASS_CLOCK_TRACE='1'))
        def current():
            state=read_json(session/'state.json') or {};value=state.get('current')
            if value: seen.add(value['pid'])
            if not value and state.get('event')=='error': raise RuntimeError('native startup failed: '+state.get('error','unknown'))
            return value
        first=wait_for(current,180,process,'initial native ready')
        def event_after(index,name):
            return wait_for(lambda:next((r for r in records()[index:] if r['event']==name),None),180,process,name)
        def query(): return command(current(),'query_style',test_id='story.card.basic')
        def values(q): return {k:v for k,v in q.items() if k not in ('generation','test_id')}
        def snapshot(tag):
            value=capture(current());atomic_json(evidence/(tag+'-snapshot.json'),value)
            atomic_json(evidence/(tag+'-style.json'),query())
            native_screenshot(evidence/(tag+'.png'));return value
        def stable_state(before,after):
            assert route(before)==route(after)=='card',(before,after)
            assert before['windows'][0]['scroll']==after['windows'][0]['scroll'],(before,after)
        def wait_color(hexvalue):
            expected=dict(zip('rgba',[(hexvalue>>16)&255,(hexvalue>>8)&255,hexvalue&255,255]))
            def check():
                result=query();color=result['background']
                # ui.Color channels are unsigned bytes.
                if all(color[k]==v for k,v in expected.items()): return result
            return wait_for(check,5,process,'resolved color')
        # Put the actual scroll container at a discriminating nonzero offset.
        initial=capture(first);frame=dict(initial['windows'][0]['frame'],w=850,h=600)
        command(first,'set_frame',text=json.dumps(dict(key='storybook.main',frame=frame)))
        command(first,'set_scroll',text=json.dumps(dict(key='storybook.content',x=0,y=120)))
        before=snapshot('f-before')
        scroll=next(x for x in before['windows'][0]['scroll'] if x['key']=='storybook.content')
        assert scroll['y']>0,'card story must have nonzero test scroll'
        original_query=query();original_values=values(original_query)
        needle=b'flag selected { background: bg-primary;'
        assert originals[style].count(needle)==1,'Card selected rule changed'
        edited=originals[style].replace(needle,b'flag selected { background: #1267ab;')
        index=len(records());style.write_bytes(edited)
        applied=event_after(index,'styles_applied');changed=wait_color(0x1267ab)
        assert current()['pid']==first['pid']
        assert applied['layer']=='L1' and applied['detected_to_applied_ms']<100,applied
        def presented_latency(applied_event):
            generation=applied_event['style_generation']
            def submitted():
                frames=command(first,'health').get('style_frames',[])
                return next((f for f in frames if f['key']=='storybook.main' and f['generation']==generation and f['frame']>0),None)
            frame=wait_for(submitted,5,process,'first submitted style frame')
            def trace():
                entries=[]
                for line in (Path(first['directory'])/'app.log').read_text(errors='replace').splitlines():
                    if '[glass-clock] {' in line:
                        try:entries.append(json.loads(line.split('[glass-clock] ',1)[1]))
                        except json.JSONDecodeError:pass
                # Metal reports presentedTime=0 for a drawable that never reached the
                # display (occluded/skipped). The new style is on screen at the first
                # frame at or after the submitted one that was actually presented.
                return next((e for e in entries if e.get('kind')=='presented' and e.get('frame',-1)>=frame['frame'] and e.get('presented_time',0)>0),None)
            presented=wait_for(trace,5,process,'Metal drawable presented time')
            ms=(presented['presented_time']-applied_event['detected_monotonic_s'])*1000
            assert 0<=ms<100,dict(presented_ms=ms,frame=frame,trace=presented)
            atomic_json(evidence/'f-presented.json',dict(frame=frame,trace=presented,detected_to_presented_ms=ms,parse_ms=applied_event.get('parse_ms'),apply_ms=applied_event.get('apply_ms')))
            return ms
        present_ms=presented_latency(applied)
        stable_state(before,snapshot('f-after'))
        cases['f']=dict(status='PASS',pid=first['pid'],detected_to_applied_ms=applied['detected_to_applied_ms'],
                        detected_to_presented_ms=present_ms)
        active='h';index=len(records());style.write_bytes(edited+b'\nstyle broken { padding: ; }\n')
        error=event_after(index,'styles_error')
        wait_for(lambda:command(first,'health').get('error_overlay'),5,process,'syntax overlay')
        assert values(query())==values(changed),'syntax failure changed live style'
        assert current()['pid']==first['pid'];snapshot('h-error')
        index=len(records());fixed=edited.replace(b'#1267ab',b'#ab6712');style.write_bytes(fixed)
        event_after(index,'styles_applied');wait_color(0xab6712)
        wait_for(lambda:not command(first,'health').get('error_overlay'),5,process,'error cleared')
        snapshot('h-fixed');cases['h']=dict(status='PASS',diagnostic=error['diagnostic'])
        active='i';index=len(records());token_needle=b'"panel": 8'
        assert originals[theme].count(token_needle)==1,'panel radius token changed'
        theme.write_bytes(originals[theme].replace(token_needle,b'"panel": 11'))
        token_event=event_after(index,'styles_applied')
        wait_for(lambda:query()['corner_radius']==11,5,process,'token radius')
        assert current()['pid']==first['pid'];snapshot('i-token')
        cases['i']=dict(status='PASS',pid=first['pid'],detected_to_applied_ms=token_event['detected_to_applied_ms'])
        active='j';index=len(records());style.write_bytes(originals[style]);theme.write_bytes(originals[theme])
        event_after(index,'styles_applied')
        wait_for(lambda:values(query())==original_values,5,process,'A B A exact style')
        assert current()['pid']==first['pid'];stable_state(before,snapshot('j-returned'))
        cases['j']=dict(status='PASS',initial=original_values,returned=values(query()))
        active='g'
        # Re-establish a discriminating, non-default state right before the shape
        # edit so the handoff has something real to restore.
        command(first,'set_frame',text=json.dumps(dict(key='storybook.main',frame=frame)))
        command(first,'set_scroll',text=json.dumps(dict(key='storybook.content',x=0,y=120)))
        index=len(records())
        shape=originals[style].replace(b'    direction: column;',b'    direction: column;\n    :hover { background: #ab6712; }',1)
        assert shape!=originals[style];style.write_bytes(shape)
        fallback=event_after(index,'styles_fallback');assert fallback['reason']=='conditions',fallback
        def handed_off():
            value=current();return value if value and value['pid']!=first['pid'] else None
        second=wait_for(handed_off,180,process,'L3 handoff after shape change')
        wait_for(lambda:not alive(first['pid']),10,process,'old process retired')
        # A handoff restores the state the old process had *at handoff time* (the
        # snapshot the launcher pinned for the candidate), not the state from case f:
        # anything may legitimately move the window or scroll in between.
        after_handoff=snapshot('g-handoff')
        pinned=sorted(session.glob('generation-*/restore.json'),key=lambda p:p.stat().st_mtime)
        assert pinned,'launcher did not pin a restore snapshot for the candidate'
        used=json.loads(pinned[-1].read_text())
        assert route(used)==route(after_handoff)=='card',(used,after_handoff)
        assert used['windows'][0]['scroll']==after_handoff['windows'][0]['scroll'],(used,after_handoff)
        assert used['windows'][0]['frame']==after_handoff['windows'][0]['frame'],(used,after_handoff)
        # The pinned snapshot must carry the discriminating state set just before g.
        assert any(x['key']=='storybook.content' and x['y']>0 for x in used['windows'][0]['scroll']),used
        # Exercise real application teardown/GPA on the final process too.
        # The supervisor reports an intentionally closed current app as exit 1.
        command(second,'quit')
        wait_for(lambda:not alive(second['pid']),10,description='final app graceful exit')
        assert process.wait(timeout=10)==1, 'supervisor did not observe current exit'
        exits=[r for r in records() if r['event']=='current_exited']
        assert exits and exits[-1]['exit_code']==0, exits
        assert_clean_app_logs(session)
        cases['g']=dict(status='PASS',reason=fallback['reason'],old_pid=first['pid'],new_pid=second['pid'])
    except BaseException as exc:
        cases[active]=dict(status='FAIL',reason=f'{type(exc).__name__}: {exc}')
    finally:
        try:
            if process and process.poll() is None:
                process.terminate()
                try:
                    assert process.wait(timeout=20)==0, 'launcher shutdown failed'
                except subprocess.TimeoutExpired:
                    process.kill();process.wait(timeout=5)
                    raise RuntimeError('launcher shutdown timed out')
        except BaseException as exc:
            cases[active]=dict(status='FAIL',reason=f'cleanup: {type(exc).__name__}: {exc}')
        finally:
            for path,data in originals.items(): restore_ok=restore_source(path,data) and restore_ok
        for sig,handler in previous.items():signal.signal(sig,handler)
        log.close()
        try:
            assert_clean_app_logs(session)
            residual=[pid for pid in seen if alive(pid)]
            assert not residual, f'residual app children: {residual}'
            retired=[r for r in records() if r['event']=='retired']
            assert all(r['exit_code']==0 for r in retired), retired
        except Exception as exc:
            cases[active]=dict(status='FAIL',reason=f'{type(exc).__name__}: {exc}')
        report=dict(cases=cases,source_restored=restore_ok,seen_pids=sorted(seen),elapsed_s=time.monotonic()-start,
                    native=True,presentation_latency='f requires a correlated Metal drawable presented callback',hardware=os.uname().machine if hasattr(os,'uname') else os.name)
        atomic_json(evidence/'result.json',report)
        print(json.dumps(dict(evidence=str(evidence),**report),indent=2))
    return acceptance_exit(report, 'fghij')
if __name__=='__main__':raise SystemExit(main())
