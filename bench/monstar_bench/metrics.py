"""Unprivileged measurements and the arithmetic behind every summary."""

import json
import math
import os
import re
import statistics
from pathlib import Path

CLK_TCK = os.sysconf("SC_CLK_TCK")
CLOCK_MONOTONIC = 1


# Statistics --------------------------------------------------------------

def quantile(values, q):
    """Nearest-rank quantile (the earlier timbot scripts used the same)."""
    if not values:
        return None
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, max(0, math.ceil(q * len(ordered)) - 1))]


def spread(values):
    """Median and range of per-repetition values."""
    values = [v for v in values if v is not None]
    if not values:
        return None
    return {"median": round(statistics.median(values), 4), "min": round(min(values), 4),
            "max": round(max(values), 4), "n": len(values)}


def dist(values):
    if not values:
        return None
    return {"p50": round(quantile(values, 0.5), 3), "p90": round(quantile(values, 0.9), 3),
            "p99": round(quantile(values, 0.99), 3), "max": round(max(values), 3),
            "mean": round(statistics.fmean(values), 3), "n": len(values)}


# /proc -------------------------------------------------------------------

def cpu_ticks(pid, proc="/proc"):
    """utime+stime of all threads of `pid`, or None once it has exited."""
    try:
        text = Path(proc, str(pid), "stat").read_text()
    except OSError:
        return None
    fields = text[text.rindex(")") + 2:].split()
    return int(fields[11]) + int(fields[12])


def children(pid, proc="/proc"):
    """All descendants of `pid` (via /proc/PID/task/*/children)."""
    out, stack = [], [pid]
    while stack:
        current = stack.pop()
        for task in Path(proc, str(current), "task").glob("*"):
            try:
                kids = [int(x) for x in (task / "children").read_text().split()]
            except OSError:
                continue
            out.extend(kids)
            stack.extend(kids)
    return out


def memory(pid, proc="/proc"):
    """RSS, PSS (smaps_rollup) and peak RSS (VmHWM) in KiB."""
    out = {}
    try:
        for line in Path(proc, str(pid), "smaps_rollup").read_text().splitlines():
            key, _, rest = line.partition(":")
            if key in ("Rss", "Pss"):
                out[key.lower() + "_kb"] = int(rest.split()[0])
        for line in Path(proc, str(pid), "status").read_text().splitlines():
            if line.startswith("VmHWM:"):
                out["peak_rss_kb"] = int(line.split()[1])
    except OSError:
        pass
    return out


def drm_fdinfo(pid, proc="/proc"):
    """Per-client DRM usage from /proc/PID/fdinfo (drm-usage-stats): engine
    busy time in ns and memory in KiB, summed over DRM fds and deduplicated
    by drm-client-id. Unprivileged for your own processes."""
    clients = {}
    for fdinfo in Path(proc, str(pid), "fdinfo").glob("*"):
        try:
            text = fdinfo.read_text()
        except OSError:
            continue
        if "drm-client-id" not in text:
            continue
        fields = dict(line.split(":", 1) for line in text.splitlines() if ":" in line)
        client = fields["drm-client-id"].strip()
        stats = clients.setdefault(client, {"engine_ns": {}, "memory_kb": {}})
        for key, value in fields.items():
            value = value.strip()
            if key.startswith("drm-engine-") and not key.startswith("drm-engine-capacity"):
                stats["engine_ns"][key[len("drm-engine-"):]] = int(value.split()[0])
            elif key.startswith("drm-memory-") or key.startswith("drm-total-") or key.startswith("drm-resident-"):
                num, _, unit = value.partition(" ")
                scale = {"KiB": 1, "MiB": 1024, "GiB": 1024 * 1024, "": 1 / 1024}.get(unit.strip(), 1)
                stats["memory_kb"][key[len("drm-"):]] = int(int(num) * scale)
    total = {"engine_ns": {}, "memory_kb": {}}
    for stats in clients.values():
        for kind in total:
            for key, value in stats[kind].items():
                total[kind][key] = total[kind].get(key, 0) + value
    return total if clients else None


# Frame telemetry -----------------------------------------------------------

def read_telemetry(path):
    events = []
    try:
        with open(path) as f:
            for line in f:
                if line.endswith("\n"):
                    events.append(json.loads(line))
    except FileNotFoundError:
        pass
    return events


def telemetry_path_info(events):
    """Last effective renderer/presentation path, and the clock id."""
    path = None
    clock = None
    for ev in events:
        if ev["ev"] == "path":
            path = {"renderer": ev["renderer"], "presentation": ev["presentation"]}
        elif ev["ev"] == "clock":
            clock = ev["id"]
    return path, clock


def first_presented(events):
    for ev in events:
        if ev["ev"] == "frame" and "present" in ev:
            return ev
    return None


