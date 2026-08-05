"""Local backend for the token-stack web control panel.

A browser cannot spawn install.ps1, probe a TCP port, or read .mcp.json, so the
React front end needs a process on this machine to do it. That is all this is: a
thin, localhost-only bridge. It reimplements no install logic - every action
builds an argv and runs the same install.ps1 the CLI and the WPF GUI run.

It runs on the SHARED TOOL VENV's Python, which already carries fastapi and
uvicorn because headroom-ai[proxy] depends on them. Nothing new is installed and
the project's own interpreter is never involved.

Security posture - this endpoint runs installers, so it is deliberately narrow:

  * bound to 127.0.0.1 only, never 0.0.0.0
  * every /api call requires a token minted at startup and handed to the page
    in its URL. Without it, any website you happen to have open could POST to
    this port and run an installer on your machine.
  * the Origin header, when present, must be this exact server. That closes the
    DNS-rebinding path the token alone does not.
  * arguments are passed as an argv list, never a shell string, so a project
    path cannot inject a command.
"""

from __future__ import annotations

import argparse
import json
import os
import secrets
import socket
import string
import subprocess
import sys
import threading
import webbrowser
from pathlib import Path

from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

HERE = Path(__file__).resolve().parent
INSTALL_PS1 = HERE.parent / "install.ps1"
DIST = HERE / "app" / "dist"
PS_EXE = Path(os.environ.get("WINDIR", r"C:\Windows")) / "System32" / "WindowsPowerShell" / "v1.0" / "powershell.exe"

TOKEN = secrets.token_urlsafe(24)
# Filled in by main() once the port is known. Both spellings of loopback are
# allowed because the browser may normalise one to the other; nothing else is.
ORIGINS: set[str] = set()

app = FastAPI(title="token-stack control panel")


# ---------------------------------------------------------------------------
# Job runner - one at a time, mirroring the WPF panel's single-job model
# ---------------------------------------------------------------------------
class Job:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.lines: list[str] = []
        self.proc: subprocess.Popen | None = None
        self.exit: int | None = None
        self.caption: str = ""
        self.running: bool = False

    def start(self, argv: list[str], caption: str, cwd: Path | None = None) -> None:
        with self.lock:
            if self.running:
                raise HTTPException(409, "A job is already running.")
            self.lines = [f"==> {caption}", "    " + " ".join(argv), ""]
            self.exit = None
            self.caption = caption
            self.running = True

        def pump() -> None:
            try:
                # stderr folded into stdout so pip warnings land in the log
                # instead of vanishing, same as the WPF panel does with 2>&1.
                self.proc = subprocess.Popen(
                    argv,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    encoding="utf-8",
                    errors="replace",
                    bufsize=1,
                    cwd=str(cwd) if cwd else None,
                    creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
                )
                assert self.proc.stdout is not None
                for line in self.proc.stdout:
                    with self.lock:
                        self.lines.append(line.rstrip("\r\n"))
                        if len(self.lines) > 4000:
                            self.lines = ["[log trimmed]"] + self.lines[-3000:]
                code = self.proc.wait()
            except Exception as exc:  # surfaced in the log rather than swallowed
                with self.lock:
                    self.lines.append(f"[failed to start: {exc}]")
                code = -1
            with self.lock:
                self.exit = code
                self.running = False
                self.lines.append(f"[exit code {code}]")

        threading.Thread(target=pump, daemon=True).start()

    def snapshot(self, since: int) -> dict:
        with self.lock:
            return {
                "lines": self.lines[since:],
                "total": len(self.lines),
                "running": self.running,
                "exit": self.exit,
                "caption": self.caption,
            }

    def cancel(self) -> None:
        with self.lock:
            proc, running = self.proc, self.running
        if running and proc and proc.poll() is None:
            proc.terminate()
            with self.lock:
                self.lines.append(
                    "[cancelled - a partially finished install is repaired by running Install again]"
                )


JOB = Job()


# ---------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------
def guard(request: Request, token: str | None) -> None:
    if token != TOKEN:
        raise HTTPException(403, "Bad or missing session token.")
    origin = request.headers.get("origin")
    if origin and origin not in ORIGINS:
        raise HTTPException(403, f"Refusing cross-origin request from {origin}.")


def safe_dir(p: str) -> Path:
    path = Path(p).expanduser()
    if not path.is_absolute():
        raise HTTPException(400, "Path must be absolute.")
    return path


