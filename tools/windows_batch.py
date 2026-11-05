#!/usr/bin/env python3
"""One-shot Windows acceptance over the worker queue (VM or real hardware).

Build every executable once, bundle every suite for the worker, and ship them together with a
stage manifest in ONE job. The worker runs all stages locally (each app beside its bundled suite,
no harness request crosses the network) and returns each stage's evidence at the end. The host
then judges every stage exactly as the per-stage tools do: suite summaries, the Modal / Sheet /
Notification submitted-frame audits and the native D3D12 contract probe.

  python3 tools/windows_batch.py --base URL [--arch x86_64] [--artifact-dir BIN] [--skip-build]

Stages: the shared render/input gates (windows_shared_regression.PHASES), the native GPU contract
probe (scope all) and the UI Automation suites (reported, not blocking).
"""
import argparse
import urllib.parse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import windows_shared_regression as shared  # noqa: E402
import windows_vm_http as queue  # noqa: E402

REPO = queue.REPO
GPU_PROBE = queue.PROBES["gpu"][1]


HOVER_PROBE = "zenit-windows-hover-probe.exe"


def hover_stages() -> list[dict]:
    """Hover liveness with real input on the worker (needs --allow-foreground: they move the
    worker's cursor, wheel and foreground). `hover-probe` measures the native Win32 facts
    (tools/windows_hover_probe.c); `hover-native` checks Zenit against them in Storybook."""
    return [
        {"name": "hover-probe", "kind": "probe", "exe_name": HOVER_PROBE, "blocking": True, "allow_foreground": True},
        {"name": "hover-native", "kind": "e2e", "exe_name": queue.E2E_APPS["storybook"],
         "suite_source": "e2e/windows-hover-native.test.ts", "minimum_cases": 1, "blocking": True, "filter": "",
         "allow_foreground": True, "app_env": {"ZENIT_E2E_ISOLATE_POINTER": "0"}},
    ]


