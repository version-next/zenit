#!/usr/bin/env python3
"""Authenticated Windows job queue; artifacts and evidence live on the macOS host."""
from __future__ import annotations

import argparse
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import hashlib
import os
from pathlib import Path
import re
import secrets
import struct
import zlib
import shutil
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from windows_upload_parts import MAX_SIZE, PART_SIZE, UploadConflict, UploadParts

REPO = Path(__file__).resolve().parent.parent
FILENAMES = {
    "windows-presented-frames.zip",
    "zenit-accept.log", "zenit-app-stderr.log", "zenit-app-stdout.log",
    "zenit-empty.png", "zenit-long.png", "zenit-selected.png",
    "zenit-home.png", "zenit-end.png", "agent.log", "agent-trace.log", "windows-e2e-stdout.log", "windows-e2e-stderr.log", "windows-probe-stdout.log", "windows-probe-stderr.log", "native-startup.json",
    "windows-suite.log", "windows-suite-session.zip",
}
# A suite compiled for and run on the worker (e2e --suite-on-worker): every
# harness request stays on the Windows machine instead of crossing the tunnel.
# The Windows bun runtime is cached on the worker by SHA-256 (sent once); the
# bundled suite script is small.
LOCAL_SUITE_RUNTIME = "zenit-bun.exe"
LOCAL_SUITE_SCRIPT = "zenit-e2e-suite.js"
LOCAL_SUITE_ENV = {"ZENIT_E2E_TIMEOUT_MS", "ZENIT_E2E_EXPECT_RENDERER", "ZENIT_E2E_STARTUP_TIMEOUT_MS",
                   "ZENIT_E2E_VISUAL_QUALITY", "ZENIT_E2E_FILTER", "ZENIT_E2E_SUITE_TIMEOUT_MS",
                   "ZENIT_E2E_FORCE_LOCKED_CLOCK"}
E2E_APPS = {"render-gallery": "zenit-windows-render-gallery.exe", "text-input": "zenit-windows-text-input.exe", "storybook": "zenit-windows-storybook.exe", "adaptive-window": "zenit-windows-adaptive-window.exe"}
PROBES = {"gpu-d3d11": ("windows-d3d11-contract", "zenit-windows-d3d11-contract.exe"), "gpu": ("windows-arm64-gpu-resources-contract", "zenit-windows-gpu-resources-contract.exe"), "font": ("windows-arm64-font-smoke", "zenit-windows-font-smoke.exe"), "drop": ("windows-arm64-drop-contract", "zenit-windows-drop-contract.exe")}
# A batch job (tools/windows_batch.py): every executable, bundled suite and the
# stage manifest in one archive; the worker runs the stages locally and returns
# all evidence in one results archive.
BATCH_BUNDLE = "zenit-batch.zip"
# One archive per stage, reassembled from bounded, hash-verified parts.
BATCH_RESULT_RE = re.compile(r"^batch-[a-z0-9-]{1,48}\.zip$")
ARTIFACTS = {BATCH_BUNDLE, "Zenit-UI-Scroll.exe", "windows_ui_acceptance.ps1", LOCAL_SUITE_RUNTIME, LOCAL_SUITE_SCRIPT, *E2E_APPS.values(), *(item[1] for item in PROBES.values())}
ID_RE = re.compile(r"^[a-f0-9]{32}$")
MAX_UPLOAD = 32 * 1024 * 1024
MAX_FRAME_ARCHIVE_UPLOAD = MAX_SIZE


def data_dir() -> Path:
    return Path(os.environ.get("ZENIT_VM_HTTP_DATA", "/tmp/zenit-vm-http")).resolve()


def token_file(root: Path) -> Path:
    return root / "token"


def read_token(root: Path, create: bool = False) -> str:
    path = token_file(root)
    if create and not path.exists():
        root.mkdir(parents=True, exist_ok=True)
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(fd, "w") as file:
            file.write(secrets.token_urlsafe(32))
    return path.read_text().strip()


class QueueServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address: tuple[str, int], root: Path):
        super().__init__(address, Handler)
        self.root = root
        self.token = read_token(root, create=True)
        self.jobs: dict[str, dict] = {}
        self.pending: deque[str] = deque()
        self.condition = threading.Condition()
        self.last_worker_seen_at = 0.0
        # Keep the idle worker connected across host service updates. Losing
        # this generation on restart otherwise tells the valid worker to retire.
        generation_path = root / "worker-generation"
        generation = generation_path.read_text().strip() if generation_path.is_file() else ""
        self.worker_generation = generation if ID_RE.fullmatch(generation) else ""
        # A failed installer never releases dispatch automatically. A later
        # installer may take over only after its recorded host process group is gone.
        maintenance_path = root / "worker-maintenance.json"
        self.worker_maintenance = json.loads(maintenance_path.read_text()) if maintenance_path.is_file() else None
        self.rpc_pending: dict[str, deque[dict]] = {}
        # Pulls are consumed server-side, but a tunnelled worker cannot tell a
        # lost response from an unsent request and retries. Keep the last pulled
        # RPC per job until /rpc/complete names it, and redeliver it meanwhile.
        self.rpc_inflight: dict[str, dict] = {}
        self.rpc_results: dict[str, dict] = {}
        self.rpc_screenshots: dict[str, Path] = {}
        self.upload_parts = UploadParts(root / "upload-parts")


