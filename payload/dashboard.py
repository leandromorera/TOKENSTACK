"""Render the token-savings dashboard from the logged metrics.

Reads every record in metrics.jsonl and writes a standalone dashboard.html with
the data inlined — no server, no build step, opens straight from disk.

It makes no network calls of its own. The Headroom figures it shows were read
from the proxy's /stats by collect.py at measurement time, so "Live" on that
page means the proxy answered when the measurement was taken, not now.

Usage:
    python tools/token-metrics/dashboard.py
    python tools/token-metrics/dashboard.py --open
"""

from __future__ import annotations

import argparse
import html
import json
import re
import sys
import webbrowser
from datetime import datetime, timezone
from pathlib import Path

OUT_DIR = Path(__file__).resolve().parent
# <project>/tools/token-metrics/dashboard.py -> <project>
REPO_ROOT = OUT_DIR.parents[1]
METRICS_FILE = OUT_DIR / "metrics.jsonl"
DASHBOARD_FILE = OUT_DIR / "dashboard.html"


# ---------------------------------------------------------------- data loading

def load_records() -> list[dict]:
    if not METRICS_FILE.exists():
        return []
    records = []
    for line in METRICS_FILE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line:
            records.append(json.loads(line))
    return records


def parse_graphify_benchmark(raw: str | None) -> dict:
    """Pull the measured numbers out of `graphify benchmark` stdout."""
    if not raw:
        return {}

    def num(pattern: str) -> float | None:
        m = re.search(pattern, raw)
        return float(m.group(1).replace(",", "")) if m else None

    questions = [
        {"question": q.strip(), "factor": float(f)}
        for f, q in re.findall(r"\[([\d.]+)x\]\s+(.+)", raw)
    ]
    return {
        "naive_tokens": num(r"~([\d,]+) tokens \(naive\)"),
        "query_tokens": num(r"Avg query cost:\s+~([\d,]+) tokens"),
        "reduction": num(r"Reduction:\s+([\d.]+)x"),
        "questions": questions,
    }


def human_bytes(n: int) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:,.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} GB"


def session_periods(records: list[dict]) -> list[dict]:
    """Output-token rate between consecutive measurements.

    collect.py stores cumulative transcript totals, so the interesting number is
    the difference between two records: how many output tokens per turn were
    spent in the window between them. A lifetime average would blur any change.
    """
    periods = []
    prev = None
    for rec in records:
        cur = rec.get("sessions")
        if not cur:
            continue
        if prev is not None:
            d_turns = cur["turns"] - prev["sessions"]["turns"]
            d_out = cur["output_tokens"] - prev["sessions"]["output_tokens"]
            # Transcripts can be pruned or a new machine can start fresh; a
            # negative delta means the totals are not comparable, so skip it.
            if d_turns > 0 and d_out >= 0:
                periods.append({
                    "from": prev["label"],
                    "to": rec["label"],
                    "turns": d_turns,
                    "output_tokens": d_out,
                    "avg_output_per_turn": round(d_out / d_turns, 1),
                    "caveman": bool(rec.get("caveman")),
                })
        prev = rec
    return periods


