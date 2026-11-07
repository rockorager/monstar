"""Compositor sessions: the user's own Sway or Hyprland, or a Sway that the
tool starts nested (in a window) or headless."""

import glob
import json
import os
import shutil
import signal
import subprocess
import tempfile
import time

from . import wayland

BENCH_WORKSPACE = "monstar-bench"
# Gaps keep a lone tiled window from covering the output, so "tiled" is
# always composited; wlroots would scan out a borderless window that does.
TILED_GAPS = 32


class SessionError(RuntimeError):
    pass


def run(cmd, env, check=True):
    proc = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=15)
    if check and proc.returncode != 0:
        raise SessionError(f"{' '.join(cmd)} failed: {proc.stderr.strip() or proc.stdout.strip()}")
    return proc.stdout


class Session:
    compositor = None  # "sway" | "hyprland"
    mode = None  # "own" | "nested" | "headless"
    uses_libinput = False

    def __init__(self, env):
        self.env = env
        self.pid = wayland.compositor_pid(env)

    def describe(self):
        return {"compositor": self.compositor, "version": self.version(), "mode": self.mode,
                "display": self.display(), "pid": self.pid}

    def prepare(self):
        pass

    def restore(self):
        pass

    def close(self):
        self.restore()


class Sway(Session):
    compositor = "sway"

    def msg(self, *args, check=True):
        return run(["swaymsg", *args], self.env, check)

    def query(self, kind):
        return json.loads(self.msg("-t", kind, "-r"))

    def version(self):
        info = self.query("get_version")
        return info.get("human_readable") or info.get("version")

    def display(self):
        outputs = [o for o in self.query("get_outputs") if o.get("active")]
        focused = next((o for o in outputs if o.get("focused")), outputs[0] if outputs else None)
        if not focused:
            return None
        mode = focused.get("current_mode") or {}
        return {"output": focused.get("name"), "width": mode.get("width"), "height": mode.get("height"),
                "refresh_hz": round(mode.get("refresh", 0) / 1000, 3) or None, "scale": focused.get("scale"),
                "make": focused.get("make"), "model": focused.get("model"),
                "renderer": os.environ.get("WLR_RENDERER")}

    def prepare(self):
        tree = self.query("get_workspaces")
        self.previous_workspace = next((w["name"] for w in tree if w.get("focused")), None)
        self.msg(f"workspace {BENCH_WORKSPACE}")
        self.msg(f"gaps outer current set {TILED_GAPS}")

    def restore(self):
        if getattr(self, "previous_workspace", None):
            self.msg(f"workspace {self.previous_workspace}", check=False)
            self.previous_workspace = None

    def _find(self, node, app_id):
        if node.get("app_id") == app_id:
            return node
        for child in node.get("nodes", []) + node.get("floating_nodes", []):
            found = self._find(child, app_id)
            if found:
                return found
        return None

    def window(self, app_id):
        node = self._find(self.query("get_tree"), app_id)
        if not node:
            return None
        return {"pid": node.get("pid"), "fullscreen": node.get("fullscreen_mode", 0) != 0, "rect": node.get("rect"),
                "focused": node.get("focused")}

    def set_fullscreen(self, app_id, enable):
        self.msg(f'[app_id="{app_id}"] fullscreen {"enable" if enable else "disable"}')

    def scanout(self):
        return None  # Sway exposes no direct-scanout state over IPC


class OwnSway(Sway):
    mode = "own"
    uses_libinput = True


class SpawnedSway(Sway):
    """A Sway the tool starts: headless (WLR_BACKENDS=headless) or nested
    inside the current Wayland session (WLR_BACKENDS=wayland)."""

    def __init__(self, mode, size="1920x1200", refresh=60, outer_env=None):
        self.mode = mode
        outer_env = dict(outer_env or os.environ)
        self.runtime = tempfile.mkdtemp(prefix="monstar-bench-sway-")
        os.chmod(self.runtime, 0o700)
        config = os.path.join(self.runtime, "sway.conf")
        output = "HEADLESS-1" if mode == "headless" else "WL-1"
        with open(config, "w") as f:
            f.write(
                f"output {output} mode {size}@{refresh}Hz scale 1\n"
                "output * bg #202020 solid_color\n"
                "default_border none\n"
                "default_floating_border none\n"
                f"gaps outer {TILED_GAPS}\n"
                "focus_follows_mouse no\n"
                "seat * hide_cursor 1000\n"
                "xwayland disable\n"
            )
        env = dict(outer_env)
        env["XDG_RUNTIME_DIR"] = self.runtime
        if mode == "headless":
            env.update(WLR_BACKENDS="headless", WLR_LIBINPUT_NO_DEVICES="1")
            env.pop("WAYLAND_DISPLAY", None)
        else:
            if "WAYLAND_DISPLAY" not in outer_env:
                raise SessionError("a nested session needs a running Wayland session")
            env["WLR_BACKENDS"] = "wayland"
            env["WAYLAND_DISPLAY"] = wayland.socket_path(outer_env)
        env.pop("SWAYSOCK", None)
        self.log = open(os.path.join(self.runtime, "sway.log"), "w")
        self.proc = subprocess.Popen(["sway", "-c", config, "--unsupported-gpu"], env=env,
                                     stdout=self.log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                     start_new_session=True)
        deadline = time.monotonic() + 15
        socket_path = sock = None
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                raise SessionError(f"sway exited; see {self.log.name}")
            sockets = [p for p in glob.glob(os.path.join(self.runtime, "wayland-*")) if not p.endswith(".lock")]
            ipc = glob.glob(os.path.join(self.runtime, f"sway-ipc.*.{self.proc.pid}.sock"))
            if sockets and ipc:
                socket_path, sock = sockets[0], ipc[0]
                break
            time.sleep(0.05)
        if not sock:
            self.close()
            raise SessionError(f"sway did not start; see {self.log.name}")
        session_env = dict(outer_env, XDG_RUNTIME_DIR=self.runtime, WAYLAND_DISPLAY=os.path.basename(socket_path),
                           SWAYSOCK=sock)
        session_env.pop("HYPRLAND_INSTANCE_SIGNATURE", None)
        super().__init__(session_env)

    def prepare(self):
        pass

    def restore(self):
        pass

    def close(self):
        if self.proc.poll() is None:
            os.killpg(self.proc.pid, signal.SIGTERM)
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(self.proc.pid, signal.SIGKILL)
        self.log.close()
        shutil.rmtree(self.runtime, ignore_errors=True)


