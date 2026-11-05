#!/usr/bin/env python3
"""Runtime sensitivity probes for the LP3 component lifecycle gate.

This does not cover typed holes or the LP4 publication/fallback controller.
Run only with exclusive access to this worktree; restores view.zig on every exit.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess


def is_compile_failure(output):
    # Runtime allocator diagnostics end with "N errors were logged". Match
    # Zig compiler headers/source diagnostics, never that runtime summary.
    return re.search(r"(?m)compilation errors|^[^\n]*\bcompile (?:test|obj|exe|lib)\b[^\n]*\b[0-9]+ errors|^.*:[0-9]+:[0-9]+: error:|unable to resolve|failed to compile", output) is not None


def inventory(root, target):
    paths = {root / "build.zig", root / "build.zig.zon"}
    for folder in ("src", "tests", "examples", "scripts", "tools"):
        for path in (root / folder).rglob("*"):
            if path.suffix not in (".zig", ".yix", ".yss", ".py", ".json") or not path.is_file():
                continue
            if any(part in (".zig-cache", "zig-out", "node_modules") for part in path.parts):
                continue
            paths.add(path)
    return {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(paths) if path != target}


def run(root, evidence, name):
    command = ["zig", "build", "test-component-view", "-j1"]
    process = subprocess.Popen(command, cwd=root, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True,
                               start_new_session=True)
    try:
        output, _ = process.communicate(timeout=240)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        output, _ = process.communicate()
        (evidence / f"{name}.log").write_text(output)
        raise RuntimeError(f"{name}: timed out; not counted as a detected mutation")
    (evidence / f"{name}.log").write_text(output)
    return process.returncode, output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, default=Path(".zig-cache/lp3a-mutation"))
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    evidence = args.evidence.resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    source = root / "src/ui/view.zig"
    original = source.read_text()
    frozen = inventory(root, source)

    def check_inputs():
        if inventory(root, source) != frozen:
            raise RuntimeError("validation inputs changed concurrently; mutation evidence is invalid")
    mutations = {
        "wrong_scope": ("const result = build(ctx, vs, cx, Sink.capture(&root, &stray))",
                        "const result = build(ctx, setup_scope, cx, Sink.capture(&root, &stray))"),
        "missing_node_cleanup": ("const result = build(ctx, vs, cx, Sink.capture(&root, &stray)) catch |err| {\n        control_flow.discardCaptured(cx, vs, root, stray);",
                                 "const result = build(ctx, vs, cx, Sink.capture(&root, &stray)) catch |err| {\n        vs.dispose(); // deliberate regression: emitted nodes leaked"),
        "slot_stray_dropped": ("try emitContents(c, s, context, at, current);", "_ = at; try emitContents(c, s, context, .{ .parent = null }, current);"),
        "persistent_capture_adapter": ("slot == .capture and componentInstance(node) == null", "slot == .capture"),
        "ignore_lifetime_ticket": ("if (disposed) {", "if (disposed and false) {"),
        "false_rebuild_success": ("const parts = try self.render_fn(self);", "const parts = self.render_fn(self) catch return .{ .root = null };"),
    }
    mutations.update({
        "ignore_graph_flush": ("owner.graph.flushing or owner.reactive_callback_depth", "owner.reactive_callback_depth"),
        "state_reset": ("const parts = try self.render_fn(self);", """const parts = try self.render_fn(self);
        if (parts.root) |root| {
            if (self.setup.signals.items.len != 0 and root.meta.ownership.meta.component_name != null and std.mem.eql(u8, root.meta.ownership.meta.component_name.?, "Split")) {
                const reset: *Signal(i32) = @ptrCast(@alignCast(self.setup.signals.items[0]));
                reset.set(0);
            }
        }"""),
    })
    results = {}
    baseline, _ = run(root, evidence, "before")
    check_inputs()
    if baseline != 0:
        raise RuntimeError("unmodified ownership gate failed")
    for name, (old, new) in mutations.items():
        if original.count(old) != 1:
            raise RuntimeError(f"{name}: source anchor is not unique")
        mutated = original.replace(old, new)
        source.write_text(mutated)
        try:
            rc, output = run(root, evidence, name)
        finally:
            if source.read_text() != mutated:
                raise RuntimeError("source changed concurrently; refusing to overwrite it")
            source.write_text(original)
        check_inputs()
        if rc == 0:
            raise RuntimeError(f"{name}: mutation escaped")
        if is_compile_failure(output):
            raise RuntimeError(f"{name}: compile failure is not mutation evidence")
        if not re.search(r"FAIL \(|leaked|panic:|Segmentation fault|Aborted", output, re.I):
            raise RuntimeError(f"{name}: no runtime assertion/leak evidence")
        results[name] = {"exit_code": rc, "runtime_failure_detected": True}
        print(f"{name}: detected at runtime (exit {rc})", flush=True)
    restored, _ = run(root, evidence, "restored")
    check_inputs()
    if restored != 0:
        raise RuntimeError("restored ownership gate failed")
    results["baseline_exit"] = baseline
    results["restored_exit"] = restored
    results["input_digest"] = hashlib.sha256(json.dumps(frozen, sort_keys=True).encode()).hexdigest()
    (evidence / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    print(f"component ownership mutation probes: {len(mutations)}/{len(mutations)} detected; source restored")


if __name__ == "__main__":
    main()
