"""Command line: bootstrap, probe, run, report, merge."""

import argparse
import dataclasses
import json
import subprocess
import sys
import time
import uuid
from pathlib import Path

from . import bootstrap, metrics, pins, privileged, report, runner, sensors
from . import session as sessions
from .workloads import all_workloads

BENCH_DIR = Path(__file__).resolve().parent.parent
REPO_DIR = BENCH_DIR.parent
ENTRY = BENCH_DIR / "monstar-bench"
TOOL_VERSION = "1"


def parse_args(argv):
    p = argparse.ArgumentParser(prog="monstar-bench", description=__doc__)
    sub = p.add_subparsers(dest="command", required=True)

    def common(sp):
        sp.add_argument("--cache", type=Path, default=bootstrap.default_cache_dir(), help="workload cache directory")

    sp = sub.add_parser("bootstrap", help="fetch pinned workloads into the cache (uses the network)")
    common(sp)
    sp.add_argument("--skip-lazyvim", action="store_true", help="skip LazyVim (the nvim workloads are skipped)")

    for name in ("run", "probe"):
        sp = sub.add_parser(name, help="run the benchmark matrix" if name == "run" else
                            "show the session and which configs this Monstar build supports")
        common(sp)
        sp.add_argument("--monstar", type=Path, default=REPO_DIR / "zig-out" / "bin" / "monstar")
        sp.add_argument("--session", choices=("auto", "own", "nested", "headless"), default="auto",
                        help="auto uses the current Sway/Hyprland session, else starts Sway nested or headless")
        sp.add_argument("--headless-mode", default="1920x1200@60", help="output mode for a started Sway")
        sp.add_argument("--configs", default=",".join(runner.CONFIGS))
        sp.add_argument("--sysfs-root", default="/", help=argparse.SUPPRESS)  # fake sysfs for tests
        if name == "run":
            sp.add_argument("--states", default=",".join(runner.STATES))
            sp.add_argument("--workloads", default=None, help="comma-separated subset (default: all)")
            sp.add_argument("--reps", type=int, default=3)
            sp.add_argument("--startup-launches", type=int, default=15, help="0 skips the startup matrix")
            sp.add_argument("--baseline-seconds", type=float, default=20.0)
            sp.add_argument("--input", choices=("auto", "uinput", "virtual-keyboard"), default="auto")
            sp.add_argument("--label", default=None, help="machine name in tables (default: hostname)")
            sp.add_argument("--out", type=Path, default=None, help="result JSON (Markdown is written next to it)")
            sp.add_argument("--quick", action="store_true", help="1 rep, 3 s cells, 3 startup launches (smoke test)")
            sp.add_argument("--screenshots", type=Path, default=None,
                            help="save a grim screenshot of every cell at the end of its measurement")
            sp.add_argument("--no-sudo", action="store_true", help=argparse.SUPPRESS)  # tests: helper without sudo

    sp = sub.add_parser("report", help="render the Markdown table from result JSON")
    sp.add_argument("files", nargs="+", type=Path)
    sp = sub.add_parser("merge", help="merge result JSON from several machines")
    sp.add_argument("files", nargs="+", type=Path)
    sp.add_argument("-o", "--out", type=Path, required=True)

    sp = sub.add_parser("_helper", help=argparse.SUPPRESS)
    sp.add_argument("--sysfs-root", default="/")
    return p.parse_args(argv)


def monstar_version(binary):
    out = subprocess.run([str(binary), "--version"], capture_output=True, text=True, timeout=10).stdout.strip()
    commit, dirty = metrics.parse_version_commit(out)
    return {"binary": str(binary), "version": out, "commit": commit, "dirty": dirty}


def parse_mode(text):
    size, _, refresh = text.partition("@")
    return size, float(refresh or 60)


def selected(names, allowed, what):
    chosen = [n.strip() for n in names.split(",") if n.strip()]
    unknown = [n for n in chosen if n not in allowed]
    if unknown:
        raise SystemExit(f"unknown {what}: {', '.join(unknown)} (choose from {', '.join(allowed)})")
    return chosen


class NoHelper:
    info = {}

    def call(self, *_a, **_k):
        raise privileged.HelperError("no root helper in probe mode")

    def close(self):
        pass


def open_session(args):
    size, refresh = parse_mode(args.headless_mode)
    session = sessions.detect(args.session, size, refresh)
    print(f"[monstar-bench] session: {session.compositor} ({session.mode})", flush=True)
    return session


def cmd_probe(args):
    cache = bootstrap.Cache(args.cache)
    problem = cache.check()
    zones = privileged.rapl_zones(args.sysfs_root)
    session = open_session(args)
    try:
        session.prepare()
        bench = runner.Bench(args, session, NoHelper(), cache, str(args.monstar), None, {})
        configs = bench.detect_configs(selected(args.configs, list(runner.CONFIGS), "configs"))
        print(json.dumps({
            "monstar": monstar_version(args.monstar),
            "session": session.describe(),
            "cache": problem or "ok",
            "rapl_zones": [name for name, _ in zones] or privileged.rapl_missing_message(args.sysfs_root),
            "configs": configs,
            "gpus": sensors.gpus(),
        }, indent=2))
    finally:
        session.close()


