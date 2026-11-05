#!/usr/bin/env python3
"""Native acceptance for compositor sprites (ui core/compositor_sprite.zig).

Drawable readback cannot see the native sprite layers, so the ordinary e2e
suite runs with sprites disabled. This check runs a test-mode Storybook in the
foreground with sprites enabled and reads WindowServer images of its own window
(/screenshot/composited; no screen-recording permission needed):

  spinner-exact   locked frame clock on a flipbook sample, sprite frozen on that
                  frame; disabling sprites makes the GPU paint the same instant:
                  the two composited windows must match pixel for pixel. No
                  frame may be rendered while the sprite is up.
  spinner-live    real clock: the compositor animates (images 270 ms apart
                  differ) while the app renders no frames.
  caret           after typing, the focused caret blinks through the compositor
                  (both phases seen, no frames); its lit phase matches the GPU
                  caret pixel for pixel. Runs with CPU patches on as well, so
                  the caret atlas is rasterized on the CPU.
  patch-scroll    the same for wheel scrolling a list (shadows, icons, text):
                  every step a CPU patch, the final one equal to the GPU frame.
  patch-scroll-glass
                  content scrolling beneath the glass toolbar is never patched.
  patch-sidebar   scrolling inside the glass sidebar: patches reuse the GPU
                  glass underlay byte for byte and draw the rows over it.
  glass-refresh   typing within the glass sidebar's sampled margin: CPU patches,
                  then one GPU frame recomposites the glass once typing stops.
  patch-typing    locked clock, frozen caret sprite: typed edits are presented as CPU
                  damage patches (no GPU frame); disabling patches makes the
                  GPU render the same instant: the composited windows must
                  match pixel for pixel.

  scripts/check_compositor_sprites.py zig-out-tm/bin/storybook
Build: zig build -Dtest-mode=true -Doptimize=fast storybook-exe --prefix zig-out-tm
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from measure_usage import Rpc  # noqa: E402

from PIL import Image, ImageChops  # noqa: E402

SPINNER_PERIOD_MS = 5600.0
SPINNER_FRAMES = 336
PATCH_SETTLE_S = 0.5


class App:
    def __init__(self, binary, story, env, workdir):
        self.dir = tempfile.mkdtemp(prefix="zenit_sprite_rpc.", dir=workdir)
        environ = os.environ.copy()
        environ.pop("ZENIT_E2E_BACKGROUND", None)
        environ.update(ZENIT_E2E_FILE_RPC_DIR=self.dir, ZENIT_E2E_ISOLATE_POINTER="1",
                       ZENIT_STORYBOOK_STORY=story, ZENIT_SPRITES="1",
                       # The harness' virtual cursor overlay is test-only paint.
                       ZENIT_E2E_HIDE_VIRTUAL_CURSOR="1")
        environ.update(env)
        self.log = open(os.path.join(workdir, story + ".app.log"), "w")
        self.proc = subprocess.Popen([binary], env=environ, stdout=self.log, stderr=subprocess.STDOUT)
        self.rpc = Rpc(self.dir, self.proc)
        deadline = time.monotonic() + 20
        try:
            while True:
                try:
                    self.rpc("GET", "/health", timeout=2)
                    startup_log = Path(self.log.name).read_text(errors="replace")
                    if "matches no story; opening the first one" in startup_log or "is not in this build's -Dstories selection" in startup_log:
                        raise RuntimeError("requested Storybook story did not load")
                    return
                except (TimeoutError, FileNotFoundError):
                    if time.monotonic() > deadline:
                        raise
        except BaseException:
            self.close()
            raise

    def sprites(self, enabled=None):
        return self.rpc("POST", "/sprites", {} if enabled is None else {"enabled": enabled})

    def patches(self, enabled=None):
        return self.rpc("POST", "/cpu_patches", {} if enabled is None else {"enabled": enabled})

    def frames(self):
        return self.rpc("POST", "/stats")["frame_count"]

    def capture(self, path):
        # The window's captured bounds can be transiently larger right after
        # activation; use an image once two consecutive sizes agree.
        size = None
        for _ in range(6):
            result = self.rpc("POST", "/screenshot/composited", {"path": path})
            if not result or not result.get("ok"):
                raise RuntimeError("composited capture failed: %r" % (result,))
            image = Image.open(path).convert("RGB")
            if image.size == size:
                return image
            size = image.size
            time.sleep(0.05)
        raise RuntimeError("window capture size unstable")

    def quiet_frames(self, seconds):
        """Frames rendered during `seconds` without any harness command (every
        command forces a frame)."""
        f0 = self.frames()
        time.sleep(seconds)
        return self.frames() - f0 - 1

    def close(self):
        try:
            if self.proc.poll() is None:
                self.proc.terminate()
            try:
                code = self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=5)
                raise RuntimeError("app shutdown timed out")
        finally:
            self.log.close()
        if code != 0:
            raise RuntimeError("app exited with status %s" % code)
        with open(self.log.name, errors="replace") as log:
            if re.search(r"error\((?:gpa|DebugAllocator)\):.*leaked", log.read()):
                raise RuntimeError("allocator leak reported at app exit")


# System traffic-light buttons follow the window's key state, which another
# app can take between two captures; they are not Zenit pixels.
SYSTEM_BUTTONS_PX = (0, 0, 150, 64)


def region_diff(a, b, rects):
    """Differences inside the sprite cells only (pixels elsewhere may change
    between captures for unrelated reasons, e.g. glass recomputation)."""
    total = dict(pixels=0, max=0, cells=len(rects))
    for x, y, w, h in rects:
        d = diff_stats(a.crop((x, y, x + w, y + h)), b.crop((x, y, x + w, y + h)))
        total["pixels"] += d["pixels"]
        total["max"] = max(total["max"], d["max"])
    return total


def channel_max(diff):
    """Per-pixel largest channel difference (a luma conversion would round a
    one-level blue or red difference to zero)."""
    r, g, b = diff.split()
    return ImageChops.lighter(ImageChops.lighter(r, g), b)


def diff_stats(a, b, mask=None):
    if a.size != b.size:
        return dict(size_mismatch=True, pixels=a.size[0] * a.size[1], max=255, bbox=None)
    d = ImageChops.difference(a, b)
    if mask:
        d.paste((0, 0, 0), mask)
    hist = channel_max(d).histogram()
    return dict(pixels=sum(hist[1:]), max=max(i for i, c in enumerate(hist) if c) if any(hist) else 0, bbox=d.getbbox())


def wait_until(predicate, timeout, interval=0.05):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(interval)
    return predicate()


def check(results, name, ok, **detail):
    results.append(dict(check=name, ok=bool(ok), **detail))
    print(("PASS " if ok else "FAIL ") + name + " " + json.dumps(detail, default=str), flush=True)


def accent_pixels(image):
    # Spinner accent is a saturated blue: count pixels clearly bluer than red.
    return sum(1 for r, g, b in image.get_flattened_data() if b > r + 50 and b > 120)


def spinner_exact(binary, workdir, results, story="spinner", tag="spinner-exact"):
    """story="button": loading rings inherit the button's text color
    (currentColor); a flipbook drawn without it painted every ring dark."""
    app = App(binary, story, {"ZENIT_DEBUG_SPRITE_FREEZE": "1"}, workdir)
    try:
        app.rpc("POST", "/clock", {"step_ms": 16, "locked": True})
        time.sleep(0.3)
        t = app.sprites()["frame_time_ms"]
        sample = SPINNER_PERIOD_MS / SPINNER_FRAMES
        # Mid cycle: long arcs, so a phase error cannot hide in a tiny one.
        target = (int(t // sample) + 3 + 120) * sample
        app.rpc("POST", "/clock/advance", {"ms": target - t})
        status = wait_until(lambda: (s := app.sprites())["active"] > 0 and s["active"] == s["sources"]
                            and abs(s["frame_time_ms"] - target) < 1e-3 and s, 6)
        check(results, tag + ": sprites admitted", status and status["active"] > 0, status=status)
        check(results, tag + ": clock on a flipbook sample", status and abs(status["frame_time_ms"] - target) < 1e-3,
              frame_time=status and status["frame_time_ms"], target=target)
        settled = wait_until(lambda: app.quiet_frames(0.5) <= 0, 4, interval=0)
        quiet = app.quiet_frames(0.6)
        check(results, tag + ": no frames while composited", settled and quiet <= 0, frames=quiet)
        rects = status["rects"] if status else []
        sprite = app.capture(os.path.join(workdir, tag + "-sprite.png"))
        app.sprites(False)
        gone = wait_until(lambda: app.sprites()["active"] == 0, 3)
        time.sleep(0.4)
        check(results, tag + ": sprites released", gone)
        check(results, tag + ": frozen clock unchanged", abs(app.sprites()["frame_time_ms"] - target) < 1e-3)
        gpu = app.capture(os.path.join(workdir, tag + "-gpu.png"))
        stats = region_diff(sprite, gpu, rects)
        if story == "spinner":
            check(results, tag + ": spinner present", accent_pixels(gpu) > 200 and accent_pixels(sprite) > 200,
                  gpu=accent_pixels(gpu), sprite=accent_pixels(sprite))
        if story == "spinner":
            check(results, tag + ": composited sprite == GPU paint", stats["pixels"] == 0 and stats["cells"] > 0, **stats)
        else:
            # Ring color must match (a wrong currentColor differs by >200).
            # Open: button rings also differ by up to ~14 levels on a few edge
            # pixels between sprite and GPU paint (present before one-pass
            # atlases; position and color agree), so this is not yet exact.
            check(results, tag + ": composited ring color == GPU paint", stats["max"] <= 32 and stats["cells"] > 0, **stats)
    finally:
        app.close()


def spinner_live(binary, workdir, results):
    app = App(binary, "spinner", {}, workdir)
    try:
        status = wait_until(lambda: (s := app.sprites())["active"] > 0 and s, 6)
        check(results, "spinner-live: sprites admitted", status, status=status)
        settled = wait_until(lambda: app.quiet_frames(0.5) <= 0, 4, interval=0)
        quiet = app.quiet_frames(1.0)
        check(results, "spinner-live: no frames while animating", settled and quiet <= 0, frames=quiet)
        a = app.capture(os.path.join(workdir, "spinner-live-a.png"))
        time.sleep(0.27)
        b = app.capture(os.path.join(workdir, "spinner-live-b.png"))
        stats = diff_stats(a, b)
        check(results, "spinner-live: compositor animates", stats["pixels"] > 50, **stats)
        check(results, "spinner-live: still composited after captures", app.sprites()["active"] > 0)
    finally:
        app.close()


def blink_series(app, workdir, tag, box, count=14, interval=0.1):
    """Sample the caret box; returns [((start, end), darkness, image)] where
    the capture reflects the screen at some instant within [start, end]."""
    series = []
    for i in range(count):
        start = time.monotonic()
        image = app.capture(os.path.join(workdir, "caret-%s-%d.png" % (tag, i)))
        series.append(((start, time.monotonic()), sum(sum(px) for px in image.crop(box).get_flattened_data()), image))
        time.sleep(interval)
    return series


def trace_events(path):
    out = []
    with open(path, errors="replace") as f:
        for line in f:
            if line.startswith("[glass-clock] {"):
                try:
                    out.append(json.loads(line[len("[glass-clock] "):]))
                except ValueError:
                    pass
    return out


# GPU presentation latency reaches ~55 ms (three frames); a wrong blink
# phase is off by 100 ms or more.
CARET_PHASE_TOLERANCE_MS = 80


def caret_phase(binary, workdir, results, target, env=None, tag="caret-phase"):
    """The composited caret and the frame-drawn caret blink on one clock,
    timed from trace timestamps instead of screenshots: the compositor shows
    flipbook frame 0 (caret on) at anchor + k*period; a frame-drawn turn-on
    shows at the first GPU presentation or CPU patch after the frame that
    turned it on, or at the commit of a natively flipped caret layer. Their
    phases (mod the period) differ by presentation latency
    only (a frame or two), not by a blink offset."""
    app = App(binary, "input", dict(env or {}, ZENIT_GLASS_CLOCK_TRACE="1"), workdir)
    log = os.path.join(workdir, "input.app.log")
    try:
        app.rpc("POST", "/click", {"test_id": target})
        app.rpc("POST", "/text_input", {"text": "ab"})
        up = wait_until(lambda: app.sprites()["active"] > 0, 4)
        check(results, tag + ": sprite admitted", up)
        if not up:
            return
        time.sleep(0.3)
        app.sprites(False)
        wait_until(lambda: app.sprites()["active"] == 0, 3)
        time.sleep(3.5)
    finally:
        app.close()
    events = trace_events(log)
    sprites = [e for e in events if e.get("kind") == "sprite"]
    check(results, tag + ": compositor phase traced", bool(sprites), sprites=len(sprites))
    if not sprites:
        return
    anchor, period = sprites[-1]["anchor"], sprites[-1]["period"]
    released = sprites[-1]["host_time"]
    gpu = sorted(e["presented_time"] for e in events if e.get("kind") == "presented" and e.get("presented_time", 0) > 0)
    patches = sorted(e["host_time"] for e in events if e.get("kind") == "patch")
    gaps = []
    for e in events:
        if e.get("kind") != "caret" or not e["visible"] or e["host_time"] <= released:
            continue
        if e.get("path") == "flip":
            shown = [e["host_time"]]  # a native layer flip shows with its commit
        else:
            shown = [t for t in gpu if t >= e["host_time"]][:1] + [t for t in patches if t >= e["host_time"]][:1]
        if not shown:
            continue
        d = ((min(shown) - anchor) * 1000) % (period * 1000)
        gaps.append(round(min(d, period * 1000 - d), 1))
    check(results, tag + ": frame-drawn turn-ons share the compositor phase",
          len(gaps) >= 2 and max(gaps) <= CARET_PHASE_TOLERANCE_MS, gaps_ms=gaps, tolerance_ms=CARET_PHASE_TOLERANCE_MS)


def caret(binary, workdir, results, target, env=None, tag="caret"):
    app = App(binary, "input", env or {}, workdir)
    try:
        app.rpc("POST", "/click", {"test_id": target})
        app.rpc("POST", "/text_input", {"text": "ab"})
        status = wait_until(lambda: (s := app.sprites())["active"] > 0 and s, 4)
        check(results, tag + ": sprite admitted", status, status=status)
        if not status:
            return
        # Focus transitions (border colour) keep rendering briefly; the blink
        # hand-off is judged once they settle.
        settled = wait_until(lambda: app.quiet_frames(0.5) <= 0, 4, interval=0)
        quiet = app.quiet_frames(1.5)
        check(results, tag + ": no frames while blinking", settled and quiet <= 0, frames=quiet)
        x, y, w, h = app.sprites()["rects"][0]
        box = (x, y, x + w, y + h)
        sprite = blink_series(app, workdir, tag + "-sprite", box)
        app.sprites(False)
        wait_until(lambda: app.sprites()["active"] == 0, 3)
        gpu = blink_series(app, workdir, tag + "-gpu", box)
        check(results, tag + ": compositor blinks", len({d for _, d, _ in sprite}) >= 2)
        for name, series in (("sprite", sprite), ("gpu", gpu)):
            states = {d for _, d, _ in series}
            check(results, tag + ": %s shows both phases" % name, len(states) >= 2, states=len(states))
        lit_sprite = min(sprite, key=lambda e: e[1])[2]
        lit_gpu = min(gpu, key=lambda e: e[1])[2]
        stats = region_diff(lit_sprite, lit_gpu, [(x, y, w, h)])
        check(results, tag + ": composited lit caret == GPU caret", stats["pixels"] == 0, **stats)
        # Blink phase agreement is timed from trace timestamps (caret_phase).
    finally:
        app.close()


def patch_typing(binary, workdir, results, target):
    app = App(binary, "input", {"ZENIT_CPU_PATCH": "1", "ZENIT_DEBUG_CPU_PATCH": "1", "ZENIT_DEBUG_SPRITE_FREEZE": "1", "ZENIT_GLASS_REFRESH_MS": "60000"}, workdir)
    try:
        app.rpc("POST", "/clock", {"step_ms": 16, "locked": True})
        app.rpc("POST", "/click", {"test_id": target})
        # AppKit draws its I-beam input-source indicator into the window at
        # the pointer; keep the pointer off the patched field.
        app.rpc("POST", "/mouse_move", {"x": 1000, "y": 900})
        time.sleep(0.3)
        before = app.patches()
        edits = ["h", "e", "l", "l", "o", " ", "w", "o", "r", "l", "d"]
        for text in edits:
            app.rpc("POST", "/text_input", {"text": text})
        for _ in range(3):
            app.rpc("POST", "/key_down", {"key": "backspace"})
            app.rpc("POST", "/key_up", {"key": "backspace"})
        app.rpc("POST", "/text_input", {"text": "xyz"})
        time.sleep(PATCH_SETTLE_S)
        typed = app.patches()
        cpu = typed["cpu_frames"] - before["cpu_frames"]
        gpu = typed["gpu_frames"] - before["gpu_frames"]
        check(results, "patch-typing: edits presented on the CPU", cpu >= len(edits) and gpu == 0 and typed["rects"],
              cpu_frames=cpu, gpu_frames=gpu, rects=typed["rects"])
        patched = app.capture(os.path.join(workdir, "patch-cpu.png"))
        # The caret blinks on the wall clock and is not composited yet (the
        # locked clock never reaches the compositor's settle time), so the two
        # captures may catch different blink phases. Caret pixels are the caret
        # scenarios' subject: mask its patch (the only one a caret wide).
        after = typed
        sprite_rects = app.sprites()["rects"] + [r for r in typed["rects"] if r[2] <= 16]
        app.patches(False)
        cleared = wait_until(lambda: (s := app.patches())["shown"] == 0 and s["gpu_frames"] > after["gpu_frames"] and s, 3)
        check(results, "patch-typing: GPU frame replaced the patches", cleared, status=cleared)
        time.sleep(0.3)
        rendered = app.capture(os.path.join(workdir, "patch-gpu.png"))
        # The caret sprite (own scenario) is excluded from both images.
        for image in (patched, rendered):
            for x, y, w, h in sprite_rects:
                image.paste((0, 0, 0), (x, y, x + w, y + h))
        stats = region_diff(patched, rendered, [r for r in typed["rects"] if r[2] > 16])
        check(results, "patch-typing: composited patches == GPU frame", stats["pixels"] == 0 and stats["cells"] > 0, **stats)
    finally:
        app.close()


def presented_scroll_step(app, x, y, dy):
    """Observe each step before issuing the next; RPC completion precedes paint.

    This is a visual path contract, not a throughput benchmark. Unchanged
    frames cannot satisfy it, and a missing presentation fails the scenario.
    """
    before = app.patches()
    app.rpc("POST", "/scroll", {"x": x, "y": y, "dx": 0, "dy": dy})
    shown = wait_until(lambda: (s := app.patches())["cpu_frames"] + s["gpu_frames"] >
                       before["cpu_frames"] + before["gpu_frames"] and s, 2, interval=0.01)
    if not shown:
        raise RuntimeError("scroll step did not produce a CPU patch or GPU frame")
    return shown


def patch_scroll(binary, workdir, results, story, at, under_glass=False):
    """under_glass: the scrolled content passes beneath glass, which refracts
    it; every step must then be rendered on the GPU (no patch may show a
    stale backdrop)."""
    # Region-sized patches exceed the default CPU budget (they go to the GPU,
    # see patch_budget); a fixed budget keeps their raster under test.
    app = App(binary, story, {"ZENIT_CPU_PATCH": "1", "ZENIT_CPU_PATCH_MAX_PIXELS": "4000000", "ZENIT_CPU_PATCH_BUDGET_US": "1000000",
                              "ZENIT_GLASS_REFRESH_MS": "60000"}, workdir)
    try:
        app.rpc("POST", "/clock", {"step_ms": 16, "locked": True})
        x, y = at
        if under_glass:
            stage = app.rpc("POST", "/query", {"test_id": "story.glasschrome.stage"})
            edge = app.rpc("POST", "/query", {"test_id": "story.glasschrome.edge"})
            if not stage or not edge:
                raise RuntimeError("glass scroll fixture did not mount")
            rect = stage[0]["rect"]
            x, y = rect["x"] + rect["w"] / 2, rect["y"] + rect["h"] * 0.7
        app.rpc("POST", "/mouse_move", {"x": x, "y": y})
        time.sleep(0.3)
        if under_glass:
            app.capture(os.path.join(workdir, "glass-scroll-initial.png"))
        before = app.patches()
        steps = 24
        # Keep the glass fixture away from its scroll limit, so every step
        # changes the backdrop instead of merely repeating a clamped offset.
        for i in range(steps):
            presented_scroll_step(app, x, y, (-12 if i < 16 else 12) if under_glass else (-37 if i < 16 else 23))
            if under_glass and i in (7, 15, 23):
                app.capture(os.path.join(workdir, "glass-scroll-step-%02d.png" % (i + 1)))
        time.sleep(0.3)
        after = app.patches()
        cpu = after["cpu_frames"] - before["cpu_frames"]
        gpu = after["gpu_frames"] - before["gpu_frames"]
        if under_glass:
            check(results, "patch-scroll(%s): steps under glass rendered on the GPU" % story, cpu == 0 and gpu >= steps and not after["rects"],
                  cpu_frames=cpu, gpu_frames=gpu, rects=after["rects"])
            return
        check(results, "patch-scroll(%s): steps presented on the CPU" % story, cpu >= steps and gpu == 0 and after["rects"],
              cpu_frames=cpu, gpu_frames=gpu, rects=after["rects"])
        patched = app.capture(os.path.join(workdir, "scroll-%s-cpu.png" % story))
        app.patches(False)
        cleared = wait_until(lambda: (s := app.patches())["shown"] == 0 and s["gpu_frames"] > after["gpu_frames"] and s, 3)
        check(results, "patch-scroll(%s): GPU frame replaced the patches" % story, cleared, status=cleared)
        time.sleep(0.3)
        rendered = app.capture(os.path.join(workdir, "scroll-%s-gpu.png" % story))
        stats = region_diff(patched, rendered, after["rects"])
        check(results, "patch-scroll(%s): composited patches == GPU frame" % story, stats["pixels"] == 0 and stats["cells"] > 0, **stats)
    finally:
        app.close()


def patch_budget(binary, workdir, results, story, at):
    """Default policy: scroll steps whose patch would cost the CPU more than a
    GPU frame are rendered on the GPU (low CPU first); typing stays on the CPU
    (patch_typing)."""
    app = App(binary, story, {"ZENIT_CPU_PATCH": "1"}, workdir)
    try:
        app.rpc("POST", "/clock", {"step_ms": 16, "locked": True})
        x, y = at
        app.rpc("POST", "/mouse_move", {"x": x, "y": y})
        time.sleep(0.3)
        before = app.patches()
        steps = 24
        for i in range(steps):
            app.rpc("POST", "/scroll", {"x": x, "y": y, "dx": 0, "dy": -37 if i < 16 else 23})
        time.sleep(0.3)
        after = app.patches()
        cpu = after["cpu_frames"] - before["cpu_frames"]
        gpu = after["gpu_frames"] - before["gpu_frames"]
        check(results, "patch-budget(%s): region-sized scroll steps rendered on the GPU" % story, cpu == 0 and gpu >= steps // 2,
              cpu_frames=cpu, gpu_frames=gpu, last_reason=after.get("last_reason"))
    finally:
        app.close()


def glass_refresh(binary, workdir, results, target):
    """Typing beside the glass sidebar changes only its sampled margin: the
    edits are CPU patches over the previous glass, and once typing stops one
    GPU frame recomposites the glass and replaces every patch."""
    app = App(binary, "input", {"ZENIT_CPU_PATCH": "1"}, workdir)
    try:
        app.rpc("POST", "/click", {"test_id": target})
        app.rpc("POST", "/mouse_move", {"x": 1000, "y": 900})
        time.sleep(0.5)
        before = app.patches()
        for text in "glass margin":
            app.rpc("POST", "/text_input", {"text": text})
        during = app.patches()
        cpu = during["cpu_frames"] - before["cpu_frames"]
        check(results, "glass-refresh: typing presented on the CPU", cpu >= len("glass margin") - 1 and during["gpu_frames"] == before["gpu_frames"],
              cpu_frames=cpu, gpu_frames=during["gpu_frames"] - before["gpu_frames"])
        # Every harness command renders a frame, which restarts the quiet
        # period: wait without polling, then look once.
        time.sleep(3.0)
        s = app.patches()
        done = s["gpu_frames"] > during["gpu_frames"] and s["shown"] == 0 and s
        check(results, "glass-refresh: one GPU frame replaced the patches after typing", done
              and done["gpu_frames"] - during["gpu_frames"] <= 2, status=done)
    finally:
        app.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("binary")
    ap.add_argument("--out", help="artifact directory (default: a new temporary directory)")
    ap.add_argument("--input-target", default="story.input.name")
    ap.add_argument("--only", action="append", help="run only this scenario (repeatable)")
    args = ap.parse_args()
    workdir = args.out or tempfile.mkdtemp(prefix="zenit_sprite_check.")
    os.makedirs(workdir, exist_ok=True)
    results = []
    scenarios = {
        "spinner-exact": lambda: spinner_exact(args.binary, workdir, results),
        "button-ring-exact": lambda: spinner_exact(args.binary, workdir, results, "button", "button-ring-exact"),
        "spinner-live": lambda: spinner_live(args.binary, workdir, results),
        "caret": lambda: caret(args.binary, workdir, results, args.input_target),
        "caret-phase": lambda: caret_phase(args.binary, workdir, results, args.input_target),
        "caret-phase+cpu": lambda: caret_phase(args.binary, workdir, results, args.input_target, {"ZENIT_CPU_PATCH": "1"}, "caret-phase+cpu"),
        "caret+cpu": lambda: caret(args.binary, workdir, results, args.input_target, {"ZENIT_CPU_PATCH": "1"}, "caret+cpu"),
        "patch-typing": lambda: patch_typing(args.binary, workdir, results, args.input_target),
        "patch-scroll": lambda: patch_scroll(args.binary, workdir, results, "virtuallist", (400, 260)),
        "patch-scroll-glass": lambda: patch_scroll(args.binary, workdir, results, "glasschrome", (558, 300), under_glass=True),
        "patch-sidebar": lambda: patch_scroll(args.binary, workdir, results, "badge", (100, 500)),
        "patch-budget": lambda: patch_budget(args.binary, workdir, results, "badge", (100, 500)),
        "glass-refresh": lambda: glass_refresh(args.binary, workdir, results, args.input_target),
    }
    unknown = set(args.only or ()) - set(scenarios)
    if unknown:
        ap.error("unknown scenario(s): " + ", ".join(sorted(unknown)))
    for name, run in scenarios.items():
        if args.only and name not in args.only:
            continue
        try:
            run()
        except Exception as error:  # a crashed scenario is a failure, not a skip
            check(results, name + ": scenario error", False, error=repr(error))
    failed = [r for r in results if not r["ok"]]
    with open(os.path.join(workdir, "result.json"), "w") as f:
        json.dump(dict(ok=not failed, results=results), f, indent=2, default=str)
    print(json.dumps(dict(ok=not failed, failed=len(failed), total=len(results), artifacts=workdir)))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
