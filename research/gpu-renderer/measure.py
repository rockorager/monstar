#!/usr/bin/env python3
"""Sample process CPU, package power, GPU busy, and page-flip rate.

usage: measure.py LABEL SECONDS OUT.jsonl proc_name[,proc_name...]
CPU is % of one core (utime+stime over all threads) per named process.
"""
import json, os, re, subprocess, sys, time

TR = "/sys/kernel/tracing"
RAPL = "/sys/class/powercap/intel-rapl:0/energy_uj"
PPT = "/sys/class/hwmon/hwmon5/power1_input"  # amdgpu SMU package power (PPT)
BUSY = "/sys/class/drm/card1/device/gpu_busy_percent"
HZ = os.sysconf("SC_CLK_TCK")


def rd(p):
    with open(p) as f:
        return f.read().strip()


def pids(name):
    out = subprocess.run(["pgrep", "-x", name], capture_output=True, text=True).stdout
    return [int(x) for x in out.split()]


def cpu_ticks(pid):
    try:
        s = rd(f"/proc/{pid}/stat")
    except FileNotFoundError:
        return 0
    f = s[s.rindex(")") + 2:].split()
    return int(f[11]) + int(f[12])


def w(path, val):
    with open(f"{TR}/{path}", "w") as f:
        f.write(val)


def main():
    label, secs, out, names = sys.argv[1], float(sys.argv[2]), sys.argv[3], sys.argv[4].split(",")
    procs = {n: pids(n) for n in names}
    w("events/drm/drm_vblank_event/enable", "0")
    w("trace", "")
    w("events/drm/drm_vblank_event/enable", "1")
    c0 = {n: sum(cpu_ticks(p) for p in ps) for n, ps in procs.items()}
    e0 = int(rd(RAPL))
    t0 = time.monotonic()
    ppt, busy = [], []
    while time.monotonic() - t0 < secs:
        ppt.append(int(rd(PPT)) / 1e6)
        busy.append(int(rd(BUSY)))
        time.sleep(0.1)
    dt = time.monotonic() - t0
    e1 = int(rd(RAPL))
    c1 = {n: sum(cpu_ticks(p) for p in ps) for n, ps in procs.items()}
    w("events/drm/drm_vblank_event/enable", "0")
    flips = sum(1 for line in open(f"{TR}/trace") if "drm_vblank_event:" in line)
    res = dict(label=label, seconds=round(dt, 2),
               cpu={n: round(100 * (c1[n] - c0[n]) / HZ / dt, 1) for n in names},
               rapl_pkg_w=round((e1 - e0) / 1e6 / dt, 2),
               ppt_w=round(sum(ppt) / len(ppt), 2),
               gpu_busy_pct=round(sum(busy) / len(busy), 1),
               flips_per_s=round(flips / dt, 1))
    with open(out, "a") as f:
        f.write(json.dumps(res) + "\n")
    print(json.dumps(res))


main()
