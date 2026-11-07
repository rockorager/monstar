#!/usr/bin/env python3
"""Colored log lines at a fixed rate: loggen.py LINES_PER_SECOND.

Deterministic (seeded) content, paced on an absolute schedule so a slow
terminal falls behind instead of slowing the generator down."""
import os
import random
import sys
import time

LEVELS = (("INFO ", 32), ("DEBUG", 90), ("WARN ", 33), ("ERROR", 31), ("INFO ", 32), ("INFO ", 32))
COMPONENTS = ("wayland", "render", "pty", "parser", "font", "input", "dmabuf", "vulkan", "shm", "scanout")
WORDS = ("frame committed buffer released damage region scroll glyph cache miss hit swapchain image acquired "
         "presented refresh vblank latency queue flush atlas upload shaped run cells rows resize configure").split()


def lines(seed=1):
    rng = random.Random(seed)
    t = 0
    while True:
        level, color = rng.choice(LEVELS)
        comp = rng.choice(COMPONENTS)
        msg = " ".join(rng.choice(WORDS) for _ in range(rng.randint(6, 18)))
        kv = " ".join(f"\x1b[36m{k}\x1b[0m={rng.randint(0, 99999)}" for k in rng.sample(("id", "ms", "w", "h", "n", "seq"), 3))
        yield (f"\x1b[2m2026-11-07T12:{t // 60000 % 60:02d}:{t // 1000 % 60:02d}.{t % 1000:03d}Z\x1b[0m "
               f"\x1b[{color}m{level}\x1b[0m \x1b[35m[{comp}]\x1b[0m {msg} {kv}\n").encode()
        t += rng.randint(1, 40)


def main():
    rate = float(sys.argv[1])
    out = os.fdopen(1, "wb", 0)
    period = 1.0 / rate
    deadline = time.monotonic()
    for line in lines():
        out.write(line)
        deadline += period
        delay = deadline - time.monotonic()
        if delay > 0:
            time.sleep(delay)


if __name__ == "__main__":
    try:
        main()
    except (BrokenPipeError, KeyboardInterrupt):
        pass
