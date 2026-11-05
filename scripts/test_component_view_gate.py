#!/usr/bin/env python3
import subprocess
import io
from contextlib import redirect_stdout, redirect_stderr
import sys
import unittest
from unittest.mock import patch

from run_component_view_gate import CASES, main, validate, without_orphan_probes
from gen_template_manifest import calls, host_digest, validate_hosts
from test_component_view_mutation import is_compile_failure


def passing():
    lines = [f"{i + 1}/{len(CASES)} fixture.test.LP3 setup/view: {name}...OK"
             for i, name in enumerate(CASES)]
    return "\n".join(lines) + f"\nAll {len(CASES)} tests passed.\n"


class GateContract(unittest.TestCase):
    def test_mutation_compile_classification_preserves_runtime_leak_evidence(self):
        self.assertFalse(is_compile_failure('4 tests failed.\n5578 errors were logged.\n10 tests leaked memory.'))
        for output in ('+- compile test fixture debug native 1 errors',
                       'src/ui/view.zig:6:10: error: expected type',
                       'error: 1 compilation errors',
                       'unable to resolve module'):
            with self.subTest(output=output): self.assertTrue(is_compile_failure(output))

    def test_root_host_inventory_fails_on_missing_added_and_changed_calls(self):
        expected = calls('view.pinComponentRoot(root); view.renderInto(scope, cx, node);')
        self.assertEqual(2, len(expected))
        self.assertEqual([], calls('// view.pinComponentRoot(root);\nconst text = "renderInto(x)";'))
        for source in ('view.pinComponentRoot(root);',
                       'view.pinComponentRoot(other); view.renderInto(scope, cx, node);',
                       'view.pinComponentRoot(root); view.renderInto(scope, cx, node); view.renderInto(extra);'):
            with self.subTest(source=source), self.assertRaises(ValueError):
                validate_hosts(expected, calls(source))

    def test_host_digest_ignores_only_orphan_probe_lines(self):
        import pathlib, tempfile
        base = b'test "x" {\n    try foo();\n}\n'
        probed = base.replace(b'{', b'{\n    @import("std").debug.print("ORPHAN-PROBE-HIT src/a.zig\\n", .{});', 1)
        edited = base.replace(b'foo', b'bar')
        d = pathlib.Path(tempfile.mkdtemp())
        paths = []
        for i, content in enumerate((base, probed, edited)):
            p = d / f'{i}.zig'
            p.write_bytes(content)
            paths.append(p)
        self.assertEqual(host_digest(paths[0]), host_digest(paths[1]))
        self.assertNotEqual(host_digest(paths[0]), host_digest(paths[2]))

    def test_complete_run(self):
        validate(0, passing())

    def test_orphan_probe_markers_are_the_only_tolerated_split(self):
        marker = CASES[0] + "...OK"
        probed = passing().replace(marker, CASES[0] + "...ORPHAN-PROBE-HIT src/ui/view.zig\nOK", 1)
        validate(0, without_orphan_probes(probed))
        other = passing().replace(marker, CASES[0] + "...SOME-OTHER-DIAGNOSTIC src/ui/view.zig\nOK", 1)
        with self.assertRaises(ValueError):
            validate(0, without_orphan_probes(other))

    def test_allocation_sweep_diagnostics_require_its_own_completion(self):
        name = "every rebuild allocation failure leaves no partial view or live ref"
        marker = name + "...OK"
        warning = "[default] (warn): ui.view: style layer update dropped (out of memory)\n"
        validate(0, passing().replace(marker, name + "..." + warning + "OK"))
        for suffix in (warning, "unrecognized output\nOK", warning + "FAIL (TestUnexpectedResult)"):
            with self.subTest(suffix=suffix), self.assertRaises(ValueError):
                validate(0, passing().replace(marker, name + "..." + suffix))

    def test_missing_or_duplicate_or_unfinished_case(self):
        for output in ("\n".join(passing().splitlines()[1:]),
                       passing() + passing().splitlines()[0] + "\n",
                       passing().replace("...OK", "...SKIP", 1),
                       passing().replace(f"All {len(CASES)} tests passed.", "PASS")):
            with self.subTest(output=output), self.assertRaises(ValueError):
                validate(0, output)

    def test_crash_timeout_leak_after_success(self):
        for rc, tail in ((-11, ""), (1, ""), (0, "panic: broken"),
                         (0, "error(gpa): memory address 0x1 leaked"),
                         (0, "timeout"), (0, "Segmentation fault")):
            with self.subTest(rc=rc, tail=tail), self.assertRaises(ValueError):
                validate(rc, passing() + tail)

    def test_actual_child_exit_after_markers(self):
        real_run = subprocess.run

        def child(*_args, **kwargs):
            # Exercise a real failing child on every host, without depending on
            # shell scripts or executable permission bits.
            return real_run([sys.executable, "-c", "import sys; print(" + repr(passing()) + "); sys.exit(1)"], **kwargs)

        with patch.object(sys, "argv", ["gate", "fake"]), patch(
                "run_component_view_gate.subprocess.run", side_effect=child), redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()) as diagnostics:
            self.assertEqual(1, main())
        self.assertIn("test process exited 1", diagnostics.getvalue())

    def test_timeout_is_failure(self):
        with patch.object(sys, "argv", ["gate", "fake"]), patch(
                "run_component_view_gate.subprocess.run",
                side_effect=subprocess.TimeoutExpired("fake", 120)), redirect_stderr(io.StringIO()) as diagnostics:
            self.assertEqual(1, main())
        self.assertIn("timed out", diagnostics.getvalue())

    def test_actual_child_timeout_after_markers(self):
        real_run = subprocess.run

        def child(*_args, **kwargs):
            kwargs["timeout"] = 1
            try:
                return real_run([sys.executable, "-c", "import sys,time; sys.stdout.write(" + repr(passing()) + "); sys.stdout.flush(); time.sleep(5)"], **kwargs)
            except subprocess.TimeoutExpired as error:
                output = error.stdout.decode() if isinstance(error.stdout, bytes) else error.stdout
                self.assertIn(passing(), output)
                raise

        with patch.object(sys, "argv", ["gate", "fake"]), patch(
                "run_component_view_gate.subprocess.run", side_effect=child), redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()) as diagnostics:
            self.assertEqual(1, main())
        self.assertIn("timed out", diagnostics.getvalue())


if __name__ == "__main__":
    unittest.main()
