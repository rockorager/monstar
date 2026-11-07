"""Workload definitions: what runs in the terminal and how it is driven."""

import os
import shutil
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Optional

from . import input as keys
from . import pins

WORKLOAD_DIR = Path(__file__).resolve().parent.parent / "workloads"
PROMPT = "monstar-bench$ "
TYPING_RATE_HZ = 9
REPEAT_RATE_HZ = 25  # Sway's and Hyprland's default key repeat rate
SHELL_LINE = "echo the quick brown fox jumps over the lazy dog | wc -c"
NVIM_LINE = "\tstatic int monstar_bench_value = 42; /* typed by monstar-bench */\n"


@dataclass
class Workload:
    name: str
    duration: float
    argv: list
    env: dict = field(default_factory=dict)
    settle: float = 2.0  # after the first frame, before anything starts
    gated: bool = False  # the program waits for the gate at measurement start
    warmup: float = 0.0  # gate open to measurement start
    schedule: Optional[Callable[[float], list]] = None
    until_done: bool = False  # cat flood: measure until the result file appears
    latency: bool = False
    skip: Optional[str] = None  # reason this machine cannot run it
    setup: Optional[Callable[[Path], dict]] = None  # per-run files; returns env


def bash_argv():
    return ["bash", "--noprofile", "--norc", "-i"]


BASH_ENV = {"PS1": PROMPT, "HISTFILE": "/dev/null", "PROMPT_COMMAND": ""}


def btop_setup(run_dir):
    config = run_dir / "btop-config"
    (config / "btop").mkdir(parents=True, exist_ok=True)
    (config / "btop" / "btop.conf").write_text(f"update_ms = {pins.BTOP_UPDATE_MS}\n")
    return {"XDG_CONFIG_HOME": str(config)}


def all_workloads(cache):
    nvim = str(cache.nvim_bin)
    nvim_ok = cache.nvim_bin.exists() and (cache.lazyvim / "config" / "nvim").exists()
    nvim_skip = None if nvim_ok else "LazyVim is not bootstrapped (rerun bootstrap without --skip-lazyvim)"

    def nvim_setup(run_dir):
        state = run_dir / "nvim-state"
        state.mkdir(parents=True, exist_ok=True)
        env = cache.lazyvim_env(state)
        env["PATH"] = f"{cache.nvim_bin.parent}:{os.environ.get('PATH', '')}"
        return env

    ctrl_d = keys.Tap(keys.char_key("d")[0], ctrl=True, label="C-d")
    j = keys.Tap.char("j")
    tte_env = {"PYTHONPATH": str(cache.tte)}
    loggen = str(WORKLOAD_DIR / "loggen.py")

    workloads = [
        Workload("idle", 20, bash_argv(), env=BASH_ENV),
        Workload("shell-typing", 10, bash_argv(), env=BASH_ENV, latency=True,
                 schedule=lambda s: keys.typing_schedule(
                     SHELL_LINE, TYPING_RATE_HZ, s, seed=1,
                     reset=[keys.Tap(keys.char_key("u")[0], ctrl=True, label="C-u", measure=False)])),
        Workload("btop", 10, ["btop"], settle=3.0, setup=btop_setup,
                 skip=None if shutil.which("btop") else "btop is not installed"),
        Workload("nvim-scroll", 10, [nvim, str(cache.nvim_file)], settle=5.0, setup=nvim_setup, skip=nvim_skip,
                 schedule=lambda s: keys.repeat_schedule([(s / 2, j), (s / 2, ctrl_d)], REPEAT_RATE_HZ)),
        Workload("nvim-insert", 10, [nvim, "+6000", str(cache.nvim_file)], settle=5.0, setup=nvim_setup,
                 skip=nvim_skip, latency=True,
                 schedule=lambda s: keys.typing_schedule(
                     NVIM_LINE, TYPING_RATE_HZ, s, seed=2, typo_every=0,
                     prefix=[keys.Tap.char("o", measure=False)])),
        Workload("screensaver", 10, ["sh", str(WORKLOAD_DIR / "screensaver.sh"), str(cache.logo), pins.TTE_EFFECT],
                 env=tte_env, gated=True, warmup=1.5,
                 skip=None if (cache.tte / "terminaltexteffects").exists() else "tte is not bootstrapped"),
    ]
    for rate in (10, 60, 500):
        workloads.append(Workload(f"log-{rate}", 10, ["python3", loggen, str(rate)], gated=True, warmup=1.0))
    workloads.append(Workload("cat-flood", 180, ["python3", str(WORKLOAD_DIR / "flood.py"), str(cache.corpus),
                               str(pins.FLOOD_COPIES)],
                              gated=True, until_done=True))
    return workloads


STARTUP_ARGV = bash_argv()