class Handler(BaseHTTPRequestHandler):
    server: QueueServer

    def log_message(self, fmt: str, *args: object) -> None:
        print(f"{self.address_string()} {fmt % args}", flush=True)

    def auth(self) -> bool:
        header = self.headers.get("Authorization", "")
        if secrets.compare_digest(header, f"Bearer {self.server.token}"):
            return True
        self.send_error(401)
        return False

    def json_response(self, status: int, value: object) -> None:
        body = json.dumps(value, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def body(self, limit: int = 8192) -> bytes:
        length = int(self.headers.get("Content-Length", "0"))
        if length < 0 or length > limit:
            raise ValueError("request body too large")
        return self.rfile.read(length)

    def upload_file(self, destination: Path, limit: int) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        if length < 0 or length > limit:
            raise ValueError("upload too large")
        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary = destination.with_suffix(destination.suffix + ".tmp")
        try:
            with temporary.open("wb") as output:
                remaining = length
                while remaining:
                    chunk = self.rfile.read(min(remaining, 1024 * 1024))
                    if not chunk:
                        raise ValueError("truncated upload")
                    output.write(chunk)
                    remaining -= len(chunk)
            temporary.replace(destination)
        finally:
            temporary.unlink(missing_ok=True)

    def job(self, job_id: str) -> dict | None:
        if not ID_RE.fullmatch(job_id):
            return None
        with self.server.condition:
            return self.server.jobs.get(job_id)

    def do_GET(self) -> None:
        if not self.auth():
            return
        parts = self.path.strip("/").split("/")
        if parts == ["health"]:
            with self.server.condition:
                health = {"status": "ok", "worker_seen_at": self.server.last_worker_seen_at,
                          "worker_generation": self.server.worker_generation,
                          "worker_maintenance": self.server.worker_maintenance is not None}
            return self.json_response(200, health)
        if len(parts) == 2 and parts[0] == "next" and ID_RE.fullmatch(parts[1]):
            with self.server.condition:
                if parts[1] != self.server.worker_generation:
                    return self.json_response(200, {"kind": "retired"})
                self.server.last_worker_seen_at = time.time()
                # A claim whose response was lost: the same worker generation
                # asks again before touching the job. Redeliver it at once.
                job_id = next((key for key, value in self.server.jobs.items()
                               if value.get("status") == "running" and value.get("claimed_by") == parts[1]
                               and not value.get("worker_acked")), None)
                if job_id is None:
                    if self.server.worker_maintenance is not None:
                        self.server.condition.wait(timeout=1)
                    elif not self.server.pending:
                        self.server.condition.wait(timeout=20)
                    if parts[1] != self.server.worker_generation:
                        return self.json_response(200, {"kind": "retired"})
                    if self.server.worker_maintenance is not None or not self.server.pending:
                        return self.json_response(200, {"kind": "idle"})
                    job_id = self.server.pending.popleft()
                    job = self.server.jobs[job_id]
                    job["status"] = "running"
                    job["started_at"] = time.time()
                    job["claimed_by"] = parts[1]
                job = self.server.jobs[job_id]
            return self.json_response(200, {"kind": job["kind"], "id": job_id, "exe_name": job.get("exe_name"), "custom_titlebar": job.get("custom_titlebar", False), "native_titlebar": job.get("native_titlebar", False), "capture_frames": job.get("capture_frames", False), "trace_frames": job.get("trace_frames", False), "capture_desktop": job.get("capture_desktop", False), "allow_foreground": job.get("allow_foreground", False), "local_suite": job.get("local_suite")})
        if len(parts) == 3 and parts[:2] == ["rpc", "next"]:
            job = self.job(parts[2])
            if job is None or job["kind"] != "e2e":
                return self.send_error(404)
            with self.server.condition:
                self.server.last_worker_seen_at = time.time()
                job["worker_acked"] = True
                item = self.server.rpc_inflight.get(parts[2])
                if item is None:
                    pending = self.server.rpc_pending[parts[2]]
                    while not pending and not job.get("stop"):
                        self.server.condition.wait(timeout=20)
                    item = pending.popleft() if pending else {"kind": "stop"}
                    if item.get("kind") == "rpc":
                        self.server.rpc_inflight[parts[2]] = item
            return self.json_response(200, item)
        if len(parts) == 2 and parts[0] == "jobs":
            job = self.job(parts[1])
            if job is None:
                return self.send_error(404)
            return self.json_response(200, job)
        if len(parts) == 3 and parts[0] == "artifacts":
            job = self.job(parts[1])
            if job is None or parts[2] not in ARTIFACTS:
                return self.send_error(404)
            with self.server.condition:
                job["worker_acked"] = True
            path = self.server.root / "jobs" / parts[1] / parts[2]
            if not path.is_file():
                return self.send_error(404)
            data = path.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(data)))
            # Tunnelled transfers have arrived truncated with a 200; the worker
            # verifies this digest before running anything it downloaded.
            self.send_header("X-Content-SHA256", hashlib.sha256(data).hexdigest())
            self.end_headers()
            self.wfile.write(data)
            return
        self.send_error(404)

    def do_POST(self) -> None:
        if not self.auth():
            return
        parts = self.path.strip("/").split("/")
        try:
            payload = json.loads(self.body(MAX_UPLOAD))
        except (ValueError, json.JSONDecodeError):
            return self.send_error(400)
        if parts in (["worker", "prepare"], ["worker", "finish"]):
            generation = payload.get("generation")
            if not isinstance(generation, str) or not ID_RE.fullmatch(generation):
                return self.send_error(400)
            maintenance_path = self.server.root / "worker-maintenance.json"
            with self.server.condition:
                current = self.server.worker_maintenance
                if parts[-1] == "prepare":
                    owner = payload.get("owner_pid")
                    if type(owner) is not int or owner <= 0:
                        return self.send_error(400, "Installer host PID required")
                    try:
                        os.kill(owner, 0)
                        if os.getpgid(owner) != owner:
                            return self.send_error(409, "Installer must own an isolated host process group")
                    except ProcessLookupError:
                        return self.send_error(409, "Installer host process is not alive")
                    active = [job["id"] for job in self.server.jobs.values() if job["status"] not in ("queued", "passed", "failed")]
                    if active:
                        return self.json_response(409, {"error": "Worker update refused during active jobs", "active_jobs": active})
                    if current:
                        try:
                            os.killpg(current["owner_pid"], 0)
                        except ProcessLookupError:
                            pass  # Gate remains closed while ownership transfers.
                        else:
                            return self.json_response(409, {"error": "Another worker installer is alive"})
                    current = {"generation": generation, "owner_pid": owner, "started_at": time.time()}
                    temporary = maintenance_path.with_suffix(".tmp")
                    temporary.write_text(json.dumps(current) + "\n")
                    temporary.replace(maintenance_path)
                    self.server.worker_maintenance = current
                else:
                    if not current or current["generation"] != generation:
                        return self.send_error(409, "Worker maintenance generation mismatch")
                    if self.server.worker_generation != generation or self.server.last_worker_seen_at == 0:
                        return self.send_error(409, "Replacement worker has not connected")
                    maintenance_path.unlink()
                    self.server.worker_maintenance = None
                self.server.condition.notify_all()
            return self.json_response(200, {"generation": generation, "dispatch_paused": parts[-1] == "prepare"})
        if parts == ["worker", "activate"]:
            generation = payload.get("generation")
            if not isinstance(generation, str) or not ID_RE.fullmatch(generation):
                return self.send_error(400)
            with self.server.condition:
                current = self.server.worker_maintenance
                if not current or current["generation"] != generation:
                    return self.send_error(409, "Reserve worker maintenance before activation")
                self.server.worker_generation = generation
                self.server.last_worker_seen_at = 0.0
                self.server.condition.notify_all()
            return self.json_response(200, {"worker_generation": generation})
        if parts == ["jobs"]:
            job_id = payload.get("id")
            if not isinstance(job_id, str) or not ID_RE.fullmatch(job_id):
                return self.send_error(400)
            folder = self.server.root / "jobs" / job_id
            kind = payload.get("kind", "acceptance")
            exe_name = E2E_APPS.get(payload.get("app", "text-input"))
            if kind == "probe":
                probe = PROBES.get(payload.get("probe", "font"))
                if probe is None:
                    return self.send_error(400, "unknown probe")
                exe_name = probe[1]
            modal_audit = payload.get("modal_audit")
            custom_titlebar = payload.get("custom_titlebar") is True
            native_titlebar = payload.get("native_titlebar") is True
            startup_timeout_ms = payload.get("startup_timeout_ms", 90000)
            if type(startup_timeout_ms) is not int or not 1 <= startup_timeout_ms <= 300000:
                return self.send_error(400, "invalid startup timeout")
            if custom_titlebar and (kind != "e2e" or payload.get("app") != "storybook"):
                return self.send_error(400, "custom titlebar requires Storybook")
            if native_titlebar and (custom_titlebar or kind != "e2e" or payload.get("app") != "storybook"):
                return self.send_error(400, "native titlebar requires Storybook without custom titlebar")
            if modal_audit not in (None, "target", "desktop") or modal_audit and (kind != "e2e" or payload.get("app") != "storybook"):
                return self.send_error(400, "Modal audit requires Storybook and target/desktop source")
            if kind == "e2e" and exe_name is None:
                return self.send_error(400, "unknown app")
            local_suite = payload.get("local_suite")
            if kind == "batch" and local_suite is None:
                return self.send_error(400, "batch needs the suite runtime digest")
            if local_suite is not None and (kind not in ("e2e", "batch") or not isinstance(local_suite, dict) or set(local_suite) != {"env", "runtime_sha256"} or
                                            not isinstance(local_suite["env"], dict) or
                                            not all(key in LOCAL_SUITE_ENV and isinstance(value, str) for key, value in local_suite["env"].items()) or
                                            not re.fullmatch(r"[0-9a-f]{64}", str(local_suite["runtime_sha256"]))):
                return self.send_error(400, "invalid local suite")
            needed = {"Zenit-UI-Scroll.exe", "windows_ui_acceptance.ps1"} if kind == "acceptance" else {exe_name}
            if kind == "batch":
                needed = {BATCH_BUNDLE, LOCAL_SUITE_RUNTIME}
            elif local_suite is not None:
                needed |= {LOCAL_SUITE_RUNTIME, LOCAL_SUITE_SCRIPT}
            if kind not in {"acceptance", "e2e", "probe", "batch"} or not all((folder / name).is_file() for name in needed):
                return self.send_error(400, "artifacts missing")
            with self.server.condition:
                if job_id in self.server.jobs:
                    return self.send_error(409)
                self.server.jobs[job_id] = {"id": job_id, "kind": kind, "exe_name": exe_name, "status": "queued", "created_at": time.time(), "capture_frames": bool(payload.get("capture_frames", False)), "trace_frames": bool(payload.get("trace_frames", False)), "capture_desktop": bool(payload.get("capture_desktop", False)), "modal_audit": modal_audit, "allow_foreground": payload.get("allow_foreground") is True}
                if kind == "batch":
                    self.server.jobs[job_id]["local_suite"] = local_suite
                if kind == "e2e":
                    self.server.jobs[job_id]["startup_timeout_ms"] = startup_timeout_ms
                    self.server.jobs[job_id]["custom_titlebar"] = custom_titlebar
                    self.server.jobs[job_id]["native_titlebar"] = native_titlebar
                    self.server.jobs[job_id]["local_suite"] = local_suite
                    self.server.rpc_pending[job_id] = deque()
                self.server.pending.append(job_id)
                self.server.condition.notify_all()
            return self.json_response(201, self.server.jobs[job_id])
        if len(parts) == 2 and parts[0] == "rpc":
            job = self.job(parts[1])
            if job is None or job["kind"] != "e2e" or job["status"] != "running":
                return self.json_response(409, {"error": "Windows E2E app not running", "detail": job.get("error", "") if job else "unknown job"})
            if payload.get("path") in {"/windows/native-input", "/windows/native-desktop"}:
                native_body = payload.get("body")
                if not isinstance(native_body, dict):
                    return self.send_error(400, "native RPC body must be an object")
                action = native_body.get("action")
                background_safe = payload.get("path") == "/windows/native-input" and action in {"status", "uia-tree", "uia-invoke", "uia-toggle", "uia-set-value", "uia-set-range", "uia-select", "uia-expand", "uia-text-action"}
                if not background_safe and not job.get("allow_foreground"):
                    return self.json_response(403, {"error": "Native Windows input requires --allow-foreground"})
            request_id = uuid.uuid4().hex
            requested_path = None
            if payload.get("path") in {"/screenshot", "/frames/capture", "/windows/native-desktop"}:
                raw_path = payload.get("body", {}).get("path")
                if not isinstance(raw_path, str):
                    return self.send_error(400, "screenshot path required")
                requested_path = Path(raw_path).resolve()
                safe_roots = [Path("/tmp/zenit_e2e_test").resolve(),
                              (self.server.root / "jobs" / parts[1]).resolve()]
                if not any(requested_path.is_relative_to(parent) for parent in safe_roots):
                    return self.send_error(400, "screenshot path outside E2E evidence roots")
            with self.server.condition:
                if requested_path is not None:
                    self.server.rpc_screenshots[request_id] = requested_path
                self.server.rpc_pending[parts[1]].append({"kind": "rpc", "id": request_id, "method": payload.get("method"), "path": payload.get("path"), "body_json": json.dumps(payload.get("body"), ensure_ascii=False) if payload.get("body") is not None else ""})
                self.server.condition.notify_all()
                # Let the worker's 40-second command deadline finish before
                # the host transport gives up, including a small network margin.
                deadline = time.monotonic() + 45
                while request_id not in self.server.rpc_results and job["status"] == "running" and time.monotonic() < deadline:
                    self.server.condition.wait(timeout=1)
                response = self.server.rpc_results.pop(request_id, None)
                if response is None:
                    self.server.rpc_screenshots.pop(request_id, None)
            if response is None and job["status"] != "running":
                return self.json_response(502, {"error": "Windows E2E app exited", "detail": job.get("error", "")})
            return self.json_response(200 if response is not None else 504, response if response is not None else {"error": "Windows RPC timeout"})
        if len(parts) == 3 and parts[:2] == ["rpc", "stop"]:
            job = self.job(parts[2])
            if job is None or job["kind"] != "e2e":
                return self.send_error(404)
            with self.server.condition:
                job["stop"] = True
                job["suite_passed"] = payload.get("passed") is True
                if job["status"] == "queued":
                    self.server.pending.remove(job["id"])
                    job.update(status="failed", error="Queued E2E cancelled before execution", completed_at=time.time())
                    (self.server.root / "jobs" / job["id"] / "result.json").write_text(json.dumps(job, indent=2) + "\n")
                self.server.condition.notify_all()
            return self.json_response(200, {"ok": True})
        if len(parts) == 4 and parts[:2] == ["rpc", "complete"]:
            job = self.job(parts[2])
            if job is None or job["kind"] != "e2e" or not ID_RE.fullmatch(parts[3]):
                return self.send_error(404)
            with self.server.condition:
                inflight = self.server.rpc_inflight.get(parts[2])
                if inflight is not None and inflight.get("id") == parts[3]:
                    del self.server.rpc_inflight[parts[2]]
                self.server.rpc_results[parts[3]] = payload
                self.server.rpc_screenshots.pop(parts[3], None)
                self.server.condition.notify_all()
            return self.json_response(200, {"ok": True})
        if len(parts) == 2 and parts[0] == "complete":
            job = self.job(parts[1])
            if job is None:
                return self.send_error(404)
            folder = self.server.root / "jobs" / parts[1]
            expected = {"zenit-accept.log", "zenit-empty.png", "zenit-long.png",
                        "zenit-selected.png", "zenit-home.png", "zenit-end.png"}
            if job["kind"] == "probe":
                expected = {"windows-probe-stdout.log", "windows-probe-stderr.log"}
            elif job["kind"] == "batch":
                # The verdict is the host's (tools/windows_batch.py audits each stage); the job
                # records whether every stage's results archive arrived and every stage exited 0.
                expected = {name for name in payload.get("uploaded", []) if isinstance(name, str) and BATCH_RESULT_RE.fullmatch(name)}
            elif job["kind"] == "e2e":
                expected = {"windows-e2e-stdout.log", "windows-e2e-stderr.log", "native-startup.json"}
                if job.get("capture_frames"):
                    expected.add("windows-presented-frames.zip")
                if job.get("local_suite") is not None:
                    expected.add("windows-suite.log")
            uploaded = {name for name in expected if (folder / name).is_file()}
            log_pass = (folder / "zenit-accept.log").is_file() and \
                "PASS" in (folder / "zenit-accept.log").read_text(errors="replace").splitlines()
            if job["kind"] in ("probe", "batch"):
                passed = payload.get("exit_code") == 0 and uploaded == expected
            elif job["kind"] == "acceptance":
                passed = payload.get("exit_code") == 0 and uploaded == expected and log_pass
            elif job.get("local_suite") is not None:
                # The worker reports the local suite's exit code.
                passed = payload.get("exit_code") == 0 and uploaded == expected
            else:
                passed = payload.get("exit_code") == 0 and job.get("suite_passed") is True and uploaded == expected
            audit_error = ""
            if passed and job.get("modal_audit"):
                with self.server.condition:
                    job["status"] = "auditing"
                command = [sys.executable, str(REPO / "tools/windows_modal_frame_audit.py"), str(folder), "--allow-shadow-halo"]
                if job["modal_audit"] == "desktop":
                    command.append("--desktop")
                try:
                    audit = subprocess.run(command, capture_output=True, text=True, timeout=60)
                    (folder / "host-modal-audit.log").write_text(audit.stdout + audit.stderr)
                    passed = audit.returncode == 0
                    if not passed:
                        audit_error = "Modal " + job["modal_audit"] + " audit failed: " + (audit.stdout + audit.stderr).strip()
                except (OSError, subprocess.TimeoutExpired) as error:
                    passed = False
                    audit_error = "Modal audit did not complete: " + str(error)
                job["modal_audit_passed"] = passed
            with self.server.condition:
                job.update(status="passed" if passed else "failed",
                           exit_code=payload.get("exit_code"), completed_at=time.time(),
                           uploaded=sorted(uploaded), error=audit_error or payload.get("error", ""))
                self.server.condition.notify_all()
            (folder / "result.json").write_text(json.dumps(job, indent=2))
            return self.json_response(200, job)
        self.send_error(404)

    def do_PUT(self) -> None:
        if not self.auth():
            return
        parts = self.path.strip("/").split("/")
        if len(parts) == 4 and parts[0] == "upload-parts":
            job = self.job(parts[1])
            if job is None or job["kind"] != "batch" or not BATCH_RESULT_RE.fullmatch(parts[2]):
                return self.send_error(404)
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= PART_SIZE:
                    return self.send_error(413)
                self.connection.settimeout(30)
                data = self.rfile.read(length)
                result = self.server.upload_parts.receive(
                    parts[1], parts[2], int(parts[3]),
                    int(self.headers.get("X-Upload-Size", "0")),
                    int(self.headers.get("X-Upload-Count", "0")),
                    self.headers.get("X-Upload-SHA256", ""),
                    self.headers.get("X-Part-SHA256", ""), data,
                    self.server.root / "jobs" / parts[1] / parts[2])
            except UploadConflict as error:
                return self.send_error(409, str(error))
            except ValueError as error:
                return self.send_error(400, str(error))
            except TimeoutError:
                return self.send_error(408)
            except OSError:
                return self.send_error(500)
            return self.json_response(200, result)
        if len(parts) != 3 or parts[0] != "upload" or (parts[2] not in FILENAMES and not BATCH_RESULT_RE.fullmatch(parts[2])):
            if len(parts) == 4 and parts[:2] == ["rpc", "screenshot"]:
                if self.job(parts[2]) is None or not ID_RE.fullmatch(parts[3]):
                    return self.send_error(404)
                # Read, not pop: a retried upload must find its destination;
                # /rpc/complete clears it.
                with self.server.condition:
                    dest = self.server.rpc_screenshots.get(parts[3])
                if dest is None:
                    return self.send_error(404)
                try:
                    contents = self.body(MAX_UPLOAD)
                except ValueError:
                    return self.send_error(413)
                dest.parent.mkdir(parents=True, exist_ok=True)
                temporary = dest.with_suffix(dest.suffix + ".tmp")
                temporary.write_bytes(contents)
                temporary.replace(dest)
                return self.json_response(200, {"ok": True})
            return self.send_error(404)
        job = self.job(parts[1])
        if job is None:
            return self.send_error(404)
        if BATCH_RESULT_RE.fullmatch(parts[2]):
            # A legacy write could race reassembly or replace a verified ZIP
            # behind its completion record. Batch archives use one protocol.
            return self.send_error(409, "Batch evidence requires upload-parts")
        with self.server.condition:
            job["worker_acked"] = True
        dest = self.server.root / "jobs" / parts[1] / parts[2]
        limit = MAX_FRAME_ARCHIVE_UPLOAD if parts[2] in {"windows-presented-frames.zip", "windows-suite-session.zip"} else MAX_UPLOAD
        try:
            self.upload_file(dest, limit)
        except ValueError:
            return self.send_error(413)
        except OSError:
            return self.send_error(500)
        self.json_response(200, {"ok": True})


