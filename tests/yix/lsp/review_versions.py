#!/usr/bin/env python3
"""Deterministic LSP regressions using a protocol-valid ZLS stub.

Run: python3 tests/yix/lsp/review_versions.py /path/to/current/yix-lsp /path/to/current/yix
The stub delays a hover across an edit, coalesces diagnostics, and returns a
definition in a stale disk twin. No installed ZLS or network is required.
"""
import json
import os
import pathlib
import queue
import subprocess
import sys
import tempfile
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parents[3]


def read(stream):
    headers = b""
    while not headers.endswith(b"\r\n\r\n"):
        byte = stream.read(1)
        if not byte:
            return None
        headers += byte
    length = int(headers.split(b"Content-Length: ")[1].split(b"\r\n")[0])
    return json.loads(stream.read(length))


def write(stream, message):
    body = json.dumps(message).encode()
    stream.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
    stream.flush()


def stub():
    pending = None
    changed = False
    while (message := read(sys.stdin.buffer)) is not None:
        method = message.get("method")
        params = message.get("params", {})
        response = None
        if method == "initialize":
            response = {"capabilities": {"hoverProvider": True, "definitionProvider": True}}
        elif method == "shutdown":
            response = None
        elif method == "textDocument/hover":
            if changed:
                pos = params["position"]
                write(sys.stdout.buffer, {"jsonrpc": "2.0", "id": message["id"],
                                         "result": {"contents": "current hover", "range": {
                                             "start": pos, "end": {**pos, "character": pos["character"] + 1}}}})
                continue
            pending = message
            write(sys.stdout.buffer, {"jsonrpc": "2.0", "method": "window/logMessage",
                                     "params": {"type": 3, "message": "hover held"}})
            continue
        elif method == "textDocument/didChange":
            changed = True
            td = params["textDocument"]
            if pending:
                pos = pending["params"]["position"]
                write(sys.stdout.buffer, {"jsonrpc": "2.0", "id": pending["id"],
                                         "result": {"contents": "old hover", "range": {
                                             "start": pos, "end": {**pos, "character": pos["character"] + 1}}}})
                pending = None
            # No didOpen diagnostic: servers may publish only the latest state.
            for version, label in [(None, "coalesced"), (td["version"] - 1, "stale"),
                                   (td["version"], "current")]:
                p = {"uri": td["uri"], "diagnostics": [{"range": {
                    "start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 1}},
                    "message": label, "severity": 1}]}
                if version is not None:
                    p["version"] = version
                write(sys.stdout.buffer, {"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": p})
            write(sys.stdout.buffer, {"jsonrpc": "2.0", "method": "window/logMessage",
                                     "params": {"type": 3, "message": "change complete"}})
            continue
        elif method == "textDocument/definition":
            response = {"uri": os.environ["REVIEW_TWIN_URI"], "range": {
                "start": {"line": 3, "character": 0}, "end": {"line": 3, "character": 1}}}
        elif method == "exit":
            return
        if "id" in message:
            write(sys.stdout.buffer, {"jsonrpc": "2.0", "id": message["id"], "result": response})


def run(binary, compiler):
    failures = []
    with tempfile.TemporaryDirectory(prefix="yix-lsp-review-") as directory:
        base = pathlib.Path(directory)
        launcher = base / "zls-stub"
        launcher.write_text(f"#!/bin/sh\nexec '{sys.executable}' '{pathlib.Path(__file__).resolve()}' --stub\n")
        launcher.chmod(0o755)
        source = base / "target.yix"
        twin = base / "_target.yix.zig"
        canonical = (ROOT / "tests/yix/lsp/fixture.yix").read_text()
        source.write_text(canonical)
        # Generate with the same project root as the LSP. Editing the basename
        # of a checked-in twin preserves the wrong module identity.
        subprocess.run([compiler, "gen", "."], cwd=base, check=True, capture_output=True)
        generated = twin.read_bytes()
        if b'.module = "target.yix"' not in generated or b'@src().file' in generated:
            raise AssertionError('CLI must emit literal project-relative module identities')
        with tempfile.TemporaryDirectory(prefix="yix-lsp-other-root-") as other:
            other_base = pathlib.Path(other)
            (other_base / "target.yix").write_text(canonical)
            subprocess.run([compiler, "gen", "."], cwd=other_base, check=True, capture_output=True)
            if generated != (other_base / "_target.yix.zig").read_bytes():
                raise AssertionError('generated identities changed across project roots')
        print('PASS literal module identity is stable across project roots')
        source.write_text("\n" * 8 + canonical)
        env = dict(os.environ, YIX_ZLS=str(launcher), REVIEW_TWIN_URI=twin.as_uri())
        process = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, cwd=ROOT, env=env)
        inbox = queue.Queue()

        def reader():
            while (message := read(process.stdout)) is not None:
                inbox.put(message)

        threading.Thread(target=reader, daemon=True).start()
        seen = []

        def send(method, params, identifier=None):
            msg = {"jsonrpc": "2.0", "method": method, "params": params}
            if identifier is not None:
                msg["id"] = identifier
            write(process.stdin, msg)

        def wait(predicate):
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                msg = inbox.get(timeout=max(0.01, deadline - time.monotonic()))
                seen.append(msg)
                if predicate(msg):
                    return msg
            raise TimeoutError("no matching LSP response")

        def check(name, condition, detail):
            print(("PASS " if condition else "FAIL ") + name + ("" if condition else ": " + str(detail)))
            if not condition:
                failures.append(name)

        try:
            send("initialize", {"processId": os.getpid(), "rootUri": base.as_uri(),
                               "initializationOptions": {"buildOnSave": False},
                               "capabilities": {"textDocument": {"publishDiagnostics": {"versionSupport": True}}}}, 1)
            wait(lambda m: m.get("id") == 1)
            send("initialized", {})
            text = "const marker = 1;\npub fn Demo() View { return <text>hi</text>; }\n"
            uri = (base / "request.yix").as_uri()
            send("textDocument/didOpen", {"textDocument": {"uri": uri, "languageId": "yix", "version": 1, "text": text}})
            send("textDocument/hover", {"textDocument": {"uri": uri}, "position": {"line": 0, "character": 7}}, 2)
            wait(lambda m: m.get("params", {}).get("message") == "hover held")
            send("textDocument/didChange", {"textDocument": {"uri": uri, "version": 2},
                                             "contentChanges": [{"text": "\n" * 8 + text}]})
            response = wait(lambda m: m.get("id") == 2)
            check("discard hover whose source changed", response.get("result") is None, response)
            wait(lambda m: m.get("params", {}).get("message") == "change complete")
            labels = [d["message"] for m in seen if m.get("method") == "textDocument/publishDiagnostics"
                      for d in m["params"]["diagnostics"]]
            check("publish coalesced versionless diagnostics", "coalesced" in labels, labels)
            check("reject explicitly stale diagnostics", "stale" not in labels, labels)
            check("publish current version diagnostics", "current" in labels, labels)
            send("textDocument/hover", {"textDocument": {"uri": uri}, "position": {"line": 8, "character": 7}}, 4)
            response = wait(lambda m: m.get("id") == 4)
            check("current hover still maps to source", response["result"]["range"]["start"] == {"line": 8, "character": 7}, response)
            send("textDocument/definition", {"textDocument": {"uri": uri}, "position": {"line": 8, "character": 7}}, 3)
            response = wait(lambda m: m.get("id") == 3)
            check("preserve disk twin location when source differs", response["result"]["uri"] == twin.as_uri(), response)
            source.write_text((ROOT / "tests/yix/lsp/fixture.yix").read_text())
            send("textDocument/definition", {"textDocument": {"uri": uri}, "position": {"line": 8, "character": 7}}, 5)
            response = wait(lambda m: m.get("id") == 5)
            check("matching disk twin still maps to source", response["result"]["uri"] == source.as_uri(), response)
        finally:
            process.terminate()
            process.wait(timeout=5)
    return bool(failures)


if __name__ == "__main__":
    if sys.argv[1:] == ["--stub"]:
        stub()
    else:
        if len(sys.argv) != 3:
            raise SystemExit("usage: review_versions.py CURRENT_YIX_LSP CURRENT_YIX")
        sys.exit(run(str(pathlib.Path(sys.argv[1]).resolve()), str(pathlib.Path(sys.argv[2]).resolve())))
