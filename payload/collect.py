"""Token-usage metrics collector.

Measures the cost of feeding this repository to an LLM, under whichever
token-reduction tools are currently installed. Every run appends one record to
metrics.jsonl so before/after comparisons are reproducible rather than claimed.

Usage:
    python tools/token-metrics/collect.py --label baseline
    python tools/token-metrics/collect.py --label post-install
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

import tiktoken

REPO_ROOT = Path(__file__).resolve().parents[2]
OUT_DIR = Path(__file__).resolve().parent
METRICS_FILE = OUT_DIR / "metrics.jsonl"

# Token tools live in an isolated venv, deliberately NOT the project interpreter:
# Headroom's deps conflict with this repo's pinned fastapi/pydantic/openai.
TOOLS_VENV = Path.home() / ".token-tools" / "venv" / "Scripts"
HEADROOM_BIN = TOOLS_VENV / "headroom.exe"
TOKEN_SAVIOR_BIN = TOOLS_VENV / "token-savior.exe"
HEADROOM_PROXY = os.environ.get("HEADROOM_PROXY_URL", "http://127.0.0.1:8787")

ENC = tiktoken.get_encoding("cl100k_base")

# Directories that are never part of what an agent would read.
SKIP_DIRS = {
    ".git", "node_modules", "__pycache__", ".venv", "venv", "dist", "build",
    ".pytest_cache", "graphify-out", ".vite", "docker",
}
# Extensions an agent would plausibly read when working in this repo.
SOURCE_EXTS = {
    ".py", ".ts", ".tsx", ".js", ".jsx", ".md", ".json", ".yml", ".yaml",
    ".sql", ".sh", ".ps1", ".html", ".css", ".txt",
}


def count_tokens(text: str) -> int:
    return len(ENC.encode(text, disallowed_special=()))


def iter_source_files():
    """Git-tracked source files — the corpus an agent actually reasons about.

    Deliberately NOT a filesystem walk: this working tree carries gitignored
    data dumps (docs/search_results_all_fields.json alone is ~20M tokens) that
    would swamp the measurement by 20x and are not part of the codebase.
    """
    proc = subprocess.run(
        ["git", "ls-files", "-z"],
        capture_output=True, text=True, cwd=REPO_ROOT, check=True,
    )
    for rel in proc.stdout.split("\0"):
        if not rel:
            continue
        path = REPO_ROOT / rel
        if not path.is_file():
            continue
        if any(part in SKIP_DIRS for part in Path(rel).parts):
            continue
        if path.suffix.lower() not in SOURCE_EXTS:
            continue
        yield path


def measure_untracked_bloat() -> dict:
    """Untracked/gitignored files heavy enough to poison a naive file read."""
    tracked = {str(p) for p in iter_source_files()}
    offenders = []
    # os.walk with in-place pruning, not rglob: rglob descends into skipped
    # directories anyway, and stat()ing what it finds there raises on Windows
    # for symlinks with missing targets (a .venv/lib64 gives WinError 1920).
    for dirpath, dirnames, filenames in os.walk(REPO_ROOT):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            path = Path(dirpath) / name
            if str(path) in tracked:
                continue
            if path.suffix.lower() not in SOURCE_EXTS:
                continue
            try:
                size = path.stat().st_size
            except OSError:
                continue  # broken symlink, permission denied, path too long
            if size < 1_000_000:  # only files big enough to matter
                continue
            try:
                tokens = count_tokens(path.read_text(encoding="utf-8", errors="replace"))
            except OSError:
                continue
            rel = path.relative_to(REPO_ROOT)
            offenders.append({"file": str(rel), "tokens": tokens, "bytes": size})

    offenders.sort(key=lambda r: -r["tokens"])
    return {
        "count": len(offenders),
        "tokens": sum(o["tokens"] for o in offenders),
        "files": offenders[:10],
    }


def measure_naive_corpus() -> dict:
    """Cost of the pathological baseline: read every source file in full."""
    total_tokens = 0
    total_bytes = 0
    per_file = []
    for path in iter_source_files():
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        tokens = count_tokens(text)
        total_tokens += tokens
        total_bytes += len(text.encode("utf-8"))
        per_file.append({"file": str(path.relative_to(REPO_ROOT)), "tokens": tokens})

    per_file.sort(key=lambda r: -r["tokens"])
    return {
        "files": len(per_file),
        "tokens": total_tokens,
        "bytes": total_bytes,
        "top_files": per_file[:15],
    }


def measure_graphify() -> dict | None:
    """Read graphify's own benchmark: cost of answering from the graph instead."""
    graph_json = REPO_ROOT / "graphify-out" / "graph.json"
    if not graph_json.exists():
        return None

    result: dict = {"graph_tokens": count_tokens(graph_json.read_text(encoding="utf-8"))}

    cost_file = REPO_ROOT / "graphify-out" / "cost.json"
    if cost_file.exists():
        cost = json.loads(cost_file.read_text(encoding="utf-8"))
        result["build_input_tokens"] = cost.get("total_input_tokens", 0)
        result["build_output_tokens"] = cost.get("total_output_tokens", 0)
        result["build_runs"] = len(cost.get("runs", []))

    if shutil.which("graphify"):
        try:
            proc = subprocess.run(
                ["graphify", "benchmark"],
                capture_output=True, text=True, timeout=300, cwd=REPO_ROOT,
            )
            result["benchmark_raw"] = proc.stdout.strip()
        except (subprocess.SubprocessError, OSError) as exc:
            result["benchmark_error"] = str(exc)
    return result