def stages(include_a11y: bool, renderer: str = "d3d12", full_app_suites: bool = False, hover_native: bool = False) -> list[dict]:
    out = []
    for name, app, suite, minimum, _reuse, extra in shared.PHASES:
        modal = "--audit-modal-frames" in extra
        out.append({"name": name, "kind": "e2e", "exe_name": queue.E2E_APPS[app], "suite_source": suite,
                    "minimum_cases": minimum, "blocking": True, "filter": shared.STAGE_FILTERS.get(name, ""),
                    "capture_frames": modal or "--capture-frames" in extra, "trace_frames": modal,
                    "audit": "modal" if modal else {"sheet-frames": "sheet", "notification-frames": "notification"}.get(name)})
    if full_app_suites:
        for name, app, suite, minimum in (
            ("storybook-full", "storybook", "e2e/storybook.test.ts", 98),
            ("text-input-full", "text-input", "e2e/text-input-demo-audit.test.ts", 12),
        ):
            out.append({"name": name, "kind": "e2e", "exe_name": queue.E2E_APPS[app],
                        "suite_source": suite, "minimum_cases": minimum,
                        "blocking": True, "filter": ""})
    # The shared retained phase filters this suite to one case. Run the full
    # suite too, including texture replacement, geometry, compositing and menus.
    out.append({"name": "gallery-images", "kind": "e2e", "exe_name": queue.E2E_APPS["render-gallery"],
                "suite_source": "e2e/windows-image-render.test.ts", "minimum_cases": 27,
                "blocking": True, "filter": ""})
    for name, app, cases in (
        ("glass-render", "render-gallery", 1), ("visual-fallback", "storybook", 4),
        ("submitted-screenshot", "storybook", 1), ("local-frame-action", "storybook", 1),
        ("timed-frame", "storybook", 1), ("textarea-edit-stress", "text-input", 1),
        ("recording", "text-input", 2), ("frame-timing", "storybook", 1),
        ("shared-timing", "storybook", 1),
    ):
        out.append({"name": name, "kind": "e2e", "exe_name": queue.E2E_APPS[app],
                    "suite_source": f"e2e/windows-{name}.test.ts", "minimum_cases": cases,
                    "blocking": True, "filter": ""})
    # Native WM_MOUSE(W/H)WHEEL must reach the SDK instead of the Harness /scroll route.
    out.append({"name": "native-scroll", "kind": "e2e", "exe_name": queue.E2E_APPS["storybook"],
                "suite_source": "e2e/windows-native-scroll.test.ts", "minimum_cases": 1,
                "blocking": True, "filter": "", "app_env": {"ZENIT_E2E_ISOLATE_POINTER": "0"}})
    # The adaptive window example: preset gallery geometry, real caption actions,
    # F11 fullscreen reveal and one real "Try" window opened from a preset.
    out.append({"name": "adaptive-window", "kind": "e2e", "exe_name": queue.E2E_APPS["adaptive-window"],
                "suite_source": "e2e/windows-adaptive-window.test.ts", "minimum_cases": 5, "blocking": True, "filter": ""})
    # Storybook's Windows 11 title bar at rest, scrolled, fullscreen and restored
    # (screenshots for review).
    out.append({"name": "storybook-header", "kind": "e2e", "exe_name": queue.E2E_APPS["storybook"],
                "suite_source": "e2e/window-header-probe.test.ts", "minimum_cases": 1, "blocking": True, "filter": ""})
    out.append({"name": "multi-window-screenshot", "kind": "e2e", "exe_name": queue.E2E_APPS["storybook"],
                "suite_source": "e2e/multi-window-screenshot.test.ts", "minimum_cases": 1,
                "blocking": True, "filter": ""})
    out.append({"name": "window-lifetime", "kind": "probe",
                "exe_name": "zenit-windows-window-chrome.exe", "blocking": True})
    out.append({"name": "gpu-contracts", "kind": "probe",
                "exe_name": "zenit-windows-d3d11-contract.exe" if renderer == "d3d11" else GPU_PROBE,
                "renderer": renderer, "blocking": True})
    if hover_native:
        out.extend(hover_stages())
    if include_a11y:
        for suite in sorted((REPO / "e2e").glob("windows-accessibility*.test.ts")):
            short = suite.name.removeprefix("windows-").removesuffix(".test.ts")
            # The original UIA suite exercises Gallery controls; the widget
            # suites exercise Storybook. Keep each suite with its fixture app.
            app = "render-gallery" if suite.name == "windows-accessibility.test.ts" else "storybook"
            out.append({"name": short, "kind": "e2e", "exe_name": queue.E2E_APPS[app],
                        "suite_source": f"e2e/{suite.name}", "minimum_cases": 1, "blocking": False, "filter": ""})
    return out


ZDOC_ARCH_LABELS = {"aarch64": "arm64", "x86_64": "x64"}
ZDOC_ARCH_RENDERERS = {"aarch64": "d3d12", "x86_64": "d3d11"}


def zdoc_stage(zdoc_bin: Path, suite: Path, arch: str | None = None, renderer: str | None = None, label: str | None = None,
               minimum_cases: int = 12) -> dict:
    """zdoc (zeditor) on the worker: its test-mode exe and assets/ from another
    checkout, an isolated workspace inside the stage directory, and its own
    smoke suite (zdoc's harness has no renderer/visual-quality endpoints, so
    the Zenit renderer preflight is skipped). With `arch`, the stage and its
    exe are named per architecture so several builds share one bundle (and one
    transfer); assets/ is packed once."""
    workspace = "{stage_dir}\\workspace"
    label = (label or ZDOC_ARCH_LABELS[arch]) if arch else None
    extra = {"arch": arch, "renderer": renderer or ZDOC_ARCH_RENDERERS[arch], "source_exe": "zdoc-e2e.exe"} if arch else {}
    return {**extra, "name": f"zdoc-smoke-{label}" if label else "zdoc-smoke", "kind": "e2e",
            "exe_name": f"zdoc-e2e-{label}.exe" if label else "zdoc-e2e.exe", "suite_source": str(suite),
            "minimum_cases": minimum_cases, "blocking": True, "filter": "", "bin_dir": str(zdoc_bin),
            "extra_dirs": ["assets"], "preflight": False,
            "app_env": {"ZDOC_E2E_WORKSPACE": workspace, "ZDOC_E2E_RPC_ONLY": "1",
                        "ZENIT_SESSION_DB_PATH": workspace + "\\session.sqlite",
                        "ZDOC_USER_DATA_DIR": workspace + "\\.zdoc-user-data",
                        "ZENIT_E2E_DISABLE_FILE_TREE_BOUNCE": "1"}}


