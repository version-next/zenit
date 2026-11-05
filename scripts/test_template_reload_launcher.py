#!/usr/bin/env python3
"""L2 routing and source-race contracts, without GUI/builds."""
import math
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from preview import Inputs, Preview, parse_args, route_template_changes
class Routing(unittest.TestCase):
    def test_template_only_and_conservative_mixed_routing(self):
        for paths, layer in [(['src/a.yix'], 'L2'), (['a.yix', 'b.yix'], 'L2'),
                             (['a.yix', '_a.yix.zig'], 'L3'), (['a.yix', 'a.yss'], 'L3'),
                             (['../a.yix'], 'L3'), (['/a.yix'], 'L3'), ([], 'L3'), (['a.yss'], 'L1')]:
            self.assertEqual(layer, route_template_changes(paths)['layer'])
    def test_fast_poll_tracks_template_contents_deletion_and_revert(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root/'src').mkdir()
            path = root/'src/a.yix'; path.write_text('A')
            inputs = Inputs(root); initial = inputs.snapshot()
            self.assertEqual([path], inputs.template_paths())
            path.write_text('B'); self.assertNotEqual(initial, inputs.refresh(inputs.reloadable_paths()))
            path.write_text('A'); self.assertEqual(initial, inputs.refresh(inputs.reloadable_paths()))
            path.unlink(); self.assertNotEqual(initial, inputs.refresh(inputs.reloadable_paths()))
class Reload(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.p = Preview(parse_args(['storybook', '--root', str(self.root)]))
        self.p.check_ownership = Mock(); self.p.show_error = Mock()
        self.p.inputs.refresh = Mock(return_value='new'); self.p.inputs.template_paths = Mock(return_value=[])
        self.p.current = {'pid':123}; self.p.source_inputs = {self.root/'a.yix':b'A'}
        self.new = {self.root/'a.yix':b'B'}
        self.events = []; self.p.event = lambda name, **kw:self.events.append(dict(event=name, **kw))
    def run_reply(self, reply):
        self.p.command = Mock(return_value=reply)
        return self.p.reload_templates('new', self.new, ['a.yix'], time.monotonic())
    def test_apply_uses_same_pid_and_retains_online_audit(self):
        self.assertTrue(self.run_reply(dict(result='applied', generation=3, elapsed_ms=2)))
        self.assertEqual(self.new, self.p.source_inputs); self.assertEqual(123, self.p.current['pid'])
        self.assertEqual({'a.yix'}, self.p.online_files); self.assertEqual(3, self.p.state['template_generation'])
        self.assertEqual('L2', self.events[-1]['layer'])
    def test_error_and_fallback_do_not_bless_sources(self):
        before = self.p.source_inputs.copy()
        self.assertTrue(self.run_reply(dict(result='error', diagnostic='a.yix:2: bad')))
        self.assertEqual(before, self.p.source_inputs)
        self.assertFalse(self.run_reply(dict(result='fallback', reason='TemplateHoleChanged')))
        self.assertEqual(before, self.p.source_inputs); self.assertEqual('L3', self.events[-1]['layer'])
    def test_stale_response_retries_even_after_revert(self):
        self.p.inputs.refresh.return_value = 'reverted'
        self.assertTrue(self.run_reply(dict(result='applied', generation=1, elapsed_ms=2)))
        self.assertEqual({'a.yix'}, self.p.pending_template_files)
        self.assertEqual('templates_discarded', self.events[-1]['event'])
        self.assertEqual('L2', self.p.route(self.p.source_inputs)['layer'])
    def test_protocol_timeout_and_nonfinite_apply_use_l3(self):
        for reply in ({}, dict(result='applied', generation=True, elapsed_ms=1), dict(result='applied', generation=1, elapsed_ms=math.nan)):
            self.assertFalse(self.run_reply(reply))
        self.p.command = Mock(side_effect=TimeoutError())
        self.assertFalse(self.p.reload_templates('new', self.new, ['a.yix'], time.monotonic()))
if __name__ == '__main__': unittest.main()