def _run(cmd: list[str], timeout: int = 120) -> str | None:
    """Run a tool command, returning stdout or None if the tool isn't usable."""
    if not shutil.which(cmd[0]):
        return None
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except (subprocess.SubprocessError, OSError):
        return None
    return (proc.stdout or proc.stderr).strip() or None


def measure_headroom() -> dict | None:
    """Headroom's own counters, read from the running proxy's /stats endpoint.

    The proxy is authoritative: it sees the actual request stream, whereas the
    CLI only summarises what the proxy already recorded.
    """
    if not HEADROOM_BIN.exists():
        return None

    result: dict = {"installed": True, "binary": str(HEADROOM_BIN)}
    try:
        with urllib.request.urlopen(f"{HEADROOM_PROXY}/stats", timeout=15) as resp:
            stats = json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, OSError, json.JSONDecodeError, TimeoutError) as exc:
        result["proxy_reachable"] = False
        result["proxy_error"] = str(exc)
        return result

    result["proxy_reachable"] = True
    summary = stats.get("summary", {})
    comp = summary.get("compression", {})
    cost = summary.get("cost", {})
    result["api_requests"] = summary.get("api_requests", 0)
    result["requests_compressed"] = comp.get("requests_compressed", 0)
    result["avg_compression_pct"] = comp.get("avg_compression_pct", 0.0)
    result["tokens_removed"] = comp.get("total_tokens_removed", 0)
    result["tool_schema_tokens_saved"] = comp.get("tool_schema_tokens_saved", 0)
    result["tokens_saved_all_layers"] = comp.get("total_tokens_saved_all_layers", 0)
    result["tokens_before"] = comp.get("total_tokens_before_with_cli_filtering", 0)
    result["cost_without_usd"] = cost.get("without_headroom_usd", 0.0)
    result["cost_with_usd"] = cost.get("with_headroom_usd", 0.0)
    result["cost_saved_usd"] = cost.get("total_saved_usd", 0.0)
    result["mcp"] = summary.get("mcp", {})
    return result


def measure_token_savior() -> dict | None:
    """token-savior's symbol index and memory DB; sized once it has indexed."""
    if not TOKEN_SAVIOR_BIN.exists():
        return None

    result: dict = {"installed": True, "binary": str(TOKEN_SAVIOR_BIN)}
    for stats_dir in (
        Path.home() / ".local" / "share" / "token-savior",
        Path(os.environ.get("TOKEN_SAVIOR_STATS_DIR", "")) if os.environ.get("TOKEN_SAVIOR_STATS_DIR") else None,
    ):
        if stats_dir and stats_dir.exists():
            files = [p for p in stats_dir.rglob("*") if p.is_file()]
            result["stats_dir"] = str(stats_dir)
            result["stat_files"] = len(files)
            result["index_bytes"] = sum(p.stat().st_size for p in files)
            # An index that exists but was written before the tool was wired up
            # is not evidence it is being used, so record when it last changed.
            result["indexed"] = bool(files)
            if files:
                newest = max(p.stat().st_mtime for p in files)
                result["last_written"] = datetime.fromtimestamp(
                    newest, timezone.utc).isoformat()
                result["artifacts"] = sorted(p.name for p in files)
            break
    else:
        result["indexed"] = False
    return result


