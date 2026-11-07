#!/usr/bin/env python3
"""Keypress-to-flip latency through the real input path.

Creates a uinput keyboard (kernel -> libinput -> compositor -> client),
alternates 'a' / BackSpace presses at random intervals, and records each
press's CLOCK_MONOTONIC time. Page-flip completions come from the
drm:drm_vblank_event tracepoint, whose `time` field is the vblank timestamp on
CLOCK_MONOTONIC. Latency = first flip after the press. The scene must be
otherwise static (no cursor, no animation) so every flip is caused by an echo.

usage: latency.py N OUT.json
"""
import fcntl, json, os, random, re, struct, sys, time

UI_SET_EVBIT = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_DEV_SETUP = 0x405c5503
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502
EV_SYN, EV_KEY = 0, 1
KEY_A, KEY_BACKSPACE = 30, 14
TR = "/sys/kernel/tracing"


def emit(fd, t, c, v):
    os.write(fd, struct.pack("llHHi", 0, 0, t, c, v))


def key(fd, code):
    emit(fd, EV_KEY, code, 1)
    emit(fd, EV_SYN, 0, 0)
    t = time.clock_gettime_ns(time.CLOCK_MONOTONIC)
    time.sleep(0.03)
    emit(fd, EV_KEY, code, 0)
    emit(fd, EV_SYN, 0, 0)
    return t


def w(path, val):
    with open(f"{TR}/{path}", "w") as f:
        f.write(val)


def main():
    n = int(sys.argv[1])
    out = sys.argv[2]
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    for k in (KEY_A, KEY_BACKSPACE):
        fcntl.ioctl(fd, UI_SET_KEYBIT, k)
    setup = struct.pack("HHHH80sI", 3, 0x1234, 0x5678, 1, b"mvk-latency-kbd", 0)
    fcntl.ioctl(fd, UI_DEV_SETUP, setup)
    fcntl.ioctl(fd, UI_DEV_CREATE)
    time.sleep(1.5)  # let libinput/compositor add the device
    w("events/drm/drm_vblank_event/enable", "0")
    w("trace", "")
    w("buffer_size_kb", "8192")
    w("events/drm/drm_vblank_event/enable", "1")
    # One untimed press so the keyboard has focus/keymap state warmed up.
    key(fd, KEY_A)
    time.sleep(0.3)
    presses = []
    for i in range(n):
        presses.append(key(fd, KEY_BACKSPACE if i % 2 == 0 else KEY_A))
        time.sleep(random.uniform(0.15, 0.30))
    time.sleep(0.2)
    w("events/drm/drm_vblank_event/enable", "0")
    flips = []
    with open(f"{TR}/trace") as f:
        for line in f:
            m = re.search(r"time=(\d+)", line)
            if m:
                flips.append(int(m.group(1)))
    fcntl.ioctl(fd, UI_DEV_DESTROY)
    flips.sort()
    lat = []
    extra = 0
    j = 0
    for i, t in enumerate(presses):
        nxt = presses[i + 1] if i + 1 < len(presses) else float("inf")
        while j < len(flips) and flips[j] <= t:
            j += 1
        if j < len(flips) and flips[j] < nxt:
            lat.append((flips[j] - t) / 1e6)
            k = j + 1
            while k < len(flips) and flips[k] < nxt:
                extra += 1
                k += 1
    lat.sort()
    q = lambda p: lat[min(len(lat) - 1, int(p * len(lat)))]
    res = dict(n=n, matched=len(lat), extra_flips=extra, flips=len(flips),
               p50=q(0.5), p90=q(0.9), p99=q(0.99), min=lat[0], max=lat[-1],
               mean=sum(lat) / len(lat), samples=lat)
    json.dump(res, open(out, "w"))
    print(json.dumps({k: v for k, v in res.items() if k != "samples"}))


main()
