"""The root helper and its client.

monstar-bench runs as the user. Reading RAPL energy, creating a uinput
keyboard, tracing KMS page flips and dropping the page cache need root, so
the tool starts this helper once with sudo and talks to it over a pipe in
JSON lines. The helper does nothing else; Monstar, the compositor and the
workloads never run as root.

Every sysfs/debugfs/tracefs path is relative to `root` so tests and
development machines can point it at a fake tree (`--sysfs-root`)."""

import fcntl
import glob
import json
import os
import re
import struct
import subprocess
import sys
import threading
import time
from pathlib import Path

POWERCAP = "sys/class/powercap"
TRACEFS = "sys/kernel/tracing"
VBLANK_EVENTS = ("drm_vblank_event", "drm_vblank_event_delivered")
DEBUGFS_DRI = "sys/kernel/debug/dri"
DROP_CACHES = "proc/sys/vm/drop_caches"

EXPLANATION = """\
monstar-bench needs sudo for a small root helper.

Power is the headline metric of this benchmark, and it comes from the CPU
package's RAPL energy counter. Since the PLATYPUS power side-channel fix
(CVE-2020-8694), the kernel lets only root read that counter.

The helper runs as root for the whole run and only:
  - reads the RAPL energy counters (/sys/class/powercap/*/energy_uj),
  - creates a uinput keyboard so input latency includes libinput,
  - traces KMS page flips (tracefs drm_vblank_event) and reads the plane
    state in debugfs to detect direct scanout,
  - drops the page cache before cold-start launches.
Monstar, the compositor and every workload keep running as you.
"""


def now_ns():
    return time.clock_gettime_ns(time.CLOCK_MONOTONIC)


def rapl_zones(root):
    """Top-level package zones: [(name, dir)]. Visible without root."""
    zones = []
    for zone in sorted(glob.glob(os.path.join(root, POWERCAP, "*"))):
        base = os.path.basename(zone)
        # intel-rapl:0 is a package; intel-rapl:0:0 is a subzone. AMD's RAPL
        # driver registers under the same control type.
        if not re.fullmatch(r"intel-rapl:\d+", base):
            continue
        try:
            name = Path(zone, "name").read_text().strip()
        except OSError:
            continue
        if name.startswith("package") and os.path.exists(os.path.join(zone, "energy_uj")):
            zones.append((name, zone))
    return zones


def rapl_missing_message(root):
    return (
        "RAPL package energy is not available: no package zone under "
        f"{os.path.join(root, POWERCAP)}.\n"
        "Power is the headline metric, so monstar-bench cannot run here. RAPL needs "
        "an Intel or AMD (Zen) CPU with the intel_rapl/rapl powercap driver loaded "
        "(`modprobe intel_rapl_msr`); virtual machines usually do not expose it."
    )


def energy_delta_uj(start, end, max_range):
    """Counter delta with one wraparound allowed."""
    return end - start if end >= start else end + max_range - start


# uinput ------------------------------------------------------------------

UI_SET_EVBIT = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_DEV_SETUP = 0x405C5503
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502
EV_SYN, EV_KEY = 0, 1