class Hyprland(Session):
    compositor = "hyprland"
    mode = "own"
    uses_libinput = True

    def ctl(self, *args, check=True):
        return run(["hyprctl", *args], self.env, check)

    def query(self, kind):
        return json.loads(self.ctl(kind, "-j"))

    def version(self):
        info = self.query("version")
        return info.get("tag") or info.get("version")

    def display(self):
        monitors = self.query("monitors")
        focused = next((m for m in monitors if m.get("focused")), monitors[0] if monitors else None)
        if not focused:
            return None
        return {"output": focused.get("name"), "width": focused.get("width"), "height": focused.get("height"),
                "refresh_hz": round(focused.get("refreshRate", 0), 3) or None, "scale": focused.get("scale"),
                "make": focused.get("make"), "model": focused.get("model")}

    def dispatch(self, lua, classic):
        """Hyprland 0.55+ with a Lua config takes only Lua dispatchers
        (`hyprctl dispatch 'hl.dsp...'`, printing "ok"); older releases take
        only the classic ones. Try Lua first."""
        out = self.ctl("dispatch", lua, check=False).strip()
        if out == "ok":
            return
        classic_out = self.ctl("dispatch", *classic, check=False).strip()
        if classic_out != "ok":
            raise SessionError(f"hyprctl dispatch {lua} failed: {out}")

    @staticmethod
    def workspace_selector(name):
        # Numbered workspaces are selected by id; "name:3" does not find them.
        return name if name.lstrip("-").isdigit() else f"name:{name}"

    def focus_workspace(self, name):
        selector = self.workspace_selector(name)
        self.dispatch(f'hl.dsp.focus({{ workspace = "{selector}" }})', ["workspace", selector])

    def prepare(self):
        self.previous_workspace = self.query("activeworkspace").get("name")
        self.focus_workspace(BENCH_WORKSPACE)

    def restore(self):
        previous = getattr(self, "previous_workspace", None)
        if previous:
            try:
                self.focus_workspace(previous)
            except SessionError:
                pass
            self.previous_workspace = None

    def describe(self):
        # direct_scanout (default 0) decides whether fullscreen dma-buf
        # clients are offered to KMS at all, which changes their frame rate.
        out = super().describe()
        try:
            option = json.loads(self.ctl("getoption", "render:direct_scanout", "-j"))
            out["options"] = {"render:direct_scanout": option.get("int")}
        except (SessionError, ValueError):
            pass
        return out

    def window(self, app_id):
        for client in self.query("clients"):
            if client.get("class") == app_id:
                x, y = client.get("at", [0, 0])
                w, h = client.get("size", [0, 0])
                return {"pid": client.get("pid"), "fullscreen": bool(client.get("fullscreen")),
                        "rect": {"x": x, "y": y, "width": w, "height": h},
                        "focused": client.get("focusHistoryID") == 0}
        return None

    def set_fullscreen(self, app_id, enable):
        win = self.window(app_id)
        if win and win["fullscreen"] == enable:
            return
        self.dispatch(f'hl.dsp.focus({{ window = "class:{app_id}" }})', ["focuswindow", f"class:{app_id}"])
        self.dispatch("hl.dsp.window.fullscreen()", ["fullscreen", "0"])

    def scanout(self):
        monitors = self.query("monitors")
        focused = next((m for m in monitors if m.get("focused")), None)
        if not focused or "directScanoutTo" not in focused:
            return None
        target = focused.get("directScanoutTo")
        return target not in (None, "", "0", 0, "none")


def detect(kind, size, refresh):
    """Pick the session. `kind` is auto | own | nested | headless."""
    env = dict(os.environ)
    in_wayland = "WAYLAND_DISPLAY" in env and "XDG_RUNTIME_DIR" in env
    if kind in ("auto", "own") and in_wayland:
        if env.get("HYPRLAND_INSTANCE_SIGNATURE"):
            if not shutil.which("hyprctl"):
                raise SessionError("Hyprland session found but hyprctl is missing")
            return Hyprland(env)
        if env.get("SWAYSOCK"):
            return OwnSway(env)
        if kind == "own":
            raise SessionError("the current Wayland session is neither Sway nor Hyprland")
    if kind == "own":
        raise SessionError("no Wayland session found (WAYLAND_DISPLAY is unset)")
    if not shutil.which("sway"):
        raise SessionError("starting a nested or headless session needs sway")
    if kind == "nested" or (kind == "auto" and in_wayland):
        return SpawnedSway("nested", size, refresh)
    return SpawnedSway("headless", size, refresh)