def build(arch: str, prefix: Path, renderer: str = "d3d12") -> None:
    common = [f"-Dwindows-arch={arch}", "--prefix", str(prefix)]
    subprocess.run(["zig", "build", "windows-arm64-storybook", "windows-arm64-text-input", "windows-arm64-render-gallery", "windows-adaptive-window",
                    "-Dtest-mode=true", f"-Dgpu-backend={renderer}", "-Doptimize=fast", *common], cwd=REPO, check=True)
    # DebugAllocator exit checks are part of the lifetime contract.
    subprocess.run(["zig", "build", "windows-window-chrome", "-Dtest-mode=true",
                    f"-Dgpu-backend={renderer}", "-Doptimize=Debug", *common], cwd=REPO, check=True)
    subprocess.run(["zig", "build", "windows-hover-probe", "-Doptimize=fast", *common], cwd=REPO, check=True)
    if renderer == "d3d11":
        subprocess.run(["zig", "build", "windows-d3d11-contract", "-Dgpu-backend=d3d11", "-Doptimize=fast", *common], cwd=REPO, check=True)
        return
    subprocess.run(["zig", "build", "windows-arm64-gpu-resources-contract", "-Doptimize=fast",
                    "-Dwindows-gpu-contract-scope=all", *common], cwd=REPO, check=True)


def bundle_suite(suite: str, outfile: Path, preflight: bool = True) -> None:
    source = Path(suite) if Path(suite).is_absolute() else REPO / suite
    entry = source.parent / f".windows-batch-entry-{uuid.uuid4().hex}.ts"
    # Imports evaluate in order: the preflight (startup, renderer checks) completes before the suite.
    lines = [f'import "{REPO / "e2e/windows-renderer-preflight.ts"}";'] if preflight else []
    lines.append(f'import "./{source.name}";')
    entry.write_text("\n".join(lines) + "\n")
    try:
        subprocess.run(["bun", "build", "--target=bun", "--sourcemap=inline", str(entry), "--outfile", str(outfile)],
                       cwd=source.parent, check=True, stdout=subprocess.DEVNULL)
    finally:
        entry.unlink(missing_ok=True)


def suite_runtime(scratch: Path) -> Path:
    version = subprocess.run(["bun", "--version"], check=True, capture_output=True, text=True).stdout.strip()
    # Baseline (no AVX2): Windows on Arm's x64 emulation lacks AVX2.
    runtime = Path.home() / ".bun/install/cache" / f"bun-windows-x64-baseline-v{version}"
    if not runtime.is_file():
        entry = REPO / "e2e" / "windows-renderer-preflight.ts"
        subprocess.run(["bun", "build", "--compile", "--target=bun-windows-x64-baseline", str(entry),
                        "--outfile", str(scratch / "runtime-fetch.exe")], cwd=REPO, check=True, stdout=subprocess.DEVNULL)
        (scratch / "runtime-fetch.exe").unlink(missing_ok=True)
    queue.require_pe_arch(runtime, "x86_64")
    return runtime