def caveman_verdict(latest: dict, periods: list[dict]) -> tuple[str, str, str]:
    """(status, headline, detail) for caveman - the only output-token tool.

    Comparing caveman on against caveman off is the only thing that can support
    a savings claim, so say plainly when no such comparison exists rather than
    presenting one period's rate as an effect.
    """
    if not latest.get("caveman"):
        return ("inactive", "Not installed",
                "Add it from inside Claude Code: /plugin marketplace, then install caveman.")

    sessions = latest.get("sessions")
    if not sessions:
        return ("pending", "No session data",
                "No Claude Code transcripts found for this repo yet.")

    on = [p for p in periods if p["caveman"]]
    off = [p for p in periods if not p["caveman"]]

    if on and off:
        r_on = sum(p["output_tokens"] for p in on) / sum(p["turns"] for p in on)
        r_off = sum(p["output_tokens"] for p in off) / sum(p["turns"] for p in off)
        delta = (r_off - r_on) / r_off * 100 if r_off else 0
        verb = "fewer" if delta >= 0 else "more"
        return ("measured", f"{abs(delta):.1f}% {verb} output tokens per turn",
                f"{r_on:,.0f}/turn with it over {sum(p['turns'] for p in on):,} turns "
                f"vs {r_off:,.0f}/turn without over {sum(p['turns'] for p in off):,} turns. "
                "Input tokens are untouched and the skill itself costs ~1-1.5k input "
                "tokens/turn, so weigh this against that.")

    recent = periods[-1] if periods else None
    rate = recent["avg_output_per_turn"] if recent else sessions["avg_output_per_turn"]
    span = (f"{recent['turns']:,} turns since '{recent['from']}'" if recent
            else f"{sessions['turns']:,} turns, all history")
    return ("observed", f"{rate:,.0f} output tokens/turn",
            f"Installed and observed over {span}, but every measurement so far has it "
            "enabled - there is no caveman-off period to compare against, so this rate "
            "is a baseline, not a saving. It only affects output; the skill costs "
            "~1-1.5k input tokens/turn, which can be a net loss on a read-heavy repo.")


def savior_verdict(savior: dict) -> tuple[str, str, str]:
    """(status, headline, detail) for token-savior.

    It exposes an index on disk but no saved-token counter, so the honest
    reading is evidence-of-use, and the row must not imply a measured saving.
    """
    if not savior.get("installed"):
        return ("inactive", "Not installed", "No token-savior binary in the tool venv.")
    if not savior.get("indexed"):
        return ("pending", "Configured, not yet indexed",
                "MCP server is wired but has written nothing. It indexes on first use - "
                "reconnect Claude Code and use it, then re-run collect.py.")

    artifacts = ", ".join(savior.get("artifacts", [])) or "index"
    when = (savior.get("last_written") or "")[:16].replace("T", " ")
    return ("live", f"{human_bytes(savior.get('index_bytes', 0))} index in use",
            f"{savior.get('stat_files', 0)} artifact(s): {artifacts}"
            + (f" · last written {when} UTC" if when else "")
            + ". token-savior exposes no saved-token counter, so this is evidence it is "
              "working, not a measured saving.")


def build_payload() -> dict:
    records = load_records()
    if not records:
        raise SystemExit("No metrics recorded. Run collect.py first.")

    baseline = next((r for r in records if r["label"] == "baseline"), records[0])
    latest = records[-1]

    graphify = latest.get("graphify") or {}
    bench = parse_graphify_benchmark(graphify.get("benchmark_raw"))

    headroom = latest.get("headroom") or {}
    savior = latest.get("token_savior") or {}
    caveman = latest.get("caveman") or {}

    periods = session_periods(records)
    sv_status, sv_headline, sv_detail = savior_verdict(savior)
    cv_status, cv_headline, cv_detail = caveman_verdict(latest, periods)

    # Each tool gets an honest verdict. "Not yet measured" is a real state and is
    # rendered as such — never as a zero, never as a vendor-claimed percentage.
    tools = [
        {
            "name": "graphify",
            "affects": "Input tokens",
            "status": "measured",
            "headline": f"{bench.get('reduction', 0):.1f}x fewer tokens per query",
            "detail": (
                f"{int(bench['naive_tokens']):,} tokens to read the corpus vs "
                f"{int(bench['query_tokens']):,} avg to answer from the graph"
            ) if bench.get("naive_tokens") else "Graph built; benchmark unavailable",
        },
        {
            "name": "Headroom",
            "affects": "Input tokens",
            "status": "live" if headroom.get("proxy_reachable") else "inactive",
            "headline": (
                f"{headroom.get('tokens_saved_all_layers', 0):,} tokens saved so far"
                if headroom.get("proxy_reachable") else "Proxy not running"
            ),
            "detail": (
                f"{headroom.get('api_requests', 0)} request(s) seen · "
                f"{headroom.get('requests_compressed', 0)} compressed · "
                f"avg {headroom.get('avg_compression_pct', 0):.1f}%"
            ) if headroom.get("proxy_reachable")
            else "Start it: headroom proxy --port 8787",
        },
        {
            "name": "token-savior",
            "affects": "Input tokens",
            "status": sv_status,
            "headline": sv_headline,
            "detail": sv_detail,
        },
        {
            "name": "caveman",
            "affects": "Output tokens only",
            "status": cv_status,
            "headline": cv_headline,
            "detail": cv_detail,
        },
    ]

    layers = []
    if headroom.get("proxy_reachable"):
        layers = [
            {"label": "Tool schema trimming", "tokens": headroom.get("tool_schema_tokens_saved", 0)},
            {"label": "Context compression", "tokens": headroom.get("tokens_removed", 0)},
            {"label": "MCP compression", "tokens": (headroom.get("mcp") or {}).get("tokens_removed", 0)},
        ]

    return {
        "project": REPO_ROOT.name,
        "generated": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
        "baseline": baseline,
        "latest": latest,
        "records": records,
        "benchmark": bench,
        "tools": tools,
        "headroom": headroom,
        "layers": layers,
        "token_savior": savior,
        "caveman": caveman,
    }


