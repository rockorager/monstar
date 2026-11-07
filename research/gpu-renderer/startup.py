#!/usr/bin/env python3
"""Launch-to-first-flip: spawn a client on an empty output and take the first
page flip after exec as its first visible frame. Optionally also report the
first flip after a stderr `mark <name>` line (CLOCK_MONOTONIC `mono` value).

usage: startup.py LABEL N OUT.jsonl PROCNAME [--mark NAME] -- CMD...
"""
import json, re, subprocess, sys, time

TR = "/sys/kernel/tracing"


def w(path, val):
    with open(f"{TR}/{path}", "w") as f:
        f.write(val)


def flips():
    out = []
    for line in open(f"{TR}/trace"):
        m = re.search(r"time=(\d+)", line)
        if m:
            out.append(int(m.group(1)))
    return sorted(out)


def main():
    label, n, out, proc = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
    rest = sys.argv[5:]
    mark = None
    if rest[0] == "--mark":
        mark, rest = rest[1], rest[2:]
    cmd = rest[1:]
    first, marked = [], []
    for i in range(n):
        w("events/drm/drm_vblank_event/enable", "0")
        w("trace", "")
        w("events/drm/drm_vblank_event/enable", "1")
        time.sleep(0.2)
        t0 = time.clock_gettime_ns(time.CLOCK_MONOTONIC)
        p = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        time.sleep(1.0)
        subprocess.run(["pkill", "-x", proc])
        err = p.communicate()[1]
        w("events/drm/drm_vblank_event/enable", "0")
        fl = [f for f in flips() if f > t0]
        if fl:
            first.append((fl[0] - t0) / 1e6)
        if mark:
            m = re.search(rf"mark {re.escape(mark)}\s.*mono (\d+)", err)
            if m:
                tm = int(m.group(1))
                after = [f for f in fl if f > tm]
                if after:
                    marked.append((after[0] - t0) / 1e6)
        time.sleep(0.5)

    def stats(xs):
        xs = sorted(xs)
        return dict(n=len(xs), p50=round(xs[len(xs) // 2], 2), min=round(xs[0], 2), max=round(xs[-1], 2)) if xs else None

    res = dict(label=label, first_flip_ms=stats(first))
    if mark:
        res[f"first_flip_after_{mark}_ms"] = stats(marked)
    with open(out, "a") as f:
        f.write(json.dumps(res) + "\n")
    print(json.dumps(res))


main()