# ---------------------------------------------------------------------------
# State - the Python twin of Update-Status in token-stack-gui.ps1
# ---------------------------------------------------------------------------
def read_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def port_open(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(0.4)
        return s.connect_ex(("127.0.0.1", port)) == 0


# Cached because compute_state runs on every poll of /api/state and this spawns a
# process. The answer only changes when repair.ps1 runs, which restarts nothing —
# the cache is keyed on the shim's mtime, which the byte-patch updates.
_EXE_RUNS: dict[tuple[str, float], bool] = {}


def exe_runs(exe: Path) -> bool:
    """Whether a console-script launcher actually executes.

    A Windows console script is a launcher .exe with the target interpreter path
    embedded as a #! line. A venv copied away from where it was built keeps shims
    pointing at the original path, and the launcher then exits 1 having written
    nothing at all - no traceback, no message. Callers that only check .exists()
    report success for tools that cannot start.
    """
    try:
        key = (str(exe), exe.stat().st_mtime)
    except OSError:
        return False
    if key in _EXE_RUNS:
        return _EXE_RUNS[key]
    try:
        proc = subprocess.run([str(exe), "--version"], capture_output=True, timeout=20)
        ok = proc.returncode == 0
    except (OSError, subprocess.SubprocessError):
        ok = False
    _EXE_RUNS[key] = ok
    return ok


def compute_state(project: Path, tools: Path, port: int) -> list[dict]:
    rows: list[dict] = []

    # `ident` is the annotations.json key, sent by the server rather than
    # derived from the label in the UI - a label reword must not silently
    # detach a row from its explanation.
    def add(ident: str, key: str, value: str, state: str) -> None:
        rows.append({"id": ident, "key": key, "value": value, "state": state})

    # project
    if not project.exists():
        add("st-project", "Project", "path does not exist", "bad")
    elif (project / ".git").exists():
        add("st-project", "Project", f"git repo: {project.name}", "ok")
    else:
        add("st-project", "Project", "not a git repo - measurement will not work", "warn")

    # shared venv. Presence of a shim is not the same as a working shim: in a
    # relocated bundle every console script is present and unrunnable, so report
    # what actually executes rather than what exists.
    scripts = tools / "venv" / "Scripts"
    if (scripts / "python.exe").exists():
        found = [n for n in ("headroom", "token-savior", "graphify") if (scripts / f"{n}.exe").exists()]
        if len(found) == 3 and not exe_runs(scripts / "headroom.exe"):
            add("st-venv", "Tool venv",
                "3/3 tools present but not runnable - run repair.ps1 in the bundle", "bad")
        else:
            state = "ok" if len(found) == 3 else ("warn" if found else "bad")
            add("st-venv", "Tool venv", f"{len(found)}/3 tools: {', '.join(found) or 'none'}", state)
    else:
        add("st-venv", "Tool venv", "not built yet", "off")

    # mcp servers
    mcp = read_json(project / ".mcp.json") or {}
    servers = list((mcp.get("mcpServers") or {}).keys())
    add("st-mcp", "MCP servers", ", ".join(servers) if servers else "none configured", "ok" if servers else "off")

    # proxy wiring
    settings = read_json(project / ".claude" / "settings.local.json") or {}
    base_url = (settings.get("env") or {}).get("ANTHROPIC_BASE_URL")
    add("st-wiring", "Proxy wiring", base_url or "not set (Claude Code goes direct)", "ok" if base_url else "off")

    # proxy process - wired but down is the state that actually breaks things
    if port_open(port):
        add("st-proxy", "Proxy process", f"listening on :{port}", "ok")
    elif base_url:
        add("st-proxy", "Proxy process", "DOWN - Claude Code will fail here", "bad")
    else:
        add("st-proxy", "Proxy process", "not running", "off")

    # graphify
    graph = project / "graphify-out" / "graph.json"
    if graph.exists():
        mb = round(graph.stat().st_size / (1024 * 1024), 1)
        if "graphify" in servers:
            add("st-graphify", "graphify", f"graph built ({mb} MB), linked", "ok")
        else:
            add("st-graphify", "graphify", f"graph built ({mb} MB) - not linked", "warn")
    else:
        add("st-graphify", "graphify", "no graph yet - run /graphify in the project", "off")

    # caveman
    if (Path.home() / ".claude" / "plugins" / "marketplaces" / "caveman").exists():
        add("st-caveman", "caveman", "plugin installed (all projects)", "ok")
    else:
        add("st-caveman", "caveman", "not installed - /plugin install caveman@caveman", "off")

    # measurements
    metrics = project / "tools" / "token-metrics" / "metrics.jsonl"
    if metrics.exists():
        n = sum(1 for line in metrics.read_text(encoding="utf-8").splitlines() if line.strip())
        add("st-metrics", "Measurements", f"{n} record(s)", "ok")
    else:
        add("st-metrics", "Measurements", "none yet", "off")

    return rows


# ---------------------------------------------------------------------------
# API
# ---------------------------------------------------------------------------
class RunReq(BaseModel):
    action: str
    project: str
    tools: str
    port: int = 8787
    dryRun: bool = False
    skipProxy: bool = False
    upgrade: bool = False
    removeTools: bool = False
    label: str = "baseline"


def metrics_python(tools: Path) -> Path | None:
    """The shared venv carries tiktoken, which is all collect.py needs - so
    measuring never drags in the project's own interpreter."""
    venv_py = tools / "venv" / "Scripts" / "python.exe"
    if venv_py.exists():
        return venv_py
    from shutil import which

    found = which("python")
    return Path(found) if found else None


@app.get("/api/state")
def api_state(request: Request, project: str, tools: str, port: int = 8787,
              x_token: str | None = Header(None)):
    guard(request, x_token)
    return {"rows": compute_state(safe_dir(project), safe_dir(tools), port)}


@app.post("/api/run")
def api_run(req: RunReq, request: Request, x_token: str | None = Header(None)):
    guard(request, x_token)
    project, tools = safe_dir(req.project), safe_dir(req.tools)

    def installer(extra: list[str]) -> list[str]:
        argv = [str(PS_EXE), "-NoProfile", "-File", str(INSTALL_PS1),
                "-ProjectPath", str(project), "-ToolsHome", str(tools), "-Port", str(req.port)]
        if req.skipProxy:
            argv.append("-SkipProxy")
        if req.upgrade:
            argv.append("-Upgrade")
        return argv + extra

    if req.action == "preview":
        JOB.start(installer(["-DryRun"]), "Preview (dry run)")
    elif req.action == "install":
        JOB.start(installer(["-DryRun"] if req.dryRun else []), "Install")
    elif req.action == "uninstall":
        extra = ["-Uninstall"]
        if req.removeTools:
            extra.append("-RemoveTools")
        if req.dryRun:
            extra.append("-DryRun")
        JOB.start(installer(extra), "Uninstall")
    elif req.action == "link-graphify":
        if not (project / "graphify-out" / "graph.json").exists():
            raise HTTPException(400, "No graphify-out/graph.json yet. Run /graphify in the project first.")
        JOB.start(installer([]), "Link graphify (re-run installer)")
    elif req.action in ("measure", "dashboard"):
        py = metrics_python(tools)
        script = project / "tools" / "token-metrics" / ("collect.py" if req.action == "measure" else "dashboard.py")
        if not py or not script.exists():
            raise HTTPException(400, f"{script.name} or a Python interpreter is missing. Install first.")
        argv = [str(py), str(script)]
        argv += ["--label", req.label or "run"] if req.action == "measure" else ["--open"]
        JOB.start(argv, f"Measure ({req.label})" if req.action == "measure" else "Render dashboard")
    elif req.action == "proxy":
        headroom = tools / "venv" / "Scripts" / "headroom.exe"
        if not headroom.exists():
            raise HTTPException(400, "headroom.exe not found. Install first.")
        # The shim exists but may still be unrunnable: console-script launchers
        # embed the absolute path of the venv they were built in, so a relocated
        # bundle's shims exit 1 with no output. Popen would succeed, the console
        # window would flash and vanish, and this endpoint would report success
        # for a proxy that never started. Probe before promising anything.
        if not exe_runs(headroom):
            raise HTTPException(
                400,
                "headroom.exe exists but does not run - the bundle's console-script "
                "shims point at another path. Run repair.ps1 in the bundle directory.",
            )
        if port_open(req.port):
            return {"started": False, "message": f"Already listening on :{req.port}."}
        # Its own console: the proxy is long-lived and you need somewhere to
        # watch it and press Ctrl+C.
        subprocess.Popen([str(headroom), "proxy", "--port", str(req.port)],
                         creationflags=getattr(subprocess, "CREATE_NEW_CONSOLE", 0))
        return {"started": True, "message": f"Proxy starting on :{req.port} in its own window."}
    elif req.action == "folder":
        if project.exists():
            os.startfile(str(project))  # noqa: S606 - opening Explorer on a validated dir
        return {"started": True, "message": "Opened in Explorer."}
    else:
        raise HTTPException(400, f"Unknown action: {req.action}")

    return {"started": True, "message": req.action}


@app.get("/api/job")
def api_job(request: Request, since: int = 0, x_token: str | None = Header(None)):
    guard(request, x_token)
    return JOB.snapshot(since)


@app.post("/api/cancel")
def api_cancel(request: Request, x_token: str | None = Header(None)):
    guard(request, x_token)
    JOB.cancel()
    return {"ok": True}


@app.get("/api/browse")
def api_browse(request: Request, path: str = "", x_token: str | None = Header(None)):
    """List subdirectories so the page can offer a folder picker.

    A browser file dialog cannot hand a real directory path back to a page, so
    the picker is served from here instead. Directory names only - no file
    contents, no file listing - and it browses the machine running the server,
    which is the correct end when the panel is reached through an SSH tunnel.
    """
    guard(request, x_token)

    if not path:
        # No path yet: offer the drives as roots.
        roots = []
        for letter in string.ascii_uppercase:
            d = Path(f"{letter}:\\")
            if d.exists():
                roots.append({"name": f"{letter}:", "path": str(d), "repo": False})
        return {"path": "", "parent": None, "dirs": roots, "repo": False}

    here = safe_dir(path)
    if not here.is_dir():
        raise HTTPException(404, f"Not a directory: {here}")

    dirs = []
    try:
        for entry in os.scandir(here):
            # is_dir() on a broken symlink raises on Windows; follow_symlinks
            # False keeps a dead .venv/lib64 from taking the whole listing down.
            try:
                if not entry.is_dir(follow_symlinks=False):
                    continue
            except OSError:
                continue
            # Dotted directories are noise in a project picker. The repo flag
            # below still detects .git without listing it.
            if entry.name.startswith("."):
                continue
            p = Path(entry.path)
            dirs.append({"name": entry.name, "path": str(p), "repo": (p / ".git").exists()})
    except PermissionError:
        raise HTTPException(403, f"Access denied: {here}")

    dirs.sort(key=lambda d: d["name"].lower())
    parent = str(here.parent) if here.parent != here else ""
    return {"path": str(here), "parent": parent, "dirs": dirs,
            "repo": (here / ".git").exists()}


@app.get("/api/defaults")
def api_defaults(request: Request, x_token: str | None = Header(None)):
    guard(request, x_token)
    return {
        "tools": str(Path.home() / ".token-tools"),
        "installer": str(INSTALL_PS1),
        "cwd": os.getcwd(),
    }


@app.get("/healthz")
def healthz():
    return {"ok": True}


# Static bundle last, so /api never gets shadowed by a route file.
if DIST.exists():
    app.mount("/assets", StaticFiles(directory=str(DIST / "assets")), name="assets")

    @app.get("/")
    def index():
        return FileResponse(str(DIST / "index.html"))
else:
    @app.get("/")
    def missing():
        return JSONResponse(
            {"error": "UI bundle not built. Run: npm install && npm run build in tools/token-stack/web/app"},
            status_code=503,
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8799)
    parser.add_argument("--project", default=os.getcwd())
    parser.add_argument("--no-browser", action="store_true")
    args = parser.parse_args()

    ORIGINS.update({f"http://127.0.0.1:{args.port}", f"http://localhost:{args.port}"})
    url = f"http://127.0.0.1:{args.port}/?token={TOKEN}&project={args.project}"

    # flush=True matters: Python block-buffers stdout when it is redirected, so
    # without it the URL - and the token you need to use the panel - never
    # appears for anyone running this detached or piped to a file.
    print("  token-stack web control panel", flush=True)
    print(f"  {url}", flush=True)
    print("  The token in that URL is what authorises the API. Do not share it.", flush=True)
    print("  Ctrl+C to stop.\n", flush=True)

    if not args.no_browser:
        threading.Timer(1.0, lambda: webbrowser.open(url)).start()

    import uvicorn

    uvicorn.run(app, host="127.0.0.1", port=args.port, log_level="warning")
    return 0


if __name__ == "__main__":
    sys.exit(main())
