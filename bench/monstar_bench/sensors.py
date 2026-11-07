"""Optional unprivileged sensors and machine description."""

import glob
import os
import platform
import re
import shutil
import subprocess
import threading
from pathlib import Path

from .metrics import read_number

DISCRETE_VRAM_BYTES = 2 << 30


def read_text(path, default=None):
    try:
        return Path(path).read_text().strip()
    except OSError:
        return default


def gpus(root="/"):
    """DRM cards with driver, PCI ids, VRAM and power sensors."""
    out = []
    for card in sorted(glob.glob(os.path.join(root, "sys/class/drm/card[0-9]*"))):
        if "-" in os.path.basename(card):
            continue
        dev = os.path.join(card, "device")
        driver = os.path.basename(os.path.realpath(os.path.join(dev, "driver"))) if os.path.exists(os.path.join(dev, "driver")) else None
        vram = read_number(os.path.join(dev, "mem_info_vram_total"))
        hwmons = glob.glob(os.path.join(dev, "hwmon", "hwmon*"))
        power_file = None
        for hw in hwmons:
            for name in ("power1_average", "power1_input"):
                if os.path.exists(os.path.join(hw, name)):
                    power_file = os.path.join(hw, name)
                    break
        gpu = {
            "card": os.path.basename(card),
            "driver": driver,
            "vendor": read_text(os.path.join(dev, "vendor")),
            "device": read_text(os.path.join(dev, "device")),
            "vram_mb": vram // (1 << 20) if vram else None,
            "boot_vga": read_text(os.path.join(dev, "boot_vga")) == "1",
            "power_sensor": power_file,
            "busy_file": os.path.join(dev, "gpu_busy_percent") if os.path.exists(os.path.join(dev, "gpu_busy_percent")) else None,
        }
        # amdgpu's sensor on an APU is the SoC package (PPT) and overlaps
        # RAPL; only count it as separate GPU power on a discrete card.
        gpu["discrete"] = bool(vram and vram >= DISCRETE_VRAM_BYTES) or driver in ("nvidia",)
        out.append(gpu)
    return out


class GpuSampler:
    """Samples discrete GPU power (hwmon or nvidia-smi) and busy % at 10 Hz
    on a thread while a measurement runs."""

    def __init__(self, gpu_list, interval=0.1):
        self.interval = interval
        self.hwmon = [g for g in gpu_list if g["discrete"] and g["power_sensor"]]
        self.busy = [g for g in gpu_list if g["busy_file"]]
        self.nvidia = shutil.which("nvidia-smi") if any(g["driver"] == "nvidia" for g in gpu_list) else None
        self.samples = {"dgpu_w": [], "busy_pct": []}
        self._stop = threading.Event()
        self._thread = None

    @property
    def has_dgpu_power(self):
        return bool(self.hwmon or self.nvidia)

    def _nvidia_power(self):
        try:
            out = subprocess.run([self.nvidia, "--query-gpu=power.draw", "--format=csv,noheader,nounits"],
                                 capture_output=True, text=True, timeout=2).stdout
            return sum(float(x) for x in out.split())
        except (OSError, ValueError, subprocess.TimeoutExpired):
            return None

    def _run(self):
        while not self._stop.wait(self.interval):
            watts = 0.0
            seen = False
            for g in self.hwmon:
                uw = read_number(g["power_sensor"])
                if uw is not None:
                    watts += uw / 1e6
                    seen = True
            if self.nvidia:
                nv = self._nvidia_power()
                if nv is not None:
                    watts += nv
                    seen = True
            if seen:
                self.samples["dgpu_w"].append(watts)
            busy = [read_number(g["busy_file"]) for g in self.busy]
            busy = [b for b in busy if b is not None]
            if busy:
                self.samples["busy_pct"].append(max(busy))

    def start(self):
        self.samples = {"dgpu_w": [], "busy_pct": []}
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()
        if self._thread:
            self._thread.join()
        avg = lambda xs: round(sum(xs) / len(xs), 3) if xs else None
        return {"dgpu_w": avg(self.samples["dgpu_w"]), "gpu_busy_pct": avg(self.samples["busy_pct"])}


def first_line(cmd):
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return None
    text = (out.stdout or out.stderr).strip()
    return text.splitlines()[0] if text else None


def mesa_version():
    for cmd, pattern in ((["vulkaninfo", "--summary"], r"Mesa ([0-9][\w.\-]*)"),
                         (["glxinfo", "-B"], r"Mesa ([0-9][\w.\-]*)"),
                         (["eglinfo", "-B"], r"Mesa ([0-9][\w.\-]*)")):
        if not shutil.which(cmd[0]):
            continue
        try:
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=20).stdout
        except (OSError, subprocess.TimeoutExpired):
            continue
        m = re.search(pattern, out)
        if m:
            return m.group(1)
    for cmd in (["pacman", "-Q", "mesa"], ["dpkg-query", "-W", "-f", "${Version}", "libgl1-mesa-dri"],
                ["rpm", "-q", "--qf", "%{VERSION}", "mesa-dri-drivers"]):
        if shutil.which(cmd[0]):
            line = first_line(cmd)
            if line and "not" not in line.lower():
                return line.split()[-1]
    return None


def cpu_info(root="/"):
    model = None
    for line in (read_text(os.path.join(root, "proc/cpuinfo"), "") or "").splitlines():
        if line.startswith("model name"):
            model = line.split(":", 1)[1].strip()
            break
    cpufreq = os.path.join(root, "sys/devices/system/cpu/cpu0/cpufreq")
    return {
        "model": model or platform.processor() or None,
        "threads": os.cpu_count(),
        "governor": read_text(os.path.join(cpufreq, "scaling_governor")),
        "driver": read_text(os.path.join(cpufreq, "scaling_driver")),
        "epp": read_text(os.path.join(cpufreq, "energy_performance_preference")),
        "platform_profile": read_text(os.path.join(root, "sys/firmware/acpi/platform_profile")),
    }


def machine_info(label, root="/"):
    os_release = read_text(os.path.join(root, "etc/os-release"), "") or ""
    distro = dict(line.split("=", 1) for line in os_release.splitlines() if "=" in line).get("PRETTY_NAME", "").strip('"')
    mem = read_text(os.path.join(root, "proc/meminfo"), "") or ""
    m = re.search(r"MemTotal:\s+(\d+)", mem)
    on_ac = None
    for supply in glob.glob(os.path.join(root, "sys/class/power_supply/*")):
        if read_text(os.path.join(supply, "type")) == "Mains":
            on_ac = read_text(os.path.join(supply, "online")) == "1"
    return {
        "label": label,
        "hostname": platform.node(),
        "arch": platform.machine(),
        "cpu": cpu_info(root),
        "gpus": [{k: v for k, v in g.items() if k not in ("power_sensor", "busy_file")} for g in gpus(root)],
        "kernel": platform.release(),
        "distro": distro or None,
        "mesa": mesa_version(),
        "memory_mb": int(m.group(1)) // 1024 if m else None,
        "on_ac_power": on_ac,
        "loadavg": read_text(os.path.join(root, "proc/loadavg")),
    }