# ------------------------------------------------------------------ rendering

def esc(value) -> str:
    return html.escape(str(value))


def bar_rows(items: list[dict], value_key: str, label_key: str,
             series: str, unit: str = "") -> str:
    """Horizontal bars as HTML — thin marks, direct labels, hover tooltip.

    All bars in one call share a single scale off the largest value, so lengths
    stay comparable. An item may override the series colour via a "series" key;
    never call this once per bar, or each bar renormalises to itself and the
    comparison silently becomes a lie.
    """
    if not items:
        return '<p class="empty">No data recorded yet.</p>'
    peak = max((i[value_key] or 0) for i in items) or 1
    out = []
    for item in items:
        value = item[value_key] or 0
        pct = (value / peak) * 100
        label = esc(item[label_key])
        shown = f"{value:,.1f}{unit}" if isinstance(value, float) else f"{value:,}{unit}"
        out.append(
            f'<div class="bar-row" tabindex="0" '
            f'title="{label}: {shown}">'
            f'<span class="bar-label">{label}</span>'
            f'<span class="bar-track">'
            f'<span class="bar-fill" style="width:{pct:.2f}%;'
            f'background:var(--{item.get("series", series)})"></span>'
            f'</span>'
            f'<span class="bar-value">{shown}</span>'
            f'</div>'
        )
    return "\n".join(out)


