# Deployment notes

Why the standalone bundle needs a repair step, what it rewrites, and what the
release workflow guarantees. Written for whoever maintains the build; users only
need the README.

## The premise and the problem

The bundle promises "no Python, no pip, no internet". It delivers that by
shipping a pre-built venv. But **a Python venv is not relocatable**, and neither
are the console scripts inside it. Three separate bindings are established at
build time and every one of them records an absolute path from the build machine:

| What | Where the path is recorded | Symptom when wrong |
|---|---|---|
| Base interpreter | `venv\pyvenv.cfg` → `home` | `No Python at '<CI path>'`, exit 103 |
| Standard library | same `home` entry | as above — the stub aborts before running code |
| Console scripts | `#!` line inside each `venv\Scripts\*.exe` | **exit 1, no output at all** |

`venv\Scripts\python.exe` is a stub that reads `home` from `pyvenv.cfg` to find
the real interpreter and the standard library. A Windows console script is a
launcher `.exe` with the target interpreter path embedded as a `#!` line in its
appended payload; the launcher never consults `pyvenv.cfg`, so fixing the venv
does not fix the shims. They are independent repairs.

The shim failure is the dangerous one because it is **completely silent** — no
message, no traceback, just exit 1. Three consumers invoke those shims by
absolute path and cannot fall back:

- `web/server.py` — the panel's *Start proxy* button runs `headroom.exe`. Without
  a probe, `Popen` succeeds, a console window flashes and vanishes, and the
  endpoint reports that the proxy started.
- `install.ps1` — writes `token-savior.exe`, `headroom.exe`, and
  `graphify-mcp.exe` into the project's `.mcp.json`. Claude Code then reports
  three dead MCP servers every session with nothing explaining why.
- `install.ps1` closing instructions — tell the user to run `headroom.exe proxy`
  and `graphify.exe .`, both of which no-op.

In `venv\Scripts\` 39 of the 44 `.exe` files carry an embedded path, `pip.exe`
included. The other five are unaffected: `python.exe` and `pythonw.exe` are the
interpreter stubs covered by `pyvenv.cfg`, and `ast-grep.exe`, `sg.exe`, and
`magika.exe` are native binaries rather than Python entry points.

## What `repair.ps1` does

Run automatically by `bootstrap.ps1` on every launch, and by `install.ps1` if it
detects a shim that cannot execute. Idempotent.

1. **Resolves a base interpreter** of the same major.minor version as the venv,
   preferring `.\python\` inside the bundle, then an already-valid `home`, then a
   locally installed match. The minor version must be exact — the bundled
   site-packages contain version-tagged binaries (`numpy`, `onnxruntime`) that
   will not load on another minor version.
2. **Rewrites `venv\pyvenv.cfg`** to point at it, backing up to `pyvenv.cfg.bak`
   the first time.
3. **Byte-patches every console-script shim** to `<bundle>\venv\Scripts\python.exe`.
   The launcher scans for the `#!` marker rather than using a fixed offset, so a
   replacement path of a different length is safe.
4. **Verifies** that the venv imports `fastapi`/`uvicorn` and that
   `headroom.exe --version` exits 0, and fails loudly if not.

Users hit this only when they move an already-extracted bundle. That case is
documented in the README because nothing can detect it ahead of time.

## Why the interpreter ships in the zip

Without `.\python\`, the bundle silently depends on the recipient having the
identical Python minor version installed — which contradicts the stated premise,
and fails on a clean machine with an error naming a CI path the user has never
seen. The release workflow copies the runner's interpreter into the bundle, and
`repair.ps1` prefers it. Cost is roughly 20–30 MB compressed on a zip already in
the hundreds of MB.

`repair.ps1` still falls back to a local interpreter, which keeps older bundles
and plain git clones working.

## What the release workflow guarantees

`.github/workflows/release.yml` extracts the finished zip **to a different path
than the build tree** and runs the bundle from there. This matters: testing in
place passes even when nothing is relocatable, which is exactly how the defects
above shipped in v1.0.4. The smoke test asserts:

- `repair.ps1` exits 0 on a fresh extract
- the bundled venv imports `fastapi`, `uvicorn`, `graphify` with no Python on PATH
- `headroom.exe`, `token-savior.exe`, `graphify.exe` all exit 0
- `install.ps1 -DryRun` receives `-ProjectPath` and writes nothing to the project
- `bootstrap.ps1` forwards `-ProjectPath` through to the panel

That last one guards a defect worth describing, because the failure was reported
two layers away from its cause. `bootstrap.ps1` built a `$splat` hashtable and
then invoked the panel with `@args`. Since the script declares a
`[CmdletBinding()] param(...)` block, every argument binds to a declared
parameter and `$args` is left `$null` — and splatting `$null` passes one empty
positional argument rather than nothing. That bound to `-ProjectPath` in
`token-stack-web.ps1`, so the error surfaced as
`Cannot bind argument to parameter 'Path'` from a `Test-Path` call, naming a
parameter that appears nowhere in the user's command. Every argument the user
passed was discarded. The bundle could not launch at all.

## Operational notes

**Port conflicts.** A panel left running from an earlier session produced two
misleading symptoms at once: the new process printed a URL with a freshly minted
session token and then died on the bind conflict, so the browser reached the old
process and reported `Bad or missing session token` — which reads like an auth
bug. `token-stack-web.ps1` now probes the port first and names the holding PID.

**Windows PowerShell 5.1 traps** for anyone editing these scripts:

- Never redirect a native executable's stderr with `2>&1`. 5.1 wraps each stderr
  line in an `ErrorRecord` and sets `$?` to `$false` even on exit code 0. Since
  graphify writes a version warning to stderr, this aborts any script running
  under `$ErrorActionPreference = 'Stop'` on a perfectly successful call.
  Redirect to a file, or capture stdout and read `$LASTEXITCODE`.
- PowerShell strips double quotes when passing arguments to a native executable:
  `python -c 'print("x", v)'` arrives as `print(x, v)`. Use single quotes inside
  the Python source.
- PowerShell 7 does the opposite thing and turns a native command's non-zero exit
  into a terminating error under `Stop`. The smoke test disables
  `$PSNativeCommandUseErrorActionPreference` because several assertions
  deliberately invoke scripts that exit non-zero.
- No `&&`/`||`, no ternary, no null-coalescing, and a here-string's closing `'@`
  must sit at column 0.

**graphify.** The `/graphify` skill probes `uv`, then `pipx`, then `python` on
PATH, and pip-installs `graphifyy` if none of them import it — it has no
knowledge of this bundle, so on a machine with a bare local Python it builds a
second copy. Pre-seed `<project>\graphify-out\.graphify_python` with the bundle's
interpreter to prevent that; `install.ps1` already gitignores that file as
machine-local. Two further notes: the skill and the packaged CLI are versioned
independently and warn on skew, and `graph.json` is NetworkX node-link JSON whose
edge list is `links`, not `edges`.

The skill itself is not installed by pip. `graphify install --platform claude`
copies it into `~/.claude/skills/graphify/`, and until that runs there is no
`/graphify` command for the closing instructions to refer to. `install.ps1` runs
it unconditionally, which doubles as the fix for the version skew above — a
0.8.x skill sitting next to a 0.9.x package prints a warning on every CLI call.