def make_job(plan: list[dict], bin_dir: Path, arch: str, folder: Path, startup_timeout: float, renderer: str = "d3d12", suite_timeout: float = 900) -> str:
    """Write zenit-batch.zip + zenit-bun.exe into the job folder; return the runtime digest."""
    scratch = Path(tempfile.mkdtemp(prefix="zenit-batch-"))
    manifest = {"arch": arch, "renderer": renderer, "stages": []}
    with zipfile.ZipFile(folder / queue.BATCH_BUNDLE, "w", zipfile.ZIP_DEFLATED) as bundle:
        # Packed name -> (file, architecture); a per-architecture stage packs
        # its build under its own name.
        sources = {stage["exe_name"]: (Path(stage.get("bin_dir") or bin_dir) / stage.get("source_exe", stage["exe_name"]), stage.get("arch") or arch)
                   for stage in plan}
        for exe_name in sorted(sources):
            exe, exe_arch = sources[exe_name]
            queue.require_pe_arch(exe, exe_arch)
            bundle.write(exe, exe_name)
        packed_dirs = set()
        for stage in plan:
            for extra in stage.get("extra_dirs") or []:
                if extra in packed_dirs:
                    continue
                packed_dirs.add(extra)
                root_dir = Path(stage.get("bin_dir") or bin_dir) / extra
                if not root_dir.is_dir():
                    raise SystemExit(f"missing {root_dir} for stage {stage['name']}")
                for path in sorted(root_dir.rglob("*")):
                    if path.is_file():
                        bundle.write(path, f"{extra}/{path.relative_to(root_dir).as_posix()}")
        for stage in plan:
            entry = {key: stage.get(key) for key in ("name", "kind", "exe_name", "capture_frames", "trace_frames", "app_env", "extra_dirs", "allow_foreground")}
            if stage["kind"] == "e2e":
                js = scratch / f"{stage['name']}.js"
                bundle_suite(stage["suite_source"], js, stage.get("preflight", True))
                bundle.write(js, f"suites/{stage['name']}.js")
                entry["suite"] = f"suites/{stage['name']}.js"
                entry["env"] = {"ZENIT_E2E_TIMEOUT_MS": "40000", "ZENIT_E2E_EXPECT_RENDERER": stage.get("renderer") or renderer, "ZENIT_E2E_VISUAL_QUALITY": "full",
                                "ZENIT_E2E_STARTUP_TIMEOUT_MS": str(round(startup_timeout * 1000)),
                                "ZENIT_E2E_SUITE_TIMEOUT_MS": str(round(suite_timeout * 1000))}
                if stage["filter"]:
                    entry["env"]["ZENIT_E2E_FILTER"] = stage["filter"]
            entry["startup_timeout_ms"] = round(startup_timeout * 1000)
            manifest["stages"].append(entry)
        bundle.writestr("manifest.json", json.dumps(manifest, indent=2))
    shutil.copy2(suite_runtime(scratch), folder / queue.LOCAL_SUITE_RUNTIME)
    shutil.rmtree(scratch, ignore_errors=True)
    (folder / "batch-plan.json").write_text(json.dumps(plan, indent=2) + "\n")
    return hashlib.sha256((folder / queue.LOCAL_SUITE_RUNTIME).read_bytes()).hexdigest()


def extract(archive: Path, target: Path) -> None:
    target = target.resolve()
    with zipfile.ZipFile(archive) as z:
        # .NET Framework's ZipFile writes Windows separators into names.
        for info in z.infolist():
            destination = (target / info.filename.replace("\\", "/")).resolve()
            if target not in destination.parents or info.is_dir():
                continue
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(z.read(info))


def suite_summary(stage_dir: Path) -> dict | None:
    session = stage_dir / "windows-suite-session.zip"
    if not session.is_file():
        return None
    extract(session, stage_dir / "session")
    found = list((stage_dir / "session").rglob("summary.json"))
    return json.loads(found[0].read_text()) if len(found) == 1 else None


