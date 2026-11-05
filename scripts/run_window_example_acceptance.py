#!/usr/bin/env python3
"""Accept m97vV geometry and real window behavior through Zenit's Harness."""
import argparse, hashlib, json, os, subprocess, sys, time, uuid
from pathlib import Path

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--binary',type=Path,required=True);ap.add_argument('--evidence-dir',type=Path,required=True);args=ap.parse_args()
    out=args.evidence_dir.resolve();out.mkdir(parents=True,exist_ok=False);rpc_dir=out/'rpc';rpc_dir.mkdir()
    results={'passed':False,'binary_sha256':hashlib.sha256(args.binary.read_bytes()).hexdigest(),'checks':[]}
    env=os.environ.copy();env.update(ZENIT_E2E_FILE_RPC_DIR=str(rpc_dir),ZENIT_E2E_ISOLATE_POINTER='1')
    with (out/'app.log').open('w') as log:
        p=subprocess.Popen([str(args.binary.resolve())],env=env,stdout=log,stderr=subprocess.STDOUT)
        def rpc(path,body=None):
            key=uuid.uuid4().hex;tmp=rpc_dir/('req-'+key+'.tmp');tmp.write_text(json.dumps({'method':'POST','path':path,'body_json':json.dumps(body or {})}));tmp.rename(rpc_dir/('req-'+key+'.json'))
            response=rpc_dir/('res-'+key+'.json');deadline=time.monotonic()+30
            while not response.exists():
                if p.poll() is not None:raise RuntimeError('app exited: '+str(p.returncode))
                if time.monotonic()>deadline:raise RuntimeError('RPC timeout '+path)
                time.sleep(.01)
            data=json.loads(response.read_text());response.unlink()
            if isinstance(data,dict) and data.get('error'):raise RuntimeError(path+': '+str(data))
            return data
        def check(name,ok,data):
            results['checks'].append({'name':name,'passed':bool(ok),'observed':data})
            if not ok:raise AssertionError(name)
        def query(id):return [n for n in rpc('/query',{'test_id':id}) if n['rect']['w']>0 and n['rect']['h']>0]
        def click(id):
            rect=query(id)[0]['rect'];rpc('/click',{'x':rect['x']+rect['w']/2,'y':rect['y']+rect['h']/2})
        def descendants(node):
            yield node
            for child in node.get('children',[]):yield from descendants(child)
        def wait_state(field,value):
            deadline=time.monotonic()+12
            while True:
                s=rpc('/window-state')
                if s[field]==value or time.monotonic()>deadline:return s
                time.sleep(.05)
        try:
            initial=rpc('/window-state');rpc('/resize',{'width':1500,'height':1040});time.sleep(.3)
            geometry={}
            for name in ['macos','windows','windows-max','gnome','ubuntu','kde','left','fallback','narrow720','narrow640','narrow520']:
                header=query('preview.'+name+'.header')[0];r=header['rect'];geometry[name]=r
                check(name+'-38px-header',abs(r['h']-38)<.01,r)
                drag=query('preview.'+name+'.drag')[0]['rect'];check(name+'-drag-minimum',drag['w']>=159.99,drag)
                check(name+'-drag-fills-header-height',abs(drag['h']-r['h'])<.01 and abs(drag['y']-r['y'])<.01,drag)
                if name=='macos':check('macos-preview-has-no-painted-caption',not any(n.get('test_id','').startswith('window.controls') and n['rect']['w'] for n in descendants(header)),r)
                if name in ['windows','windows-max','ubuntu','gnome','kde']:
                    button=query('preview.'+name+'.close')[0];br=button['rect'];expected=0 if name.startswith('windows') else 10 if name=='kde' else 8
                    check(name+'-right-caption-inset',abs(r['x']+r['w']-br['x']-br['w']-expected)<.02,br)
                    glyph=next(n for n in descendants(button) if n['tag']=='image')['rect']
                    check(name+'-caption-glyph-centered',abs(glyph['x']+glyph['w']/2-br['x']-br['w']/2)<.02 and abs(glyph['y']+glyph['h']/2-br['y']-br['h']/2)<.02,glyph)
            (out/'geometry.json').write_text(json.dumps(geometry,indent=2))
            rpc('/screenshot',{'path':str(out/'gallery.png')})
            # Preview action must leave the real native window untouched.
            before=rpc('/window-state');click('preview.windows.maximize');after=rpc('/window-state');check('preview-does-not-maximize-real-window',before['maximized']==after['maximized'],after)
            click('window.maximize');s=wait_state('maximized',True);check('native-maximize',s['maximized'],s)
            click('window.maximize');s=wait_state('maximized',False);check('native-restore',not s['maximized'],s)
            rpc('/key_down',{'key':'f11'});s=wait_state('fullscreen',True);s=wait_state('fullscreen_transitioning',False);check('F11-native-fullscreen',s['fullscreen'] and not s['fullscreen_transitioning'],s)
            rpc('/mouse_move',{'x':400,'y':1});time.sleep(.45)
            s=rpc('/window-state');check('fullscreen-platform-header-policy',not s['revealed'] if sys.platform=='darwin' else s['revealed'],s)
            rpc('/key_down',{'key':'f11'});s=wait_state('fullscreen',False);s=wait_state('fullscreen_transitioning',False);check('F11-restore-without-reusing-destroyed-header',not s['fullscreen'] and not s['fullscreen_transitioning'] and query('window.header')[0]['rect']['h']==38,s)
            if sys.platform!='darwin':
                rpc('/key_down',{'key':'Alt'});rpc('/key_up',{'key':'Alt'});check('Alt-release-temporary-menu',rpc('/window-state')['menu'],rpc('/window-state'))
                rpc('/key_down',{'key':'escape'});check('Escape-dismiss-menu',not rpc('/window-state')['menu'],rpc('/window-state'))
            rpc('/screenshot',{'path':str(out/'restored.png')})
            # "Try" opens a real window for presets that match this desktop and is
            # disabled for the others. The Harness follows the newest window once
            # one is open, so this is the last interaction with the gallery.
            fits={'darwin':{'macos','fallback'},'win32':{'windows','windows-max','fallback','narrow720','narrow640','narrow520'},'linux':{'gnome','ubuntu','kde','left','fallback'}}[sys.platform]
            for name in ['macos','windows','windows-max','gnome','ubuntu','kde','left','fallback','narrow720','narrow640','narrow520']:
                check(name+'-try-button',bool(query('preview.'+name+'.try')),name)
            before=rpc('/window-state')['windows']
            disabled=next(n for n in ['macos','windows','gnome'] if n not in fits)
            click('preview.'+disabled+'.try');time.sleep(.6)
            check('try-disabled-preset-opens-nothing',rpc('/window-state')['windows']==before,rpc('/window-state'))
            enabled=next(n for n in ['macos','windows','gnome','fallback'] if n in fits)
            click('preview.'+enabled+'.try')
            deadline=time.monotonic()+8
            while rpc('/window-state')['windows']<before+1 and time.monotonic()<deadline:time.sleep(.1)
            check('try-'+enabled+'-opens-real-window',rpc('/window-state')['windows']==before+1,rpc('/window-state'))
            time.sleep(.5);rpc('/screenshot',{'path':str(out/'try-window.png')})
            results['passed']=True
        except Exception as err:results['error']=str(err)
        finally:
            if p.poll() is None:p.terminate();p.wait(timeout=10)
    (out/'results.json').write_text(json.dumps(results,indent=2));print(json.dumps(results,indent=2));return 0 if results['passed'] else 1
if __name__=='__main__':raise SystemExit(main())
