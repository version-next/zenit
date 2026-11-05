#!/usr/bin/env python3
"""LP2 routing and protocol failures; no GPU and no Zig builds."""
import math
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock, patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from preview import Inputs, Preview, parse_args, route_style_changes

class Routing(unittest.TestCase):
    def test_value_files_twins_mixed_and_external(self):
        cases = [(['src/a.yss'], (), 'L1'), (['examples/theme.json'], (), 'L1'), (['src/tokens/default.json'], (), 'L1'), (['other/default.json'], (), 'L3'),
                 (['src/a.yss', 'src/_a.yss.zig'], (), 'L3'),
                 (['src/_a.yss.zig'], ('src/a.yss',), 'L3'),
                 (['src/_a.yss.zig'], (), 'L3'),
                 (['src/a.yss', 'src/a.zig'], (), 'L3'),
                 (['src/a.yss', 'src/a.yix'], (), 'L3'),
                 (['src/a.yss', 'asset.png'], (), 'L3'),
                 (['../a.yss'], (), 'L3'), (['/tmp/a.yss'], (), 'L3'), ([], (), 'L3')]
        for paths, online, layer in cases:
            with self.subTest(paths=paths): self.assertEqual(layer, route_style_changes(paths)['layer'])
    def test_online_source_never_exempts_generated_zig(self):
        route = route_style_changes(['src/_foo.yss.zig'])
        self.assertEqual('L3', route['layer'])
        self.assertEqual([], route['files'])
        self.assertEqual('L3', route_style_changes(['src/_foo.yss.zig', 'src/_x.yix.zig'])['layer'])

class FastStylePolling(unittest.TestCase):
    """Between throttled full scans only reloadable style inputs are re-stat'd."""
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'src').mkdir()
        self.style = self.root / 'src' / 'a.yss'; self.style.write_text('style a { gap: space100; }')
        self.zig = self.root / 'src' / 'a.zig'; self.zig.write_text('// a')
        self.inputs = Inputs(self.root)
        self.base = self.inputs.snapshot()
    def test_style_edit_is_seen_by_refresh(self):
        self.assertEqual([self.style], self.inputs.style_paths())
        self.style.write_text('style a { gap: space200; }')
        self.assertNotEqual(self.base, self.inputs.refresh(self.inputs.style_paths()))
    def test_default_tokens_are_fast_polled(self):
        tokens = self.root / 'src/tokens/default.json'
        tokens.parent.mkdir(); tokens.write_text('{}')
        before = self.inputs.snapshot()
        self.assertIn(tokens, self.inputs.style_paths())
        tokens.write_text('{"changed": true}')
        self.assertNotEqual(before, self.inputs.refresh(self.inputs.style_paths()))
    def test_external_inputs_do_not_require_checkout_relative_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            external = Path(directory).resolve()
            zig = external / 'dep.zig'; zig.write_text('// dependency')
            style = external / 'dep.yss'; style.write_text('style x { gap: 1; }')
            inputs = Inputs(self.root, [external])
            inputs.snapshot()
            self.assertIn(zig, inputs.contents())
            self.assertIn(style, inputs.style_paths())
            self.assertEqual('L3', route_style_changes([str(style)])['layer'])
    def test_unchanged_refresh_reuses_digest_and_other_inputs_wait_for_full_scan(self):
        self.assertEqual(self.base, self.inputs.refresh(self.inputs.style_paths()))
        self.zig.write_text('// b')
        self.assertEqual(self.base, self.inputs.refresh(self.inputs.style_paths()))
        self.assertNotEqual(self.base, self.inputs.snapshot())
    def test_new_style_file_needs_full_scan_and_deleted_style_drops_out(self):
        new = self.root / 'src' / 'b.yss'; new.write_text('style b { gap: space100; }')
        self.assertEqual(self.base, self.inputs.refresh(self.inputs.style_paths()))
        after_scan = self.inputs.snapshot()
        self.assertIn(new, self.inputs.style_paths())
        new.unlink()
        self.assertNotEqual(after_scan, self.inputs.refresh(self.inputs.style_paths()))
        self.assertNotIn(new, self.inputs.contents())

