"""Positive fixture and corruption controls for the shared Notification gate."""
import json
from pathlib import Path
import struct
import tempfile
import unittest
import zipfile
from windows_shared_notification_frame_audit import audit, body_points, sample_point
from windows_shared_modal_frame_audit import LINEAR, srgb

class SharedNotificationAuditTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        self.make([0]+[.2,1,.2,0]*3)

    def make(self, alphas, fixed_colors=None):
        self.files={}
        logs=[]
        for i,a in enumerate(alphas):
            stem=f'shared-1-frame-{i:04d}'
            meta={'backend':'d3d12','animation_clock_step_ms':33,'window_id':1,'index':i,'frame_serial':i+1,'width':600,'height':160,'scale':1,
                  'frame_work_area':[0,0,600,160,600,160,0,0,600,160],'image':stem+'.bmp','tree':stem+'.tree.json','cursor':{'visible':False,'x':0,'y':0}}
            color=fixed_colors[a] if fixed_colors else round(srgb(LINEAR[245]+(LINEAR[251]-LINEAR[245])*a))
            data=bytes((color,color,color,255))*600*160
            bmp=b'BM'+struct.pack('<IHHI',54+len(data),0,0,54)+struct.pack('<IiiHHIIiiII',40,600,-160,1,32,0,len(data),0,0,0,0)+data
            children=[{'test_id':'story.notify.btn.warning'}]
            if a>0:
                children.append({'test_id':'story.notify.warning','effective_opacity':a,'rect':{'x':100,'y':20,'w':392,'h':68}})
            self.files[stem+'.json']=json.dumps(meta).encode()
            self.files[stem+'.tree.json']=json.dumps({'rect':{'x':0,'y':0,'w':600,'h':160},'children':children}).encode()
            self.files[stem+'.bmp']=bmp
            logs.append(f'[windows-shared-capture] window=1 index={i} serial={i+1}')
        (self.root/'windows-e2e-stderr.log').write_text('\n'.join(logs))
        self.save()

    def save(self):
        with zipfile.ZipFile(self.root/'windows-presented-frames.zip','w',compression=zipfile.ZIP_DEFLATED) as z:
            for name,value in self.files.items():z.writestr(name,value)

    def corrupt_pixel(self,index,x,y):
        name=f'shared-1-frame-{index:04d}.bmp'
        data=bytearray(self.files[name]);offset=54+(y*600+x)*4
        data[offset:offset+3]=b'\0\0\0';self.files[name]=data;self.save()

    def test_samples_follow_affine_frame_geometry(self):
        node = {'rect':{'x':0,'y':0,'w':392,'h':68}, 'world_transform':[.98,0,0,.98,125,387]}
        self.assertEqual(sample_point(node,80,7,1.75),(355,689))

    def test_offscreen_native_frame_rejected(self):
        name='shared-1-frame-0002.json'
        m=json.loads(self.files[name]);m['frame_work_area']=[10,0,600,160,600,160,0,0,600,160]
        self.files[name]=json.dumps(m).encode();self.save()
        with self.assertRaisesRegex(ValueError,'outside monitor work area'): audit(self.root)

    def test_padding_tracks_content_layout(self):
        node = {'rect':{'x':90,'y':40,'w':392,'h':80}, 'children':[{'tag':'text','rect':{'x':140,'y':58,'w':260,'h':20}}]}
        points = body_points(node)
        self.assertEqual(len(points),9)
        self.assertTrue(all(7 <= dy <= 11 for _,dy in points))
        node['children'][0]['rect']['y'] = 44
        with self.assertRaises(ValueError): body_points(node)

    def test_complete_cycles(self):
        self.assertTrue(audit(self.root)['passed'])

    def test_padding_ignores_descendants_of_hidden_controls(self):
        node = {'rect':{'x':90,'y':40,'w':392,'h':80}, 'children':[
            {'visible':False,'children':[{'children':[{'tag':'image','rect':{'x':95,'y':42,'w':14,'h':14}}]}]},
            {'tag':'text','rect':{'x':140,'y':58,'w':260,'h':20}},
        ]}
        self.assertEqual(body_points(node), body_points({'rect':node['rect'],'children':[node['children'][1]]}))
        node['children'][0]['visible'] = True
        with self.assertRaisesRegex(ValueError,'no blank body padding'): body_points(node)

    def test_black_intermediate_rejected(self):
        self.corrupt_pixel(1,178,46)
        r=audit(self.root)
        self.assertFalse(r['passed']);self.assertGreater(r['max_channel_error'],200)

    def test_closed_residue_rejected(self):
        self.corrupt_pixel(12,300,50)
        r=audit(self.root)
        self.assertFalse(r['passed']);self.assertEqual(r['closed_max_channel_error'],245)

    def test_missing_image_rejected(self):
        del self.files['shared-1-frame-0001.bmp'];self.save()
        with self.assertRaises(KeyError):audit(self.root)

    def test_endpoint_only_rejected(self):
        self.make([0]+[1,0]*3)
        r=audit(self.root)
        self.assertFalse(r['passed']);self.assertEqual(r['entry_intermediates'],0)

    def test_native_encoded_unorm_blend_reference(self):
        # Native GPU readback independently fixes half-opacity 240 over 32 to 136.
        self.make([0]+[.5,1,.5,0]*3, {0:32,.5:136,1:240})
        r=audit(self.root)
        self.assertTrue(r['passed']);self.assertEqual(r['max_channel_error'],0)

    def test_missing_work_area_rejected(self):
        name='shared-1-frame-0002.json';m=json.loads(self.files[name]);del m['frame_work_area']
        self.files[name]=json.dumps(m).encode();self.save()
        with self.assertRaisesRegex(ValueError,'missing native'):audit(self.root)

    def test_one_pixel_viewport_mismatch_rejected(self):
        name='shared-1-frame-0002.tree.json';m=json.loads(self.files[name]);m['rect']['w']=599
        self.files[name]=json.dumps(m).encode();self.save()
        with self.assertRaisesRegex(ValueError,'viewport/drawable'):audit(self.root)

    def test_missing_clock_evidence_rejected(self):
        name='shared-1-frame-0002.json';m=json.loads(self.files[name]);del m['animation_clock_step_ms']
        self.files[name]=json.dumps(m).encode();self.save()
        with self.assertRaises(ValueError):audit(self.root)

    def test_serial_gap_rejected(self):
        name='shared-1-frame-0001.json';m=json.loads(self.files[name]);m['frame_serial']=50
        self.files[name]=json.dumps(m).encode();self.save()
        with self.assertRaises(ValueError):audit(self.root)

if __name__=='__main__':unittest.main()
