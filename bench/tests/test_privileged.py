import os
import socket
import stat
import struct
import sys
import tempfile
import textwrap
import threading
import unittest
from pathlib import Path

BENCH = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(BENCH))

from monstar_bench import metrics, privileged, runner, sensors, session, wayland  # noqa: E402

STATE = textwrap.dedent("""\
    plane[31]: plane-0
    \tcrtc=crtc-0
    \tfb=120
    \t\tallocated by = sway
    \t\trefcount=2
    \t\tformat=XR24 little-endian (0x34325258)
    \t\tmodifier=0x200000020801b04
    \t\tsize=1920x1200
    \t\tlayers:
    \t\t\tsize[0]=1920x1200
    \tcrtc-pos=1920x1200+0+0
    plane[40]: plane-1
    \tcrtc=(null)
    \tfb=0
    plane[49]: plane-2
    \tcrtc=crtc-0
    \tfb=130
    \t\tallocated by = sway
    \t\tformat=AR24 little-endian (0x34325241)
    \t\tmodifier=0x0
    \t\tsize=64x64
    crtc[80]: crtc-0
    \tenable=1
""")


def fake_sysfs(root, energy=1000, max_range=2**32):
    zone = Path(root, privileged.POWERCAP, "intel-rapl:0")
    zone.mkdir(parents=True)
    (zone / "name").write_text("package-0\n")
    (zone / "energy_uj").write_text(f"{energy}\n")
    (zone / "max_energy_range_uj").write_text(f"{max_range}\n")
    sub = Path(root, privileged.POWERCAP, "intel-rapl:0:0")
    sub.mkdir()
    (sub / "name").write_text("core\n")
    (sub / "energy_uj").write_text("5\n")
    psys = Path(root, privileged.POWERCAP, "intel-rapl:1")
    psys.mkdir()
    (psys / "name").write_text("psys\n")
    (psys / "energy_uj").write_text("5\n")
    Path(root, "proc/sys/vm").mkdir(parents=True)
    Path(root, privileged.DROP_CACHES).write_text("0\n")
    trace = Path(root, privileged.TRACEFS)
    (trace / "events/drm/drm_vblank_event").mkdir(parents=True)
    (trace / "events/drm/drm_vblank_event/enable").write_text("0")
    (trace / "trace").write_text(
        "  <idle>-0 [003] d.h1. 100.0: drm_vblank_event: crtc=0, seq=10, time=5000000, high-prec=true\n"
        "  <idle>-0 [003] d.h1. 100.1: drm_vblank_event: crtc=0, seq=11, time=4000000, high-prec=true\n")
    dri = Path(root, privileged.DEBUGFS_DRI, "1")
    dri.mkdir(parents=True)
    (dri / "state").write_text(STATE)
    return zone


class RaplTest(unittest.TestCase):
    def test_only_package_zones(self):
        with tempfile.TemporaryDirectory() as root:
            fake_sysfs(root)
            self.assertEqual([n for n, _ in privileged.rapl_zones(root)], ["package-0"])

    def test_missing_rapl_message(self):
        with tempfile.TemporaryDirectory() as root:
            self.assertEqual(privileged.rapl_zones(root), [])
            self.assertIn("virtual machines", privileged.rapl_missing_message(root))

    def test_wraparound(self):
        start = {"t": 0, "zones": {"package-0": [2**32 - 1_000_000, 2**32]}}
        end = {"t": 2_000_000_000, "zones": {"package-0": [9_000_000, 2**32]}}
        self.assertEqual(metrics.rapl_power(start, end), {"package_w": 5.0, "package_j": 10.0, "seconds": 2.0})


class HelperTest(unittest.TestCase):
    def test_helper_over_pipe(self):
        with tempfile.TemporaryDirectory() as root:
            zone = fake_sysfs(root, energy=1000)
            client = privileged.Client([sys.executable, str(BENCH / "monstar-bench"), "_helper", "--sysfs-root", root])
            try:
                self.assertEqual(client.info["rapl"], ["package-0"])
                self.assertTrue(client.info["tracefs"])
                self.assertEqual(client.info["debugfs_dri"], ["1"])
                self.assertEqual(client.call("rapl")["zones"], {"package-0": [1000, 2**32]})
                (zone / "energy_uj").write_text("2500\n")
                self.assertEqual(client.call("rapl")["zones"]["package-0"][0], 2500)
                client.call("drop_caches")
                self.assertEqual(Path(root, privileged.DROP_CACHES).read_text(), "3\n")
                client.call("vblank_start")
                enable = Path(root, privileged.TRACEFS, "events/drm/drm_vblank_event/enable")
                self.assertEqual(enable.read_text(), "1")
                Path(root, privileged.TRACEFS, "trace").write_text(
                    "x-1 [000] d.h1. 1.0: drm_vblank_event: crtc=0, seq=1, time=7000, high-prec=true\n")
                self.assertEqual(client.call("vblank_stop")["flips"], [7000])
                self.assertEqual(enable.read_text(), "0")
                planes = client.call("planes")["cards"]["1"]
                self.assertEqual([p["fb"] for p in planes], [120, 130])
                with self.assertRaises(privileged.HelperError):
                    client.call("key", code=30, value=1)  # no uinput opened
            finally:
                client.close()
            self.assertEqual(client.proc.returncode, 0)

    def test_parse_planes(self):
        planes = privileged.parse_planes(STATE)
        self.assertEqual(planes[0], {"plane": 31, "name": "plane-0", "crtc": "crtc-0", "fb": 120,
                                     "allocated_by": "sway", "format": "XR24", "modifier": "0x200000020801b04",
                                     "size": "1920x1200"})
        self.assertEqual(planes[1]["size"], "64x64")

    def test_vblank_times_sorted(self):
        self.assertEqual(privileged.parse_vblank_times(Path(__file__).read_text()[:0]), [])
        text = "a: drm_vblank_event: crtc=0, seq=2, time=20\nb: drm_vblank_event: crtc=0, seq=1, time=10\n"
        self.assertEqual(privileged.parse_vblank_times(text), [10, 20])