def request(base: str, token: str, method: str, path: str, body: dict | None = None) -> dict:
    payload = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(base + path, data=payload, method=method,
                                 headers={"Authorization": f"Bearer {token}",
                                          "Content-Type": "application/json"})
    # A tunnelled queue (cloudflared quick tunnel) returns 5xx/530 or resets the
    # connection for a few seconds at a time; retry those instead of failing a run.
    delay = 1.0
    for attempt in range(8):
        try:
            with urllib.request.urlopen(req, timeout=30) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if error.code < 500 or attempt == 7:
                raise
        except (urllib.error.URLError, TimeoutError, ConnectionError, OSError):
            if attempt == 7:
                raise
        time.sleep(delay)
        delay = min(delay * 2, 15.0)
    raise AssertionError("unreachable")


def require_worker(health: dict) -> None:
    if health.get("worker_maintenance") is True:
        print("Windows worker update in progress; the job will wait in the queue.", flush=True)
    elif time.time() - health.get("worker_seen_at", 0) > 35:
        raise SystemExit("Windows HTTP worker is not connected; start it before queuing E2E")


def run(args: argparse.Namespace) -> int:
    root = data_dir()
    token = read_token(root)
    exe = REPO / "zig-out/bin/zenit-windows-ui-smoke.exe"
    if not args.skip_build:
        subprocess.run(["zig", "build", "windows-arm64-ui-probe"], cwd=REPO, check=True)
    if not exe.is_file():
        raise SystemExit(f"missing {exe}")
    job_id = uuid.uuid4().hex
    folder = root / "jobs" / job_id
    folder.mkdir(parents=True)
    shutil.copy2(exe, folder / "Zenit-UI-Scroll.exe")
    shutil.copy2(REPO / "tools/windows_ui_acceptance.ps1", folder / "windows_ui_acceptance.ps1")
    base = args.base.rstrip("/")
    health = request(base, token, "GET", "/health")
    require_worker(health)
    request(base, token, "POST", "/jobs", {"id": job_id})
    print(f"Queued {job_id}", flush=True)
    deadline = time.monotonic() + args.timeout
    while time.monotonic() < deadline:
        result = request(base, token, "GET", f"/jobs/{job_id}")
        if result["status"] in {"passed", "failed"}:
            print(f"{result['status'].upper()}: {folder}")
            log = folder / "zenit-accept.log"
            if log.exists():
                print(log.read_text(errors="replace").strip())
            return 0 if result["status"] == "passed" else 1
        time.sleep(0.5)
    print(f"TIMEOUT: {folder}", file=sys.stderr)
    return 1


