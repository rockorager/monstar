#!/usr/bin/env python3
"""Median tables from results/suite.jsonl and latency JSON files."""
import glob, json, re, statistics
from collections import defaultdict

runs = defaultdict(list)
for line in open("results/suite.jsonl"):
    r = json.loads(line)
    runs[r["label"]].append(r)

print("| config | workload | client CPU % | sway CPU % | RAPL pkg W | GPU busy % | n |")
print("|---|---|---:|---:|---:|---:|---:|")
for label, rs in runs.items():
    renderer, kind, wl = label.split("/")
    client = [v for k, v in rs[0]["cpu"].items() if k != "sway"][0]
    med = lambda f: statistics.median(f(r) for r in rs)
    cl = med(lambda r: [v for k, v in r["cpu"].items() if k != "sway"][0])
    print(f"| {renderer}/{kind} | {wl} | {cl:.1f} | {med(lambda r: r['cpu']['sway']):.1f} | "
          f"{med(lambda r: r['rapl_pkg_w']):.2f} | {med(lambda r: r['gpu_busy_pct']):.1f} | {len(rs)} |")

print()
print("| latency set | n | mean ms | p50 | p90 | p99 | >16.7 ms |")
print("|---|---:|---:|---:|---:|---:|---:|")
groups = defaultdict(list)
for f in sorted(glob.glob("results/latx-*.json")):
    m = re.match(r"results/latx-(.+)-(\w+)-\d+\.json", f)
    groups[f"{m.group(1)}/{m.group(2)}"] += json.load(open(f))["samples"]
for f in sorted(glob.glob("results/lat-*.json")):
    groups[f[len("results/lat-"):-5] + " (suite)"] += json.load(open(f))["samples"]
for k, s in groups.items():
    s = sorted(s)
    q = lambda p: s[min(len(s) - 1, int(p * len(s)))]
    print(f"| {k} | {len(s)} | {sum(s)/len(s):.2f} | {q(.5):.2f} | {q(.9):.2f} | {q(.99):.2f} | "
          f"{100*sum(x > 16.7 for x in s)/len(s):.0f}% |")
