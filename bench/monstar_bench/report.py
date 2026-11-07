"""Result summaries, the Markdown table, and merging results across machines.

A result file is one run of the tool (schema `monstar-bench/1`). A merged
file (schema `monstar-bench-merged/1`) holds several runs unchanged under
`runs`; summaries are recomputed from raw samples on every finalize, so
merging never averages summaries."""

import json
import statistics

from .metrics import dist, spread

SCHEMA = "monstar-bench/1"
MERGED_SCHEMA = "monstar-bench-merged/1"
# A cell keeps up when at most this share of refreshes it should have drawn
# were missed while content was pending.
KEEPS_UP_MAX_MISSED_PCT = 1.0


def _get(run, *path):
    for key in path:
        if run is None:
            return None
        run = run.get(key)
    return run


def summarize_cell(cell, baseline_w):
    runs = cell["runs"]
    if not runs:
        return {"runs": 0}
    col = lambda *path: [_get(r, *path) for r in runs]
    pooled = lambda *path: [x for r in runs for x in (_get(r, *path) or [])]
    presented = sum(_get(r, "frames", "presented") or 0 for r in runs)
    missed = sum(_get(r, "frames", "missed_refreshes") or 0 for r in runs)
    kb_to_mb = lambda values: [v / 1024 if v is not None else None for v in values]
    pkg = col("power", "package_w")
    summary = {
        "runs": len(runs),
        "package_w": spread(pkg),
        "package_delta_w": spread([p - baseline_w for p in pkg if p is not None]) if baseline_w is not None else None,
        "dgpu_w": spread(col("power", "dgpu_w")),
        "gpu_busy_pct": spread(col("power", "gpu_busy_pct")),
        "client_cpu_pct": spread(col("cpu", "client_pct")),
        "compositor_cpu_pct": spread(col("cpu", "compositor_pct")),
        "workload_cpu_pct": spread(col("cpu", "workload_pct")),
        "client_cpu_ms_per_frame": spread([r["cpu"]["client_pct"] * r["seconds"] * 10 / r["frames"]["presented"]
                                           for r in runs if _get(r, "cpu", "client_pct") is not None
                                           and _get(r, "frames", "presented")]),
        "frames_presented": spread(col("frames", "presented")),
        "fps": spread([(_get(r, "frames", "presented") or 0) / r["seconds"] for r in runs if r.get("seconds")]),
        "presented_total": presented,
        "missed_refreshes": missed,
        "late_frames": sum(_get(r, "frames", "late_frames") or 0 for r in runs),
        "missed_pct": round(100 * missed / (presented + missed), 3) if presented + missed else None,
        "frame_interval_ms": dist(pooled("frames", "interval_ms")),
        "render_ms": dist(pooled("frames", "render_ms")),
        "gpu_ms": dist(pooled("frames", "gpu_ms")),
        "commit_to_present_ms": dist(pooled("frames", "commit_to_present_ms")),
        "client_rss_mb": spread(kb_to_mb(col("memory", "client", "rss_kb"))),
        "client_pss_mb": spread(kb_to_mb(col("memory", "client", "pss_kb"))),
        "client_peak_rss_mb": spread(kb_to_mb(col("memory", "client", "peak_rss_kb"))),
        "compositor_rss_mb": spread(kb_to_mb(col("memory", "compositor", "rss_kb"))),
        "compositor_pss_mb": spread(kb_to_mb(col("memory", "compositor", "pss_kb"))),
    }
    # Idle draws nothing and the flood is about throughput, not pacing.
    if presented + missed and cell["workload"] not in ("idle", "cat-flood"):
        summary["keeps_up"] = summary["missed_pct"] <= KEEPS_UP_MAX_MISSED_PCT
    if any(_get(r, "latency") for r in runs):
        summary["latency"] = {k: dist(pooled("latency", k)) for k in
                              ("key_to_present_ms", "key_to_commit_ms", "key_to_receive_ms", "key_to_flip_ms")}
        summary["latency"]["input"] = _get(runs[0], "latency", "input")
        summary["latency"]["unmatched"] = sum(_get(r, "latency", "unmatched") or 0 for r in runs)
    if any(_get(r, "flood") for r in runs):
        summary["flood_wall_s"] = spread(col("flood", "wall_s"))
        summary["flood_mb_per_s"] = spread(col("flood", "mb_per_s"))
        summary["flood_energy_j"] = spread(col("power", "package_j"))
        summary["flood_complete"] = all(_get(r, "flood", "complete") for r in runs)
    gpu_mem = {}
    for r in runs:
        for name, kb in (_get(r, "gpu", "client_memory_kb") or {}).items():
            gpu_mem.setdefault(name, []).append(kb / 1024)
    if gpu_mem:
        summary["client_gpu_memory_mb"] = {name: spread(v) for name, v in gpu_mem.items()}
    engine = {}
    for r in runs:
        frames = _get(r, "frames", "presented") or 0
        for name, ms in (_get(r, "gpu", "client_engine_ms") or {}).items():
            if frames:
                engine.setdefault(name, []).append(ms / frames)
    if engine:
        summary["gpu_engine_ms_per_frame"] = {name: spread(v) for name, v in engine.items()}
    scan = [r.get("scanout_compositor") for r in runs if "scanout_compositor" in r]
    if scan:
        summary["scanout_compositor"] = all(scan)
    if "scanout_kms" in cell:
        summary["scanout_kms"] = cell["scanout_kms"]
    return summary


