# token-stack — portable installer

## Getting started

### Option A — standalone bundle (no Python or internet required)

Download `tokenstack-standalone.zip` from the
[Releases page](../../releases/latest), extract it anywhere, and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1 -ProjectPath C:\code\my-app
```

The zip carries a pre-built venv with every tool installed, plus the matching
Python interpreter — no pip, no internet, no Python on PATH needed.

The `-ExecutionPolicy Bypass` prefix is there because the bundle's scripts are
unsigned and a zip download is marked as internet-sourced. It applies to that one
process only and changes nothing on the machine. `.\bootstrap.ps1` on its own
works if your policy already allows unsigned local scripts.

**Extract first, then run in place.** A Python venv records absolute paths, so
`bootstrap.ps1` runs `repair.ps1` on first launch to bind the bundle to wherever
you extracted it. If you later move or copy the extracted folder, run it again:

```powershell
powershell -ExecutionPolicy Bypass -File .\repair.ps1
```

It is idempotent and takes a second. Skipping it after a move leaves the venv
unable to start and every tool shim silently exiting — see
[DEPLOYMENT.md](DEPLOYMENT.md) for why, and for the full list of what the repair
step rewrites.

### Option B — git clone (Python 3.10+ and internet required)

```powershell
git clone https://github.com/leandromorera/TOKENSTACK
cd TOKENSTACK
.\bootstrap.ps1 -ProjectPath C:\code\my-app
```

`bootstrap.ps1` detects that no bundled venv is present and opens the web
control panel. Click **Install** to download the tool packages from PyPI and
build the shared venv.

---

One command also puts the stack into any project directly from the CLI:

```powershell
.\install.ps1 -ProjectPath C:\code\my-app
```

Run it from anywhere; it does not need to be inside the target project. To see
exactly what it would do without touching disk:

```powershell
.\install.ps1 -ProjectPath C:\code\my-app -DryRun
```

There are also two graphical front ends over the same script, both of which add a
live view of what is currently installed in a project:

```powershell
.\token-stack-gui.ps1 -ProjectPath C:\code\my-app
```

```powershell
.\token-stack-web.ps1 -ProjectPath C:\code\my-app
```

`token-stack-gui.ps1` is a native WPF window — nothing listens on a port.
`token-stack-web.ps1` is a React app served from 127.0.0.1, with the annotated
guide built in as a second tab; it costs no new dependency, because the shared
venv already carries fastapi and uvicorn.

Walkthrough of the controls in [`docs/token-stack-gui.md`](../../docs/token-stack-gui.md);
web setup and security in [`docs/token-stack-web.md`](../../docs/token-stack-web.md).

## What it installs

| Tool | Package / source | Reduces |
|---|---|---|
| **Headroom** | `headroom-ai[proxy,mcp,code]` | Input tokens in flight — tool-schema trimming, context compression |
| **token-savior** | `token-savior-recall` | Repeated lookups — symbol index + persistent memory |
| **graphify** | `graphifyy` | Context per question — query a knowledge graph instead of reading files |
| **caveman** | Claude Code plugin | Output tokens only |

caveman is the one thing the script cannot install, because plugins are added
from inside Claude Code. The installer detects whether it is already present and
otherwise prints the two commands.

## Two scopes, deliberately separated

**Machine** — one shared venv at `~/.token-tools/venv` holding the tool
binaries. Created once, reused by every project.

**Project** — written into the target repo:

```
.mcp.json                        token-savior + headroom MCP servers
.claude/settings.local.json      ANTHROPIC_BASE_URL -> the local proxy
tools/token-metrics/collect.py   measurement collector
tools/token-metrics/dashboard.py dashboard renderer
.gitignore                       machine-local entries appended
```

`.claude/settings.local.json` makes Claude Code in that project **require** the
Headroom proxy on `:8787`. If the proxy is not running, Claude Code fails there.
Delete the file to opt out. `install.ps1 -DryRun` shows everything it would write
without touching disk.

Measurement needs the target to be a **git repository** — `collect.py` scopes its
corpus with `git ls-files` rather than walking the filesystem.

## How the tools link to a project and to Claude

There are three different binding mechanisms, and knowing which is which
explains what the installer has to do per project versus once per machine.

| Tool | Binds via | Scope |
|---|---|---|
| token-savior | `.mcp.json` -> stdio subprocess | **per project** |
| Headroom (MCP) | `.mcp.json` -> stdio subprocess | **per project** |
| Headroom (proxy) | `.claude/settings.local.json` -> `ANTHROPIC_BASE_URL` | **per project**, one shared process |
| graphify | `.mcp.json`, once `graphify-out/graph.json` exists | **per project** |
| caveman | `~/.claude/plugins/` | **every project, automatically** |
| graphify skill | `~/.claude/skills/` | **every project, automatically** |

So caveman and the `/graphify` skill need no per-project linking at all — they
are user-scoped and already apply everywhere. Only the MCP servers and the proxy
URL are written into a repo, which is exactly what `install.ps1` does.

**graphify is linked only after the graph is built.** An MCP server pointing at a
missing `graph.json` makes Claude Code report a failed server on every session,
so the installer wires it only when `graphify-out/graph.json` exists. Build the
graph, then re-run the installer to link it. Once linked it exposes
`query_graph`, `get_node`, `get_neighbors`, `get_community`, `god_nodes`,
`graph_stats`, `shortest_path` and PR-triage tools — which is what turns the
per-question saving into something Claude reaches for on its own, rather than
only when the skill is invoked explicitly.

**One proxy serves every project.** `ANTHROPIC_BASE_URL` is written per project,
but they all point at the same `127.0.0.1:8787` process. Its `/stats` counters
are therefore machine-wide, not per-project: if you work in two installed repos,
their savings are pooled. Treat proxy numbers as a machine total and the
`metrics.jsonl` corpus figures as the per-project ones.

### The tools never touch the project's interpreter

This is the whole reason for the shared venv, and it is not theoretical.
Installing Headroom into a project's own environment pulls its
fastapi/pydantic/openai, which silently upgraded a pinned `fastapi==0.115.0` to
`0.141.1` and `openai==2.20.0` to `2.52.1` on the machine this was built for.
Recovery took a reinstall from `requirements.txt` plus removing orphaned
transitive deps.

## Options

| Flag | Effect |
|---|---|
| `-ProjectPath <path>` | Repo to configure. Default: current directory. |
| `-ToolsHome <path>` | Where the shared venv lives. Default `~/.token-tools`. |
| `-Port <n>` | Headroom proxy port. Default 8787. |
| `-SkipProxy` | Install everything but don't point Claude Code at the proxy. |
| `-Upgrade` | Upgrade the tool packages. |
| `-DryRun` | Print every action, write nothing. |
| `-Uninstall` | Remove this stack's project config. |
| `-RemoveTools` | With `-Uninstall`, also delete the shared venv. |

## After installing

```powershell
# 1. start the proxy and leave it running
& "$env:USERPROFILE\.token-tools\venv\Scripts\headroom.exe" proxy

