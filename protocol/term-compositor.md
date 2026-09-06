# Terminal Compositing via Wayland (TC-Wayland) Specification

**Version:** 1.0.0-draft
**Status:** Working Draft
**Target Audience:** Terminal Emulator Developers, CLI Tool Authors, TUI Framework Maintainers
**Companion XML Protocol:** [`protocol/term-compositor-v1.xml`](file:///home/erock/dev/term/monstar/protocol/term-compositor-v1.xml)

---

## 1. Abstract & Vision

The terminal emulator has historically functioned as a software simulation of a 1970s hardware serial video terminal (DEC VT100/xterm). Drawing user interfaces over an in-band serial character stream (`/dev/tty`) forces modern TUIs and overlays into destructive compromises:
1. **Screen Corruption**: Overwriting character cells destroys underlying scrollback and cell history.
2. **The Alternate Screen Trap**: Full-screen TUIs hijack the viewport (`\x1b[?1049h`), disabling native trackpad scrolling, search, and multiplexer splits.
3. **Serial Desynchronization**: High-speed escape sequences desynchronize and glitch under heavy output.
4. **ANSI Serialization Waste**: TUI frameworks maintain an internal 2D grid of styled cells, run expensive diff algorithms, serialize that grid into thousands of ANSI escape bytes, write them to a PTY, and the terminal's VT parser reconstructs that exact same 2D grid.

The **Terminal Compositing via Wayland (TC-Wayland)** architecture pivots the terminal emulator from a serial teletype emulator to a **text-first Wayland display server**.

Rather than inventing a new bespoke IPC protocol, framing system, and code generator, TC-Wayland directly leverages:
- The standard **Wayland wire protocol** (binary, zero-allocation, 32-bit aligned).
- The standard **Wayland object lifecycle and event loop** (`wl_display`, `wl_registry`).
- Standard Wayland surface and overlay primitives (`wl_surface`, `wl_subsurface`, `zwlr_layer_shell_v1`).
- Existing language scanners (`wayland-scanner`, `zig-wayland`, `wayland-rs`, `pywayland`).

Terminal-specific capabilities (character cell grids, text streams, cursor-anchored positioners, remote SSH buffer streams, structured keyboard input, and theme negotiation) are defined in the extension protocol **`term-compositor-v1.xml`**.

---

## 2. Architecture & Protocol Layering

```
┌────────────────────────────────────────────────────────────────────────┐
│  APPLICATIONS & TOOLS                                                  │
│  • Modern Tools (fzf, monstar-ui, lazygit) ──> TC-Wayland ($TC_WAYLAND)│
│  • Legacy CLI/TUIs (bash, vim, htop)       ──> PTY Bridge ("XPTY")     │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ Wayland Wire Protocol (IPC)
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│  MONSTAR TERMINAL DISPLAY SERVER                                       │
│                                                                        │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │ CORE WAYLAND PROTOCOLS (Off-the-shelf)                           │  │
│  │ • wl_display / wl_registry : Connection, Globals, Versioning     │  │
│  │ • wl_compositor / wl_surface: Canvas primitives, atomic commits   │  │
│  │ • wl_subcompositor         : Child surface attachment & z-order  │  │
│  │ • zwlr_layer_shell_v1      : Background, Top, Overlay tiers      │  │
│  │ • wl_data_device_manager   : MIME clipboard & selection          │  │
│  │ • wl_seat / wl_pointer     : Pointer & smooth scroll routing     │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                   │                                    │
│  ┌────────────────────────────────┴─────────────────────────────────┐  │
│  │ TERMINAL COMPOSITOR EXTENSION (term-compositor-v1.xml)           │  │
│  │ • zterm_compositor_v1      : Surface role & positioner factory   │  │
│  │ • zterm_buffer_factory_v1  : Cell buffers (SSH-safe & SHM)       │  │
│  │ • zterm_grid_surface_v1    : 2D cell grid (panes, popups, TUIs)  │  │
│  │ • zterm_stream_surface_v1  : Structured append-only text logs    │  │
│  │ • zterm_cursor_anchor_v1   : Pins overlays to text cursor        │  │
│  │ • zterm_keyboard_v1        : Resolved terminal keys & modifiers  │  │
│  │ • zterm_theme_manager_v1   : Live color palettes & RGBA tokens   │  │
│  │ • zterm_property_manager_v1: Getters, setters, desktop notifies  │  │
│  │ • zterm_xpty_v1            : Sandboxed legacy PTY container      │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                   │                                    │
│                                   ▼                                    │
│                     2D Compositing & Blending Pass                     │
│               • Font Rasterization (FreeType / HarfBuzz)               │
│               • Z-Ordering, Shadows, Backdrop Dimming                  │
│               • TrueColor RGBA Blending                                │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│  HOST DISPLAY OUTPUT (Wayland / DRM / Metal / DirectX)                 │
└────────────────────────────────────────────────────────────────────────┘
```

### 2.1 Separation of Concerns: Reuse vs. Extension

| Capability | Provided By | Rationale |
| :--- | :--- | :--- |
| **Connection & Handshake** | `wl_display`, `wl_registry` | Battle-tested object tracking and interface version negotiation. |
| **Rendering Canvas** | `wl_surface` | Universal abstraction for buffer attachment, dirty regions, and atomic commits. |
| **Overlay Stacking** | `zwlr_layer_shell_v1` | Defines canonical `background`, `bottom`, `top`, and `overlay` tiers and input grabs. |
| **Subsurface Anchoring** | `wl_subcompositor` | Anchors child surfaces (inline graphics, badges) to parent surfaces. |
| **Clipboard Exchange** | `wl_data_device_manager` | Out-of-band clipboard read/write with MIME type negotiation. |
| **Cell Memory Buffers** | `zterm_buffer_factory_v1` | **Missing in Wayland**: Allows attaching character cell arrays (`compact_v1`, `rich_v1`) to `wl_surface`. |
| **Grid Geometry Negotiation** | `zterm_grid_surface_v1` | **Missing in Wayland**: Negotiates character columns/rows and pixel font metrics. |
| **Cursor-Relative Placement** | `zterm_cursor_anchor_v1` | **Missing in Wayland**: Positions overlays relative to prompt text cursor coordinates. |
| **Structured Terminal Keys** | `zterm_keyboard_v1` | **Missing in Wayland**: Delivers resolved key names and UTF-8 strings without requiring `libxkbcommon` over SSH. |
| **Palettes & Theming** | `zterm_theme_manager_v1` | **Missing in Wayland**: Broadcasts terminal 16-color ANSI palettes and dynamic RGBA theme tokens. |
| **Getters / Setters / Notify**| `zterm_property_manager_v1` | **Missing in Wayland**: Structured session property queries, window title mutation, and notifications. |
| **Legacy PTY Sandboxing (xpty)** | `zterm_xpty_v1` | **Missing in Wayland**: The "xpty" bridge running legacy VT100 applications (analogous to Xwayland). |

---

## 3. SSH Compatibility & The Dual-Path Buffer Strategy

Wayland desktop compositors historically struggled over SSH because `wl_shm` and DRM pass file descriptors using Unix domain socket ancillary data (`SCM_RIGHTS`), which standard TCP or SSH socket forwarding drops.

TC-Wayland completely resolves this by supporting **two distinct buffer creation mechanisms** in `zterm_buffer_factory_v1`:

```
                           ┌────────────────────────────────────────┐
                           │       zterm_buffer_factory_v1          │
                           └───────────────────┬────────────────────┘
                                               │
                      ┌────────────────────────┴────────────────────────┐
                      ▼                                                 ▼
        create_cell_buffer (Stream Path)               create_shm_cell_buffer (SHM Path)
        ────────────────────────────────               ─────────────────────────────────
        • Uses Wayland <arg type="array"/>             • Uses standard wl_shm_pool
        • Transmitted on the byte stream socket        • Zero-copy memory mapping
        • Zero file descriptors (no SCM_RIGHTS)        • Passes memfd via SCM_RIGHTS
        • 100% SSH Socket Forwarding Safe              • Maximum speed for local high-FPS
```

### 3.1 Transparent SSH Socket Forwarding
Because `create_cell_buffer` sends raw binary cell arrays inline over the stream socket, remote CLI tools running over SSH require only standard OpenSSH Unix socket forwarding:

```ssh_config
# ~/.ssh/config snippet
Host *
    RemoteForward /tmp/tc-%u.sock %d/tc-wayland-0
    StreamLocalBindUnlink yes
```

When connecting to the remote host:
```bash
export TC_WAYLAND_DISPLAY=/tmp/tc-$USER.sock
lazygit  # Launches as a native Wayland client directly over SSH!
```

### 3.2 Path Selection: How Client & Compositor Decide

The protocol cleanly decouples client transport selection from compositor dispatch:

#### A. Compositor: Automatic Dispatch via Opcode
The compositor does not need heuristic guessing. The client's request choice explicitly dictates the backing storage:
- `create_cell_buffer`: Compositor allocates an internal `wl_buffer` referencing the inline stream array bytes.
- `create_shm_cell_buffer`: Compositor allocates an internal `wl_buffer` referencing the mmap'd `wl_shm_pool`.

When the client commits the surface (`wl_surface.commit()`), the compositor's renderer inspects the buffer's variant tag (`inline_array` vs `shm_pool`) and blits accordingly.

#### B. Client: Transport Selection Heuristics
Client libraries (e.g. `monstar-ui`, `ratatui`) decide which factory method to call at startup:

```
┌────────────────────────────────────────────────────────┐
│ Client Startup                                         │
│  ├─ 1. Explicit override? ($TC_BUFFER_MODE=stream|shm) │
│  ├─ 2. Remote SSH detected? ($SSH_CONNECTION set)      │
│  │     └─► Use create_cell_buffer (inline array)       │
│  └─ 3. Local Unix socket + wl_shm available?           │
│        └─► Use create_shm_cell_buffer (zero-copy SHM)  │
└────────────────────────────────────────────────────────┘
```

```zig
pub fn selectBufferMethod() enum { inline_array, shm_pool } {
    // Overrides take precedence
    if (std.posix.getenv("TC_BUFFER_MODE")) |m| {
        if (std.mem.eql(u8, m, "stream")) return .inline_array;
        if (std.mem.eql(u8, m, "shm")) return .shm_pool;
    }
    // Remote SSH sessions cannot pass file descriptors
    if (std.posix.getenv("SSH_CONNECTION") != null or
        std.posix.getenv("SSH_CLIENT") != null)
    {
        return .inline_array;
    }
    // Default to zero-copy SHM for local clients
    return .shm_pool;
}
```

*Note on Safe Defaults:* For small surfaces (such as autocomplete popups and dialogs under 50 KB), clients may always safely use `create_cell_buffer`, as inline socket transfers complete in a few microseconds even locally.

---

## 4. Binary Cell Memory ABI Specifications

Rather than formatting cells into JSON or strings, `create_cell_buffer` accepts contiguous binary cell arrays conforming to one of two standard memory layouts. Cells are laid out in **row-major order**:
$$\text{offset} = (y \times \text{cols} + x) \times \text{sizeof}(\text{Cell})$$

### 4.1 Tier 1: `compact_v1` (8 Bytes per Cell)
Optimized for ultra-low memory footprints, high-throughput log streams, and fast scrolling:

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                      Unicode Codepoint (u32)                  |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|   FG Color    |   BG Color    |       Style Flags (u16)       |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

```zig
pub const CompactCell = extern struct {
    codepoint: u32,
    fg_color: u8,
    bg_color: u8,
    flags: CompactFlags,
};

pub const CompactFlags = packed struct(u16) {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    reverse: bool = false,
    strikethrough: bool = false,
    fg_is_palette: bool = true,
    bg_is_palette: bool = true,
    reserved: u7 = 0,
};
```

### 4.2 Tier 2: `rich_v1` (32 Bytes per Cell)
Designed for modern graphical TUIs, 24-bit TrueColor RGBA blending, dedicated underline styling, complex grapheme clusters (emojis, ZWJ sequences), and OSC 8 hyperlinks:

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|          Content (Codepoint or Grapheme Pool Offset) (u32)    |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                     Foreground RGBA (u32)                     |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                     Background RGBA (u32)                     |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                  Underline Color RGBA (u32)                   |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                     Hyperlink ID / Ref (u32)                  |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                       Rich Flags (u32)                        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| Width |                   Reserved (7 bytes)                  |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

---

## 5. Overlay Layers & Cursor-Anchoring

### 5.1 Leveraging `zwlr_layer_shell_v1`
For modals, dialogs, status bars, and floating palettes, applications assign the layer surface role to their `wl_surface` using `zwlr_layer_shell_v1.get_layer_surface()`:
- **`ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY`**: Window-wide modal dialogs, search finders, toasts.
- **`ZWLR_LAYER_SHELL_V1_LAYER_TOP`**: Terminal tab bars and headers.
- **`ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM`**: Persistent status lines, mode indicators.
- **`set_keyboard_interactivity(EXCLUSIVE)`**: Grabs keyboard input for modal dialogs.

### 5.2 Cursor-Anchored Overlays (`zterm_cursor_anchor_v1`)
When an autocomplete dropdown, hover documentation card, or inline diagnostic card is spawned, it must follow the prompt's active text cursor.

```
 CLIENT                                              COMPOSITOR
 ──────                                              ──────────
 wl_compositor.create_surface()                  ──> (Allocates wl_surface)
 zterm_compositor_v1.get_grid_surface(grid, surf)──> (Assigns grid role)
 zterm_compositor_v1.get_cursor_anchor(anchor,   ──> (Pins surface to text cursor
   surf, parent_surf)                                 of active prompt)
 zterm_cursor_anchor_v1.set_placement(BELOW_START)
 zterm_cursor_anchor_v1.set_offset(0, 1)         ──> (Offset 1 row below cursor)
 wl_surface.attach(cell_buffer)                  ──> (Attaches suggestions)
 wl_surface.commit()                             ──> (Renders dropdown tear-free)
```

Because the overlay floats on a separate surface, **the underlying command line and prompt are never overwritten or damaged**.

---

## 6. Structured Keyboard & Input (`zterm_keyboard_v1`)

Standard Wayland `wl_keyboard` delivers Linux evdev scancodes and requires clients to parse keymaps using `libxkbcommon`. For local GUI apps, this is ideal. For remote CLI tools and TUIs running across SSH, compiling or linking `libxkbcommon` is an unnecessary dependency.

`zterm_keyboard_v1` provides a streamlined terminal keyboard event stream:
- **`key_name`**: Pre-resolved canonical symbols (`"Enter"`, `"Escape"`, `"Tab"`, `"ArrowDown"`, `"BackSpace"`, `"F1"`-`"F12"`).
- **`utf8_text`**: Pre-composed UTF-8 text for printable keys (`"a"`, `"$"`, `"ñ"`).
- **`modifiers`**: Explicit bitmask flags (`shift`, `ctrl`, `alt`, `super`, `caps_lock`).
- **`state`**: Pressed, released, or auto-repeat.

Tools receive clean, unambiguous key events without needing to parse escape sequences or manage keyboard maps.

---

## 7. Theming, Colors & Properties

### 7.1 Dynamic Theme Manager (`zterm_theme_manager_v1`)
Replaces clunky in-band OSC 10/11 color queries with an asynchronous theme broadcast:
- Notifies clients of the active color scheme (`"Catppuccin Mocha"`, `"Nord"`, `"Tokyo Night"`).
- Reports dark mode vs. light mode (`is_dark`).
- Broadcasts default `bg_rgba`, `fg_rgba`, and `cursor_rgba`.
- Delivers the full 16-color ANSI palette as a packed array of 32-bit RGBA integers.
- Broadcasts live updates when the user switches themes—allowing TUIs to restyle dynamically without roundtrips.

### 7.2 Properties, Getters, and Setters (`zterm_property_manager_v1`)
Provides structured getters, setters, and change watchers for terminal metadata:
- **`window.title` / `window.subtitle`**: Clean title setting without OSC 0/2 escapes.
- **`window.grid`**: Informs clients of overall terminal column/row capacity.
- **`a11y.screen_reader_active` / `a11y.high_contrast`**: Informs tools to adapt for accessibility.
- **`system_notify`**: Posts native desktop notifications via the compositor.

---

## 8. Legacy PTY Bridge: xpty ("Xwayland for Terminals")

To guarantee 100% backward compatibility with existing software (`bash`, `zsh`, `vim`, `htop`, `curl`), Monstar incorporates **xpty** (`zterm_xpty_v1`), analogous to Xwayland for desktop compositors:

```
┌────────────────────────────────────────────────────────┐
│ UNMODIFIED LEGACY PROGRAM (e.g. bash, vim, htop)       │
└───────────────────────────┬────────────────────────────┘
                            │ Standard TTY I/O
                            ▼
┌────────────────────────────────────────────────────────┐
│ SLAVE PTY DESCRIPTOR (/dev/pts/N)                      │
└───────────────────────────┬────────────────────────────┘
                            │ Raw ANSI Bytes
                            ▼
┌────────────────────────────────────────────────────────┐
│ xpty BRIDGE ("Xwayland for Terminals")                 │
│                                                        │
│  1. Owns master PTY descriptor.                        │
│  2. Houses legacy VT100 / xterm parser state machine.  │
│  3. Manages Primary and Alternate screen cell grids.   │
│  4. Converts VT dirty rectangles into cell buffers.    │
│  5. Translates Wayland key events into VT escapes.     │
└───────────────────────────┬────────────────────────────┘
                            │
                            │ Standard Wayland IPC (wl_surface + cell buffer)
                            ▼
┌────────────────────────────────────────────────────────┐
│ MONSTAR TERMINAL COMPOSITOR                            │
│ • Blits cell buffer to window scene graph.             │
│ • Completely isolated from rogue ANSI escape glitches. │
└────────────────────────────────────────────────────────┘
```

### Invariants of xpty:
1. **Zero Upward Escapes**: The bridge never leaks ANSI escapes into the compositor. It outputs only clean cell rectangles.
2. **Spatial Clamping**: Escapes like `\x1b[2J` (clear screen) or rogue cursor coordinates are strictly clamped to the surface's bounding box. They physically cannot damage adjacent panes or overlays.
3. **Pristine Compositor Core**: The compositor code does not need legacy VT state machines. It operates purely on Wayland surfaces and cell buffers.

---

## 9. End-to-End Client Walkthrough (Zig Example)

Here is how a modern CLI tool creates an atomic, centered confirmation dialog using TC-Wayland in Zig:

```zig
const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const zterm = wayland.client.zterm;
const zwlr = wayland.client.zwlr;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // 1. Connect to Wayland socket ($TC_WAYLAND_DISPLAY or $WAYLAND_DISPLAY)
    const display = try wl.Display.connect(null);
    const registry = try display.getRegistry();

    // Context holding bound globals
    var ctx: AppContext = .{};
    registry.setListener(*AppContext, registryListener, &ctx);
    _ = try display.roundtrip();

    // 2. Allocate Wayland Surface and assign Grid Role
    const surface = try ctx.compositor.createSurface();
    const grid_surface = try ctx.tc_compositor.getGridSurface(surface);
    grid_surface.setTitle(" Confirmation Dialog ");

    // 3. Assign Layer Role for centered floating modal with backdrop
    const layer_surface = try ctx.layer_shell.getLayerSurface(
        surface,
        null, // Default output
        zwlr.LayerShellV1.Layer.overlay,
        "modal",
    );
    layer_surface.setAnchor(.{}); // Centered
    layer_surface.setKeyboardInteractivity(.exclusive);

    // 4. Create Cell Buffer with dialog contents (40 cols x 6 rows)
    const cols: u32 = 40;
    const rows: u32 = 6;
    const cells = try allocator.alloc(CompactCell, cols * rows);
    defer allocator.free(cells);

    // Populate cell matrix...
    fillDialogContent(cells, cols, rows);

    const cell_bytes = std.mem.sliceAsBytes(cells);
    const buffer = try ctx.buffer_factory.createCellBuffer(
        cols,
        rows,
        .compact_v1,
        cell_bytes,
    );

    // 5. Attach and commit atomically
    try surface.attach(buffer, 0, 0);
    try surface.damage(0, 0, cols, rows);
    try surface.commit();

    // 6. Event loop: listen for zterm_keyboard_v1 events
    while (ctx.running) {
        _ = try display.dispatch();
    }
}
```

---

## 10. Summary & Roadmap

By refactoring the Terminal Compositor proposal around standard Wayland architecture and the `term-compositor-v1.xml` extension:
1. **Zero Reinvention**: `wl_surface`, `zwlr_layer_shell_v1`, `wl_subsurface`, and `wl_data_device` are reused as-is.
2. **Standard Tooling**: Client and server code are generated with standard tools (`wayland-scanner`, `zig-wayland`).
3. **100% SSH Compatibility**: Inline array cell buffers eliminate `SCM_RIGHTS` dependencies over remote connections.
4. **Clean Backward Compatibility**: The PTY Bridge sandboxes legacy command-line applications without polluting the compositor.