def session_dirs() -> list[Path]:
    """Claude Code transcript directories belonging to this repo.

    The directory name is the project path with separators replaced, which is an
    encoding we do not control, so it is only the fast path. The fallback reads
    the `cwd` recorded in each transcript's first line - one line per file, not
    the whole file - and is authoritative if the encoding ever changes.
    """
    root = Path.home() / ".claude" / "projects"
    if not root.is_dir():
        return []

    encoded = re.sub(r"[^A-Za-z0-9]", "-", str(REPO_ROOT))
    guess = root / (encoded[0].lower() + encoded[1:])
    if guess.is_dir():
        return [guess]

    found = []
    for d in root.iterdir():
        if not d.is_dir():
            continue
        for f in d.glob("*.jsonl"):
            try:
                with f.open(encoding="utf-8") as fh:
                    cwd = json.loads(fh.readline() or "{}").get("cwd", "")
            except (OSError, ValueError):
                continue
            if cwd and Path(cwd) == REPO_ROOT:
                found.append(d)
            break
    return found


def measure_sessions() -> dict | None:
    """Real token usage from Claude Code's own transcripts.

    This is the only source in the pipeline that sees *output* tokens, which is
    what caveman claims to reduce. Totals are cumulative over all transcripts;
    the dashboard differences consecutive records to get a per-period rate,
    because a lifetime average would hide any change.
    """
    dirs = session_dirs()
    if not dirs:
        return None

    # The same message.id is written to several records per request. Summing
    # the records rather than the distinct messages inflates every total by
    # roughly 2x, so dedupe on message id.
    seen: set[str] = set()
    out = inp = cache_read = cache_write = 0
    turns = files = 0

    for d in dirs:
        for f in d.glob("*.jsonl"):
            files += 1
            try:
                fh = f.open(encoding="utf-8")
            except OSError:
                continue
            with fh:
                for line in fh:
                    try:
                        rec = json.loads(line)
                    except ValueError:
                        continue
                    if rec.get("type") != "assistant":
                        continue
                    msg = rec.get("message") or {}
                    usage = msg.get("usage")
                    mid = msg.get("id")
                    if not usage or not mid or mid in seen:
                        continue
                    seen.add(mid)
                    turns += 1
                    out += usage.get("output_tokens", 0) or 0
                    inp += usage.get("input_tokens", 0) or 0
                    cache_read += usage.get("cache_read_input_tokens", 0) or 0
                    cache_write += usage.get("cache_creation_input_tokens", 0) or 0

    if not turns:
        return None

    return {
        "transcripts": files,
        "turns": turns,
        "output_tokens": out,
        "input_tokens": inp,
        "cache_read_tokens": cache_read,
        "cache_write_tokens": cache_write,
        "avg_output_per_turn": round(out / turns, 1),
    }


def measure_caveman() -> dict | None:
    """caveman is a plugin on disk; it emits no runtime counters by design.

    It compresses assistant *output* only — input and reasoning tokens are
    untouched, and the skill text itself costs ~1-1.5k input tokens per turn.
    """
    plugin_root = Path.home() / ".claude" / "plugins"
    found = [
        str(p) for p in (
            plugin_root / "cache" / "caveman",
            plugin_root / "marketplaces" / "caveman",
            Path.home() / ".claude" / "skills" / "caveman",
        ) if p.exists()
    ]
    if not found:
        return None
    return {
        "installed": True,
        "paths": found,
        "affects": "output_tokens_only",
        "self_cost_input_tokens_per_turn": "~1000-1500",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--label", required=True,
                        help="Name for this measurement, e.g. 'baseline'.")
    parser.add_argument("--note", default="", help="Optional free-text context.")
    args = parser.parse_args()

    record = {
        "label": args.label,
        "note": args.note,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "naive_corpus": measure_naive_corpus(),
        "untracked_bloat": measure_untracked_bloat(),
        "graphify": measure_graphify(),
        "headroom": measure_headroom(),
        "token_savior": measure_token_savior(),
        "caveman": measure_caveman(),
        "sessions": measure_sessions(),
    }

    with METRICS_FILE.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(record, ensure_ascii=False) + "\n")

    active = [k for k in ("graphify", "headroom", "token_savior", "caveman") if record[k]]
    naive = record["naive_corpus"]
    bloat = record["untracked_bloat"]
    print(f"[{args.label}] {naive['files']} tracked files, {naive['tokens']:,} tokens read naively")
    if bloat["count"]:
        print(f"  untracked bloat: {bloat['count']} file(s), {bloat['tokens']:,} tokens (excluded)")
    print(f"  active tools: {', '.join(active) if active else 'none'}")
    sess = record["sessions"]
    if sess:
        print(f"  sessions: {sess['turns']:,} turns, {sess['output_tokens']:,} output tokens "
              f"({sess['avg_output_per_turn']:,} avg/turn)")
    print(f"  appended to {METRICS_FILE.relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
