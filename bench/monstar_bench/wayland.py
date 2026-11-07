"""A minimal Wayland client: enough wire protocol for a virtual keyboard.

zwp_virtual_keyboard_v1 lets an unprivileged client inject keys through the
compositor's seat (Sway and Hyprland both expose it). The keymap is a plain
US layout compiled by the compositor and the client from system XKB data,
so evdev key codes mean the same thing as with uinput."""

import array
import os
import socket
import struct
import time

US_KEYMAP = (
    "xkb_keymap {\n"
    '  xkb_keycodes { include "evdev+aliases(qwerty)" };\n'
    '  xkb_types { include "complete" };\n'
    '  xkb_compat { include "complete" };\n'
    '  xkb_symbols { include "pc+us+inet(evdev)" };\n'
    "};\n"
)

MOD_SHIFT = 1
MOD_CTRL = 4


def socket_path(env):
    display = env.get("WAYLAND_DISPLAY", "wayland-0")
    if display.startswith("/"):
        return display
    return os.path.join(env["XDG_RUNTIME_DIR"], display)


def compositor_pid(env):
    """PID of the compositor serving the Wayland socket (SO_PEERCRED)."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.connect(socket_path(env))
        creds = sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
    pid, _uid, _gid = struct.unpack("3i", creds)
    return pid


def pack_string(text):
    data = text.encode() + b"\0"
    pad = (4 - len(data) % 4) % 4
    return struct.pack("=I", len(data)) + data + b"\0" * pad


class WaylandError(RuntimeError):
    pass


class Connection:
    def __init__(self, env):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(socket_path(env))
        self.next_id = 2
        self.globals = {}
        self.buf = b""

    def new_id(self):
        oid = self.next_id
        self.next_id += 1
        return oid

    def send(self, obj, opcode, payload=b"", fds=()):
        header = struct.pack("=II", obj, ((8 + len(payload)) << 16) | opcode)
        ancdata = []
        if fds:
            ancdata = [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", fds).tobytes())]
        self.sock.sendmsg([header + payload], ancdata)

    def read_events(self):
        data = self.sock.recv(65536)
        if not data:
            raise WaylandError("compositor closed the connection")
        self.buf += data
        events = []
        while len(self.buf) >= 8:
            obj, word = struct.unpack_from("=II", self.buf)
            size = word >> 16
            if len(self.buf) < size:
                break
            events.append((obj, word & 0xFFFF, self.buf[8:size]))
            self.buf = self.buf[size:]
        return events

    def roundtrip(self, on_event=None):
        callback = self.new_id()
        self.send(1, 0, struct.pack("=I", callback))  # wl_display.sync
        while True:
            for obj, opcode, payload in self.read_events():
                if obj == 1 and opcode == 0:  # wl_display.error
                    _oid, code = struct.unpack_from("=II", payload)
                    (length,) = struct.unpack_from("=I", payload, 8)
                    raise WaylandError(f"protocol error {code}: {payload[12:12 + length - 1].decode()}")
                if obj == callback:
                    return
                if on_event:
                    on_event(obj, opcode, payload)

    def load_globals(self):
        registry = self.new_id()
        self.send(1, 1, struct.pack("=I", registry))  # wl_display.get_registry

        def on_event(obj, opcode, payload):
            if obj == registry and opcode == 0:
                (name,) = struct.unpack_from("=I", payload)
                (length,) = struct.unpack_from("=I", payload, 4)
                interface = payload[8:8 + length - 1].decode()
                offset = 8 + length + (4 - length % 4) % 4
                (version,) = struct.unpack_from("=I", payload, offset)
                self.globals.setdefault(interface, (name, version))

        self.roundtrip(on_event)
        self.registry = registry

    def bind(self, interface, version):
        name, available = self.globals[interface]
        oid = self.new_id()
        payload = struct.pack("=I", name) + pack_string(interface) + struct.pack("=II", min(version, available), oid)
        self.send(self.registry, 0, payload)
        return oid

    def close(self):
        self.sock.close()


class VirtualKeyboard:
    """Inject evdev key codes through zwp_virtual_keyboard_v1."""

    name = "virtual-keyboard"
    privileged = False

    def __init__(self, env):
        self.conn = Connection(env)
        self.conn.load_globals()
        if "zwp_virtual_keyboard_manager_v1" not in self.conn.globals:
            self.conn.close()
            raise WaylandError("compositor does not expose zwp_virtual_keyboard_manager_v1")
        seat = self.conn.bind("wl_seat", 1)
        manager = self.conn.bind("zwp_virtual_keyboard_manager_v1", 1)
        self.kbd = self.conn.new_id()
        self.conn.send(manager, 0, struct.pack("=II", seat, self.kbd))
        keymap = US_KEYMAP.encode() + b"\0"
        fd = os.memfd_create("monstar-bench-keymap", os.MFD_CLOEXEC)
        try:
            os.write(fd, keymap)
            self.conn.send(self.kbd, 0, struct.pack("=II", 1, len(keymap)), fds=(fd,))
        finally:
            os.close(fd)
        self.mods = 0
        self.conn.roundtrip()

    def key(self, code, pressed, mods=None):
        """Send one key event; returns its CLOCK_MONOTONIC send time (ns)."""
        if mods is not None and mods != self.mods:
            self.mods = mods
            self.conn.send(self.kbd, 2, struct.pack("=IIII", mods, 0, 0, 0))
        now = time.clock_gettime_ns(time.CLOCK_MONOTONIC)
        self.conn.send(self.kbd, 1, struct.pack("=III", (now // 1_000_000) & 0xFFFFFFFF, code, 1 if pressed else 0))
        return now

    def close(self):
        try:
            self.conn.send(self.kbd, 3)  # destroy
            self.conn.roundtrip()
        except (OSError, WaylandError):
            pass
        self.conn.close()