class Uinput:
    def __init__(self, root):
        self.fd = os.open(os.path.join(root, "dev/uinput") if root != "/" else "/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
        fcntl.ioctl(self.fd, UI_SET_EVBIT, EV_KEY)
        for code in range(1, 128):
            fcntl.ioctl(self.fd, UI_SET_KEYBIT, code)
        setup = struct.pack("HHHH80sI", 3, 0x1234, 0x5679, 1, b"monstar-bench keyboard", 0)
        fcntl.ioctl(self.fd, UI_DEV_SETUP, setup)
        fcntl.ioctl(self.fd, UI_DEV_CREATE)

    def emit(self, etype, code, value):
        os.write(self.fd, struct.pack("llHHi", 0, 0, etype, code, value))

    def key(self, code, value):
        self.emit(EV_KEY, code, value)
        self.emit(EV_SYN, 0, 0)
        return now_ns()

    def close(self):
        try:
            fcntl.ioctl(self.fd, UI_DEV_DESTROY)
        finally:
            os.close(self.fd)


# KMS ---------------------------------------------------------------------

def parse_flip_times(text):
    """Page-flip times (CLOCK_MONOTONIC ns) from a tracefs dump.
    drm_vblank_event fires on every vblank while the interrupt is on, so a
    flip is a vblank for which an event was also delivered to user space
    (drm_vblank_event_delivered, same crtc and seq); that event carries no
    timestamp of its own."""
    times = {(m.group(1), m.group(2)): int(m.group(3))
             for m in re.finditer(r"drm_vblank_event: crtc=(-?\d+), seq=(\d+), time=(-?\d+)", text)}
    delivered = {(m.group(1), m.group(2))
                 for m in re.finditer(r"drm_vblank_event_delivered: file=\S+ crtc=(-?\d+), seq=(\d+)", text)}
    return sorted(times[key] for key in delivered if key in times)


def parse_planes(state_text):
    """Planes with a framebuffer in a debugfs dri/N/state dump:
    [{plane, crtc, fb, allocated_by, format, modifier, size}]."""
    planes, current = [], None
    for raw in state_text.splitlines():
        line = raw.strip()
        m = re.match(r"plane\[(\d+)\]:\s*(\S+)", line)
        if m:
            current = {"plane": int(m.group(1)), "name": m.group(2)}
            planes.append(current)
            continue
        if raw and not raw[0].isspace():
            current = None
            continue
        if current is None:
            continue
        for key, pattern in (("crtc", r"crtc=(\S+)"), ("fb", r"fb=(\d+)"), ("allocated_by", r"allocated by = (.+)"),
                             ("format", r"format=(\S+)"), ("modifier", r"modifier=(\S+)"), ("size", r"^size=(\S+)")):
            mm = re.match(pattern, line)
            if mm and key not in current:
                current[key] = int(mm.group(1)) if key == "fb" else mm.group(1)
    return [p for p in planes if p.get("fb") and p.get("crtc") not in (None, "(null)")]


class Helper:
    """Root side. One instance serves one tool run."""

    def __init__(self, root="/"):
        self.root = root
        self.uinput = None
        self.tracing = False

    def path(self, rel):
        return os.path.join(self.root, rel)

    def op_hello(self, _req):
        tracefs = self.path(TRACEFS)
        return {
            "uid": os.geteuid(),
            "rapl": [name for name, _ in rapl_zones(self.root)],
            "uinput": os.path.exists("/dev/uinput") if self.root == "/" else os.path.exists(self.path("dev/uinput")),
            "tracefs": all(os.path.exists(os.path.join(tracefs, f"events/drm/{event}/enable")) for event in VBLANK_EVENTS),
            "debugfs_dri": sorted(os.path.basename(os.path.dirname(p)) for p in glob.glob(self.path(DEBUGFS_DRI) + "/*/state")),
        }

    def op_rapl(self, _req):
        zones = {}
        for name, zone in rapl_zones(self.root):
            energy = int(Path(zone, "energy_uj").read_text())
            max_range = int(Path(zone, "max_energy_range_uj").read_text())
            zones[name] = [energy, max_range]
        if not zones:
            raise RuntimeError(rapl_missing_message(self.root))
        return {"t": now_ns(), "zones": zones}

    def op_drop_caches(self, _req):
        os.sync()
        Path(self.path(DROP_CACHES)).write_text("3\n")
        return {}

    def op_uinput_open(self, _req):
        if not self.uinput:
            self.uinput = Uinput(self.root)
        return {}

    def op_key(self, req):
        return {"t": self.uinput.key(req["code"], req["value"])}

    def op_uinput_close(self, _req):
        if self.uinput:
            self.uinput.close()
            self.uinput = None
        return {}

    def _trace(self, rel, value):
        Path(self.path(TRACEFS), rel).write_text(value)

    def _enable_vblank_events(self, value):
        for event in VBLANK_EVENTS:
            self._trace(f"events/drm/{event}/enable", value)

    def op_vblank_start(self, _req):
        self._enable_vblank_events("0")
        self._trace("buffer_size_kb", "8192")
        self._trace("trace", "")
        self._enable_vblank_events("1")
        self.tracing = True
        return {}

    def op_vblank_stop(self, _req):
        self._enable_vblank_events("0")
        self.tracing = False
        return {"flips": parse_flip_times(Path(self.path(TRACEFS), "trace").read_text())}

    def op_planes(self, _req):
        out = {}
        for state in sorted(glob.glob(self.path(DEBUGFS_DRI) + "/*/state")):
            out[os.path.basename(os.path.dirname(state))] = parse_planes(Path(state).read_text())
        return {"cards": out}

    def close(self):
        if self.uinput:
            self.uinput.close()
        if self.tracing:
            try:
                self._enable_vblank_events("0")
            except OSError:
                pass

    def serve(self, rfile, wfile):
        for line in rfile:
            req = json.loads(line)
            if req["op"] == "quit":
                break
            try:
                resp = {"ok": True, **getattr(self, "op_" + req["op"])(req)}
            except Exception as exc:  # report every failure to the client
                resp = {"ok": False, "error": f"{type(exc).__name__}: {exc}"}
            wfile.write(json.dumps(resp) + "\n")
            wfile.flush()
        self.close()


def helper_main(root):
    Helper(root).serve(sys.stdin, sys.stdout)


class HelperError(RuntimeError):
    pass


class Client:
    """User side. `command` starts the helper; by default through sudo."""

    def __init__(self, command):
        self.proc = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
        self.lock = threading.Lock()
        self.info = self.call("hello")

    def call(self, op, **args):
        with self.lock:
            self.proc.stdin.write(json.dumps({"op": op, **args}) + "\n")
            self.proc.stdin.flush()
            line = self.proc.stdout.readline()
        if not line:
            raise HelperError("root helper exited")
        resp = json.loads(line)
        if not resp.pop("ok"):
            raise HelperError(resp["error"])
        return resp

    def close(self):
        if self.proc.poll() is None:
            try:
                self.proc.stdin.write('{"op":"quit"}\n')
                self.proc.stdin.close()
            except OSError:
                pass
            self.proc.wait(timeout=10)


def start_helper(entry, sysfs_root, use_sudo=True):
    """Explain, authenticate, and start the root helper."""
    command = [sys.executable, str(entry), "_helper", "--sysfs-root", sysfs_root]
    if use_sudo and os.geteuid() != 0:
        print(EXPLANATION, file=sys.stderr, flush=True)
        if subprocess.run(["sudo", "-v"]).returncode != 0:
            raise SystemExit("sudo authentication failed; monstar-bench needs root for RAPL energy")
        command = ["sudo", "-n", "--"] + command
    return Client(command)


class UinputKeyboard:
    """input.play() backend that types through the helper's uinput device."""

    name = "uinput"
    privileged = True

    def __init__(self, client):
        self.client = client
        client.call("uinput_open")
        time.sleep(1.5)  # libinput and the compositor add the device

    def key(self, code, pressed, mods=None):
        return self.client.call("key", code=code, value=1 if pressed else 0)["t"]

    def close(self):
        self.client.call("uinput_close")