class SensorsTest(unittest.TestCase):
    def test_gpu_discrete_detection(self):
        with tempfile.TemporaryDirectory() as root:
            for card, vram, driver in (("card0", 512 << 20, "amdgpu"), ("card1", 8 << 30, "amdgpu")):
                dev = Path(root, "sys/class/drm", card, "device")
                (dev / "hwmon/hwmon3").mkdir(parents=True)
                (dev / "mem_info_vram_total").write_text(str(vram))
                (dev / "hwmon/hwmon3/power1_average").write_text("25000000\n")
                drv = Path(root, "drivers", driver)
                drv.mkdir(parents=True, exist_ok=True)
                os.symlink(drv, dev / "driver")
            Path(root, "sys/class/drm/card1-DP-1").mkdir()
            gpus = sensors.gpus(root)
            self.assertEqual([(g["card"], g["discrete"]) for g in gpus], [("card0", False), ("card1", True)])
            sampler = sensors.GpuSampler(gpus, interval=0.01)
            sampler.start()
            threading.Event().wait(0.1)
            self.assertEqual(sampler.stop()["dgpu_w"], 25.0)


def write_script(path, body):
    path.write_text("#!/bin/sh\n" + body)
    path.chmod(path.stat().st_mode | stat.S_IEXEC)


