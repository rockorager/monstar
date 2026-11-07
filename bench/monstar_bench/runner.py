"""The run matrix: configs x window states x workloads x repetitions, plus
startup launches and an idle-system power baseline."""

import json
import os
import shutil
import signal
import subprocess
import tempfile
import threading
import time
from pathlib import Path

from . import input as keys
from . import metrics, report, sensors, wayland
from .privileged import HelperError, UinputKeyboard

APP_ID = "monstar-bench"
CONFIGS = {
    "cpu": {"overrides": ["renderer=cpu", "presentation=shm"], "expect": {"renderer": "cpu", "presentation": "shm"}},
    "udmabuf": {"overrides": ["renderer=cpu", "presentation=dmabuf"], "expect": {"renderer": "cpu", "presentation": "dmabuf"}},
    # vulkan-startup = cpu-first (the default) presents CPU frames until
    # Vulkan is ready; only frames after that handoff are measured.
    "vulkan": {"overrides": ["renderer=vulkan"], "expect": {"renderer": "vulkan"}, "handoff_from": {"renderer": "cpu"}},
}
STATES = ("tiled", "fullscreen")
FIRST_FRAME_TIMEOUT = 15.0
KMS_PLANE_SAMPLES = 5


def now_ns():
    return time.clock_gettime_ns(time.CLOCK_MONOTONIC)


def log(msg):
    print(f"[monstar-bench] {msg}", flush=True)


def path_matches(effective, expect):
    return metrics.path_ok(effective, expect)


def accepted_override(monstar, override):
    """Whether this Monstar build accepts `-o override`. Overrides are
    applied before Monstar connects to Wayland, so a bogus display makes a
    valid override fail later (exit 1) and an invalid one fail first with
    'invalid command line' (exit 2)."""
    env = dict(os.environ, WAYLAND_DISPLAY="/nonexistent/monstar-bench-probe")
    proc = subprocess.run([monstar, "-o", override, "-e", "true"], env=env, capture_output=True, text=True, timeout=30)
    return not (proc.returncode == 2 and "invalid command line" in proc.stderr)


def skip_reason(spec, accepted, effective, warnings):
    """Why a config cannot run: Monstar showed nothing, the build rejects an
    override, or Monstar accepted it but fell back to another path."""
    if effective is None:
        return "Monstar did not present a frame with these overrides"
    accepted_keys = {o.split("=", 1)[0] for o in accepted}
    got = f"{effective['renderer']}/{effective['presentation']}"
    parts = []
    for key, want in spec["expect"].items():
        if effective.get(key) == want:
            continue
        if key in accepted_keys:
            part = f"{key}={want} was accepted but Monstar fell back to {got}"
            # Monstar logs why a requested path fell back, naming the path.
            related = [w for w in warnings if want in w]
            if related:
                part += f" ({related[-1]})"
            parts.append(part)
        else:
            parts.append(f"this build rejects {key}={want} and presents through {got}")
    return "; ".join(parts)


