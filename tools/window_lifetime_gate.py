#!/usr/bin/env python3
"""Run the Debug window lifetime fixture and require complete, leak-free exit."""
import argparse
import itertools
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


def judge(log: str, returncode: int | None) -> tuple[bool, str]:
    cases = re.findall(r"lifetime callback passed: trigger=(click|focus|key|cleanup) close_owner=(true|false)", log)
    expected = set(itertools.product(("click", "focus", "key", "cleanup"), ("true", "false")))
    complete = log.count("lifetime smoke complete:") == 1
    leaks = bool(re.search(r"(?i)(memory address .* leaked|\bleaked:|error\(gpa\)|error\(debug_allocator\))", log))
    ok = returncode == 0 and len(cases) == 8 and set(cases) == expected and complete and not leaks
    return ok, f"cases={len(set(cases))}/8, records={len(cases)}, complete={complete}, leaks={leaks}, exit={returncode}"


def run(app: Path, evidence: Path, timeout: float) -> int:
    evidence.mkdir(parents=True, exist_ok=True)
    timed_out = False
    launch_error = None
    with (evidence / "app.log").open("w") as log:
        try:
            result = subprocess.run([str(app.resolve()), "--lifetime-smoke"], stdout=log,
                                    stderr=subprocess.STDOUT, timeout=timeout)
            returncode = result.returncode
        except subprocess.TimeoutExpired:
            returncode = None
            timed_out = True
        except OSError as error:
            returncode = None
            launch_error = str(error)
    ok, detail = judge((evidence / "app.log").read_text(errors="replace"), returncode)
    report = dict(passed=ok, detail=detail, timed_out=timed_out, launch_error=launch_error)
    (evidence / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))
    return 0 if ok else 1


class GateContract(unittest.TestCase):
    def setUp(self):
        self.lines = [f"lifetime callback passed: trigger={t} close_owner={o}" for t, o in
                      itertools.product(("click", "focus", "key", "cleanup"), ("true", "false"))]
        self.log = "\n".join(self.lines + ["lifetime smoke complete:"])

    def test_complete(self):
        self.assertTrue(judge(self.log, 0)[0])

    def test_each_missing_case(self):
        for line in self.lines:
            with self.subTest(line=line):
                self.assertFalse(judge(self.log.replace(line, ""), 0)[0])

    def test_duplicate_cannot_replace_missing(self):
        self.assertFalse(judge(self.log.replace(self.lines[0], self.lines[1]), 0)[0])
        self.assertFalse(judge(self.log + "\n" + self.lines[0], 0)[0])

    def test_completion_required(self):
        self.assertFalse(judge("\n".join(self.lines), 0)[0])

    def test_exit_and_leaks(self):
        for code in (1, -11, None):
            self.assertFalse(judge(self.log, code)[0])
        for prefix in ("gpa", "DebugAllocator"):
            self.assertFalse(judge(self.log + f"\nerror({prefix}): memory address 0x123 leaked:", 0)[0])

    def test_launch_failure_is_recorded(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.assertEqual(run(root / "missing", root / "evidence", 1), 1)
            self.assertIsNotNone(json.loads((root / "evidence/result.json").read_text())["launch_error"])

    @unittest.skipIf(sys.platform == "win32", "executable fixture uses a POSIX shebang")
    def test_success_markers_cannot_hide_hung_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "hung-app"
            app.write_text(f"#!{sys.executable}\nimport time\nprint({self.log!r}, flush=True)\ntime.sleep(10)\n")
            app.chmod(0o700)
            self.assertEqual(run(app, root / "evidence", 0.5), 1)
            self.assertTrue(json.loads((root / "evidence/result.json").read_text())["timed_out"])


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        unittest.main(argv=[sys.argv[0]])
    else:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument("--app", required=True, type=Path)
        parser.add_argument("--evidence-dir", required=True, type=Path)
        parser.add_argument("--timeout", type=float, default=120)
        args = parser.parse_args()
        if args.timeout <= 0:
            parser.error("--timeout must be positive")
        sys.exit(run(args.app, args.evidence_dir, args.timeout))