def export_gpu_frames(folder: Path) -> None:
    """Save native GPU readback evidence on the host, without desktop capture."""
    text = "\n".join((folder / name).read_text(errors="replace") for name in
                     ["windows-probe-stdout.log", "windows-probe-stderr.log"]
                     if (folder / name).exists())
    frames = []
    for marker, width, height, name in [
        ("OFFSCREEN_RGBA8_HEX", 8, 6, "offscreen-rgba8"),
        ("GRAPHICS_RGBA8_HEX", 6, 4, "graphics-bindings-rgba8"),
        ("DEPTH_RGBA8_HEX", 4, 3, "depth-rgba8"),
        ("MSAA_RGBA8_HEX", 8, 4, "msaa-rgba8"),
        ("VIEWPORT_RGBA8_HEX", 8, 4, "viewport-rgba8"),
        ("TEXTURE_COPY_RGBA8_HEX", 4, 3, "texture-copy-rgba8"),
        ("RENDERER_TEXTURE_RGBA8_HEX", 8, 4, "renderer-texture-rgba8"),
        ("RENDERER_BLIT_RGBA8_HEX", 8, 4, "renderer-blit-rgba8"),
        ("RENDERER_RENDER_RGBA8_HEX", 8, 4, "renderer-render-rgba8"),
        ("RENDERER_UNIFORM_RGBA8_HEX", 8, 4, "renderer-uniform-rgba8"),
        ("RENDERER_SAMPLE_RGBA8_HEX", 8, 4, "renderer-sample-rgba8"),
        ("RENDERER_INSTANCE_RGBA8_HEX", 8, 4, "renderer-instance-rgba8"),
        ("RENDERER_BLUR_RGBA8_HEX", 8, 6, "renderer-blur-rgba8"),
        ("RENDERER_COMPOSITE_RGBA8_HEX", 8, 4, "renderer-composite-rgba8"),
        ("RENDERER_PATH_RGBA8_HEX", 8, 8, "renderer-path-rgba8"),
        ("RENDERER_IMAGE_RGBA8_HEX", 8, 8, "renderer-image-rgba8"),
        ("RENDERER_ICON_RGBA8_HEX", 8, 8, "renderer-icon-rgba8"),
        ("RENDERER_TEXT_RGBA8_HEX", 8, 8, "renderer-text-rgba8"),
        ("RENDERER_SDF_RGBA8_HEX", 8, 8, "renderer-sdf-rgba8"),
        ("RENDERER_GLASS_RGBA8_HEX", 8, 8, "renderer-glass-rgba8"),
        ("RENDERER_DEVICE_RGBA8_HEX", 8, 4, "renderer-device-rgba8"),
        ("RENDERER_SURFACE_RGBA8_HEX", 8, 4, "renderer-surface-rgba8"),
        ("SHARED_RENDERER_RGBA8_HEX", 8, 4, "shared-renderer-rgba8"),
        ("SHARED_SURFACE_SRGB_RGBA8_HEX", 8, 4, "shared-surface-srgb-rgba8"),
        ("SHARED_TEXT_RGBA8_HEX", 64, 32, "shared-text-rgba8"),
        *((f"UI_GLASS_{material.upper()}_FRAME_{frame}_RGBA8_HEX", 32, 32, f"ui-glass-{material}-frame-{frame}-rgba8") for material in ("neutral", "liquid") for frame in range(10)),
        *((f"UI_GLASS_{material.upper()}_SCALE_{scale}_PARENT_{parent}_FRAME_{frame}_RGBA8_HEX", 32 * scale // 100, 32 * scale // 100, f"ui-glass-{material}-scale-{scale}-parent-{parent}-frame-{frame}-rgba8") for scale in (100, 175, 200) for parent in (0, 1) for material in ("neutral", "liquid") for frame in range(10)),
        *((f"APP_RENDERER_FRAME_{frame}_RGBA8_HEX", 16, 8, f"app-renderer-frame-{frame}-rgba8") for frame in range(7)),
        ("DISPLAY_RGBA8_HEX", 16, 8, "display-rgba8"),
        *((f"DISPLAY_FRAME_{frame}_RGBA8_HEX", 16, 8, f"display-frame-{frame}-rgba8") for frame in range(9)),
        ("RENDERER_DAMAGE_CLEAR_RGBA8_HEX", 8, 8, "renderer-damage-clear-rgba8"),
        ("DEPTH_SAMPLE_RGBA8_HEX", 4, 2, "depth-sampling-rgba8"),
    ]:
        match = re.search(r"^" + marker + r"=([0-9a-fA-F]+)$", text, re.MULTILINE)
        if not match:
            continue
        rgba = bytes.fromhex(match.group(1))
        if len(rgba) != width * height * 4:
            raise ValueError(f"Invalid GPU frame dimensions: {marker}")
        def chunk(kind, data):
            return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
        for scale, suffix in [(1, ""), (50, "-enlarged")]:
            rows = []
            for y in range(height * scale):
                row = rgba[y // scale * width * 4:(y // scale + 1) * width * 4]
                rows.append(b"\0" + b"".join(row[x:x + 4] * scale for x in range(0, len(row), 4)))
            png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width * scale, height * scale, 8, 6, 0, 0, 0))
            png += chunk(b"IDAT", zlib.compress(b"".join(rows))) + chunk(b"IEND", b"")
            (folder / f"{name}{suffix}.png").write_bytes(png)
        frames.append({"name": name, "width": width, "height": height,
                       "source": "native-gpu-texture-readback", "desktop_capture": False})
    if frames:
        (folder / "gpu-frames.json").write_text(json.dumps(frames, indent=2) + "\n")


def validate_gpu_scope(folder: Path, expected: str):
    log = folder / "windows-probe-stderr.log"
    actual = re.findall(r"^NATIVE_GPU_SCOPE=(all|sdf|other|app|resources|resources_core|resources_shared|bindings)$", log.read_text(errors="replace") if log.is_file() else "", re.MULTILINE)
    evidence = {"requested": expected, "reported": actual, "passed": actual == [expected]}
    (folder / "gpu-scope-validation.json").write_text(json.dumps(evidence, indent=2) + "\n")
    if not evidence["passed"]:
        raise ValueError(f"GPU probe scope mismatch: expected {expected}, reported {actual}")


def run_probe(args: argparse.Namespace) -> int:
    if not args.skip_build and args.artifact_dir != REPO / "zig-out/bin":
        raise ValueError("--artifact-dir requires --skip-build; build isolated artifacts with zig --prefix first")
    root = data_dir()
    token = read_token(root)
    step, name = PROBES[args.probe]
    scope = getattr(args, "gpu_scope", "all")
    if args.probe != "gpu" and scope != "all":
        raise ValueError("--gpu-scope applies only to --probe gpu")
    if not args.skip_build:
        command = ["zig", "build", step, f"-Dwindows-arch={args.arch}"]
        if args.probe == "gpu":
            command += ["-Doptimize=fast", f"-Dwindows-gpu-contract-scope={scope}"]
        subprocess.run(command, cwd=REPO, check=True)
    job_id = uuid.uuid4().hex
    folder = root / "jobs" / job_id
    folder.mkdir(parents=True)
    (folder / "probe-request.json").write_text(json.dumps({"probe": args.probe, "gpu_scope": scope if args.probe == "gpu" else None, "skip_build": args.skip_build}, indent=2) + "\n")
    exe = args.artifact_dir / name
    require_pe_arch(exe, args.arch)
    shutil.copy2(exe, folder / name)
    pdb = exe.with_suffix(".pdb")
    if pdb.is_file():
        shutil.copy2(pdb, folder / pdb.name)
    base = args.base.rstrip("/")
    health = request(base, token, "GET", "/health")
    require_worker(health)
    request(base, token, "POST", "/jobs", {"id": job_id, "kind": "probe", "probe": args.probe})
    print(f"Native Windows probe {job_id}; evidence: {folder}", flush=True)
    deadline = time.monotonic() + args.timeout
    while time.monotonic() < deadline:
        result = request(base, token, "GET", f"/jobs/{job_id}")
        if result["status"] in {"passed", "failed"}:
            for filename in ["windows-probe-stdout.log", "windows-probe-stderr.log"]:
                log = folder / filename
                if log.exists():
                    print(log.read_text(errors="replace").strip())
            if args.probe == "gpu":
                if result["status"] == "passed":
                    try:
                        validate_gpu_scope(folder, scope)
                    except ValueError as error:
                        print(f"FAILED: {error}; {folder}", file=sys.stderr)
                        return 1
                export_gpu_frames(folder)
            print(f"{result['status'].upper()}: {folder}")
            return 0 if result["status"] == "passed" else 1
        time.sleep(0.2)
    print(f"TIMEOUT: {folder}", file=sys.stderr)
    return 1


def run_owned_suite(argv, *, cwd, env, output, timeout, worker_state):
    """Stop only this child after a confirmed VM failure; preserve its evidence."""
    deadline = time.monotonic() + timeout
    with subprocess.Popen(argv, cwd=cwd, env=env, stdout=output, stderr=subprocess.STDOUT) as child:
        try:
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    output.write("\nHost suite timed out\n")
                    return False
                try:
                    return child.wait(timeout=min(1, remaining)) == 0
                except subprocess.TimeoutExpired:
                    try:
                        state = worker_state()
                    except (OSError, ValueError):
                        continue  # A transient observation failure is not terminal.
                    if state.get("status") == "failed":
                        output.write("\nVM worker reported failure; stopping the owned host suite\n")
                        return False
        finally:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=5)