class Bench:
    def __init__(self, args, session, helper, cache, monstar, out_path, results):
        self.args = args
        self.session = session
        self.helper = helper
        self.cache = cache
        self.monstar = monstar
        self.out_path = out_path
        self.results = results
        self.work = Path(tempfile.mkdtemp(prefix="monstar-bench-"))
        self.gpus = sensors.gpus()
        self.sampler = sensors.GpuSampler(self.gpus)
        self.keyboard = None
        self.kms_flips = bool(helper.info.get("tracefs")) and session.mode == "own"
        self.kms_planes = bool(helper.info.get("debugfs_dri")) and session.mode == "own"
        self.netns = self._probe_netns()
        display = session.display() or {}
        refresh = display.get("refresh_hz")
        self.mode_refresh_ns = int(1e9 / refresh) if refresh else None
        self.output_size = (display.get("width"), display.get("height"))
        self.seq = 0

    # Setup -------------------------------------------------------------------

    def _probe_netns(self):
        cmd = ["unshare", "--user", "--map-current-user", "--net", "true"]
        try:
            return subprocess.run(cmd, capture_output=True, timeout=10).returncode == 0
        except (OSError, subprocess.TimeoutExpired):
            return False

    def open_keyboard(self):
        choice = self.args.input
        if choice == "auto":
            choice = "uinput" if self.session.uses_libinput and self.helper.info.get("uinput") else "virtual-keyboard"
        if choice == "uinput":
            self.keyboard = UinputKeyboard(self.helper)
        else:
            self.keyboard = wayland.VirtualKeyboard(self.session.env)
        return self.keyboard

    def detect_configs(self, wanted):
        """Decide which configs this build supports, from accepted `-o`
        overrides and the path Monstar reports presenting through."""
        out = {}
        for name in wanted:
            spec = CONFIGS[name]
            accepted = [o for o in spec["overrides"] if accepted_override(self.monstar, o)]
            effective, warnings = self.probe_path(accepted, spec)
            entry = {"overrides": accepted, "rejected": [o for o in spec["overrides"] if o not in accepted],
                     "expect": spec["expect"], "handoff_from": spec.get("handoff_from"), "effective": effective}
            if path_matches(effective, spec["expect"]):
                entry["status"] = "ok"
            else:
                entry["status"] = "skipped"
                entry["reason"] = skip_reason(spec, accepted, effective, warnings)
            out[name] = entry
            log(f"config {name}: {entry['status']}" + (f" ({entry.get('reason')})" if entry.get("reason") else ""))
        return out

    def probe_path(self, overrides, spec):
        """The path Monstar presents through with `overrides`, and the
        warnings it logged (such as why dma-buf fell back to wl_shm)."""
        run_dir = self.new_run_dir("probe")
        proc, telemetry = self.launch(overrides, ["sleep", "60"], {}, run_dir)
        try:
            frame = self.wait_first_frame(proc, telemetry)
            if frame and spec.get("handoff_from"):
                self.wait_handoff(proc, telemetry, spec)
            path = metrics.telemetry_path_info(metrics.read_telemetry(telemetry))[0] if frame else None
        finally:
            self.close_monstar(proc)
        log_text = (run_dir / "monstar.log").read_text(errors="replace")
        warnings = [line.strip() for line in log_text.splitlines() if line.startswith(("warning", "error"))]
        return path, warnings

    # Processes ---------------------------------------------------------------

    def new_run_dir(self, name):
        self.seq += 1
        path = self.work / f"{self.seq:04d}-{name}"
        path.mkdir()
        return path

    def launch(self, overrides, argv, env, run_dir, gate=None):
        telemetry = run_dir / "frames.jsonl"
        child = ["env"] + [f"{k}={v}" for k, v in env.items()]
        if self.netns:
            child += ["unshare", "--user", "--map-current-user", "--net", "--"]
        if gate:
            child += ["sh", "-c", 'read _ < "$0"; exec "$@"', str(gate)]
        child += argv
        cmd = [self.monstar, "--config", str(self.cache.monstar_config), "--app-id", APP_ID, "--title", APP_ID]
        for override in overrides:
            cmd += ["-o", override]
        cmd += ["-e"] + child
        menv = dict(self.session.env, FONTCONFIG_FILE=str(self.cache.fontconfig), MONSTAR_FRAME_TELEMETRY=str(telemetry))
        log_file = open(run_dir / "monstar.log", "w")
        proc = subprocess.Popen(cmd, env=menv, stdout=log_file, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                start_new_session=True)
        log_file.close()
        return proc, telemetry

    def wait_first_frame(self, proc, telemetry, timeout=FIRST_FRAME_TIMEOUT):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            frame = metrics.first_presented(metrics.read_telemetry(telemetry))
            if frame:
                return frame
            if proc.poll() is not None:
                return None
            time.sleep(0.005)
        return None

    def wait_handoff(self, proc, telemetry, spec, timeout=FIRST_FRAME_TIMEOUT):
        """The first frame presented through the config's expected path. With
        `handoff_from` that can follow frames on another path; otherwise it is
        the first frame when Monstar presents through the right path."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            frame = metrics.first_presented_on(metrics.read_telemetry(telemetry), spec["expect"])
            if frame:
                return frame
            if proc.poll() is not None:
                return None
            time.sleep(0.005)
        return None

    def close_monstar(self, proc):
        family = metrics.children(proc.pid) if proc.poll() is None else []
        if proc.poll() is None:
            proc.send_signal(signal.SIGTERM)
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
        for pid in family:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def open_gate(self, gate, timeout=10.0):
        deadline = time.monotonic() + timeout
        while True:
            try:
                fd = os.open(gate, os.O_WRONLY | os.O_NONBLOCK)
                break
            except OSError:
                if time.monotonic() > deadline:
                    raise RuntimeError("workload never opened its start gate")
                time.sleep(0.01)
        os.write(fd, b"go\n")
        os.close(fd)

    def apply_state(self, state):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            win = self.session.window(APP_ID)
            if win:
                break
            time.sleep(0.05)
        else:
            raise RuntimeError("the Monstar window never appeared in the compositor")
        if state == "fullscreen":
            self.session.set_fullscreen(APP_ID, True)
            time.sleep(0.5)
            win = self.session.window(APP_ID)
            if not win or not win["fullscreen"]:
                raise RuntimeError("could not make the Monstar window fullscreen")
        return win

    # Measurement -------------------------------------------------------------

    def snapshot(self, pids):
        return {pid: metrics.cpu_ticks(pid) for pid in pids}

    def measure(self, proc, workload, telemetry, run_dir, gate):
        client = proc.pid
        comp = self.session.pid
        if gate:
            self.open_gate(gate)
            time.sleep(workload.warmup)
        family0 = metrics.children(client)
        result_file = run_dir / "flood.json"
        flips = None
        planes, scans = [], []
        if self.kms_flips:
            self.helper.call("vblank_start")
        fd0 = metrics.drm_fdinfo(client)
        comp_fd0 = metrics.drm_fdinfo(comp)
        self.sampler.start()
        ticks0 = self.snapshot([client, comp] + family0)
        rapl0 = self.helper.call("rapl")
        t0 = rapl0["t"]
        sent = []
        player = None
        if workload.schedule:
            # Typing runs beside the sampling loop so KMS planes are sampled
            # during input-driven workloads too.
            failure = []

            def type_keys():
                try:
                    sent.extend(keys.play(self.keyboard, workload.schedule(workload.duration), start_ns=t0))
                except Exception as exc:  # re-raised on the measuring thread
                    failure.append(exc)

            player = threading.Thread(target=type_keys)
            player.start()
        end = t0 + int(workload.duration * 1e9)
        next_sample, samples = t0, 0
        while True:
            now = now_ns()
            if workload.until_done:
                if result_file.exists() or proc.poll() is not None or now >= end:
                    break
            elif now >= end:
                break
            # Scanout is sampled while the workload runs: a compositor can
            # stop scanning out once frames stop or a screenshot is taken.
            if now >= next_sample and samples < KMS_PLANE_SAMPLES:
                if self.kms_planes:
                    planes.append(self.helper.call("planes")["cards"])
                scan = self.session.scanout()
                if scan is not None:
                    scans.append(scan)
                samples += 1
                next_sample = now + int(workload.duration * 1e9 / KMS_PLANE_SAMPLES)
            time.sleep(0.005 if workload.until_done else min(0.05, max(0.0, (end - now) / 1e9)))
        if player:
            player.join()
        rapl1 = self.helper.call("rapl")
        t1 = rapl1["t"]
        error = failure[0] if player and failure else None
        if proc.poll() is not None and not result_file.exists():
            error = RuntimeError(f"Monstar exited during the measurement (status {proc.returncode}); "
                                 f"see {run_dir / 'monstar.log'}")
        if error:
            if self.kms_flips:
                self.helper.call("vblank_stop")
            self.sampler.stop()
            raise error
        family1 = metrics.children(client)
        ticks1 = self.snapshot([client, comp] + family1)
        gpu = self.sampler.stop()
        fd1 = metrics.drm_fdinfo(client)
        comp_fd1 = metrics.drm_fdinfo(comp)
        if self.kms_flips:
            flips = self.helper.call("vblank_stop")["flips"]
        seconds = (t1 - t0) / 1e9

        def pct(pids):
            total = 0
            for pid in pids:
                a, b = ticks0.get(pid), ticks1.get(pid)
                if a is not None and b is not None:
                    total += b - a
            return round(100 * total / metrics.CLK_TCK / seconds, 2) if seconds > 0 else None

        events = metrics.read_telemetry(telemetry)
        sample = {
            "seconds": round(seconds, 3),
            "power": metrics.rapl_power(rapl0, rapl1),
            "cpu": {"client_pct": pct([client]), "compositor_pct": pct([comp]),
                    "workload_pct": pct(sorted(set(family0) & set(family1)))},
            "frames": metrics.frame_stats(events, t0, t1, self.mode_refresh_ns),
            "memory": {"client": metrics.memory(client), "compositor": metrics.memory(comp)},
        }
        sample["power"].update({k: v for k, v in gpu.items() if v is not None})
        engine_ms = lambda a, b: {k: round((v - a["engine_ns"].get(k, 0)) / 1e6, 3) for k, v in b["engine_ns"].items()}
        if fd0 and fd1:
            sample["gpu"] = {"client_engine_ms": engine_ms(fd0, fd1), "client_memory_kb": fd1["memory_kb"]}
        if comp_fd0 and comp_fd1:
            # The compositor's GPU time: importing, uploading and compositing.
            sample.setdefault("gpu", {}).update(compositor_engine_ms=engine_ms(comp_fd0, comp_fd1),
                                                compositor_memory_kb=comp_fd1["memory_kb"])
        if workload.latency:
            sample["latency"] = metrics.match_latency(sent, events, flips)
            sample["latency"]["input"] = self.keyboard.name
        if flips is not None:
            sample["kms_flips"] = len(flips)
        if scans:
            sample["scanout_compositor"] = 2 * sum(scans) > len(scans)
        if planes:
            sample["kms_fbs"] = sorted({(p["fb"], p.get("size"), p.get("modifier"))
                                        for snap in planes for card in snap.values() for p in card}, key=str)
        if workload.until_done:
            try:
                flood = json.loads(result_file.read_text())
                wall = (flood["end_ns"] - flood["start_ns"]) / 1e9
                sample["flood"] = {"wall_s": round(wall, 3), "bytes": flood["bytes"],
                                   "mb_per_s": round(flood["bytes"] / wall / 1e6, 2), "complete": True}
            except (OSError, ValueError, KeyError):
                sample["flood"] = {"complete": False}
        return sample

    def run_cell(self, config, state, workload, rep):
        spec = self.results["configs"][config]
        run_dir = self.new_run_dir(f"{config}-{state}-{workload.name}-{rep}")
        env = dict(workload.env)
        if workload.setup:
            env.update(workload.setup(run_dir))
        argv = list(workload.argv)
        if workload.until_done:
            argv.append(str(run_dir / "flood.json"))
        gate = None
        if workload.gated:
            gate = run_dir / "gate"
            os.mkfifo(gate)
        proc, telemetry = self.launch(spec["overrides"], argv, env, run_dir, gate)
        try:
            if not self.wait_first_frame(proc, telemetry):
                raise RuntimeError(f"Monstar presented no frame; see {run_dir / 'monstar.log'}")
            # Measurement starts after the handoff, so no CPU frame of a
            # cpu-first Vulkan start falls inside it.
            if spec.get("handoff_from") and not self.wait_handoff(proc, telemetry, spec):
                raise RuntimeError(f"Monstar never switched to {spec['expect']}; see {run_dir / 'monstar.log'}")
            win = self.apply_state(state)
            time.sleep(workload.settle)
            sample = self.measure(proc, workload, telemetry, run_dir, gate)
            if getattr(self.args, "screenshots", None):
                self.args.screenshots.mkdir(parents=True, exist_ok=True)
                shot = self.args.screenshots / f"{config}-{state}-{workload.name}-{rep}.png"
                subprocess.run(["grim", str(shot)], env=self.session.env, timeout=10, check=False)
            win = self.session.window(APP_ID) or win
            sample["window"] = {"rect": win.get("rect"), "fullscreen": win.get("fullscreen")}
            events = metrics.read_telemetry(telemetry)
            path, clock = metrics.telemetry_path_info(events)
            sample["effective"] = path
            # Udmabuf falls back to wl_shm per buffer, so a run can switch.
            paths = [{"renderer": ev["renderer"], "presentation": ev["presentation"]}
                     for ev in events if ev["ev"] == "path"]
            if clock not in (None, metrics.CLOCK_MONOTONIC):
                sample["warning"] = f"presentation clock {clock} is not CLOCK_MONOTONIC; timings are not comparable"
            mismatched = metrics.path_mismatches(paths, spec["expect"], spec.get("handoff_from"))
            if mismatched:
                sample["paths"] = paths
                sample["warning"] = f"Monstar presented through {mismatched[0]}, not {spec['expect']}"
            return sample
        finally:
            self.close_monstar(proc)

    def baseline(self, seconds):
        """Idle system with no Monstar window: package power to subtract."""
        comp = self.session.pid
        ticks0 = metrics.cpu_ticks(comp)
        r0 = self.helper.call("rapl")
        time.sleep(seconds)
        r1 = self.helper.call("rapl")
        ticks1 = metrics.cpu_ticks(comp)
        power = metrics.rapl_power(r0, r1)
        power["compositor_pct"] = round(100 * (ticks1 - ticks0) / metrics.CLK_TCK / power["seconds"], 2)
        return power

    def startup(self, config, cache_state, launches):
        spec = self.results["configs"][config]
        samples, first_commit, handoff, failures = [], [], [], 0
        if cache_state == "warm":
            launches += 1  # the first launch warms the cache and is dropped
        for i in range(launches):
            run_dir = self.new_run_dir(f"startup-{config}-{cache_state}-{i}")
            if cache_state == "cold":
                self.helper.call("drop_caches")
                time.sleep(0.5)
            t0 = now_ns()
            proc, telemetry = self.launch(spec["overrides"], ["bash", "--noprofile", "--norc", "-i"],
                                          {"PS1": "monstar-bench$ ", "HISTFILE": "/dev/null"}, run_dir)
            frame = self.wait_first_frame(proc, telemetry)
            switched = self.wait_handoff(proc, telemetry, spec) if frame and spec.get("handoff_from") else None
            self.close_monstar(proc)
            time.sleep(0.5)
            if cache_state == "warm" and i == 0:
                continue
            if frame is None:
                failures += 1
                continue
            samples.append(round((frame["present"] - t0) / 1e6, 3))
            first_commit.append(round((frame["commit"] - t0) / 1e6, 3))
            if spec.get("handoff_from"):
                handoff.append(round((switched["present"] - t0) / 1e6, 3) if switched else None)
        out = {"first_present_ms": samples, "first_commit_ms": first_commit, "failures": failures}
        if spec.get("handoff_from"):
            out["handoff_ms"] = handoff
        return out

    # Matrix ------------------------------------------------------------------

    def save(self):
        report.finalize(self.results)
        tmp = self.out_path.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.results, indent=1))
        tmp.replace(self.out_path)

    def run(self, configs, states, workloads, reps, startup_launches, baseline_s):
        cells = {}
        self.results["cells"] = []
        self.results["baseline"] = {"runs": []}
        for rep in range(reps):
            log(f"repetition {rep + 1}/{reps}: idle-system baseline ({baseline_s:.0f} s)")
            self.results["baseline"]["runs"].append(self.baseline(baseline_s))
            for config in configs:
                for state in states:
                    for workload in workloads:
                        key = f"{self.session.compositor}/{config}/{state}/{workload.name}"
                        cell = cells.get(key)
                        if cell is None:
                            cell = {"key": key, "compositor": self.session.compositor, "config": config,
                                    "state": state, "workload": workload.name, "duration_s": workload.duration,
                                    "runs": [], "errors": []}
                            cells[key] = cell
                            self.results["cells"].append(cell)
                        log(f"{key} rep {rep + 1}")
                        try:
                            cell["runs"].append(self.run_cell(config, state, workload, rep))
                        except (RuntimeError, HelperError, OSError) as exc:
                            log(f"  failed: {exc}")
                            cell["errors"].append(str(exc))
                        self.save()
        self.results["startup"] = []
        if startup_launches:
            for config in configs:
                for cache_state in ("cold", "warm"):
                    log(f"startup {config} {cache_state} x{startup_launches}")
                    entry = {"key": f"{self.session.compositor}/{config}/tiled/startup-{cache_state}",
                             "compositor": self.session.compositor, "config": config, "cache": cache_state,
                             **self.startup(config, cache_state, startup_launches)}
                    self.results["startup"].append(entry)
                    self.save()
        self.save()

    def close(self):
        failed = any(cell["errors"] for cell in self.results.get("cells", []))
        if failed:
            log(f"kept per-run logs and telemetry in {self.work}")
        else:
            shutil.rmtree(self.work, ignore_errors=True)
        if self.keyboard:
            try:
                self.keyboard.close()
            except (OSError, HelperError, wayland.WaylandError):
                pass