def render(payload: dict) -> str:
    bench = payload["benchmark"]
    naive = payload["baseline"]["naive_corpus"]
    bloat = payload["baseline"].get("untracked_bloat") or {"count": 0, "tokens": 0}
    # Name the worst offender when we have it — a bare total invites the question.
    _top = (bloat.get("files") or [{}])[0].get("file")
    bloat_chief = f" &mdash; chiefly <code>{esc(_top)}</code>" if _top else ""

    # Before/after: two categories, so a legend is required.
    before_after = []
    if bench.get("naive_tokens") and bench.get("query_tokens"):
        before_after = [
            {"label": "Before — read corpus", "tokens": int(bench["naive_tokens"]),
             "series": "series-1"},
            {"label": "After — query graph", "tokens": int(bench["query_tokens"]),
             "series": "series-2"},
        ]

    questions = sorted(bench.get("questions", []), key=lambda q: -q["factor"])

    status_dot = {
        "measured": ("good", "Measured"),
        "live": ("good", "Live"),
        "pending": ("warning", "Not yet measured"),
        # A rate we can see, but nothing to compare it against. Distinct from
        # "pending" so a real number is never badged as if it were absent.
        "observed": ("warning", "Observed, no baseline"),
        "inactive": ("critical", "Inactive"),
    }

    tool_rows = "\n".join(
        f'<tr><th scope="row">{esc(t["name"])}</th>'
        f'<td><span class="dot dot-{status_dot[t["status"]][0]}" aria-hidden="true"></span>'
        f'{esc(status_dot[t["status"]][1])}</td>'
        f'<td>{esc(t["affects"])}</td>'
        f'<td class="strong">{esc(t["headline"])}</td>'
        f'<td class="muted">{esc(t["detail"])}</td></tr>'
        for t in payload["tools"]
    )

    run_rows = "\n".join(
        f'<tr><th scope="row">{esc(r["label"])}</th>'
        f'<td class="num">{r["naive_corpus"]["files"]:,}</td>'
        f'<td class="num">{r["naive_corpus"]["tokens"]:,}</td>'
        f'<td>{", ".join(k for k in ("graphify","headroom","token_savior","caveman") if r.get(k)) or "none"}</td>'
        f'<td class="muted">{esc(r["timestamp"][:16].replace("T", " "))} UTC</td></tr>'
        for r in payload["records"]
    )

    q_rows = "\n".join(
        f'<tr><th scope="row">{esc(q["question"])}</th>'
        f'<td class="num">{q["factor"]:.1f}x</td></tr>'
        for q in questions
    )

    reduction = bench.get("reduction") or 0
    query_cost = int(bench.get("query_tokens") or 0)
    hr_saved = payload["headroom"].get("tokens_saved_all_layers", 0) if payload["headroom"].get("proxy_reachable") else None

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Token savings — {esc(payload["project"])}</title>
<style>
  .viz-root {{
    color-scheme: light;
    --surface-1: #fcfcfb;
    --page: #f9f9f7;
    --text-primary: #0b0b0b;
    --text-secondary: #52514e;
    --muted: #898781;
    --grid: #e1e0d9;
    --baseline: #c3c2b7;
    --border: rgba(11,11,11,0.10);
    --series-1: #2a78d6;
    --series-2: #eb6834;
    --good: #0ca30c;
    --warning: #fab219;
    --critical: #d03b3b;
  }}
  @media (prefers-color-scheme: dark) {{
    :root:where(:not([data-theme="light"])) .viz-root {{
      color-scheme: dark;
      --surface-1: #1a1a19;
      --page: #0d0d0d;
      --text-primary: #ffffff;
      --text-secondary: #c3c2b7;
      --muted: #898781;
      --grid: #2c2c2a;
      --baseline: #383835;
      --border: rgba(255,255,255,0.10);
      --series-1: #3987e5;
      --series-2: #d95926;
    }}
  }}
  :root[data-theme="dark"] .viz-root {{
    color-scheme: dark;
    --surface-1: #1a1a19;
    --page: #0d0d0d;
    --text-primary: #ffffff;
    --text-secondary: #c3c2b7;
    --muted: #898781;
    --grid: #2c2c2a;
    --baseline: #383835;
    --border: rgba(255,255,255,0.10);
    --series-1: #3987e5;
    --series-2: #d95926;
  }}
  * {{ box-sizing: border-box; }}
  body {{ margin: 0; background: var(--page); }}
  .viz-root {{
    font-family: system-ui, -apple-system, "Segoe UI", sans-serif;
    background: var(--page);
    color: var(--text-primary);
    min-height: 100vh;
    padding: 32px 24px 64px;
  }}
  .wrap {{ max-width: 1080px; margin: 0 auto; }}
  header.top {{ display: flex; justify-content: space-between; align-items: flex-start;
    gap: 24px; flex-wrap: wrap; margin-bottom: 8px; }}
  h1 {{ font-size: 22px; font-weight: 650; margin: 0 0 4px; letter-spacing: -0.01em; }}
  .sub {{ color: var(--text-secondary); font-size: 13px; margin: 0; }}
  button.theme {{
    font: inherit; font-size: 13px; padding: 6px 12px; cursor: pointer;
    background: var(--surface-1); color: var(--text-secondary);
    border: 1px solid var(--border); border-radius: 6px;
  }}
  section {{ margin-top: 32px; }}
  h2 {{ font-size: 15px; font-weight: 600; margin: 0 0 4px; }}
  .note {{ color: var(--text-secondary); font-size: 13px; margin: 0 0 16px; max-width: 72ch; line-height: 1.5; }}
  .tiles {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 12px; margin-top: 20px; }}
  .tile {{ background: var(--surface-1); border: 1px solid var(--border); border-radius: 10px; padding: 16px 18px; }}
  .tile .k {{ font-size: 12px; color: var(--text-secondary); margin-bottom: 8px; }}
  .tile .v {{ font-size: 30px; font-weight: 640; letter-spacing: -0.02em; line-height: 1.05; }}
  .tile .c {{ font-size: 12px; color: var(--muted); margin-top: 6px; }}
  .card {{ background: var(--surface-1); border: 1px solid var(--border); border-radius: 10px; padding: 20px; }}
  .bar-row {{ display: grid; grid-template-columns: minmax(140px, 260px) 1fr auto;
    align-items: center; gap: 14px; padding: 7px 0; border-radius: 4px; }}
  .bar-row:hover, .bar-row:focus-visible {{ background: color-mix(in srgb, var(--grid) 45%, transparent); outline: none; }}
  .bar-label {{ font-size: 13px; color: var(--text-secondary); }}
  .bar-track {{ background: var(--grid); border-radius: 3px; height: 10px; width: 100%; overflow: hidden; }}
  .bar-fill {{ display: block; height: 100%; border-radius: 3px; }}
  .bar-value {{ font-size: 13px; font-variant-numeric: tabular-nums; color: var(--text-primary); min-width: 82px; text-align: right; }}
  .legend {{ display: flex; gap: 18px; margin-bottom: 14px; font-size: 12px; color: var(--text-secondary); }}
  .legend span.sw {{ width: 10px; height: 10px; border-radius: 2px; display: inline-block; margin-right: 6px; vertical-align: middle; }}
  table {{ width: 100%; border-collapse: collapse; font-size: 13px; }}
  th, td {{ text-align: left; padding: 9px 10px; border-bottom: 1px solid var(--grid); vertical-align: top; }}
  thead th {{ color: var(--muted); font-weight: 550; font-size: 12px; border-bottom: 1px solid var(--baseline); }}
  tbody th {{ font-weight: 550; }}
  td.num {{ font-variant-numeric: tabular-nums; text-align: right; }}
  td.muted, .muted {{ color: var(--text-secondary); }}
  td.strong {{ font-weight: 550; }}
  .dot {{ width: 8px; height: 8px; border-radius: 50%; display: inline-block; margin-right: 7px; }}
  .dot-good {{ background: var(--good); }}
  .dot-warning {{ background: var(--warning); }}
  .dot-critical {{ background: var(--critical); }}
  .empty {{ color: var(--muted); font-size: 13px; font-style: italic; }}
  details {{ margin-top: 14px; }}
  summary {{ cursor: pointer; font-size: 13px; color: var(--text-secondary); }}
  .warn {{ border-left: 3px solid var(--warning); padding: 10px 14px; background: var(--surface-1);
    border-radius: 0 6px 6px 0; font-size: 13px; color: var(--text-secondary); line-height: 1.55; margin-top: 16px; }}