def require_pe_arch(path: Path, arch: str) -> None:
    expected = {"aarch64": 0xaa64, "x86_64": 0x8664, "x86": 0x14c}[arch]
    with path.open("rb") as file:
        header = file.read(64)
        if len(header) < 64 or header[:2] != b"MZ":
            raise ValueError("Windows artifact has no DOS header")
        file.seek(struct.unpack_from("<I", header, 60)[0])
        pe = file.read(6)
    if len(pe) != 6 or pe[:4] != b"PE\0\0" or struct.unpack_from("<H", pe, 4)[0] != expected:
        raise ValueError(f"Windows artifact does not match requested architecture {arch}: {path}")


def e2e_build_command(app: str, renderer: str, arch: str = "aarch64") -> list[str]:
    if app not in E2E_APPS or renderer not in {"legacy", "d3d12", "d3d11"} or arch not in {"aarch64", "x86_64", "x86"}:
        raise ValueError("invalid Windows app/renderer")
    backend = renderer if renderer in {"d3d12", "d3d11"} else "metal"
    return ["zig", "build", f"windows-arm64-{app}", "-Dtest-mode=true",
            f"-Dgpu-backend={backend}", "-Doptimize=fast"] + ([f"-Dwindows-arch={arch}"] if arch != "aarch64" else [])