def annotate_kms_scanout(result):
    """Heuristic direct-scanout detection from KMS plane samples: a
    fullscreen cell scans out when its output-sized framebuffers are none of
    the compositor's own (those seen while the same config was tiled)."""
    display = _get(result, "session", "display") or {}
    size = f"{display.get('width')}x{display.get('height')}"
    composed = {}
    for cell in result.get("cells", []):
        if cell["state"] == "tiled":
            for r in cell["runs"]:
                composed.setdefault(cell["config"], set()).update(fb for fb, s, _m in r.get("kms_fbs", []) if s == size)
    for cell in result.get("cells", []):
        cell.pop("scanout_kms", None)
        if cell["state"] != "fullscreen" or cell["config"] not in composed:
            continue
        seen = {fb for r in cell["runs"] for fb, s, _m in r.get("kms_fbs", []) if s == size}
        if seen:
            cell["scanout_kms"] = not (seen & composed[cell["config"]])


def finalize(result):
    base = [r.get("package_w") for r in _get(result, "baseline", "runs") or []]
    base = [b for b in base if b is not None]
    baseline_w = statistics.median(base) if base else None
    if "baseline" in result:
        result["baseline"]["summary"] = {"package_w": spread(base),
                                         "compositor_cpu_pct": spread([r.get("compositor_pct") for r in result["baseline"]["runs"]])}
    annotate_kms_scanout(result)
    for cell in result.get("cells", []):
        cell["summary"] = summarize_cell(cell, baseline_w)
    for entry in result.get("startup", []):
        entry["summary"] = {"first_present_ms": dist(entry["first_present_ms"]),
                            "first_commit_ms": dist(entry["first_commit_ms"])}
        if "handoff_ms" in entry:
            entry["summary"]["handoff_ms"] = dist([v for v in entry["handoff_ms"] if v is not None])
    return result


def runs_of(doc):
    if doc.get("schema") == MERGED_SCHEMA:
        return doc["runs"]
    if doc.get("schema") == SCHEMA:
        return [doc]
    raise ValueError(f"not a monstar-bench result (schema {doc.get('schema')!r})")


def merge(docs):
    seen, runs = set(), []
    for doc in docs:
        for run in runs_of(doc):
            if run["id"] in seen:
                continue
            seen.add(run["id"])
            runs.append(finalize(run))
    return {"schema": MERGED_SCHEMA, "runs": runs}


# Markdown ------------------------------------------------------------------

def fmt(value, digits=1):
    if value is None:
        return "—"
    if isinstance(value, dict):
        value = value.get("median", value.get("p50"))
        if value is None:
            return "—"
    return f"{value:.{digits}f}"


def pair(d, a="p50", b="p99", digits=1):
    if not d:
        return "—"
    return f"{d[a]:.{digits}f} / {d[b]:.{digits}f}"


def machine_name(run):
    m = run["machine"]
    return m.get("label") or m.get("hostname")


def measurement_line(run):
    parts = []
    for name, info in run.get("measurements", {}).items():
        status = info["status"]
        mark = "✓" if status == "ok" else ("fake" if status == "fake" else "✗")
        root = " (root)" if info.get("privileged") else ""
        parts.append(f"{name}{root} {mark}")
    return ", ".join(parts)


def notes_for(cell, s):
    notes = []
    if cell["workload"] == "idle" and s.get("frames_presented"):
        notes.append(f"{fmt(s['frames_presented'], 0)} frames")
    if s.get("flood_wall_s"):
        notes.append(f"{fmt(s['flood_wall_s'], 2)} s, {fmt(s['flood_energy_j'], 1)} J, {fmt(s['flood_mb_per_s'], 0)} MB/s")
        if not s.get("flood_complete"):
            notes.append("incomplete")
    if s.get("scanout_compositor") is not None:
        notes.append("scanout" if s["scanout_compositor"] else "composited")
    elif s.get("scanout_kms") is not None:
        notes.append("scanout (KMS)" if s["scanout_kms"] else "composited (KMS)")
    engine = s.get("gpu_engine_ms_per_frame")
    if engine:
        busiest = max(engine.items(), key=lambda kv: (kv[1] or {}).get("median", 0))
        notes.append(f"GPU {busiest[0]} {fmt(busiest[1], 2)} ms/frame")
    warned = sum(1 for r in cell["runs"] if r.get("warning"))
    if warned:
        notes.append(f"{warned} run(s) warned: {next(r['warning'] for r in cell['runs'] if r.get('warning'))}")
    if cell.get("errors"):
        notes.append(f"{len(cell['errors'])} failed")
    return "; ".join(notes)


