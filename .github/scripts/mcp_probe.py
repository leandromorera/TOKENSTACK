"""Speak the MCP initialize handshake to every server in a .mcp.json.

This is the same exchange Claude Code performs on session start, so it is the
only check that distinguishes a server that is wired from one that actually
runs. File-existence checks pass happily on a console-script shim bound to a
venv path that no longer exists — the failure only shows up as a dead server in
someone's editor.

Usage: python mcp_probe.py <path to .mcp.json>
Exit code is the number of servers that failed, capped at 1.
"""

import json
import os
import subprocess
import sys
import threading

INIT = {
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
        "protocolVersion": "2024-11-05",
        "capabilities": {},
        "clientInfo": {"name": "smoke", "version": "0"},
    },
}


def probe(name, spec, timeout=60):
    env = dict(os.environ)
    env.update(spec.get("env") or {})
    argv = [spec["command"]] + list(spec.get("args") or [])
    try:
        proc = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
        )
    except OSError as exc:
        return "SPAWN FAIL", str(exc)

    box = {}

    def read():
        for line in proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if msg.get("id") == 1:
                box["resp"] = msg
                return

    reader = threading.Thread(target=read, daemon=True)
    reader.start()
    try:
        proc.stdin.write(json.dumps(INIT) + "\n")
        proc.stdin.flush()
    except OSError as exc:
        proc.kill()
        return "WRITE FAIL", str(exc)

    reader.join(timeout)
    resp = box.get("resp")
    stderr = ""
    try:
        proc.kill()
        stderr = (proc.stderr.read() or "").strip()
    except Exception:  # noqa: BLE001 - diagnostics only
        pass

    if resp and "result" in resp:
        info = resp["result"].get("serverInfo", {})
        return "OK", "%s %s" % (info.get("name", "?"), info.get("version", "?"))
    if resp:
        return "ERROR", json.dumps(resp.get("error"))
    return "NO RESPONSE", stderr[:400]


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    # utf-8-sig, not utf-8: Windows PowerShell's Set-Content -Encoding utf8
    # prepends a BOM, so a .mcp.json written by any hand-rolled tooling can
    # carry one. Failing to parse it would report a config problem as a probe
    # crash. utf-8-sig reads BOM-less files identically.
    with open(sys.argv[1], encoding="utf-8-sig") as fh:
        servers = json.load(fh)["mcpServers"]
    if not servers:
        print("no MCP servers declared")
        return 1
    bad = 0
    for name, spec in sorted(servers.items()):
        status, detail = probe(name, spec)
        print("%-14s %-12s %s" % (name, status, detail))
        if status != "OK":
            bad += 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