def measurements(args, helper, session, bench, sampler, keyboard):
    fake = args.sysfs_root != "/"
    ok = lambda cond: "ok" if cond else "unavailable"
    return {
        "rapl_package": {"status": "fake" if fake else "ok", "privileged": True,
                         "source": ", ".join(helper.info.get("rapl", []))},
        "frame_timing": {"status": "ok", "privileged": False, "source": "wp_presentation feedback recorded by Monstar"},
        "cpu_memory": {"status": "ok", "privileged": False, "source": "/proc"},
        "input": {"status": "ok" if keyboard else "unused", "privileged": bool(keyboard and keyboard.privileged),
                  "source": keyboard.name if keyboard else None},
        "kms_flips": {"status": ok(bench.kms_flips), "privileged": True, "source": "tracefs drm_vblank_event"},
        "kms_scanout": {"status": ok(bench.kms_planes), "privileged": True, "source": "debugfs dri/*/state (heuristic)"},
        "compositor_scanout": {"status": ok(session.compositor == "hyprland"), "privileged": False,
                               "source": "hyprctl monitors directScanoutTo"},
        "dgpu_power": {"status": ok(sampler.has_dgpu_power), "privileged": False, "source": "hwmon / nvidia-smi"},
        "gpu_fdinfo": {"status": ok(any(g["driver"] for g in bench.gpus)), "privileged": False,
                       "source": "/proc/PID/fdinfo drm-engine-*"},
        "cold_cache": {"status": "ok", "privileged": True, "source": "drop_caches"},
        "network_isolation": {"status": ok(bench.netns), "privileged": False, "source": "unshare --net (workloads)"},
    }


def cmd_run(args):
    if args.quick:
        args.reps, args.baseline_seconds = 1, min(args.baseline_seconds, 3.0)
        args.startup_launches = min(args.startup_launches, 3)
    if not args.monstar.exists():
        raise SystemExit(f"Monstar binary not found: {args.monstar} (build it with `zig build -Doptimize=ReleaseFast`)")
    cache = bootstrap.Cache(args.cache)
    problem = cache.check()
    if problem:
        raise SystemExit(problem)
    # RAPL zones are listed without root; only reading the counter needs it.
    if not privileged.rapl_zones(args.sysfs_root):
        raise SystemExit(privileged.rapl_missing_message(args.sysfs_root))
    configs = selected(args.configs, list(runner.CONFIGS), "configs")
    states = selected(args.states, list(runner.STATES), "states")
    workloads = all_workloads(cache)
    names = [w.name for w in workloads]
    wanted = selected(args.workloads, names, "workloads") if args.workloads else names
    workloads = [w for w in workloads if w.name in wanted]
    skipped_workloads = {w.name: w.skip for w in workloads if w.skip}
    workloads = [w for w in workloads if not w.skip]
    if args.quick:
        workloads = [dataclasses.replace(w, duration=min(w.duration, 3.0)) if not w.until_done else w
                     for w in workloads]

    helper = privileged.start_helper(ENTRY, args.sysfs_root, use_sudo=not args.no_sudo)
    session = None
    bench = None
    try:
        helper.call("rapl")
        session = open_session(args)
        session.prepare()
        started = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        mach = sensors.machine_info(args.label)
        stamp = time.strftime("%Y%m%d-%H%M%S")
        out = args.out or (Path.cwd() / "bench-results" / f"{args.label or mach['hostname']}-{session.compositor}-{stamp}.json")
        out.parent.mkdir(parents=True, exist_ok=True)
        results = {
            "schema": report.SCHEMA,
            "id": str(uuid.uuid4()),
            "tool": {"version": TOOL_VERSION, "argv": sys.argv[1:], "started": started},
            "machine": mach,
            "session": session.describe(),
            "monstar": monstar_version(args.monstar),
            "pins": pins.manifest(),
            "cache": cache.recorded().get("tools"),
        }
        bench = runner.Bench(args, session, helper, cache, str(args.monstar), out, results)
        keyboard = bench.open_keyboard() if any(w.schedule for w in workloads) else None
        results["configs"] = bench.detect_configs(configs)
        results["settings"] = {
            "repetitions": args.reps, "states": states, "workloads": [w.name for w in workloads],
            "skipped_workloads": skipped_workloads, "input": keyboard.name if keyboard else None,
            "durations_s": {w.name: w.duration for w in workloads}, "startup_launches": args.startup_launches,
            "baseline_s": args.baseline_seconds, "app_id": runner.APP_ID, "font": [pins.FONT_FAMILY, pins.FONT_SIZE],
            "keeps_up_max_missed_pct": report.KEEPS_UP_MAX_MISSED_PCT,
        }
        results["measurements"] = measurements(args, helper, session, bench, bench.sampler, keyboard)
        ok_configs = [c for c in configs if results["configs"][c]["status"] == "ok"]
        if not ok_configs:
            raise SystemExit("no requested config works with this Monstar build")
        bench.run(ok_configs, states, workloads, args.reps, args.startup_launches, args.baseline_seconds)
        results["tool"]["finished"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        bench.save()
        md = out.with_suffix(".md")
        md.write_text(report.render_markdown(results))
        print(f"[monstar-bench] wrote {out} and {md}", flush=True)
    finally:
        if bench:
            bench.close()
        if session:
            session.close()
        helper.close()


def cmd_report(args):
    docs = [report.load(p) for p in args.files]
    doc = docs[0] if len(docs) == 1 else report.merge(docs)
    if doc.get("schema") == report.SCHEMA:
        report.finalize(doc)
    sys.stdout.write(report.render_markdown(doc))


def cmd_merge(args):
    merged = report.merge([report.load(p) for p in args.files])
    args.out.write_text(json.dumps(merged, indent=1))
    print(f"merged {len(merged['runs'])} runs into {args.out}")


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    if args.command == "_helper":
        return privileged.helper_main(args.sysfs_root)
    if args.command == "bootstrap":
        bootstrap.bootstrap(args.cache, args.skip_lazyvim)
    elif args.command == "probe":
        cmd_probe(args)
    elif args.command == "run":
        cmd_run(args)
    elif args.command == "report":
        cmd_report(args)
    elif args.command == "merge":
        cmd_merge(args)