def keeps_up(s):
    if "keeps_up" not in s:
        return "—"
    return f"{'yes' if s['keeps_up'] else 'NO'} ({s['missed_refreshes']}/{s['presented_total']})"


def render_markdown(doc):
    runs = runs_of(doc)
    out = []
    for run in runs:
        sess, mon, mach = run["session"], run["monstar"], run["machine"]
        disp = sess.get("display") or {}
        gpus = ", ".join(f"{g.get('driver')} {g.get('vendor')}:{g.get('device')}" + (" (dGPU)" if g.get("discrete") else "")
                         for g in mach.get("gpus", [])) or "none"
        out.append(f"## {machine_name(run)} — {sess['compositor']} {sess.get('version') or ''} ({sess['mode']})\n")
        out.append(f"- Machine: {mach['cpu'].get('model')}; GPU {gpus}; kernel {mach.get('kernel')}; "
                   f"Mesa {mach.get('mesa') or '—'}; governor {mach['cpu'].get('governor') or '—'}")
        out.append(f"- Display: {disp.get('output')} {disp.get('width')}x{disp.get('height')}@{disp.get('refresh_hz')} "
                   f"scale {disp.get('scale')}")
        out.append(f"- Monstar: {mon.get('version')} ({run['settings'].get('repetitions')} reps; "
                   f"input {run['settings'].get('input')})")
        out.append(f"- Measurements: {measurement_line(run)}")
        base = _get(run, "baseline", "summary", "package_w")
        out.append(f"- Idle-system package power: {fmt(base, 2)} W" + (f" (n={base['n']})" if base else ""))
        skipped = [f"{name} ({c.get('reason')})" for name, c in run.get("configs", {}).items() if c["status"] != "ok"]
        if skipped:
            out.append(f"- Skipped configs: {'; '.join(skipped)}")
        if any(info["status"] == "fake" for info in run.get("measurements", {}).values()):
            out.append("- **Fake sensors were used; these numbers are not measurements.**")
        out.append("")
    out.append("### Steady state\n")
    out.append("Medians across repetitions; frame and latency percentiles pool every frame or key. "
               "ΔW is package power above the idle-system baseline.\n")
    header = ["Machine", "Compositor", "Config", "State", "Workload", "Keeps up (missed/frames)", "p99 frame ms",
              "Pkg W", "ΔW", "dGPU W", "Client CPU %", "Comp CPU %", "Render p50/p99 ms", "GPU p50/p99 ms", "Key→screen p50/p99 ms",
              "Client RSS MB", "Notes"]
    out.append("| " + " | ".join(header) + " |")
    out.append("|" + "|".join(["---"] * 5 + ["---:"] * 11 + ["---"]) + "|")
    for run in runs:
        for cell in run.get("cells", []):
            s = cell.get("summary") or {}
            lat = _get(s, "latency", "key_to_present_ms")
            row = [machine_name(run), cell["compositor"], cell["config"], cell["state"], cell["workload"],
                   keeps_up(s), fmt(_get(s, "frame_interval_ms", "p99")), fmt(s.get("package_w"), 2),
                   fmt(s.get("package_delta_w"), 2), fmt(s.get("dgpu_w"), 2), fmt(s.get("client_cpu_pct")),
                   fmt(s.get("compositor_cpu_pct")), pair(s.get("render_ms"), digits=2),
                   pair(s.get("gpu_ms"), digits=2), pair(lat),
                   fmt(s.get("client_rss_mb"), 0), notes_for(cell, s)]
            out.append("| " + " | ".join(row) + " |")
    startup = [(run, e) for run in runs for e in run.get("startup", [])]
    if startup:
        out.append("\n### Startup (launch to first presented frame)\n")
        out.append("Handoff is launch to the first frame through the config's own path: a cpu-first Vulkan "
                   "start shows CPU frames until then.\n")
        out.append("| Machine | Compositor | Config | Cache | n | p50 ms | p90 ms | min ms | max ms | Handoff p50 ms "
                   "| failed |")
        out.append("|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|")
        for run, e in startup:
            d = _get(e, "summary", "first_present_ms")
            vals = [fmt(d and d["p50"]), fmt(d and d["p90"]), fmt(d and min(e["first_present_ms"])),
                    fmt(d and d["max"]), fmt(_get(e, "summary", "handoff_ms", "p50"))]
            out.append(f"| {machine_name(run)} | {e['compositor']} | {e['config']} | {e['cache']} | "
                       f"{len(e['first_present_ms'])} | " + " | ".join(vals) + f" | {e['failures']} |")
    return "\n".join(out) + "\n"


def load(path):
    with open(path) as f:
        return json.load(f)
