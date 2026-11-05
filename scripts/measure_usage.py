#!/usr/bin/env python3
"""Drive a test-mode Zenit app through an in-use workload over the file RPC
harness and sample its physical footprint and CPU time the whole time.

Workloads (all synthesized inside the app; the user's mouse/keyboard are never
touched):
  typing   focus --target and type one character every --interval-ms
  scroll   wheel-scroll at --at x,y, alternating direction every 40 events
  hover    sweep the pointer over --area x0,y0,x1,y1 in a zigzag
  caret    focus --target and leave the caret blinking
  idle     nothing

  scripts/measure_usage.py zig-out-tm/bin/storybook --story input --workload typing --target story.input.name
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from measure_footprint import rusage, MIB  # noqa: E402


class Rpc:
    def __init__(self, directory, app):
        self.dir = directory
        self.app = app

    def __call__(self, method, path, body=None, timeout=20):
        token = uuid.uuid4().hex
        tmp = os.path.join(self.dir, token + ".tmp")
        with open(tmp, "w") as f:
            json.dump(dict(method=method, path=path, body_json=json.dumps(body or {})), f)
        os.rename(tmp, os.path.join(self.dir, "req-" + token + ".json"))
        response = os.path.join(self.dir, "res-" + token + ".json")
        deadline = time.monotonic() + timeout
        while not os.path.exists(response):
            if self.app.poll() is not None:
                raise RuntimeError("app exited during RPC")
            if time.monotonic() > deadline:
                raise TimeoutError(path)
            time.sleep(0.005)
        time.sleep(0.002)
        with open(response) as f:
            text = f.read()
        os.unlink(response)
        return json.loads(text) if text else None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("binary")
    ap.add_argument("--story", default="input")
    ap.add_argument("--workload", choices=("typing", "scroll", "hover", "caret", "idle"), default="typing")
    ap.add_argument("--target", default="story.input.name")
    ap.add_argument("--at", default="640,500", help="scroll position x,y (logical)")
    ap.add_argument("--scroll-step", type=float, default=12, help="wheel delta per scroll event (positive scrolls down)")
    ap.add_argument("--scroll-mode", choices=("stream", "rpc"), default="stream",
                    help="stream: the app injects wheel events at --scroll-hz itself (a trackpad's rate, independent "
                         "of RPC latency); rpc: one RPC per event every --interval-ms")
    ap.add_argument("--scroll-hz", type=float, default=120)
    ap.add_argument("--scroll-span", type=int, default=30, help="scroll events per direction")
    ap.add_argument("--scroll-phased", action="store_true",
                    help="stream trackpad gestures (began/changed/ended per span) instead of phase-less wheel events")
    ap.add_argument("--area", default="240,90,1080,980", help="hover sweep area x0,y0,x1,y1 (logical)")
    ap.add_argument("--interval-ms", type=float, default=120)
    ap.add_argument("--settle", type=float, default=6)
    ap.add_argument("--duration", type=float, default=10)
    ap.add_argument("--after", type=float, default=3, help="sample this long after the workload stops")
    ap.add_argument("--env", action="append", default=[])
    ap.add_argument("--foreground", action="store_true")
    ap.add_argument("--label", default="")
    ap.add_argument("--log", help="write the app's stdout/stderr here")
    ap.add_argument("--trace", help="write every sample (t, phase, MiB) here")
    ap.add_argument("--cadence", action="store_true",
                    help="trace presented frames (Metal) and report active-phase pacing; implies --foreground "
                         "since background windows are not composited at display rate")
    ap.add_argument("--display-hz", type=float, help="known display refresh rate; avoids inferring it from dropped GPU frames")
    ap.add_argument("--perf", action="store_true",
                    help="per-frame stage times and work counts (ZENIT_PERF_TRACE): mean and p95 over the active phase")
    ap.add_argument("--threads", action="store_true",
                    help="report each thread's active-phase CPU %% (`ps -M` deltas; index 0 = main thread)")
    ap.add_argument("--sample", help="run `sample` on the app for the active phase and write its report here")
    ap.add_argument("--windowserver", action="store_true",
                    help="also report WindowServer CPU: its rate during the active phase minus its rate while the settled window sits idle (end of settle + after)")
    ap.add_argument("--resize", help="resize the window to logical WxH before the settle phase")
    ap.add_argument("--breakdown", help="write `footprint -p` at the end of the active phase to <path>.active and of the after phase to <path>.after")
    args = ap.parse_args()

    if args.cadence or args.perf:
        if args.cadence:
            args.foreground = True
        if not args.log:
            args.log = os.path.join(tempfile.mkdtemp(prefix="zenit_usage_log."), "app.log")
    rpc_dir = tempfile.mkdtemp(prefix="zenit_usage_rpc.")
    env = os.environ.copy()
    env.update(ZENIT_E2E_FILE_RPC_DIR=rpc_dir, ZENIT_E2E_ISOLATE_POINTER="1", ZENIT_STORYBOOK_STORY=args.story)
    # Production frame loop: no per-frame screenshot copy or invariant check.
    env["ZENIT_E2E_MEASURE"] = "1"
    if not args.foreground:
        env["ZENIT_E2E_BACKGROUND"] = "1"
    if args.cadence:
        env["ZENIT_GLASS_CLOCK_TRACE"] = "1"
    if args.perf:
        env["ZENIT_PERF_TRACE"] = "1"
    for kv in args.env:
        k, _, v = kv.partition("=")
        env[k] = v
    log = open(args.log, "w") if args.log else subprocess.DEVNULL
    app = subprocess.Popen([args.binary], env=env, stdout=log, stderr=subprocess.STDOUT)
    rpc = Rpc(rpc_dir, app)
    samples = []
    phase = "settle"
    main0 = main1 = None

    def main_thread_cpu_s():
        # The first thread `ps -M` lists is the main thread: render, layout and event dispatch.
        try:
            out = subprocess.run(["ps", "-M", "-p", str(app.pid)], capture_output=True, text=True, timeout=5).stdout
            cols = out.splitlines()[1].split()
            secs = 0.0
            for t in cols[6:8]:
                m, _, sec = t.rpartition(":")
                secs += float(sec) + 60 * float(m or 0)
            return secs
        except (IndexError, ValueError, subprocess.SubprocessError):
            return None

    def thread_cpu_s():
        # Every `ps -M` row is one thread (main first); its last two time
        # columns are system and user time.
        try:
            out = subprocess.run(["ps", "-M", "-p", str(app.pid)], capture_output=True, text=True, timeout=5).stdout
        except subprocess.SubprocessError:
            return None
        secs = []
        for line in out.splitlines()[1:]:
            times = [t for t in line.split() if ":" in t and t.replace(":", "").replace(".", "").isdigit()]
            total = 0.0
            for t in times[-2:]:
                m, _, sec = t.rpartition(":")
                total += float(sec) + 60 * float(m or 0)
            secs.append(total)
        return secs

    ws_pid = None
    if args.windowserver:
        out = subprocess.run(["pgrep", "-x", "WindowServer"], capture_output=True, text=True).stdout.split()
        ws_pid = int(out[0]) if out else None
    ws_marks = {}

    def ws_mark(name):
        # WindowServer composites every app; `ps` reads its CPU time without privileges (10 ms resolution).
        if ws_pid is None:
            return
        try:
            t = subprocess.run(["ps", "-o", "time=", "-p", str(ws_pid)], capture_output=True, text=True, timeout=5).stdout.strip()
            secs = 0.0
            for part in t.split(":"):
                secs = secs * 60 + float(part)
            ws_marks[name] = (time.monotonic(), secs)
        except (ValueError, subprocess.SubprocessError):
            pass

    def sample():
        r = rusage(app.pid)
        if r:
            r["phase"] = phase
            r["t"] = time.monotonic()
            samples.append(r)

    try:
        deadline = time.monotonic() + 20
        while True:
            try:
                rpc("GET", "/health", timeout=2)
                break
            except (TimeoutError, FileNotFoundError):
                if time.monotonic() > deadline:
                    raise
        if args.resize:
            w, _, h = args.resize.partition("x")
            rpc("POST", "/resize", {"width": float(w), "height": float(h)})
        frames = {}
        end = time.monotonic() + args.settle
        ws_quiet_at = time.monotonic() + args.settle / 2
        while time.monotonic() < end:
            sample()
            if "settle_mid" not in ws_marks and time.monotonic() >= ws_quiet_at:
                ws_mark("settle_mid")
            time.sleep(0.1)
        frames["settle_end"] = rpc("POST", "/stats").get("frame_count")
        ws_mark("active_start")
        active_t0 = time.monotonic()
        main0 = main_thread_cpu_s()
        threads0 = thread_cpu_s() if args.threads else None
        sampler = None
        if args.sample:
            sampler = subprocess.Popen(["/usr/bin/sample", str(app.pid), str(max(1, int(args.duration) - 1)), "-file", args.sample],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if args.workload in ("typing", "caret"):
            rpc("POST", "/click", {"test_id": args.target})
        phase = "active"
        x, y = (float(v) for v in args.at.split(","))
        streaming = args.workload == "scroll" and args.scroll_mode == "stream"
        n = 0
        if streaming:
            n = int(args.duration * args.scroll_hz)
            rpc("POST", "/scroll_stream", {"x": x, "y": y, "step": args.scroll_step, "span": args.scroll_span,
                                           "count": n, "interval_ms": 1000 / args.scroll_hz,
                                           "phased": 1 if args.scroll_phased else 0})
        end = time.monotonic() + args.duration
        next_sample = 0.0
        while time.monotonic() < end:
            if args.workload == "typing":
                rpc("POST", "/text_input", {"text": "abcdefghij klmnopqrst "[n % 22]})
            elif args.workload == "hover":
                x0, y0, x1, y1 = (float(v) for v in args.area.split(","))
                rows = 12
                row = (n // 24) % rows
                col = n % 24 if row % 2 == 0 else 23 - n % 24
                rpc("POST", "/mouse_move", {"x": x0 + (x1 - x0) * col / 23, "y": y0 + (y1 - y0) * row / (rows - 1)})
            elif args.workload == "scroll" and not streaming:
                # Down first from the top, reversing before either end so every
                # event moves content (a pinned scroll draws nothing new).
                dy = args.scroll_step if (n // args.scroll_span) % 2 == 0 else -args.scroll_step
                rpc("POST", "/scroll", {"x": x, "y": y, "dx": 0, "dy": dy})
            if not streaming and args.workload in ("typing", "hover", "scroll"):
                n += 1
            now = time.monotonic()
            if now >= next_sample:
                sample()
                next_sample = now + 0.1
            time.sleep(args.interval_ms / 1000)
        active_t1 = time.monotonic()
        ws_mark("active_end")
        main1 = main_thread_cpu_s()
        threads1 = thread_cpu_s() if args.threads else None
        if sampler is not None:
            sampler.wait(timeout=30)
        frames["active_end"] = rpc("POST", "/stats").get("frame_count")
        if args.breakdown:
            with open(args.breakdown + ".active", "w") as f:
                f.write(subprocess.run(["/usr/bin/footprint", "-p", str(app.pid)], capture_output=True, text=True).stdout)
        phase = "after"
        end = time.monotonic() + args.after
        ws_after_at = time.monotonic() + min(1.0, args.after / 2)
        while time.monotonic() < end:
            sample()
            if "after_quiet" not in ws_marks and time.monotonic() >= ws_after_at:
                ws_mark("after_quiet")
            time.sleep(0.1)
        frames["after_end"] = rpc("POST", "/stats").get("frame_count")
        ws_mark("after_end")
        if args.breakdown:
            with open(args.breakdown + ".after", "w") as f:
                f.write(subprocess.run(["/usr/bin/footprint", "-p", str(app.pid)], capture_output=True, text=True).stdout)
    finally:
        app.terminate()
        try:
            app.wait(timeout=10)
        except subprocess.TimeoutExpired:
            app.kill()

    if args.trace:
        with open(args.trace, "w") as f:
            t0 = samples[0]["t"] if samples else 0
            for row in samples:
                f.write("%.2f %s %.1f\n" % (row["t"] - t0, row["phase"], row["phys"] / MIB))

    def stats(name):
        rows = [s for s in samples if s["phase"] == name]
        if len(rows) < 2:
            return None
        phys = sorted(s["phys"] for s in rows)
        elapsed = rows[-1]["t"] - rows[0]["t"]
        return dict(p50_mib=round(phys[len(phys) // 2] / MIB, 1), max_mib=round(phys[-1] / MIB, 1),
                    cpu_pct=round(100 * (rows[-1]["cpu_s"] - rows[0]["cpu_s"]) / elapsed, 1) if elapsed > 0 else None,
                    wakeups_per_s=round((rows[-1]["wakeups"] - rows[0]["wakeups"]) / elapsed) if elapsed > 0 else None,
                    # Process-wide retired instructions / cycles per second (all threads).
                    minstr_per_s=round((rows[-1]["instructions"] - rows[0]["instructions"]) / elapsed / 1e6, 1) if elapsed > 0 else None,
                    mcycles_per_s=round((rows[-1]["cycles"] - rows[0]["cycles"]) / elapsed / 1e6, 1) if elapsed > 0 else None)

    result = dict(label=args.label, workload=args.workload, story=args.story, events=n,
                  events_basis="requested_stream_events" if streaming else "completed_input_rpcs", frames=frames,
                  settle=stats("settle"), active=stats("active"), after=stats("after"))
    if main0 is not None and main1 is not None and result["active"]:
        result["active"]["main_cpu_pct"] = round(100 * (main1 - main0) / (active_t1 - active_t0), 1)
    if threads0 and threads1 and result["active"]:
        span = active_t1 - active_t0
        # Threads are matched by position; ones that started during the
        # active phase count from zero.
        result["active"]["thread_cpu_pct"] = [round(100 * (b - (threads0[i] if i < len(threads0) else 0)) / span, 1)
                                              for i, b in enumerate(threads1)]
    if len(ws_marks) == 5:
        rate = lambda a, b: 100 * (ws_marks[b][1] - ws_marks[a][1]) / (ws_marks[b][0] - ws_marks[a][0])
        quiet = (rate("settle_mid", "active_start") + rate("after_quiet", "after_end")) / 2
        active = rate("active_start", "active_end")
        result["windowserver"] = dict(active_pct=round(active, 1), quiet_pct=round(quiet, 1), delta_pct=round(active - quiet, 1))
    if args.cadence or args.perf:
        log.close()
    if args.perf:
        result["perf"] = perf_summary(args.log, frames.get("settle_end") or 0, frames.get("active_end") or 0)
    if args.cadence:
        # time.monotonic and CACurrentMediaTime both read mach_absolute_time on macOS.
        result["cadence"] = cadence(args.log, active_t0, active_t1,
                                    period_hint=1000 / args.display_hz if args.display_hz else None)
        result["cadence"]["period_basis"] = "explicit_display_hz" if args.display_hz else "inferred_gpu_intervals"
    print(json.dumps(result), flush=True)


def perf_summary(log_path, first, last):
    """Mean and p95 of every non-zero [perf] field over frames first+1..last."""
    rows = []
    with open(log_path, errors="replace") as f:
        for line in f:
            if line.startswith("[perf] {"):
                try:
                    e = json.loads(line[len("[perf] "):])
                except ValueError:
                    continue
                if first < e.get("frame", 0) <= last:
                    rows.append(e)
    out = {"frames": len(rows)}
    if not rows:
        return out
    for key in rows[0]:
        if key == "frame":
            continue
        xs = sorted(r.get(key, 0) for r in rows)
        mean = sum(xs) / len(xs)
        if mean:
            out[key] = [round(mean, 1), xs[min(len(xs) - 1, int(0.95 * len(xs)))]]
    return out


def percentile(xs, q):
    return xs[min(len(xs) - 1, int(q * len(xs)))] if xs else None


def cadence(log_path, t0, t1, period_hint=None):
    """Pacing of everything shown between host times t0 and t1, from the
    [glass-clock] trace: GPU frames at their presented time, CPU damage
    patches at the vsync after their hand-off, and frames whose paint equals
    the presented one ("unchanged": nothing is submitted, the screen already
    shows that image, where a GPU path would present an identical drawable)
    at the vsync such a drawable would reach: their time plus the median
    submit-to-present latency of the GPU frames. Reports display intervals,
    frames shown more than half a period late, GPU frames that never reached
    the screen (an occluded or inactive window makes the run invalid), and GPU
    execution time. Compositor-driven sprites do not appear: they animate at
    display rate without frames."""
    gpu_shown, patches, unchanged, unshown, gpu = [], [], [], 0, []
    submitted, presented_at = {}, {}
    with open(log_path, errors="replace") as f:
        for line in f:
            if not line.startswith("[glass-clock] {"):
                continue
            try:
                e = json.loads(line[len("[glass-clock] "):])
            except ValueError:
                continue
            kind, host = e.get("kind"), e.get("host_time", 0)
            if kind == "submit-ready":
                submitted[e.get("frame")] = host
            elif kind == "presented":
                t = e["presented_time"]
                if t > 0:
                    presented_at[e.get("frame")] = t
                if t > 0 and t0 <= t <= t1:
                    gpu_shown.append(t)
                elif t <= 0 and t0 <= host <= t1:
                    unshown += 1
            elif kind == "patch" and t0 <= host <= t1:
                patches.append(host)
            elif kind == "unchanged" and t0 <= host <= t1:
                unchanged.append(host)
            elif kind == "gpu-complete" and t0 <= host <= t1 and e.get("gpu_end_time", 0) > e.get("gpu_start_time", 0):
                gpu.append((e["gpu_end_time"] - e["gpu_start_time"]) * 1e3)
    raw = sorted((b - a) * 1e3 for a, b in zip(sorted(gpu_shown), sorted(gpu_shown)[1:]))
    period = period_hint or (percentile(raw, 0.1) if len(raw) > 10 else 1000 / 60)
    period_s = period / 1e3
    # A patch shows at the first vsync after it; align to the GPU vsync grid when there is one.
    phase = gpu_shown[0] if gpu_shown else 0.0
    vsync = lambda t: phase + period_s * (int((t - phase) / period_s) + 1)
    latencies = sorted(presented_at[k] - v for k, v in submitted.items() if k in presented_at and presented_at[k] > v)
    latency = percentile(latencies, 0.5) or 0.0
    nearest = lambda t: phase + period_s * round((t - phase) / period_s)
    shown = sorted(set(round(t, 4) for t in gpu_shown) | set(round(vsync(t), 4) for t in patches) |
                   set(round(nearest(t + latency), 4) for t in unchanged))
    intervals = sorted((b - a) * 1e3 for a, b in zip(shown, shown[1:]))
    r = lambda v: round(v, 2) if v is not None else None
    out = dict(gpu_frames=len(gpu_shown), patch_frames=len(patches), unchanged_frames=len(unchanged),
               unshown_gpu_frames=unshown,
               valid=len(shown) >= 2 and unshown <= max(2, len(gpu_shown) // 50), period_ms=r(period),
               fps_basis="estimated_composite_updates",
               gpu_presented_fps=r(len(gpu_shown) / (t1 - t0)),
               gpu_interval_p50_ms=r(percentile(raw, 0.5)),
               gpu_interval_p95_ms=r(percentile(raw, 0.95)),
               gpu_interval_max_ms=r(raw[-1]) if raw else None)
    if len(shown) < 2:
        return out
    g = sorted(gpu)
    out.update(fps=r(len(shown) / (t1 - t0)),
               interval_p50_ms=r(percentile(intervals, 0.5)), interval_p95_ms=r(percentile(intervals, 0.95)),
               interval_p99_ms=r(percentile(intervals, 0.99)), interval_max_ms=r(intervals[-1]),
               late_frames=sum(1 for d in intervals if d > period * 1.5),
               gpu_p50_ms=r(percentile(g, 0.5)), gpu_p95_ms=r(percentile(g, 0.95)))
    return out

if __name__ == "__main__":
    main()