class Reload(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.p = Preview(parse_args(['storybook', '--root', str(self.root)]))
        self.p.check_ownership = Mock()
        self.p.inputs.snapshot = Mock(return_value='new')
        # reload_styles re-checks only the style inputs after the reply.
        self.p.inputs.refresh = Mock(side_effect=lambda paths: self.p.inputs.snapshot())
        self.p.inputs.style_paths = Mock(return_value=[])
        self.p.show_error = Mock()
        self.events=[]; self.p.event=lambda name, **kw:self.events.append(dict(event=name, **kw))
        self.p.current={'pid':123}; self.p.source_inputs={self.root/'a.yss': b'A'}
        self.p.compiled_inputs=dict(self.p.source_inputs)
        self.new={self.root/'a.yss': b'B'}
    def run_reply(self, reply):
        self.p.command=Mock(side_effect=lambda _, name, **kw: reply if name=='reload_styles' else {'ok':True})
        return self.p.reload_styles('new', self.new, ['a.yss'], time.monotonic())
    def test_spawn_uses_checkout_cwd_from_another_directory(self):
        import os
        previous = Path.cwd()
        try:
            os.chdir(self.root.parent)
            with patch('preview.Child') as child:
                self.p.spawn(['app'], self.root / 'app.log')
            self.assertEqual(self.root.resolve(), child.call_args.kwargs['cwd'])
        finally:
            os.chdir(previous)
    def test_deleted_source_fallback_requests_l3(self):
        self.assertFalse(self.run_reply(dict(result='fallback', reason='source_deleted')))
        self.assertEqual('L3', self.events[-1]['layer'])
        self.assertEqual('source_deleted', self.events[-1]['reason'])
    def test_applied_preserves_process_and_uncompiled_source(self):
        self.assertTrue(self.run_reply(dict(result='applied', generation=4, elapsed_ms=1.5)))
        self.assertEqual(123,self.p.current['pid']); self.assertEqual({'a.yss'},self.p.online_files)
        self.assertEqual(self.new,self.p.source_inputs)
        self.assertEqual(b'A',self.p.compiled_inputs[self.root/'a.yss'])
        self.assertEqual('L1',self.events[-1]['layer']); self.assertGreaterEqual(self.events[-1]['detected_to_applied_ms'],0)
    def test_error_keeps_old_source_and_process(self):
        before=dict(self.p.source_inputs)
        self.assertTrue(self.run_reply(dict(result='error',diagnostic='a.yss:2: bad syntax')))
        self.assertEqual(before,self.p.source_inputs); self.assertEqual(123,self.p.current['pid'])
        self.p.show_error.assert_called_once(); self.assertEqual('styles_error',self.events[-1]['event'])
    def test_shape_fallback_and_timeout_request_l3(self):
        self.assertFalse(self.run_reply(dict(result='fallback',reason='conditions')))
        self.assertEqual('conditions',self.events[-1]['reason'])
        self.p.command=Mock(side_effect=TimeoutError('stalled'))
        self.assertFalse(self.p.reload_styles('new',self.new,['a.yss'],time.monotonic()))
        self.assertEqual('L3',self.events[-1]['layer'])
    def test_malformed_and_nonfinite_success_do_not_claim_application(self):
        for reply in [{}, {'result':'wat'}, {'result':'applied','generation':True,'elapsed_ms':1},
                      {'result':'applied','generation':1,'elapsed_ms':math.nan},
                      {'result':'applied','generation':1,'elapsed_ms':-1}]:
            with self.subTest(reply=reply): self.assertFalse(self.run_reply(reply))
        self.assertEqual(set(),self.p.online_files)
    def test_stale_response_and_revert_stay_dirty(self):
        self.p.inputs.snapshot.return_value='reverted'
        before=dict(self.p.source_inputs)
        self.assertTrue(self.run_reply(dict(result='applied',generation=8,elapsed_ms=2)))
        self.assertEqual(before,self.p.source_inputs); self.assertEqual({'a.yss'},self.p.pending_style_files)
        route=self.p.route(before)
        self.assertEqual('L1',route['layer']); self.assertEqual(['a.yss'],route['files'])
    def test_pending_zig_is_not_hidden_by_later_style_save(self):
        self.p.source_inputs[self.root/'logic.zig']=b'old'
        after=dict(self.p.source_inputs);after[self.root/'logic.zig']=b'new';after[self.root/'a.yss']=b'new'
        self.assertEqual('L3',self.p.route(after)['layer'])

if __name__=='__main__': unittest.main()
