#!/usr/bin/env python3
"""Native preview with L1 styles, L2 templates and L3 stateful restart; Python 3.9+."""
import argparse
import hashlib
import json
import os
import platform
from pathlib import Path
import re
import shutil
import signal
import stat
import math
import subprocess
import sys
import time
import uuid


class Stopped(Exception):
    pass


def atomic_json(path, value):
    temp = path.with_suffix('.tmp')
    with temp.open('w', encoding='utf-8') as file:
        json.dump(value, file, ensure_ascii=False)
        file.flush()
        os.fsync(file.fileno())
    os.replace(temp, path)


def read_json(path):
    try:
        return json.loads(path.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return None


class AppLock:
    """OS-owned lock with continuous path/handle identity validation."""
    def __init__(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.path = path
        # O_CREAT without O_TRUNC/O_APPEND: Windows byte zero never grows.
        self.file = os.fdopen(os.open(path, os.O_RDWR | os.O_CREAT, 0o600), 'r+b')
        try:
            if os.name == 'nt':
                import msvcrt
                self.file.seek(0)
                self.file.write(b'\0')
                self.file.flush()
                self.file.seek(0)
                msvcrt.locking(self.file.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(self.file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            self.file.close()
            raise RuntimeError('another preview launcher owns this application')

    def check(self):
        try:
            held, named = os.fstat(self.file.fileno()), self.path.stat()
            if os.name == 'nt' and (not held.st_ino or not named.st_ino):
                raise RuntimeError('preview locking requires stable nonzero Windows file IDs')
            if (held.st_dev, held.st_ino) == (named.st_dev, named.st_ino):
                return
        except OSError:
            pass
        raise RuntimeError('preview lock path was removed or replaced: ' + str(self.path))

    def close(self):
        self.file.close()


class Child:
    """Own the whole subprocess tree, including compiler/linker descendants."""
    def __init__(self, argv, **kwargs):
        self.job = None
        self.closed = False
        if os.name != 'nt':
            self.process = subprocess.Popen(argv, start_new_session=True, **kwargs)
            return
        # Start suspended: descendants cannot escape before Job assignment.
        import ctypes as c
        from ctypes import wintypes as w
        kernel = c.WinDLL('kernel32', use_last_error=True)
        kernel.CreateJobObjectW.argtypes = [c.c_void_p, w.LPCWSTR]
        kernel.CreateJobObjectW.restype = w.HANDLE
        kernel.SetInformationJobObject.argtypes = [w.HANDLE, c.c_int, c.c_void_p, w.DWORD]
        kernel.AssignProcessToJobObject.argtypes = [w.HANDLE, w.HANDLE]
        kernel.TerminateJobObject.argtypes = [w.HANDLE, w.UINT]
        kernel.CloseHandle.argtypes = [w.HANDLE]
        class Basic(c.Structure):
            _fields_ = [('process_time', c.c_int64), ('job_time', c.c_int64),
                        ('flags', w.DWORD), ('min_working', c.c_size_t), ('max_working', c.c_size_t),
                        ('active', w.DWORD), ('affinity', c.c_size_t), ('priority', w.DWORD), ('scheduling', w.DWORD)]
        class Limits(c.Structure):
            _fields_ = [('basic', Basic), ('io', c.c_uint64 * 6), ('process_memory', c.c_size_t),
                        ('job_memory', c.c_size_t), ('peak_process', c.c_size_t), ('peak_job', c.c_size_t)]
        self.kernel = kernel
        self.job = kernel.CreateJobObjectW(None, None)
        if not self.job:
            raise c.WinError(c.get_last_error())
        try:
            limits = Limits()
            limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            if not kernel.SetInformationJobObject(self.job, 9, c.byref(limits), c.sizeof(limits)):
                raise c.WinError(c.get_last_error())
            self.process = subprocess.Popen(argv, creationflags=4 | subprocess.CREATE_NEW_PROCESS_GROUP, **kwargs)
            try:
                if not kernel.AssignProcessToJobObject(self.job, int(self.process._handle)):
                    raise c.WinError(c.get_last_error())
                resume = c.WinDLL('ntdll').NtResumeProcess
                resume.argtypes = [w.HANDLE]
                resume.restype = c.c_long
                if resume(int(self.process._handle)) != 0:
                    raise RuntimeError('NtResumeProcess failed')
            except BaseException:
                self.process.kill()
                self.process.wait()
                raise
        except BaseException:
            kernel.CloseHandle(self.job)
            self.job = None
            raise

    @property
    def pid(self):
        return self.process.pid

    def poll(self):
        return self.process.poll()

    def request_window_close(self):
        # Give native windows a second cooperative retirement opportunity after
        # the dev quit deadline. PostMessage never waits for a stopped UI.
        import ctypes as c
        from ctypes import wintypes as w
        user = c.WinDLL('user32', use_last_error=True)
        callback_type = c.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)
        user.EnumWindows.argtypes = [callback_type, w.LPARAM]
        user.GetWindowThreadProcessId.argtypes = [w.HWND, c.POINTER(w.DWORD)]
        user.PostMessageW.argtypes = [w.HWND, w.UINT, w.WPARAM, w.LPARAM]
        def visit(window, _):
            pid = w.DWORD()
            user.GetWindowThreadProcessId(window, c.byref(pid))
            if pid.value == self.pid:
                user.PostMessageW(window, 0x0010, 0, 0)  # WM_CLOSE
            return True
        user.EnumWindows(callback_type(visit), 0)

    def close(self, grace=1):
        if self.closed:
            return
        if os.name == 'nt':
            if self.job:
                self.request_window_close()
                try:
                    self.process.wait(timeout=grace)
                except subprocess.TimeoutExpired:
                    pass
                self.kernel.TerminateJobObject(self.job, 1)
                self.kernel.CloseHandle(self.job)
                self.job = None
        else:
            # Even an exited leader may have living descendants in its group.
            try:
                os.killpg(self.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                self.process.wait(timeout=grace)
            except subprocess.TimeoutExpired:
                pass
            try:
                os.killpg(self.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        self.process.wait(timeout=5)
        self.closed = True


class Inputs:
    # Conservative superset: assets, native headers/shaders and build tools count too.
    roots = ('src', 'examples', 'native', 'tools', 'scripts', 'tests', 'vendor', 'templates', 'assets', 'themes')
    excluded = {'.git', '.zig-cache', 'zig-cache', 'zig-out', 'zig-pkg', 'node_modules', '__pycache__', '.preview-locks'}

    def __init__(self, root, extra=(), ignore=()):
        self.root = root
        self.ignored = {path.resolve() for path in ignore}
        self.paths = [root / p for p in self.roots] + list(extra)
        self.cache = {}

    def _scan_files(self):
        files = [self.root / p for p in ('build.zig', 'build.zig.zon')]
        files.extend(p for p in self.root.iterdir() if p.is_file() and (p.suffix in ('.zig', '.yix', '.yss', '.json', '.zon')))
        for root in self.paths:
            if any(root == path or path in root.parents for path in self.ignored):
                continue
            if root.is_file():
                files.append(root)
            elif root.exists():
                for base, dirs, names in os.walk(root, followlinks=False):
                    dirs[:] = sorted(d for d in dirs if d not in self.excluded and (Path(base) / d).resolve() not in self.ignored)
                    files.extend(Path(base) / name for name in names if name != '.DS_Store' and not name.endswith(('.pyc', '.tmp', '~', '.swp')))
        return sorted(set(files))

    def _entry(self, path):
        """(stamp, content digest) for a regular file, or None when absent/irregular."""
        if path.name == '.DS_Store':
            return None
        try:
            info = path.stat()
            if not stat.S_ISREG(info.st_mode):
                return None
            stamp = (info.st_mtime_ns, info.st_ctime_ns, info.st_size, info.st_dev, info.st_ino)
            old = self.cache.get(path)
            if old and old[0] == stamp:
                return old
            # A regular file can be replaced with a FIFO between stat/open.
            # Nonblocking open + fstat prevents this race from hanging polling.
            with os.fdopen(os.open(path, os.O_RDONLY | getattr(os, 'O_NONBLOCK', 0) | getattr(os, 'O_BINARY', 0)), 'rb') as file:
                opened = os.fstat(file.fileno())
                if not stat.S_ISREG(opened.st_mode):
                    return None
                stamp = (opened.st_mtime_ns, opened.st_ctime_ns, opened.st_size, opened.st_dev, opened.st_ino)
                return (stamp, hashlib.sha256(file.read()).digest())
        except FileNotFoundError:
            # Missing files contribute nothing; paths/content alone define identity.
            return None

    def _digest(self):
        digest = hashlib.sha256()
        for path in sorted(self.cache):
            digest.update(str(path).encode() + b'\0')
            digest.update(self.cache[path][1])
        return digest.hexdigest()

    def snapshot(self):
        """Full scan of every watched input (tens of ms on a large checkout)."""
        current = {}
        for path in self._scan_files():
            entry = self._entry(path)
            if entry is not None:
                current[path] = entry
        self.cache = current
        self._styles = [path for path in current if is_style_source(Path(os.path.relpath(path, self.root)).as_posix())]
        self._templates = [path for path in current if path.suffix == ".yix"]
        self._last_digest = self._digest()
        return self._last_digest

    def template_paths(self):
        return list(getattr(self, "_templates", ()))

    def reloadable_paths(self):
        return self.style_paths() + self.template_paths()

    def style_paths(self):
        """Known L1-reloadable inputs from the last full scan (a few dozen files)."""
        return list(getattr(self, '_styles', ()))

    def refresh(self, paths):
        """Re-stat only `paths` and return the digest of the whole cached input set.

        Style edits are detected at a fast cadence without rescanning thousands of
        files; anything else (including newly created files) waits for the next
        full snapshot().
        """
        changed = False
        for path in paths:
            entry = self._entry(path)
            if entry != self.cache.get(path):
                changed = True
                if entry is None:
                    self.cache.pop(path, None)
                else:
                    self.cache[path] = entry
        if changed or getattr(self, '_last_digest', None) is None:
            self._last_digest = self._digest()
        return self._last_digest

    def contents(self):
        """Immutable-by-convention path/content snapshot from the last scan."""
        return {path: value[1] for path, value in self.cache.items()}


def changed_paths(before, after):
    return {path for path in before.keys() | after.keys() if before.get(path) != after.get(path)}


def is_style_source(path):
    """Keep the fast watcher and runtime reload_styles source sets identical."""
    return path.endswith('.yss') or Path(path).name == 'theme.json' or path == 'src/tokens/default.json'


def route_style_changes(changed):
    """Only YSS/theme inputs use L1; every Zig/Yix change requires L3.

    Even generated companions of online-applied sources remain Zig inputs.
    The runtime is responsible for shape/compiled-thunk validation.
    """
    paths = {Path(path).as_posix() for path in changed}
    sources = {path for path in paths if is_style_source(path)}
    for path in sorted(paths):
        item = Path(path)
        if item.is_absolute() or '..' in item.parts:
            return dict(layer='L3', files=[], reason='input outside checkout: ' + path)
        if path in sources:
            continue
        return dict(layer='L3', files=[], reason='non-style input changed: ' + path)
    if not sources:
        return dict(layer='L3', files=[], reason='no reloadable style sources')
    return dict(layer='L1', files=sorted(sources), reason='style sources only')


def route_template_changes(changed):
    paths = {Path(path).as_posix() for path in changed}
    if paths and all(not Path(p).is_absolute() and '..' not in Path(p).parts and p.endswith('.yix') for p in paths):
        return dict(layer='L2', files=sorted(paths), reason='template sources only; runtime must prove hole identity')
    return route_style_changes(paths)


def diagnostics(text):
    text = re.sub(r'\x1b\[[0-9;]*m', '', text)
    lines = []
    for line in text.splitlines():
        match = re.match(r'^(.*?:\d+)(?::\d+)?:\s*(?:error:|note:)?\s*(.*)', line.strip())
        if match:
            lines.append(f'{match[1]}: {match[2]}')
    result = '\n'.join(dict.fromkeys(lines)) if lines else '\n'.join(text.splitlines()[-12:])
    return (result or 'preview:1: build failed (see build.log)').encode('utf-8')[:8000].decode('utf-8', errors='ignore')


class Preview:
    def __init__(self, args):
        self.args = args
        self.root = args.root.resolve()
        self.base = (args.session_root or self.root / '.zig-cache' / 'preview' / args.app).resolve()
        if self.base == self.root or self.base in self.root.parents:
            raise RuntimeError('session root must be a dedicated directory, not the checkout or its ancestor')
        self.base.mkdir(parents=True, exist_ok=True)
        self.inputs = Inputs(self.root, [p.resolve() for p in args.watch_dir], ignore=[self.base])
        self.children = []
        self.current = None
        self.stopping = False
        self.lock = None
        self.parent_pid = os.getppid()
        self.sequence = int((read_json(self.base / 'state.json') or {}).get('sequence', 0))
        self.state = {'sequence': self.sequence, 'current': None, 'launcher_pid': os.getpid()}
        # These are distinct: L1 changes the running values, but the next L3
        # must still compile every current source, including all online edits.
        self.source_inputs = {}
        self.compiled_inputs = {}
        self.online_files = set()
        self.pending_style_files = set()
        self.pending_template_files = set()

    def event(self, event, **fields):
        record = {'event': event, 'time': time.time(), **fields}
        with (self.base / 'events.jsonl').open('a', encoding='utf-8') as log:
            log.write(json.dumps(record) + '\n')
        self.state.update(event=event, **fields)
        atomic_json(self.base / 'state.json', self.state)
        print(json.dumps(record), flush=True)

    def check_current(self):
        if self.current and self.current['child'].poll() is not None:
            self.event('current_exited', exit_code=self.current['child'].poll())
            raise RuntimeError('current application exited; handoff cancelled')

    def check_ownership(self):
        if self.lock:
            self.lock.check()
        self.check_current()

    def claim_session(self):
        # Persistent owner prevents accidental cross-app reuse, even across runs.
        owner = self.base / 'application.json'
        try:
            with owner.open('x', encoding='utf-8') as file:
                json.dump({'app': self.args.app, 'checkout': str(self.root)}, file)
        except FileExistsError:
            pass
        if read_json(owner) != {'app': self.args.app, 'checkout': str(self.root)}:
            raise RuntimeError('session root belongs to another application/checkout or has invalid ownership')

    def pause(self, seconds=None):
        if self.stopping or (os.name != 'nt' and os.getppid() != self.parent_pid):
            raise Stopped()
        self.check_ownership()
        time.sleep(self.args.poll if seconds is None else seconds)
        self.check_ownership()
        if self.stopping:
            raise Stopped()

    def spawn(self, argv, log, env=None, cwd=None):
        self.check_ownership()
        with log.open('wb') as output:
            child = Child(argv, cwd=cwd or self.root, env=env, stdout=output, stderr=subprocess.STDOUT)
        self.children.append(child)
        return child

    def command(self, generation, name, **fields):
        control = generation['directory'] / 'dev-control'
        request_id = uuid.uuid4().hex
        request = control / f'req-{request_id}.json'
        response = control / f'res-{request_id}.json'
        try:
            atomic_json(request, {'command': name, 'timeout_ms': int(self.args.rpc_timeout * 1000), **fields})
            deadline = time.monotonic() + self.args.rpc_timeout + .5
            while time.monotonic() < deadline:
                result = read_json(response)
                if result is not None:
                    if not isinstance(result, dict):
                        raise RuntimeError('invalid command response')
                    if 'error' in result and not (name in ('reload_styles', 'reload_templates') and result.get('result') == 'error'):
                        raise RuntimeError(result['error'])
                    return result
                if generation['child'].poll() is not None:
                    raise RuntimeError('process exited during ' + name)
                self.pause(min(self.args.poll, .005) if name in ('reload_styles', 'reload_templates') else None)
            raise TimeoutError(name)
        finally:
            request.unlink(missing_ok=True)
            response.unlink(missing_ok=True)

    def snapshot(self, generation, candidate):
        try:
            pair = self.command(generation, 'snapshot')
            source = 'rpc'
        except (OSError, RuntimeError, TimeoutError):
            pair = read_json(generation['directory'] / 'dev-control' / 'latest.json')
            source = 'latest'
        try:
            path = Path(pair['path']).resolve()
            if path.parent != (generation['directory'] / 'dev-control').resolve():
                raise ValueError('snapshot outside owned session')
            if path.stat().st_size > 16 * 1024 * 1024:
                raise ValueError('snapshot too large')
            data = path.read_bytes()
            if hashlib.sha256(data).hexdigest() != pair['hash']:
                raise ValueError('snapshot hash mismatch')
            saved = json.loads(data)
            if saved['revision'] != generation['revision'] or saved['generation'] != generation['generation']:
                raise ValueError('snapshot identity mismatch')
            target = candidate / 'restore.json'
            target.write_bytes(data)
            self.event('snapshot', source=source)
            return target
        except (OSError, ValueError, KeyError, TypeError):
            self.event('snapshot', source='stateless')
            return None

    def show_error(self, text):
        self.event('error', error=text)
        if self.current and self.current['child'].poll() is None:
            try:
                self.command(self.current, 'show_error', text=text)
                self.event('overlay', error=text)
            except (OSError, RuntimeError, TimeoutError) as exc:
                self.event('overlay_unavailable', detail=str(exc))

    def relative_paths(self, paths):
        result = []
        for path in paths:
            try:
                result.append(path.relative_to(self.root).as_posix())
            except ValueError:
                result.append(path.as_posix())
        return result

    def route(self, contents):
        paths = set(self.relative_paths(changed_paths(self.source_inputs, contents)))
        paths.update(self.pending_style_files)
        paths.update(self.pending_template_files)
        return route_template_changes(paths)

    def reload_styles(self, digest, contents, files, detected_at):
        return self._reload_sources('styles', 'L1', digest, contents, files, detected_at)

    def reload_templates(self, digest, contents, files, detected_at):
        return self._reload_sources('templates', 'L2', digest, contents, files, detected_at)

    def _reload_sources(self, prefix, layer, digest, contents, files, detected_at):
        command = 'reload_' + prefix
        pending_files = self.pending_style_files if layer == 'L1' else self.pending_template_files
        generation_key = 'style_generation' if layer == 'L1' else 'template_generation'
        pending_files.update(files)
        try:
            reply = self.command(self.current, command, files=files)
            result = reply.get('result') if isinstance(reply, dict) else None
            if result not in ('applied', 'fallback', 'error'):
                raise RuntimeError('unknown reload result: ' + repr(reply))
            if result == 'applied':
                generation = reply.get('generation')
                elapsed = reply.get('elapsed_ms')
                if (not isinstance(generation, int) or isinstance(generation, bool) or generation < 0 or
                        not isinstance(elapsed, (float, int)) or isinstance(elapsed, bool) or
                        not math.isfinite(elapsed) or elapsed < 0):
                    raise RuntimeError('invalid reload applied payload')
        except (OSError, RuntimeError, TimeoutError) as exc:
            self.check_ownership()
            self.event(prefix + '_fallback', layer='L3', result='fallback', files=files,
                       reason='reload transport/protocol failure: ' + str(exc), source_digest=digest)
            return False
        self.check_ownership()
        # Commands read source files inside the app. A later save can race that
        # read or its response. Never bless that digest or build its old inputs.
        # Keep all submitted paths dirty, even if a save reverted to the last
        # successful source version while an older command was executing.
        # Re-stat only the reloadable style inputs: a racing save of a style file is
        # what can invalidate this reply. Any other input change is still picked up
        # by the next full scan and routed to L3, so a full tree walk here would
        # only add tens of ms to every L1 round-trip.
        if self.inputs.refresh(self.inputs.style_paths() if layer == 'L1' else self.inputs.template_paths()) != digest:
            self.event(prefix + '_discarded', layer=layer, files=files, source_digest=digest,
                       reason='inputs changed during reload_styles')
            return True
        if result == 'fallback':
            self.event(prefix + '_fallback', layer='L3', result=result, files=files,
                       reason=reply.get('reason', 'runtime requested L3'), source_digest=digest)
            return False
        if result == 'error':
            detail = reply.get('diagnostic') or reply.get('message') or reply.get('error')
            if not isinstance(detail, str) or not detail:
                detail = 'preview:1: style reload failed without a diagnostic'
            self.event(prefix + '_error', layer=layer, result=result, files=files,
                       diagnostic=detail, source_digest=digest)
            self.show_error(diagnostics(detail))
            return True
        self.source_inputs = contents
        pending_files.clear()
        # Retain every applied path, including A -> B -> A reverts, in the
        # online-source audit until a complete L3 compilation succeeds.
        self.online_files.update(files)
        self.state.update(source_digest=digest, online_files=sorted(self.online_files), **{generation_key: generation})
        self.event(prefix + '_applied', layer=layer, result=result, files=files, source_digest=digest,
                   generation=generation, **{generation_key: generation}, elapsed_ms=elapsed,
                   detected_to_applied_ms=(time.monotonic() - detected_at) * 1000,
                   detected_monotonic_s=detected_at,
                   parse_ms=reply.get("parse_ms"), apply_ms=reply.get("apply_ms"),
                   refreshed=reply.get("refreshed"), state_contract=reply.get("state_contract"),
                   online_files=sorted(self.online_files))
        try:
            self.command(self.current, 'clear_error')
        except (OSError, RuntimeError, TimeoutError) as exc:
            self.event('overlay_unavailable', detail=str(exc))
        return True

    def prune(self):
        self.children[:] = [child for child in self.children if not child.closed]
        # Never prune a living generation or a candidate. Snapshots used by a new
        # generation have already been copied into that generation's restore.json.
        live = {g['directory'] for g in (self.current,) if g and g['child'].poll() is None}
        generations = sorted(self.base.glob('generation-*'), key=lambda p: p.stat().st_mtime_ns, reverse=True)
        for directory in generations[self.args.keep:]:
            if directory not in live:
                shutil.rmtree(directory)
        if self.current:
            control = self.current['directory'] / 'dev-control'
            pair = read_json(control / 'latest.json') or {}
            latest = pair.get('path')
            snapshots = sorted(control.glob('snapshot-*.json'), key=lambda p: p.stat().st_mtime_ns, reverse=True)
            # RPC consumers get a generous lease of 32 files plus latest; the
            # launcher copies its pin synchronously before invoking this cleanup.
            for path in snapshots[32:]:
                if str(path) != latest:
                    path.unlink(missing_ok=True)
            for pattern in ('res-*.json', '*.tmp'):
                for path in control.glob(pattern):
                    if time.time() - path.stat().st_mtime > 60:
                        path.unlink(missing_ok=True)

    def build(self, digest):
        self.sequence += 1
        revision = f'{self.sequence}-{digest}'
        self.state['sequence'] = self.sequence
        directory = self.base / f'generation-{self.sequence:08d}-{uuid.uuid4().hex[:8]}'
        directory.mkdir()
        self.event('building', layer='L3', revision=revision, directory=str(directory), online_files=sorted(self.online_files))
        prefix = directory / 'artifact'
        options = list(self.args.build_option)
        if self.args.stories:
            options.append('-Dstories=' + self.args.stories)
        if os.name == 'nt':
            if not any(o.startswith('-Dgpu-backend=') for o in options):
                options.append('-Dgpu-backend=d3d12')
            if not any(o.startswith('-Dwindows-arch=') for o in options):
                options.append('-Dwindows-arch=' + ('aarch64' if platform.machine().lower() in ('arm64', 'aarch64') else 'x86_64'))
        argv = [self.args.zig, 'build', self.args.app + '-exe', '-Ddev-preview=true', '--prefix', str(prefix), '--color', 'off', *options]
        child = self.spawn(argv, directory / 'build.log')
        deadline = time.monotonic() + self.args.build_timeout
        while child.poll() is None:
            self.check_ownership()
            if time.monotonic() >= deadline:
                child.close()
                if self.inputs.snapshot() != digest:
                    self.event('discarded', layer='L3', revision=revision, reason='inputs changed during timed-out build')
                else:
                    self.show_error('preview:1: build timed out; see build.log')
                return
            self.pause()
        self.check_ownership()
        code = child.poll()
        child.close()  # also reclaim any surviving compiler descendants
        if self.inputs.snapshot() != digest:
            self.event('discarded', layer='L3', revision=revision, reason='inputs changed during build')
            return
        if code:
            text = (directory / 'build.log').read_text(encoding='utf-8', errors='replace')
            if self.args.mapper:
                # Mapper runs under the same supervisor and deadline as all tools.
                with (directory / 'build.log').open('rb') as source:
                    with (directory / 'mapped.log').open('wb') as output:
                        mapper = Child([str(self.args.mapper), 'map-errors', str(self.root)], stdin=source, stdout=output, stderr=subprocess.STDOUT, cwd=self.root)
                self.children.append(mapper)
                end = time.monotonic() + 10
                while mapper.poll() is None and time.monotonic() < end:
                    self.pause()
                mapped_ok = mapper.poll() == 0
                mapper.close()
                if mapped_ok:
                    text = (directory / 'mapped.log').read_text(encoding='utf-8', errors='replace')
            if self.inputs.snapshot() == digest:
                self.show_error(diagnostics(text))
            return
        restore = self.snapshot(self.current, directory) if self.current else None
        if self.inputs.snapshot() != digest:
            self.event('discarded', layer='L3', revision=revision, reason='inputs changed before launch')
            return
        generation = str(self.sequence)
        env = dict(os.environ, ZENIT_DEV_SESSION_DIR=str(directory), ZENIT_DEV_REVISION=revision, ZENIT_DEV_GENERATION=generation)
        env.pop('ZENIT_DEV_RESTORE', None)
        if restore:
            env['ZENIT_DEV_RESTORE'] = str(restore)
        if self.args.story:
            env['ZENIT_STORYBOOK_STORY'] = self.args.story
        # Dev-only per-attempt fault injection for acceptance. Consumed once.
        if (self.base / 'fail-next-start').exists():
            (self.base / 'fail-next-start').unlink()
            env['ZENIT_DEV_FAIL_START'] = '1'
        exe_name = 'zenit-windows-' + self.args.app + '.exe' if os.name == 'nt' else self.args.app.replace('-', '_')
        try:
            child = self.spawn([str(prefix / 'bin' / exe_name)], directory / 'app.log', env=env, cwd=self.root)
        except OSError as exc:
            self.show_error('preview:1: could not start candidate: ' + str(exc))
            return
        new = {'child': child, 'directory': directory, 'revision': revision, 'generation': generation}
        self.event('starting', layer='L3', candidate_pid=child.pid, candidate_directory=str(directory))
        deadline = time.monotonic() + self.args.ready_timeout
        while time.monotonic() < deadline and child.poll() is None:
            self.check_ownership()
            if self.inputs.snapshot() != digest:
                child.close()
                self.event('discarded', layer='L3', revision=revision, reason='inputs changed before ready')
                return
            ready = read_json(directory / 'dev-control' / 'ready') or {}
            if ready.get('ready') and ready.get('revision') == revision and ready.get('generation') == generation:
                # Check a live safe point too: stale ready or a crash during startup
                # must not retire a healthy predecessor.
                try:
                    health = self.command(new, 'health')
                    if health.get('revision') != revision or health.get('generation') != generation:
                        raise RuntimeError('health identity mismatch')
                except (OSError, RuntimeError, TimeoutError):
                    break
                if child.poll() is not None:
                    break
                if self.inputs.snapshot() != digest:
                    child.close()
                    self.event('discarded', layer='L3', revision=revision, reason='inputs changed at commit')
                    return
                self.check_ownership()
                old = self.current
                self.current = new
                self.source_inputs = self.inputs.contents()
                self.compiled_inputs = self.source_inputs.copy()
                self.online_files.clear()
                self.pending_style_files.clear()
                self.pending_template_files.clear()
                self.state['current'] = {'pid': child.pid, 'directory': str(directory), 'revision': revision, 'generation': generation}
                self.state.update(source_digest=digest, online_files=[], style_generation=0, template_generation=0)
                self.event('ready', layer='L3', revision=revision)
                if old:
                    try:
                        self.command(old, 'quit')
                    except (OSError, RuntimeError, TimeoutError):
                        pass
                    end = time.monotonic() + self.args.quit_timeout
                    while old['child'].poll() is None and time.monotonic() < end:
                        self.pause()
                    old['child'].close()
                    self.event('retired', pid=old['child'].pid, exit_code=old['child'].poll())
                return
            self.pause()
        code = child.poll()
        child.close()
        if self.inputs.snapshot() != digest:
            self.event('discarded', layer='L3', revision=revision, reason='inputs changed during failed startup')
        else:
            self.show_error(f'preview:1: candidate failed to become ready (exit={code}); see {directory / "app.log"}')

    def run(self):
        lock = self.lock = AppLock(self.root / '.preview-locks' / (self.args.app + '.lock'))
        try:
            lock.check()
            self.claim_session()
        except BaseException:
            lock.close()
            raise
        previous = {}
        for name in ('SIGINT', 'SIGTERM', 'SIGHUP', 'SIGBREAK'):
            sig = getattr(signal, name, None)
            if sig is not None:
                previous[sig] = signal.signal(sig, lambda *_: setattr(self, 'stopping', True))
        try:
            attempted = None
            observed = self.inputs.snapshot()
            changed_at = time.monotonic() - self.args.debounce
            pending_since = changed_at
            next_prune = 0
            next_full_scan = 0.0
            l1_pending = False
            while True:
                self.check_ownership()
                # Full scans are throttled to --poll; between them only the reloadable
                # style inputs are re-stat'd so an L1 edit is seen within --style-poll.
                # While an L1 style batch is waiting to be applied, skip full scans so
                # the batch is never delayed behind a tens-of-ms walk of the tree.
                if time.monotonic() >= next_full_scan and not l1_pending:
                    digest = self.inputs.snapshot()
                    next_full_scan = time.monotonic() + self.args.poll
                else:
                    digest = self.inputs.refresh(self.inputs.reloadable_paths())
                if digest != observed:
                    if observed == attempted:
                        pending_since = time.monotonic()
                    observed, changed_at = digest, time.monotonic()
                route = self.route(self.inputs.contents()) if self.current else dict(layer='L3', files=[], reason='initial build')
                delay = self.args.style_debounce if route['layer'] in ('L1', 'L2') else self.args.debounce
                pending = observed != attempted
                l1_pending = pending and route['layer'] in ('L1', 'L2')
                if pending and (time.monotonic() - changed_at >= delay or time.monotonic() - pending_since >= self.args.max_delay):
                    attempted = observed
                    contents = self.inputs.contents()
                    if route['layer'] not in ('L1', 'L2'):
                        self.event('routing', layer='L3', reason=route['reason'], source_digest=attempted)
                        self.build(attempted)
                    elif not (self.reload_styles if route['layer'] == 'L1' else self.reload_templates)(attempted, contents, route['files'], pending_since):
                        # Transport may have timed out while files changed. In
                        # that case the next iteration routes the newest source.
                        if self.inputs.snapshot() == attempted:
                            self.build(attempted)
                    self.prune()
                self.check_ownership()
                if time.monotonic() >= next_prune:
                    self.prune()
                    next_prune = time.monotonic() + 5
                self.pause(min(self.args.poll, .005) if pending and route['layer'] in ('L1', 'L2') else min(self.args.poll, self.args.style_poll))
        except Stopped:
            return 0
        finally:
            # Bounded teardown even if a UI thread is stopped or a build is active.
            errors = []
            for child in reversed(self.children):
                try:
                    child.close(grace=.25)
                except Exception as exc:
                    errors.append(f'{child.pid}: {exc}')
            try:
                self.event('stopped', child_pids=[c.pid for c in self.children], cleanup_errors=errors)
            finally:
                for sig, handler in previous.items():
                    signal.signal(sig, handler)
                lock.close()
            if errors:
                raise RuntimeError('child cleanup failed: ' + '; '.join(errors))


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', help='example build key, e.g. storybook or yix-counter')
    parser.add_argument('--stories')
    parser.add_argument('--story')
    parser.add_argument('--zig', default='zig')
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument('--session-root', type=Path)
    parser.add_argument('--mapper', type=Path)
    parser.add_argument('--watch-dir', type=Path, action='append', default=[])
    parser.add_argument('--build-option', action='append', default=[], help='repeat --build-option=-Dname=value')
    parser.add_argument('--poll', type=float, default=.1)
    parser.add_argument('--debounce', type=float, default=.25)
    parser.add_argument('--style-debounce', type=float, default=.01, help='quiet interval for L1 style batches (seconds)')
    parser.add_argument('--style-poll', type=float, default=.01, help='re-stat interval for reloadable style inputs between full scans (seconds)')
    parser.add_argument('--max-delay', type=float, default=2, help='maximum delay before building continuously changing inputs')
    parser.add_argument('--rpc-timeout', type=float, default=1)
    parser.add_argument('--ready-timeout', type=float, default=20)
    parser.add_argument('--build-timeout', type=float, default=300)
    parser.add_argument('--quit-timeout', type=float, default=1)
    parser.add_argument('--keep', type=int, default=5)
    args = parser.parse_args(argv)
    if not re.fullmatch('[a-z][a-z0-9-]*', args.app):
        parser.error('invalid example key')
    if args.keep < 2 or not .001 <= args.rpc_timeout <= 30 or any(not math.isfinite(v) or v <= 0 for v in (args.poll, args.debounce, args.style_debounce, args.style_poll, args.max_delay, args.ready_timeout, args.build_timeout, args.quit_timeout)):
        parser.error('timeouts must be positive; RPC 0.001..30 seconds; keep >= 2')
    for option in args.build_option:
        if not option.startswith('-D') or option.split('=', 1)[0] in ('-Ddev-preview', '-Dtarget', '-Dtest-mode'):
            parser.error('build options must be -D options; dev-preview, test-mode and native target are launcher-owned')
    if os.name == 'nt' and args.app not in ('storybook', 'text-input', 'window-chrome', 'adaptive-window'):
        parser.error('Windows preview supports storybook, text-input, window-chrome, adaptive-window')
    return args


def main():
    try:
        return Preview(parse_args()).run()
    except (RuntimeError, OSError) as exc:
        print(f'preview: {exc}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