def build_local_suite(args: argparse.Namespace, folder: Path) -> dict:
    """Bundle preflight + suite into one script and stage the Windows bun runtime."""
    suite = Path(args.suite)
    if suite.parent != Path("e2e") or suite.suffix != ".ts":
        raise SystemExit("--suite-on-worker needs a suite under e2e/")
    entry = REPO / "e2e" / f".windows-suite-entry-{folder.name}.ts"
    # Imports evaluate in order; the preflight's top-level await (startup,
    # renderer and visual-quality checks) completes before the suite runs.
    entry.write_text(f'import "./windows-renderer-preflight.ts";\nimport "./{suite.name}";\n')
    try:
        subprocess.run(["bun", "build", "--target=bun", "--sourcemap=inline", str(entry), "--outfile", str(folder / LOCAL_SUITE_SCRIPT)],
                       cwd=REPO, check=True, stdout=subprocess.DEVNULL)
        version = subprocess.run(["bun", "--version"], check=True, capture_output=True, text=True).stdout.strip()
        # Baseline (no AVX2): Windows on Arm's x64 emulation lacks AVX2, and the
        # default build dies there with STATUS_ILLEGAL_INSTRUCTION.
        runtime = Path.home() / ".bun/install/cache" / f"bun-windows-x64-baseline-v{version}"
        if not runtime.is_file():
            # A cross-compile downloads the Windows runtime into bun's cache.
            subprocess.run(["bun", "build", "--compile", "--target=bun-windows-x64-baseline", str(entry),
                            "--outfile", str(folder / "runtime-fetch.exe")], cwd=REPO, check=True, stdout=subprocess.DEVNULL)
            (folder / "runtime-fetch.exe").unlink(missing_ok=True)
    finally:
        entry.unlink(missing_ok=True)
    require_pe_arch(runtime, "x86_64")
    shutil.copy2(runtime, folder / LOCAL_SUITE_RUNTIME)
    env = {"ZENIT_E2E_TIMEOUT_MS": "40000", "ZENIT_E2E_EXPECT_RENDERER": args.renderer,
           "ZENIT_E2E_STARTUP_TIMEOUT_MS": str(round(args.startup_timeout * 1000))}
    if args.visual_quality:
        env["ZENIT_E2E_VISUAL_QUALITY"] = args.visual_quality
    if args.filter:
        env["ZENIT_E2E_FILTER"] = args.filter
    for key in ("ZENIT_E2E_SUITE_TIMEOUT_MS", "ZENIT_E2E_FORCE_LOCKED_CLOCK"):
        if key in os.environ:
            env[key] = os.environ[key]
    return {"env": env, "runtime_sha256": hashlib.sha256((folder / LOCAL_SUITE_RUNTIME).read_bytes()).hexdigest()}