def judge_hover_probe(result: dict, stage_dir: Path) -> tuple[bool, str]:
    """Every required native fact PASS, the measurement present, the run completed."""
    stdout = (stage_dir / "windows-probe-stdout.log").read_text(errors="replace")
    stderr = (stage_dir / "windows-probe-stderr.log").read_text(errors="replace")
    found = re.search(r"^HOVERPROBE_JSON (\{.*\})\s*$", stdout, re.MULTILINE)
    try:
        data = json.loads(found.group(1)) if found else None
    except ValueError:
        data = None
    failed = re.findall(r"^FAIL: (.*)$", stderr, re.MULTILINE)
    passed = len(re.findall(r"^PASS: ", stderr, re.MULTILINE))
    complete = re.search(r"^hover probe complete: 0 required fact\(s\) failed$", stderr, re.MULTILINE) is not None
    ok = result["exit_code"] == 0 and data is not None and complete and not failed and passed >= 6
    detail = f"{passed} native facts PASS" + (f"; FAIL: {'; '.join(failed)}" if failed else "")
    if data:
        detail += (f"; routing={data['wheel_routing']} inactive moves={data['inactive_moves']} wheels={data['inactive_wheels']}"
                   f" cover leave={data['cover']['leave_ms']}ms uncover move={data['uncover']['move_ms']}ms"
                   f" release-over-other leaves={data['release_over_other']['leaves']}")
    else:
        detail += "; no HOVERPROBE_JSON"
    return ok, detail + ("" if complete else "; incomplete")


