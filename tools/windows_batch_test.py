#!/usr/bin/env python3
"""Offline batch preparation and strict Windows acceptance must fail closed."""
import contextlib
import io
import json
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch
import windows_batch as batch

class BatchContract(unittest.TestCase):
    def invoke(self, extra):
        with tempfile.TemporaryDirectory(prefix="zenit-batch-contract-") as directory:
            folder = Path(directory) / "payload"
            captured = []
            def bundle(plan, bin_dir, arch, out, startup, renderer="d3d12", suite_timeout=900):
                captured.extend(plan)
                (out / batch.queue.BATCH_BUNDLE).write_bytes(b"fixture")
                return "fixture-digest"
            with patch.object(sys, "argv", ["windows_batch", "--skip-build", *extra, "--output-dir", str(folder)]), \
                 patch.object(batch, "make_job", side_effect=bundle), \
                 patch.object(batch, "build", side_effect=AssertionError("unexpected build")), \
                 patch.object(batch.queue, "read_token", side_effect=AssertionError("unexpected credential access")), \
                 patch.object(batch.queue, "request", side_effect=AssertionError("unexpected network access")), \
                 contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                result = batch.main()
            return result, captured

    def test_offline_strict_prepares_every_stage_without_credentials_or_network(self):
        code, plan = self.invoke(["--prepare-only", "--require-a11y"])
        self.assertEqual(code, 0)
        self.assertEqual(len(plan), 36)
        self.assertEqual(sum(p["kind"] == "e2e" for p in plan), 34)
        self.assertEqual(len({p["exe_name"] for p in plan}), 6)
        self.assertTrue(all(p["blocking"] for p in plan))

    def test_d3d11_x86_strict_plan_keeps_all_gates_and_native_backend(self):
        code, plan = self.invoke(["--prepare-only", "--require-a11y", "--renderer", "d3d11", "--arch", "x86"])
        self.assertEqual(code, 0)
        self.assertEqual(len(plan), 36)
        self.assertTrue(all(stage["blocking"] for stage in plan))
        native = next(stage for stage in plan if stage["name"] == "gpu-contracts")
        self.assertEqual(native["exe_name"], "zenit-windows-d3d11-contract.exe")
        self.assertEqual(native["renderer"], "d3d11")

    def test_stage_filter_keeps_only_named_stages_and_rejects_unknown_names(self):
        code, plan = self.invoke(["--prepare-only", "--require-a11y", "--stages", "input,accessibility-text"])
        self.assertEqual(code, 0)
        self.assertEqual([stage["name"] for stage in plan], ["input", "accessibility-text"])
        self.assertTrue(all(stage["blocking"] for stage in plan))
        for bad in ("input,no-such-stage", ","):
            with self.assertRaises(SystemExit):
                self.invoke(["--prepare-only", "--stages", bad])

    def test_full_application_suites_are_unfiltered_and_blocking(self):
        code, plan = self.invoke(["--prepare-only", "--require-a11y", "--renderer", "d3d11", "--full-app-suites"])
        self.assertEqual(code, 0)
        self.assertEqual(len(plan), 38)
        for name in ["storybook-full", "text-input-full"]:
            stage = next(stage for stage in plan if stage["name"] == name)
            self.assertTrue(stage["blocking"])
            self.assertEqual(stage["filter"], "")

    def test_full_plan_suite_sources_ship_with_the_controller(self):
        code, plan = self.invoke(["--prepare-only", "--require-a11y", "--full-app-suites", "--allow-foreground"])
        self.assertEqual(code, 0)
        for stage in plan:
            if stage["kind"] == "e2e":
                with self.subTest(stage=stage["name"]):
                    self.assertTrue((batch.REPO / stage["suite_source"]).is_file(), stage["suite_source"])

    def test_d3d11_probe_requires_hardware_and_successful_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "stage-result.json").write_text(json.dumps({"exit_code": 0, "error": ""}))
            (root / "windows-probe-stdout.log").write_text("D3D11 hardware contract: upload snapshot, nonzero-offset update, partial clear, padded readback, submit/wait PASS\nD3D11 timestamp contract: pending, GPU duration, queue-independent lifetime PASS")
            stderr = root / "windows-probe-stderr.log"
            stage = {"kind": "probe", "renderer": "d3d11"}
            stderr.write_text("[d3d11-adapter] name=VMware SVGA 3D feature=0xb000 software=1 result=0x00000000")
            self.assertFalse(batch.judge(stage, root)[0])
            stderr.write_text("[d3d11-adapter] name=VMware SVGA 3D feature=0xb000 software=0 result=0x00000000")
            self.assertTrue(batch.judge(stage, root)[0])
            (root / "windows-probe-stdout.log").write_text("")
            self.assertFalse(batch.judge(stage, root)[0])

    def test_lifetime_probe_requires_all_cases_completion_and_no_allocator_leaks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "stage-result.json").write_text(json.dumps({"exit_code": 0, "error": ""}))
            stderr = root / "windows-probe-stderr.log"
            stage = {"name": "window-lifetime", "kind": "probe"}
            cases = "\n".join(f"lifetime callback passed: trigger={trigger} close_owner={owner}"
                              for trigger in ("click", "focus", "key", "cleanup") for owner in ("false", "true"))
            stderr.write_text(cases)
            self.assertFalse(batch.judge(stage, root)[0])
            stderr.write_text(cases + "\nlifetime smoke complete:\n")
            self.assertTrue(batch.judge(stage, root)[0])
            stderr.write_text(cases + "\nlifetime smoke complete:\nerror(gpa): memory address 0x123 leaked:\n")
            self.assertFalse(batch.judge(stage, root)[0])

    def test_hover_stages_only_with_foreground_consent(self):
        code, plan = self.invoke(["--prepare-only", "--require-a11y"])
        self.assertEqual(code, 0)
        self.assertFalse(any(p["name"].startswith("hover-") for p in plan))
        code, plan = self.invoke(["--prepare-only", "--require-a11y", "--allow-foreground"])
        self.assertEqual(code, 0)
        hover = {p["name"]: p for p in plan if p["name"].startswith("hover-")}
        self.assertEqual(set(hover), {"hover-probe", "hover-native"})
        self.assertTrue(all(p["blocking"] and p["allow_foreground"] for p in hover.values()))
        self.assertEqual(hover["hover-probe"]["exe_name"], batch.HOVER_PROBE)
        self.assertEqual(hover["hover-native"]["suite_source"], "e2e/windows-hover-native.test.ts")
        # Real OS pointer input must reach Cx in this stage.
        self.assertEqual(hover["hover-native"]["app_env"], {"ZENIT_E2E_ISOLATE_POINTER": "0"})
        self.assertTrue((batch.REPO / hover["hover-native"]["suite_source"]).is_file())

    def test_hover_probe_requires_every_native_fact_and_the_measurement(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "stage-result.json").write_text(json.dumps({"exit_code": 0, "error": ""}))
            data = {"wheel_routing": 2, "inactive_moves": 3, "inactive_wheels": 1, "cover": {"leave_ms": 9.0},
                    "uncover": {"move_ms": 12.0}, "release_over_other": {"leaves": 1}}
            stdout = root / "windows-probe-stdout.log"
            stderr = root / "windows-probe-stderr.log"
            facts = "\n".join(f"PASS: fact {i}" for i in range(7))
            stage = {"name": "hover-probe", "kind": "probe"}
            stdout.write_text("HOVERPROBE_JSON " + json.dumps(data) + "\n")
            stderr.write_text(facts + "\nhover probe complete: 0 required fact(s) failed\n")
            self.assertTrue(batch.judge(stage, root)[0])
            stderr.write_text(facts + "\nFAIL: WM_MOUSELEAVE when covered\nhover probe complete: 1 required fact(s) failed\n")
            self.assertFalse(batch.judge(stage, root)[0])
            stderr.write_text(facts + "\n")  # crashed before completing
            self.assertFalse(batch.judge(stage, root)[0])
            stderr.write_text(facts + "\nhover probe complete: 0 required fact(s) failed\n")
            stdout.write_text("")  # no measurement
            self.assertFalse(batch.judge(stage, root)[0])
            stdout.write_text("HOVERPROBE_JSON " + json.dumps(data) + "\n")
            (root / "stage-result.json").write_text(json.dumps({"exit_code": 1, "error": ""}))
            self.assertFalse(batch.judge(stage, root)[0])

    def test_complete_gallery_suite_covers_texture_replacement_without_filter(self):
        full = [s for s in batch.stages(True) if s.get("suite_source") == "e2e/windows-image-render.test.ts" and not s.get("filter")]
        self.assertEqual(len(full), 1, "texture replacement must run in the complete gallery suite")
        self.assertEqual(full[0]["exe_name"], batch.queue.E2E_APPS["render-gallery"])
        self.assertTrue(full[0]["blocking"])
        self.assertGreaterEqual(full[0]["minimum_cases"], 27)

    def test_automated_native_feature_suites_are_required_and_unfiltered(self):
        expected = {
            "glass-render": ("render-gallery", 1), "visual-fallback": ("storybook", 4),
            "submitted-screenshot": ("storybook", 1), "local-frame-action": ("storybook", 1),
            "timed-frame": ("storybook", 1), "textarea-edit-stress": ("text-input", 1),
            "recording": ("text-input", 2), "frame-timing": ("storybook", 1),
            "shared-timing": ("storybook", 1),
        }
        stages = {s["suite_source"]: s for s in batch.stages(True) if s.get("suite_source")}
        for name, (app, cases) in expected.items():
            with self.subTest(suite=name):
                stage = stages.get(f"e2e/windows-{name}.test.ts")
                self.assertIsNotNone(stage, "automated native contract is missing from the batch")
                self.assertEqual(stage["exe_name"], batch.queue.E2E_APPS[app])
                self.assertGreaterEqual(stage["minimum_cases"], cases)
                self.assertTrue(stage["blocking"])
                self.assertFalse(stage.get("filter"))

    def test_accessibility_suites_target_their_actual_application(self):
        plan = batch.stages(True)
        accessibility = {p["name"]: p["exe_name"] for p in plan if p["name"].startswith("accessibility")}
        self.assertEqual(accessibility.pop("accessibility"), batch.queue.E2E_APPS["render-gallery"])
        self.assertEqual(len(accessibility), 6)
        self.assertTrue(all(exe == batch.queue.E2E_APPS["storybook"] for exe in accessibility.values()))

    def test_conflicting_accessibility_options_fail_before_bundling(self):
        with self.assertRaises(SystemExit) as error:
            self.invoke(["--prepare-only", "--require-a11y", "--no-a11y"])
        self.assertEqual(error.exception.code, 2)

    def judge_evidence(self, error):
        with tempfile.TemporaryDirectory(prefix="zenit-stage-evidence-") as directory:
            stage_dir = Path(directory)
            (stage_dir / "stage-result.json").write_text(json.dumps({"exit_code": 0, "error": error}))
            summary = {"total": 1, "executed": 1, "passed": 1, "failed": 0, "aborted": 0, "failures": []}
            with zipfile.ZipFile(stage_dir / "windows-suite-session.zip", "w") as archive:
                archive.writestr("summary.json", json.dumps(summary))
            return batch.judge({"kind": "e2e", "minimum_cases": 1}, stage_dir)

    def test_stage_error_cannot_pass_with_successful_suite_and_exit_code(self):
        passed, detail = self.judge_evidence("shutdown cleanup failed")
        self.assertFalse(passed)
        self.assertIn("shutdown cleanup failed", detail)

    def test_clean_stage_evidence_passes(self):
        passed, detail = self.judge_evidence("")
        self.assertTrue(passed)
        self.assertEqual(detail, "1/1 passed")

    def completed_batch(self, state):
        with tempfile.TemporaryDirectory(prefix="zenit-batch-result-") as directory:
            root = Path(directory)
            output = io.StringIO()
            def bundle(plan, bin_dir, arch, out, startup, renderer="d3d12", suite_timeout=900):
                (out / batch.queue.BATCH_BUNDLE).write_bytes(b"fixture")
                return "fixture-digest"
            def request(base, token, method, route, *args):
                return state if route.startswith("/jobs/") else {}
            with patch.object(sys, "argv", ["windows_batch", "--skip-build", "--require-a11y"]), \
                 patch.object(batch.queue, "data_dir", return_value=root), \
                 patch.object(batch.queue, "read_token", return_value="fixture"), \
                 patch.object(batch.queue, "require_worker"), \
                 patch.object(batch.queue, "request", side_effect=request), \
                 patch.object(batch, "make_job", side_effect=bundle), \
                 patch.object(batch, "judge", return_value=(True, "all stage evidence passed")), \
                 contextlib.redirect_stdout(output):
                code = batch.main()
            reports = list(root.glob("jobs/*/batch-report.json"))
            self.assertEqual(len(reports), 1)
            self.assertTrue(all(row["passed"] for row in json.loads(reports[0].read_text())))
            return code, output.getvalue()

    def test_failed_batch_cannot_pass_even_when_every_stage_passes(self):
        code, output = self.completed_batch({"status": "failed", "error": "Batch upload failed after all stage archives were delivered"})
        self.assertEqual(code, 1)
        self.assertNotIn("==> PASSED", output)

    def test_successful_batch_and_all_stages_pass(self):
        code, output = self.completed_batch({"status": "passed", "error": ""})
        self.assertEqual(code, 0)
        self.assertIn("==> PASSED", output)

    def test_missing_output_fails_before_build_or_network(self):
        with patch.object(sys, "argv", ["windows_batch", "--prepare-only"]), \
             patch.object(batch, "build", side_effect=AssertionError("unexpected build")), \
             patch.object(batch.queue, "read_token", side_effect=AssertionError("unexpected credential access")), \
             patch.object(batch.queue, "request", side_effect=AssertionError("unexpected network access")), \
             contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as error:
                batch.main()
        self.assertEqual(error.exception.code, 2)

if __name__ == "__main__":
    unittest.main()