</style>
</head>
<body>
<div class="viz-root">
<div class="wrap">

  <header class="top">
    <div>
      <h1>Token savings</h1>
      <p class="sub">{esc(payload["project"])} &middot; generated {esc(payload["generated"])}</p>
    </div>
    <button class="theme" id="themeToggle" type="button">Toggle theme</button>
  </header>

  <div class="tiles">
    <div class="tile">
      <div class="k">Tracked corpus</div>
      <div class="v">{naive["tokens"]:,}</div>
      <div class="c">tokens across {naive["files"]} files</div>
    </div>
    <div class="tile">
      <div class="k">Cost to answer one question</div>
      <div class="v">{query_cost:,}</div>
      <div class="c">avg tokens, answered from the graph</div>
    </div>
    <div class="tile">
      <div class="k">Measured reduction</div>
      <div class="v">{reduction:.1f}x</div>
      <div class="c">graphify benchmark, 5 questions</div>
    </div>
    <div class="tile">
      <div class="k">Headroom saved</div>
      <div class="v">{f"{hr_saved:,}" if hr_saved is not None else "&mdash;"}</div>
      <div class="c">{"tokens, live proxy counter" if hr_saved is not None else "proxy not running"}</div>
    </div>
  </div>

  <section>
    <h2>Before and after: cost of answering one question</h2>
    <p class="note">The only comparison here that is actually measured end-to-end. "Before" is
      the token cost of reading the corpus to answer a question; "after" is the cost of
      answering it from the knowledge graph instead.</p>
    <div class="card">
      <div class="legend">
        <span><span class="sw" style="background:var(--series-1)"></span>Before</span>
        <span><span class="sw" style="background:var(--series-2)"></span>After</span>
      </div>
      {bar_rows(before_after, "tokens", "label", "series-1", " tok")}
    </div>
  </section>

  <section>
    <h2>Reduction factor by question</h2>
    <p class="note">Not uniform &mdash; questions answered by structure (error handling, auth)
      compress far better than questions needing a specific file's contents.</p>
    <div class="card">
      {bar_rows(questions, "factor", "question", "series-1", "x")}
    </div>
  </section>

  <section>
    <h2>Headroom savings by layer</h2>
    <p class="note">Live counters from the proxy at <code>127.0.0.1:8787</code>. Compression
      layers only register once real traffic flows through them.</p>
    <div class="card">
      {bar_rows(payload["layers"], "tokens", "label", "series-1", " tok")}
    </div>
  </section>

  <section>
    <h2>Tool inventory</h2>
    <p class="note">What each tool is actually contributing right now. No vendor-claimed
      percentage is shown as if it were a measurement. "Observed, no baseline" means the
      rate is real but nothing exists to compare it against, so it is not yet a saving.</p>
    <div class="card">
      <table>
        <thead><tr><th>Tool</th><th>Status</th><th>Affects</th><th>Measured effect</th><th>Notes</th></tr></thead>
        <tbody>{tool_rows}</tbody>
      </table>
    </div>
  </section>

  <section>
    <h2>Measurement log</h2>
    <p class="note">Every <code>collect.py</code> run appends a row. Re-run it after real
      sessions to extend the series.</p>
    <div class="card">
      <table>
        <thead><tr><th>Run</th><th class="num">Files</th><th class="num">Corpus tokens</th><th>Active tools</th><th>When</th></tr></thead>
        <tbody>{run_rows}</tbody>
      </table>
      <details>
        <summary>Table view &mdash; reduction factor by question</summary>
        <table style="margin-top:12px">
          <thead><tr><th>Question</th><th class="num">Reduction</th></tr></thead>
          <tbody>{q_rows}</tbody>
        </table>
      </details>
    </div>
    <div class="warn">
      <strong>Excluded from the corpus figure:</strong> {bloat["count"]} untracked file(s)
      totalling {bloat["tokens"]:,} tokens{bloat_chief}. They are gitignored and not
      part of the codebase, but they sit in the working tree where a naive file read
      will hit them.
    </div>
  </section>

</div>
</div>
<script>
  (function () {{
    var btn = document.getElementById('themeToggle');
    var root = document.documentElement;
    var saved = null;
    try {{ saved = localStorage.getItem('viz-theme'); }} catch (e) {{}}
    if (saved) root.setAttribute('data-theme', saved);
    btn.addEventListener('click', function () {{
      var current = root.getAttribute('data-theme');
      if (!current) {{
        current = window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
      }}
      var next = current === 'dark' ? 'light' : 'dark';
      root.setAttribute('data-theme', next);
      try {{ localStorage.setItem('viz-theme', next); }} catch (e) {{}}
    }});
  }})();
</script>
</body>
</html>
"""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--open", action="store_true", help="Open the dashboard afterwards.")
    args = parser.parse_args()

    payload = build_payload()
    DASHBOARD_FILE.write_text(render(payload), encoding="utf-8")
    print(f"Dashboard written: {DASHBOARD_FILE}")
    print(f"  {len(payload['records'])} measurement run(s) plotted")

    if args.open:
        webbrowser.open(DASHBOARD_FILE.as_uri())
    return 0


if __name__ == "__main__":
    sys.exit(main())