def judge(stage: dict, stage_dir: Path) -> tuple[bool, str]:
    if not stage_dir.is_dir():
        return False, "no evidence returned"
    result = json.loads((stage_dir / "stage-result.json").read_text(encoding="utf-8-sig"))
    error = (result.get("error") or "").strip()
    if error:
        return False, f"stage error (exit {result['exit_code']}): {error[:300]}"
    if stage["kind"] == "probe":
        if stage.get("name") == "hover-probe":
            return judge_hover_probe(result, stage_dir)
        if stage.get("name") == "window-lifetime":
            stderr = (stage_dir / "windows-probe-stderr.log").read_text(errors="replace")
            case_records = re.findall(r"lifetime callback passed: trigger=(click|focus|key|cleanup) close_owner=(true|false)", stderr)
            cases = len(set(case_records))
            complete = "lifetime smoke complete:" in stderr
            leaks = bool(re.search(r"(?i)(memory address .* leaked|\bleaked:|error\(gpa\)|error\(debug_allocator\))", stderr))
            ok = result["exit_code"] == 0 and cases == 8 and len(case_records) == 8 and complete and not leaks
            return ok, f"{cases}/8 callback cases, completion={complete}, allocator_leaks={leaks}, exit={result['exit_code']}"
        if stage.get("renderer") == "d3d11":
            stdout = (stage_dir / "windows-probe-stdout.log").read_text(errors="replace")
            stderr = (stage_dir / "windows-probe-stderr.log").read_text(errors="replace")
            hardware = re.search(r"\[d3d11-adapter\].*software=0.*result=0x00000000", stderr) is not None
            contract = "D3D11 hardware contract: upload snapshot, nonzero-offset update, partial clear, padded readback, submit/wait PASS" in stdout
            timing = "D3D11 timestamp contract: pending, GPU duration, queue-independent lifetime PASS" in stdout
            ok = result["exit_code"] == 0 and hardware and contract and timing
            return ok, f"D3D11 hardware={hardware}, resource_contract={contract}, timestamp_contract={timing}, exit={result['exit_code']}"
        try:
            queue.validate_gpu_scope(stage_dir, "all")
        except ValueError as error:
            return False, str(error)
        passes = len(re.findall(r"^PASS:", (stage_dir / "windows-probe-stderr.log").read_text(errors="replace"), re.MULTILINE))
        errors = re.findall(r"^error: .*$", (stage_dir / "windows-probe-stderr.log").read_text(errors="replace"), re.MULTILINE)
        ok = result["exit_code"] == 0
        return ok, f"{passes} contract PASS" + ("" if ok else f"; {'; '.join(errors) or result.get('error', '').strip()}")
    summary = suite_summary(stage_dir)
    if summary is None:
        return False, f"no suite summary (exit {result['exit_code']}): {result.get('error', '').strip()[:300]}"
    text = f"{summary['passed']}/{summary['total']} passed"
    failures = [f"{f.get('name')}: {f.get('error', '')}"[:240] for f in summary.get("failures", [])]
    ok = (result["exit_code"] == 0 and summary["total"] >= stage["minimum_cases"] and summary["executed"] == summary["total"]
          and summary["passed"] == summary["total"] and not summary["failed"] and not summary["aborted"])
    audit = stage.get("audit")
    if ok and audit:
        command = ([sys.executable, str(REPO / "tools/windows_modal_frame_audit.py"), str(stage_dir), "--allow-shadow-halo"] if audit == "modal"
                   else [sys.executable, str(REPO / f"tools/windows_shared_{audit}_frame_audit.py"), str(stage_dir)])
        run = subprocess.run(command, capture_output=True, text=True, timeout=300)
        (stage_dir / f"host-{audit}-audit.log").write_text(run.stdout + run.stderr)
        verdict = stage_dir / f"{audit}-frame-audit.json"
        passed = run.returncode == 0 and (audit == "modal" or json.loads(verdict.read_text()).get("passed") is True)
        text += f"; {audit} frame audit {'passed' if passed else 'FAILED'}"
        if not passed:
            ok = False
            failures.append((run.stdout + run.stderr).strip()[-300:])
    return ok, text + ("" if not failures else " | " + " | ".join(failures))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base", default="http://127.0.0.1:19817")
    parser.add_argument("--arch", choices=["aarch64", "x86_64", "x86"], default="aarch64")
    parser.add_argument("--renderer", choices=["d3d12", "d3d11"], default="d3d12")
    parser.add_argument("--artifact-dir", type=Path, help="prebuilt bin directory (default: build into an isolated prefix)")
    parser.add_argument("--skip-build", action="store_true", help="reuse --artifact-dir (or zig-out/bin) as is")
    parser.add_argument("--prepare-only", action="store_true", help="bundle all artifacts without contacting a worker")
    parser.add_argument("--output-dir", type=Path, help="bundle directory for --prepare-only")
    parser.add_argument("--require-a11y", action="store_true", help="fail the batch if any UI Automation suite fails")
    parser.add_argument("--no-a11y", action="store_true", help="skip the UI Automation suites")
    parser.add_argument("--full-app-suites", action="store_true", help="also run all Storybook and text-input cases without filters")
    parser.add_argument("--stages", help="comma-separated stage names to run (iteration only; acceptance runs every stage)")
    parser.add_argument("--suite-timeout", type=float, default=900, help="seconds per individual suite")
    parser.add_argument("--zdoc", type=Path, help="zeditor checkout: add its zdoc-smoke stage (needs a Windows test-mode build in --zdoc-bin)")
    parser.add_argument("--zdoc-bin", action="append", default=[],
                        help="directory with zdoc-e2e.exe and assets/ (default: <zdoc>/zig-out/bin); "
                             "repeat as ARCH=DIR (aarch64=..., x86_64=...) to test several builds from one bundle")
    parser.add_argument("--zdoc-suite", type=Path,
                        help="zdoc suite instead of e2e/windows-zdoc-smoke.test.ts (relative to --zdoc), e.g. the manual hold")
    parser.add_argument("--zdoc-only", action="store_true", help="run only the zdoc stage (no Zenit build or stages)")
    parser.add_argument("--allow-foreground", action="store_true",
                        help="let the zdoc stages take the VM's foreground and inject native Windows input (SendInput); "
                             "also adds the real-input hover stages (hover-probe, hover-native)")
    parser.add_argument("--extra-suite", action="append", default=[], metavar="NAME=APP:SUITE[?filter=F&env.K=V]",
                        help="add a blocking e2e stage, e.g. popover-text-seam=storybook:e2e/popover-text-seam.test.ts; "
                             "optional query: filter=<ZENIT_E2E_FILTER> and env.<KEY>=<value> for the app, percent-encoded")
    parser.add_argument("--only-extra", action="store_true", help="run only the --extra-suite stages (a targeted repro)")
    parser.add_argument("--startup-timeout", type=float, default=60)
    parser.add_argument("--timeout", type=float, default=3600, help="seconds for the whole batch on the worker")
    parser.add_argument("--wait-worker", type=float, default=0, help="seconds to wait for a fresh worker heartbeat before queuing (the queue is shared; a worker inside another job's stage does not heartbeat)")
    args = parser.parse_args()
    if args.prepare_only and args.output_dir is None:
        parser.error("--prepare-only requires --output-dir")
    if args.require_a11y and args.no_a11y:
        parser.error("--require-a11y conflicts with --no-a11y")
    root = queue.data_dir()
    base = args.base.rstrip("/")
    started = time.monotonic()
    bin_dir = args.artifact_dir or REPO / "zig-out/bin"
    if args.zdoc_only and args.zdoc is None:
        parser.error("--zdoc-only requires --zdoc")
    if not args.skip_build and not args.zdoc_only:
        prefix = Path(tempfile.mkdtemp(prefix=f"zenit-win-{args.arch}-"))
        print(f"==> Building {args.arch} apps and GPU contracts into {prefix}", flush=True)
        build(args.arch, prefix, args.renderer)
        bin_dir = prefix / "bin"
    # Real-input hover stages take the worker's cursor and foreground: only with --allow-foreground.
    if args.only_extra and not args.extra_suite:
        parser.error("--only-extra requires --extra-suite")
    plan = [] if args.zdoc_only or args.only_extra else stages(not args.no_a11y, args.renderer, args.full_app_suites, args.allow_foreground)
    for spec in args.extra_suite:
        name, _, rest = spec.partition("=")
        rest, _, query = rest.partition("?")
        app, _, suite = rest.partition(":")
        if not (name and app in queue.E2E_APPS and (REPO / suite).is_file()):
            parser.error(f"--extra-suite {spec!r}: want NAME=APP:SUITE with APP in {sorted(queue.E2E_APPS)}")
        stage = {"name": name, "kind": "e2e", "exe_name": queue.E2E_APPS[app], "suite_source": suite,
                 "minimum_cases": 1, "blocking": True, "filter": ""}
        for item in filter(None, query.split("&")):
            key, _, value = item.partition("=")
            value = urllib.parse.unquote(value)  # %20 etc.: the spec travels through word splitting
            if key == "filter":
                stage["filter"] = value
            elif key.startswith("env.") and len(key) > 4:
                stage.setdefault("app_env", {})[key[4:]] = value
            else:
                parser.error(f"--extra-suite {spec!r}: unknown option {key!r} (filter=, env.KEY=)")
        plan.append(stage)
    if args.zdoc is not None:
        zdoc = args.zdoc.resolve()
        suite = zdoc / (args.zdoc_suite or "e2e/windows-zdoc-smoke.test.ts")
        # The smoke suite's case floor guards against silently skipped cases; any other suite sets none.
        cases = 12 if args.zdoc_suite is None else 1
        if len(args.zdoc_bin) <= 1 and not any("=" in b for b in args.zdoc_bin):
            plan.append(zdoc_stage(Path(args.zdoc_bin[0] if args.zdoc_bin else zdoc / "zig-out/bin").resolve(), suite, minimum_cases=cases))
        else:
            for spec in args.zdoc_bin:
                # ARCH[:RENDERER[:LABEL]]=DIR, e.g. aarch64:d3d11:arm64-d3d11-fast=out/bin
                head, sep, path = spec.partition("=")
                arch, renderer, label = (head.split(":") + [None, None])[:3]
                if not sep or arch not in ZDOC_ARCH_LABELS or (renderer and renderer not in ("d3d11", "d3d12")) or \
                        (label and not re.fullmatch(r"[a-z0-9-]{1,32}", label)):
                    parser.error(f"--zdoc-bin {spec}: expected ARCH[:RENDERER[:LABEL]]=DIR with ARCH in {', '.join(ZDOC_ARCH_LABELS)}")
                plan.append(zdoc_stage(Path(path).resolve(), suite, arch, renderer or None, label or None, cases))
        if args.allow_foreground:
            for stage in plan:
                if stage["name"].startswith("zdoc-smoke"):
                    stage["allow_foreground"] = True
    if args.stages is not None:
        wanted = [name for name in args.stages.split(",") if name]
        known = {stage["name"] for stage in plan}
        unknown = [name for name in wanted if name not in known]
        if not wanted or unknown:
            parser.error(f"--stages: unknown or empty stage names {unknown or wanted}; known: {', '.join(sorted(known))}")
        plan = [stage for stage in plan if stage["name"] in wanted]
    if args.require_a11y:
        for stage in plan:
            stage["blocking"] = True
    job_id = uuid.uuid4().hex
    folder = args.output_dir if args.prepare_only else root / "jobs" / job_id
    folder.mkdir(parents=True, exist_ok=args.prepare_only)
    print(f"==> Bundling {len(plan)} stages", flush=True)
    runtime_sha = make_job(plan, bin_dir, args.arch, folder, args.startup_timeout, args.renderer, args.suite_timeout)
    size = (folder / queue.BATCH_BUNDLE).stat().st_size
    if args.prepare_only:
        print(f"==> Prepared {len(plan)} stages ({size / 1e6:.1f} MB bundle); {folder}", flush=True)
        return 0
    token = queue.read_token(root)
    waited = time.monotonic()
    while True:
        health = queue.request(base, token, "GET", "/health")
        if args.wait_worker <= 0 or health.get("worker_maintenance") is True or time.time() - health.get("worker_seen_at", 0) <= 35:
            break
        if time.monotonic() - waited > args.wait_worker:
            break
        print(f"==> Worker busy (last heartbeat {time.time() - health.get('worker_seen_at', 0):.0f}s ago); waiting", flush=True)
        time.sleep(10)
    queue.require_worker(health)
    queue.request(base, token, "POST", "/jobs", {"id": job_id, "kind": "batch", "local_suite": {"env": {}, "runtime_sha256": runtime_sha},
                                                 "allow_foreground": args.allow_foreground})
    print(f"==> Batch job {job_id} queued ({size / 1e6:.1f} MB bundle); evidence: {folder}", flush=True)
    deadline = time.monotonic() + args.timeout
    last = ""
    while time.monotonic() < deadline:
        state = queue.request(base, token, "GET", f"/jobs/{job_id}")
        if state["status"] != last:
            print(f"    worker: {state['status']} (+{time.monotonic() - started:.0f}s)", flush=True)
            last = state["status"]
        if state["status"] in {"passed", "failed"}:
            break
        time.sleep(2)
    else:
        print(f"TIMEOUT: the batch did not finish in {args.timeout:.0f}s; {folder}", file=sys.stderr)
        return 1
    if state.get("error"):
        print(f"    worker note: {state['error'].strip()[:400]}")
    report = []
    for stage in plan:
        stage_dir = folder / "stages" / stage["name"]
        archive = folder / f"batch-{stage['name']}.zip"
        if archive.is_file():
            extract(archive, stage_dir)
        ok, detail = judge(stage, stage_dir)
        report.append({"stage": stage["name"], "blocking": stage["blocking"], "passed": ok, "detail": detail})
        mark = "PASS" if ok else ("FAIL" if stage["blocking"] else "fail (reported)")
        print(f"  {mark:16} {stage['name']:22} {detail}", flush=True)
    (folder / "batch-report.json").write_text(json.dumps(report, indent=2) + "\n")
    blocking_failed = [r["stage"] for r in report if r["blocking"] and not r["passed"]]
    # Passing stage evidence does not override a failed batch finalization.
    passed = state["status"] == "passed" and not blocking_failed
    failures = blocking_failed + ([] if state["status"] == "passed" else ["batch finalization"])
    print(f"==> {'PASSED' if passed else 'FAILED: ' + ', '.join(failures)} "
          f"in {time.monotonic() - started:.0f}s; report {folder / 'batch-report.json'}", flush=True)
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