def wait_local_suite(base: str, token: str, job_id: str, folder: Path, timeout: float) -> int:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        state = request(base, token, "GET", f"/jobs/{job_id}")
        if state["status"] in {"passed", "failed"}:
            break
        time.sleep(1)
    else:
        print(f"UNRESOLVED ({state['status']}): {folder}; the live job was not restarted")
        return 1
    log = folder / "windows-suite.log"
    print(log.read_text(errors="replace") if log.is_file() else "(no suite log uploaded)")
    archive = folder / "windows-suite-session.zip"
    if archive.is_file():
        import zipfile
        target = (folder / "session").resolve()
        with zipfile.ZipFile(archive) as bundle:
            # .NET Framework's ZipFile writes Windows separators into names.
            for info in bundle.infolist():
                destination = (target / info.filename.replace("\\", "/")).resolve()
                if target not in destination.parents or info.is_dir():
                    continue
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(bundle.read(info))
        print(f"Session output: {folder / 'session'}")
    if state.get("error"):
        print(state["error"])
    print(f"{'PASSED' if state['status'] == 'passed' else 'FAILED'}: {folder}")
    return 0 if state["status"] == "passed" else 1


def run_e2e(args: argparse.Namespace) -> int:
    if not 0 < args.startup_timeout <= 300:
        raise ValueError("--startup-timeout must be greater than 0 and at most 300 seconds")
    if not args.skip_build and args.artifact_dir != REPO / "zig-out/bin":
        raise ValueError("--artifact-dir requires --skip-build; build isolated artifacts with zig --prefix first")
    if args.visual_quality and args.renderer not in ("d3d12", "d3d11"):
        raise ValueError("--visual-quality requires --renderer d3d12 or d3d11")
    if args.custom_titlebar and args.app != "storybook":
        raise SystemExit("--custom-titlebar requires --app storybook")
    if args.audit_modal_frames and args.app != "storybook":
        raise SystemExit("--audit-modal-frames requires --app storybook")
    if args.suite_on_worker and (args.capture_desktop or args.audit_modal_frames == "desktop"):
        raise SystemExit("--suite-on-worker does not support desktop captures")
    root = data_dir()
    token = read_token(root)
    base = args.base.rstrip("/")
    if not args.skip_build:
        subprocess.run(e2e_build_command(args.app, args.renderer, args.arch), cwd=REPO, check=True)
    exe = args.artifact_dir / E2E_APPS[args.app]
    if not exe.is_file():
        raise SystemExit(f"missing {exe}")
    require_pe_arch(exe, args.arch)
    health = request(base, token, "GET", "/health")
    require_worker(health)
    job_id = uuid.uuid4().hex
    folder = root / "jobs" / job_id
    folder.mkdir(parents=True)
    shutil.copy2(exe, folder / exe.name)
    pdb = exe.with_suffix(".pdb")
    if pdb.is_file():
        shutil.copy2(pdb, folder / pdb.name)
    (folder / "host-build.json").write_text(json.dumps({
        "requested_renderer": args.renderer,
        "requested_arch": args.arch,
        "requested_visual_quality": args.visual_quality or os.environ.get("ZENIT_E2E_VISUAL_QUALITY", "auto"),
        "skip_build": args.skip_build,
        "build_command": None if args.skip_build else e2e_build_command(args.app, args.renderer, args.arch),
        "exe_name": exe.name,
        "exe_sha256": hashlib.sha256((folder / exe.name).read_bytes()).hexdigest(),
    }, indent=2) + "\n")
    local_suite = None
    if args.suite_on_worker:
        local_suite = build_local_suite(args, folder)
    request(base, token, "POST", "/jobs", {"id": job_id, "kind": "e2e", "app": args.app, "local_suite": local_suite, "startup_timeout_ms": round(args.startup_timeout * 1000), "custom_titlebar": args.custom_titlebar, "native_titlebar": args.native_titlebar, "capture_frames": args.capture_frames or args.capture_desktop or bool(args.audit_modal_frames), "trace_frames": args.trace_frames or bool(args.audit_modal_frames), "capture_desktop": args.capture_desktop or args.audit_modal_frames == "desktop", "modal_audit": args.audit_modal_frames, "allow_foreground": args.allow_foreground})
    print(f"Windows E2E job: {job_id}; evidence: {folder}", flush=True)
    deadline = time.monotonic() + args.timeout
    while time.monotonic() < deadline:
        state = request(base, token, "GET", f"/jobs/{job_id}")
        if state["status"] == "failed":
            print(f"VM job failed before the host suite started: {folder}")
            return 1
        if state["status"] == "running":
            break
        time.sleep(0.2)
    else:
        request(base, token, "POST", f"/rpc/stop/{job_id}", {"passed": False})
        raise SystemExit(f"Windows E2E queue timed out; no suite executed, cancellation requested: {folder}")
    if local_suite is not None:
        return wait_local_suite(base, token, job_id, folder, args.timeout)
    env = os.environ.copy()
    env.update(ZENIT_E2E_HTTP_BASE=base, ZENIT_E2E_HTTP_TOKEN=token,
               ZENIT_E2E_HTTP_JOB_ID=job_id, ZENIT_E2E_TIMEOUT_MS="40000",
               ZENIT_E2E_EXPECT_RENDERER=args.renderer,
               ZENIT_E2E_STARTUP_TIMEOUT_MS=str(round(args.startup_timeout * 1000)))
    if args.visual_quality:
        env["ZENIT_E2E_VISUAL_QUALITY"] = args.visual_quality
    if args.filter:
        env["ZENIT_E2E_FILTER"] = args.filter
    passed = False
    try:
        with (folder / "host-suite.log").open("w") as output:
            passed = run_owned_suite(["bun", "--preload", "./e2e/windows-renderer-preflight.ts", args.suite], cwd=REPO, env=env, output=output,
                                     timeout=args.timeout,
                                     worker_state=lambda: request(base, token, "GET", f"/jobs/{job_id}"))
    except subprocess.TimeoutExpired:
        (folder / "host-suite.log").open("a").write("\nHost suite timed out\n")
    finally:
        if args.renderer in ("d3d12", "d3d11") and (args.capture_frames or args.capture_desktop or args.audit_modal_frames):
            # The worker terminates only its owned app after /rpc/stop. First
            # serialize with frame writers on the app thread, then prevent any
            # further archive writes. Never prune an incomplete final frame.
            try:
                finished = request(base, token, "POST", f"/rpc/{job_id}",
                                   {"method": "POST", "path": "/frames/capture/finish", "body": {}})
                (folder / "frame-capture-finish.json").write_text(json.dumps(finished, indent=2) + "\n")
                if not isinstance(finished, dict) or finished.get("ok") is not True or finished.get("finished") is not True:
                    raise ValueError("missing frame capture finish acknowledgement")
            except (OSError, ValueError) as error:
                passed = False
                with (folder / "host-suite.log").open("a") as output:
                    output.write(f"\nFrame capture finish failed: {error}\n")
        request(base, token, "POST", f"/rpc/stop/{job_id}", {"passed": passed})
    # Frame archives are compressed/uploaded before the host audit. Desktop
    # captures made the old 30s wait expire while the live job was still
    # auditing, incorrectly printing FAILED before a later authoritative pass.
    deadline = time.monotonic() + max(120, args.timeout)
    while time.monotonic() < deadline:
        state = request(base, token, "GET", f"/jobs/{job_id}")
        if state["status"] in {"passed", "failed"}:
            break
        time.sleep(0.2)
    print((folder / "host-suite.log").read_text(errors="replace"))
    if state["status"] not in {"passed", "failed"}:
        print(f"UNRESOLVED ({state['status']}): {folder}; the live job was not restarted")
        return 1
    overall_passed = passed and state["status"] == "passed"
    if state.get("error"):
        print(state["error"])
    print(f"{'PASSED' if overall_passed else 'FAILED'}: {folder}")
    return 0 if overall_passed else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    serve = sub.add_parser("serve")
    serve.add_argument("--bind", default="127.0.0.1")
    serve.add_argument("--port", type=int, default=19817)
    run_cmd = sub.add_parser("run")
    run_cmd.add_argument("--base", default="http://127.0.0.1:19817")
    run_cmd.add_argument("--skip-build", action="store_true")
    run_cmd.add_argument("--timeout", type=float, default=45)
    e2e_cmd = sub.add_parser("e2e")
    e2e_cmd.add_argument("--base", default="http://127.0.0.1:19817")
    e2e_cmd.add_argument("--skip-build", action="store_true")
    e2e_cmd.add_argument("--artifact-dir", type=Path, default=REPO / "zig-out/bin")
    e2e_cmd.add_argument("--arch", choices=["aarch64", "x86_64", "x86"], default="aarch64")
    e2e_cmd.add_argument("--renderer", choices=["legacy", "d3d12", "d3d11"], default="legacy",
                         help="Build this Windows renderer and verify it in the running app, including with --skip-build")
    e2e_cmd.add_argument("--app", choices=sorted(E2E_APPS), default="text-input")
    e2e_cmd.add_argument("--suite", default="e2e/text-input-demo-audit.test.ts")
    e2e_cmd.add_argument("--filter", default="")
    e2e_cmd.add_argument("--visual-quality", choices=["auto", "full", "basic"], help="Set and verify D3D12 visual quality through the app harness before testing")
    e2e_cmd.add_argument("--custom-titlebar", action="store_true", help="Use the shared custom_inset window configuration in Storybook")
    e2e_cmd.add_argument("--native-titlebar", action="store_true", help="Storybook with the system title bar (its swap chain is presented to the HWND)")
    e2e_cmd.add_argument("--trace-frames", action="store_true", help="Log presentation intervals and D3D12 per-draw GPU timestamps (diagnostic overhead)")
    e2e_cmd.add_argument("--capture-frames", action="store_true", help="Capture up to 256 actual presented animation frames (adds readback cost)")
    e2e_cmd.add_argument("--capture-desktop", action="store_true", help="Also capture post-DwmFlush visible client pixels; changes pacing and requires a visible VM desktop")
    e2e_cmd.add_argument("--audit-modal-frames", choices=["target", "desktop"], help="Run the Storybook Modal frame audit on the host and include it in job success; implies required captures")
    e2e_cmd.add_argument("--allow-foreground", action="store_true", help="Permit attended native keyboard/IME/focus and desktop captures in the guest")
    e2e_cmd.add_argument("--startup-timeout", type=float, default=15, help="Seconds allowed for artifact download and app initialization before renderer preflight (max 300)")
    e2e_cmd.add_argument("--timeout", type=float, default=900)
    e2e_cmd.add_argument("--suite-on-worker", action="store_true", help="Compile the suite for Windows and run it on the worker beside the app (no tunnel round trip per harness request); results and session output come back with the job")
    probe_cmd = sub.add_parser("probe")
    probe_cmd.add_argument("--base", default="http://127.0.0.1:19817")
    probe_cmd.add_argument("--skip-build", action="store_true")
    probe_cmd.add_argument("--artifact-dir", type=Path, default=REPO / "zig-out/bin")
    probe_cmd.add_argument("--arch", choices=["aarch64", "x86_64", "x86"], default="aarch64")
    probe_cmd.add_argument("--probe", choices=sorted(PROBES), default="font")
    probe_cmd.add_argument("--timeout", type=float, default=60)
    probe_cmd.add_argument("--gpu-scope", choices=["all", "sdf", "other", "app", "resources", "resources_core", "resources_shared", "bindings"], default="all", help="Native contract scope; sdf + other or sdf + resources + app cover all; resources_core + resources_shared = resources. Validated even with --skip-build.")
    args = parser.parse_args()
    if args.command == "serve":
        server = QueueServer((args.bind, args.port), data_dir())
        print(f"Zenit VM HTTP listening on {args.bind}:{args.port}, data={server.root}", flush=True)
        server.serve_forever()
        return 0
    if args.command == "e2e":
        return run_e2e(args)
    if args.command == "probe":
        return run_probe(args)
    return run(args)


if __name__ == "__main__":
    raise SystemExit(main())