def missed_refreshes(start, previous, present, refresh):
    """Mirror of FrameTelemetry.missedRefreshes, for compositors that report
    refresh 0 (headless outputs): refreshes skipped before `present` when the
    frame was already rendering when the previous frame reached the screen."""
    if not refresh or not previous or not start or start > previous or present <= previous:
        return 0
    return max(0, (present - previous + refresh // 2) // refresh - 1)


def frame_stats(events, t0, t1, mode_refresh_ns=None):
    """Summarize frames committed inside [t0, t1] (CLOCK_MONOTONIC ns)."""
    frames = [ev for ev in events if ev["ev"] == "frame" and t0 <= ev["commit"] <= t1]
    presented = [ev for ev in frames if "present" in ev]
    reported = [ev["refresh"] for ev in presented if ev.get("refresh")]
    refresh = statistics.median(reported) if reported else (mode_refresh_ns or 0)
    source = "presentation" if reported else ("output-mode" if mode_refresh_ns else None)
    missed = 0
    intervals, render, latency = [], [], []
    previous = None
    for ev in presented:
        if previous is not None:
            intervals.append((ev["present"] - previous["present"]) / 1e6)
            if reported:
                missed += ev.get("missed", 0)
            else:
                missed += missed_refreshes(ev["start"], previous["present"], ev["present"], refresh)
        if ev["start"] and ev["render_done"]:
            render.append((ev["render_done"] - ev["start"]) / 1e6)
        latency.append((ev["present"] - ev["commit"]) / 1e6)
        previous = ev
    late = sum(1 for a, b in zip(presented, presented[1:])
               if (b.get("missed", 0) if reported else missed_refreshes(b["start"], a["present"], b["present"], refresh)))
    return {
        "committed": len(frames),
        "presented": len(presented),
        "discarded": sum(1 for ev in frames if ev.get("discarded")),
        "missed_refreshes": missed,
        "late_frames": late,
        "refresh_ms": round(refresh / 1e6, 4) if refresh else None,
        "refresh_source": source,
        "interval_ms": [round(x, 3) for x in intervals],
        "render_ms": [round(x, 3) for x in render],
        "commit_to_present_ms": [round(x, 3) for x in latency],
        "size": [presented[-1]["w"], presented[-1]["h"]] if presented else None,
    }


def match_latency(sent, events, flips=None):
    """Key-to-screen latency. For each measured key press, the first frame
    committed after Monstar received the key (or after the send, when no
    key event was logged) and before the next press is its echo.

    `sent` is [(send_ns, label, measure)] from input.play; `flips` are KMS
    page-flip times from the root helper, when traced."""
    keys = [ev["t"] for ev in events if ev["ev"] == "key"]
    frames = sorted((ev for ev in events if ev["ev"] == "frame" and "present" in ev), key=lambda ev: ev["commit"])
    flips = sorted(flips or [])
    out = {"key_to_present_ms": [], "key_to_commit_ms": [], "key_to_receive_ms": [], "key_to_flip_ms": []}
    ki = fi = li = 0
    unmatched = 0
    for i, (t, _label, measure) in enumerate(sent):
        nxt = sent[i + 1][0] if i + 1 < len(sent) else float("inf")
        while ki < len(keys) and keys[ki] < t:
            ki += 1
        received = keys[ki] if ki < len(keys) and keys[ki] < nxt else None
        anchor = received if received is not None else t
        while fi < len(frames) and frames[fi]["commit"] <= anchor:
            fi += 1
        frame = frames[fi] if fi < len(frames) and frames[fi]["commit"] < nxt else None
        if not measure:
            continue
        if frame is None:
            unmatched += 1
            continue
        out["key_to_present_ms"].append(round((frame["present"] - t) / 1e6, 3))
        out["key_to_commit_ms"].append(round((frame["commit"] - t) / 1e6, 3))
        if received is not None:
            out["key_to_receive_ms"].append(round((received - t) / 1e6, 3))
        if flips:
            while li < len(flips) and flips[li] <= frame["commit"]:
                li += 1
            if li < len(flips):
                out["key_to_flip_ms"].append(round((flips[li] - t) / 1e6, 3))
    out["keys"] = sum(1 for s in sent if s[2])
    out["unmatched"] = unmatched
    if not flips:
        out["key_to_flip_ms"] = None
    return out


# Power ---------------------------------------------------------------------

def rapl_power(start, end):
    """Package watts and joules between two helper `rapl` readings."""
    from .privileged import energy_delta_uj
    seconds = (end["t"] - start["t"]) / 1e9
    joules = 0.0
    for name, (energy, max_range) in end["zones"].items():
        joules += energy_delta_uj(start["zones"][name][0], energy, max_range) / 1e6
    return {"package_w": round(joules / seconds, 3) if seconds > 0 else None, "package_j": round(joules, 3),
            "seconds": round(seconds, 3)}


def read_number(path):
    try:
        return int(Path(path).read_text().split()[0])
    except (OSError, ValueError, IndexError):
        return None


def parse_version_commit(version):
    """`monstar 1.1.0-dev.145+g9b8aaa9.dirty` -> ('9b8aaa9', True)."""
    m = re.search(r"\+g([0-9a-f]+)(\.dirty)?", version or "")
    return (m.group(1), bool(m.group(2))) if m else (None, None)
