#!/usr/bin/env python3
"""Measurement regressions; fake OS sampling keeps these portable/headless."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location('measure_usage_contract', Path(__file__).with_name('measure_usage.py'))
usage = importlib.util.module_from_spec(spec)
with patch.dict(sys.modules, {'measure_footprint': types.SimpleNamespace(rusage=lambda pid: None, MIB=1024**2)}):
    spec.loader.exec_module(usage)


class MeasurementContract(unittest.TestCase):
    def workload(self, workload):
        now = [0.0]
        def sleep(seconds):
            now[0] += seconds
        rpc = Mock(return_value={'frame_count': 10, 'ok': True})
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as directory, contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(sys, 'argv', ['measure_usage', 'fake-app', '--workload', workload,
                                '--duration', '1', '--scroll-hz', '10', '--settle', '0', '--after', '0']))
            stack.enter_context(patch.object(usage.tempfile, 'mkdtemp', return_value=directory))
            stack.enter_context(patch.object(usage, 'Rpc', return_value=rpc))
            stack.enter_context(patch.object(usage.subprocess, 'Popen'))
            stack.enter_context(patch.object(usage.subprocess, 'run', return_value=types.SimpleNamespace(stdout='')))
            stack.enter_context(patch.object(usage.time, 'monotonic', side_effect=lambda: now[0]))
            stack.enter_context(patch.object(usage.time, 'sleep', side_effect=sleep))
            stack.enter_context(contextlib.redirect_stdout(output))
            usage.main()
        return json.loads(output.getvalue()), rpc

    def test_stream_request_count_survives_sampling_loop(self):
        result, rpc = self.workload('scroll')
        requests = [c for c in rpc.call_args_list if c.args[1] == '/scroll_stream']
        self.assertEqual(len(requests), 1)
        self.assertEqual(result['events'], requests[0].args[2]['count'])
        self.assertEqual(result['events'], 10)
        self.assertEqual(result['events_basis'], 'requested_stream_events')

    def test_idle_sampling_is_not_input(self):
        result, _ = self.workload('idle')
        self.assertEqual(result['events'], 0)

    def trace(self, events):
        with tempfile.NamedTemporaryFile(mode='w') as f:
            for event in events:
                f.write('[glass-clock] ' + json.dumps(event) + '\n')
            f.flush()
            return usage.cadence(f.name, 1, 2, period_hint=1000/60)

    def test_empty_trace_cannot_validate_presentation(self):
        self.assertFalse(self.trace([])['valid'])

    def test_actual_gpu_frames_remain_separate_from_estimated_updates(self):
        result = self.trace([{'kind': 'presented', 'presented_time': t} for t in (1.1, 1.2)] +
                            [{'kind': 'patch', 'host_time': 1.4}, {'kind': 'unchanged', 'host_time': 1.6}])
        self.assertEqual(result['gpu_presented_fps'], 2)
        self.assertEqual(result['fps'], 4)
        self.assertEqual(result['gpu_interval_p50_ms'], 100)
        self.assertEqual(result['fps_basis'], 'estimated_composite_updates')

    def test_unshown_frames_fail_despite_presented_markers(self):
        result = self.trace([{'kind': 'presented', 'presented_time': t} for t in (1.1, 1.2)] +
                            [{'kind': 'presented', 'presented_time': 0, 'host_time': 1.5}] * 3)
        self.assertFalse(result['valid'])


if __name__ == '__main__':
    unittest.main()