class OverrideProbeTest(unittest.TestCase):
    def test_accepted_override(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake = Path(tmp, "monstar")
            write_script(fake, 'case "$2" in renderer=*) echo "monstar: invalid command line" >&2; exit 2;; '
                               'esac\necho "error: ConnectFailed" >&2; exit 1\n')
            self.assertFalse(runner.accepted_override(str(fake), "renderer=vulkan"))
            self.assertTrue(runner.accepted_override(str(fake), "presentation=shm"))

    def test_skip_reason_tells_fallback_from_rejection(self):
        shm = {"renderer": "cpu", "presentation": "shm"}
        udmabuf = runner.CONFIGS["udmabuf"]
        reason = runner.skip_reason(udmabuf, ["presentation=dmabuf"], shm,
                                    ["warning(udmabuf): /dev/udmabuf unavailable (NOENT); presenting with wl_shm",
                                     "warning(app): session dbus unavailable"])
        self.assertIn("presentation=dmabuf was accepted but Monstar fell back to cpu/shm", reason)
        self.assertIn("/dev/udmabuf unavailable", reason)
        self.assertNotIn("dbus", reason)
        self.assertNotIn("rejects", reason)
        reason = runner.skip_reason(runner.CONFIGS["vulkan"], [], shm, ["warning(app): session dbus unavailable"])
        self.assertEqual(reason, "this build rejects renderer=vulkan and presents through cpu/shm")
        self.assertIn("did not present", runner.skip_reason(udmabuf, [], None, []))


class FakeCompositor:
    """A listening Wayland socket so Session can read the peer PID."""

    def __init__(self, runtime):
        self.path = os.path.join(runtime, "wayland-9")
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind(self.path)
        self.sock.listen(4)

    def close(self):
        self.sock.close()


class HyprlandTest(unittest.TestCase):
    def test_dispatch_falls_back_and_reads_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            comp = FakeCompositor(tmp)
            log = Path(tmp, "calls")
            state = Path(tmp, "fullscreen")
            state.write_text("false")
            write_script(Path(tmp, "hyprctl"), f"""echo "$@" >> {log}
case "$1 $2" in
  "dispatch hl.dsp"*) echo "Invalid dispatcher";;
  "dispatch fullscreen") echo true > {state}; echo ok;;
  "dispatch "*) echo ok;;
  "clients -j") echo '[{{"class":"monstar-bench","pid":7,"at":[0,0],"size":[1920,1200],"fullscreen":'$(cat {state})',"focusHistoryID":0}}]';;
  "monitors -j") echo '[{{"name":"eDP-1","focused":true,"width":1920,"height":1200,"refreshRate":60.0,"scale":1.0,"directScanoutTo":"monstar-bench"}}]';;
esac
""")
            env = dict(os.environ, PATH=f"{tmp}:{os.environ['PATH']}", XDG_RUNTIME_DIR=tmp, WAYLAND_DISPLAY="wayland-9",
                       HYPRLAND_INSTANCE_SIGNATURE="x")
            try:
                hypr = session.Hyprland(env)
                self.assertEqual(hypr.pid, os.getpid())
                self.assertFalse(hypr.window("monstar-bench")["fullscreen"])
                hypr.set_fullscreen("monstar-bench", True)
                self.assertTrue(hypr.window("monstar-bench")["fullscreen"])
                self.assertTrue(hypr.scanout())
                self.assertEqual(hypr.display()["refresh_hz"], 60.0)
                calls = log.read_text().splitlines()
                self.assertIn("dispatch focuswindow class:monstar-bench", calls)
                self.assertIn("dispatch fullscreen 0", calls)
                hypr.set_fullscreen("monstar-bench", True)  # already fullscreen: no toggle back
                self.assertEqual(sum(c == "dispatch fullscreen 0" for c in log.read_text().splitlines()), 1)
            finally:
                comp.close()


class VirtualKeyboardWireTest(unittest.TestCase):
    """Check the wire messages against a scripted fake compositor."""

    def test_keymap_and_keys(self):
        with tempfile.TemporaryDirectory() as tmp:
            comp = FakeCompositor(tmp)
            received = []

            def serve():
                conn, _ = comp.sock.accept()
                buf, fds = b"", []
                while True:
                    data, anc, _f, _a = conn.recvmsg(4096, socket.CMSG_SPACE(16))
                    if not data:
                        break
                    for level, kind, payload in anc:
                        if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                            fds.extend(struct.unpack(f"{len(payload) // 4}i", payload))
                    buf += data
                    while len(buf) >= 8:
                        obj, word = struct.unpack_from("=II", buf)
                        size = word >> 16
                        if len(buf) < size:
                            break
                        msg, buf = (obj, word & 0xFFFF, buf[8:size]), buf[size:]
                        received.append(msg)
                        if msg[0] == 1 and msg[1] == 1:  # get_registry -> two globals
                            reg = struct.unpack("=I", msg[2])[0]
                            for name, iface in ((1, b"wl_seat"), (2, b"zwp_virtual_keyboard_manager_v1")):
                                s = iface + b"\0"
                                s += b"\0" * ((4 - len(s) % 4) % 4)
                                body = struct.pack("=II", name, len(iface) + 1) + s + struct.pack("=I", 1)
                                conn.sendall(struct.pack("=II", reg, (8 + len(body)) << 16) + body)
                        elif msg[0] == 1 and msg[1] == 0:  # sync -> done
                            cb = struct.unpack("=I", msg[2])[0]
                            conn.sendall(struct.pack("=III", cb, 12 << 16, 0))
                received.append(("fds", fds))
                conn.close()

            thread = threading.Thread(target=serve, daemon=True)
            thread.start()
            env = {"XDG_RUNTIME_DIR": tmp, "WAYLAND_DISPLAY": "wayland-9"}
            kbd = wayland.VirtualKeyboard(env)
            t = kbd.key(30, True, mods=1)
            kbd.key(30, False, mods=1)
            kbd.close()
            thread.join(5)
            comp.close()
            fds = received[-1][1]
            msgs = received[:-1]
            vk_id = struct.unpack("=II", next(m for m in msgs if m[0] not in (1, 2) and m[1] == 0 and len(m[2]) == 8)[2])[1]
            keymap = next(m for m in msgs if m[0] == vk_id and m[1] == 0)
            fmt, size = struct.unpack("=II", keymap[2])
            self.assertEqual(fmt, 1)
            self.assertEqual(len(fds), 1)
            self.assertEqual(os.pread(fds[0], size, 0), wayland.US_KEYMAP.encode() + b"\0")
            mods = [struct.unpack("=IIII", m[2]) for m in msgs if m[0] == vk_id and m[1] == 2]
            self.assertEqual(mods, [(1, 0, 0, 0)])
            key_msgs = [struct.unpack("=III", m[2]) for m in msgs if m[0] == vk_id and m[1] == 1]
            self.assertEqual([(k, s) for _t, k, s in key_msgs], [(30, 1), (30, 0)])
            self.assertEqual(key_msgs[0][0], (t // 1_000_000) & 0xFFFFFFFF)
            self.assertTrue(any(m[0] == vk_id and m[1] == 3 for m in msgs))


if __name__ == "__main__":
    unittest.main()
