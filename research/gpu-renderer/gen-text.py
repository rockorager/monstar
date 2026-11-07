#!/usr/bin/env python3
"""Write the scroll corpora next to this script: text.txt (~180 columns),
text-short.txt (~100 columns) and text-accent.txt (text-short plus accented
capitals on every eighth line, which ink above the ascender in most fonts)."""
import os
import random

HERE = os.path.dirname(os.path.abspath(__file__))
WORDS = "the quick brown fox jumps over lazy dog render frame buffer vulkan wayland compositor scanout dmabuf latency".split()
ACCENT = " \x1b[33mÉcole Ångström Ölçü\x1b[0m"


def write(name, columns, tail=""):
    random.seed(1)
    with open(os.path.join(HERE, name), "w") as f:
        for i in range(20000):
            parts, n = [], 0
            while n < columns:
                wd = random.choice(WORDS)
                c = random.choice([31, 32, 33, 34, 35, 36, 37, 90, 0])
                parts.append(f"\x1b[{c}m{wd}")
                n += len(wd) + 1
            f.write(f"\x1b[2m{i:6d}\x1b[0m " + " ".join(parts) + "\x1b[0m" + (tail if i % 8 == 0 else "") + "\n")


write("text.txt", 180)
write("text-short.txt", 100)
write("text-accent.txt", 100, ACCENT)