# 2. baseline before you change how you work
python tools\token-metrics\collect.py --label baseline

# 3. ...do real work...

# 4. measure again and render the comparison
python tools\token-metrics\collect.py --label after
python tools\token-metrics\dashboard.py --open
```

`collect.py` appends one record per run to `metrics.jsonl` and never overwrites,
so comparisons stay reproducible. `dashboard.py` renders a standalone
`dashboard.html` — no build step, no server.

## Things that will bite you

**The proxy becomes a dependency.** `.claude/settings.local.json` points
`ANTHROPIC_BASE_URL` at `127.0.0.1:8787`, so Claude Code *in that project* fails
when the proxy is down. Use `-SkipProxy` if you don't want that coupling, or
delete the file to opt out later.

**The project must be a git repo.** `collect.py` scopes the corpus with
`git ls-files` rather than walking the filesystem — deliberately, because working
trees accumulate gitignored data dumps. The repo this was built for had a
gitignored JSON file worth ~20M tokens, 20x the entire tracked codebase. A
filesystem walk would have made every measurement meaningless.

**`.mcp.json` and `.claude/settings.local.json` are gitignored.** They contain
absolute single-machine paths and a localhost URL. Committing them breaks every
other clone — which is why the installer adds them to `.gitignore` rather than
leaving that to chance. Each developer runs the installer once.

**Both config files are merged, not overwritten.** An existing `.mcp.json` with
your own servers keeps them; uninstall removes only the two keys this script
added. `metrics.jsonl` is never deleted, including by `-Uninstall`.

**caveman can be net negative on short sessions.** It compresses assistant
output only — input and reasoning tokens are untouched — and the skill text
itself costs roughly 1–1.5k input tokens per turn.

## Requirements

Windows PowerShell 5.1 (what ships with Windows) or later, Python 3.10+ on PATH,
and git. The script is written against 5.1 specifically: it avoids
`ConvertFrom-Json -AsHashtable` (6+ only) and writes UTF-8 without BOM, because
5.1's `Set-Content -Encoding utf8` emits a BOM that makes `.json` unreadable to
strict parsers.
