# tc-shell Architecture & Design Proposal

**Version:** 0.1.0-draft  
**Target:** Monstar Terminal Compositor (`term-compositor-v1`)  
**Status:** Proposal / Design RFC  

---

## 1. Executive Summary

Traditional Unix shells (`sh`, `bash`, `zsh`, `fish`) operate over a serial, single-stream teletype abstraction (`/dev/tty`). In this historical model:
1. All commands, prompts, and tools write into one shared, mutable 2D character matrix.
2. Formatted text and UI interactions rely on destructive in-band ANSI escape sequences.
3. State mutations (`cd`, `export`) leak invisibly across subsequent commands.
4. History is a flat, unstructured text log of past keystrokes.
5. Interactive TUI programs (e.g. `vim`, `htop`) hijack the entire viewport using the alternate screen buffer, blowing away context and scrollback.

**`tc-shell`** redesigns the command shell for the **Terminal Compositor via Wayland (TC-Wayland)** era. It bridges modern graphical compositing, notebook-style document ergonomics, and POSIX pipeline utilities:
- **Zero ANSI bytestreams in the shell:** The shell core never parses or emits VT100/xterm escape codes.
- **Surface-per-invocation:** Every command execution runs in its own isolated Wayland surface.
- **Dual Execution Models:** 
  - **Standalone Programs:** Fullscreen or tiled surfaces managed by the window manager or compositor multiplexer.
  - **Notebook Documents (`notebook` / `doc`):** Linear, collapsible, reproducible blocks of command recipes and pipelines.
- **Sandboxed Legacy Tools (`xpty`):** Unmodified VT100 tools run via the compositor’s sandboxed PTY bridge without corrupting adjacent surfaces.
- **Cross-Platform & Remote (macOS & SSH):** Operates natively under desktop Wayland compositors (Sway, Hyprland) or within Monstar acting as an embedded "desktop-in-a-window" over SSH.

---

## 2. Core Architectural Pillars

```
┌────────────────────────────────────────────────────────────────────────┐
│ USER INTERACTION                                                       │
│ • Stationary Persistent Prompt (Docks, status bar, or input line)      │
│ • Standalone Commands (htop, neovim, cargo build)                      │
│ • Notebook Workflows (`notebook run build.tc`, multi-stage blocks)     │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ tc-shell ENGINE                                                        │
│ ┌────────────────────────┐ ┌────────────────────┐ ┌──────────────────┐ │
│ │ POSIX Parser & Pipes   │ │ Surface Controller │ │ Notebook Runtime │ │
│ │ (fork, exec, pipe(2))  │ │ (Wayland Client)   │ │ (Blocks, Folds)  │ │
│ └────────────────────────┘ └────────────────────┘ └──────────────────┘ │
└───────────────────┬───────────────────────────────────┬────────────────┘
                    │ Standard OS Pipes (Raw Data)      │ Wayland Wire IPC
                    ▼                                   ▼
┌───────────────────────────────┐     ┌──────────────────────────────────┐
│ UNIX DATA PIPELINE            │     │ MONSTAR / WAYLAND COMPOSITOR     │
│ • Intermediate stages: OS FDs │     │ • Stationary Prompt Surface      │
│ • Endpoint: zterm_stream or   │     │ • Command Blocks (Subsurfaces)   │
│   zterm_grid surface          │     │ • Standalone Windows (xdg_shell) │
│                               │     │ • Sandboxed xpty Bridge (VT100)  │
└───────────────────────────────┘     └──────────────────────────────────┘
```

---

## 3. Surface & Layout Model

### 3.1 The Stationary Prompt
In `tc-shell`, the prompt does not scroll up into oblivion as lines are printed.
- The prompt is an independent, pinned Wayland surface (`zwlr_layer_shell_v1` or a dedicated subsurface).
- It remains anchored (typically at the bottom of the viewport or docked at the top).
- As commands execute, their visual blocks scroll up into the history canvas above the prompt.
- Autocomplete menus, documentation hovers, and history search pickers float directly over the prompt using `zterm_cursor_anchor_v1`.

### 3.2 Standalone Execution vs. Notebook Blocks

`tc-shell` explicitly differentiates between two execution modes:

#### 1. Standalone / Full-Screen Programs (Default for Interactive TUIs)
When running standalone programs (`htop`, `neovim`, `aerc`, `yazi`):
- `tc-shell` requests a new toplevel window via `xdg_shell` (or a dedicated pane in Monstar).
- In a **Native Wayland WM (Sway / Hyprland)**: The program opens as a first-class tiled or floating window. The desktop window manager provides multiplexing naturally.
- In a **Nested Compositor (Monstar on macOS / SSH)**: Monstar acts as the window manager, displaying the program in a tiled pane, tab, or maximizable modal.
- **Surface Clamping**: The program's alternate screen buffer is restricted to the bounds of its surface. Maximizing the surface expands it to the full window without breaking the rest of the workspace.

#### 2. Notebook / Document Mode (Via `notebook` / `doc` Builtin)
For exploratory coding, build pipelines, and multi-stage imperative workflows, users work within a **Notebook**:
```
┌────────────────────────────────────────────────────────────────────────┐
│ [▼] WORKFLOW: Build & Test              [Success] [1.4s] [Re-run] [x]  │ ◄ Block Header
├────────────────────────────────────────────────────────────────────────┤
│ Scope: cwd = ~/dev/monstar | env = { ZIG_DEBUG: "1" }                  │
├────────────────────────────────────────────────────────────────────────┤
│ [✓] 1. cd ~/dev/monstar                                     (0.2ms)    │
│ [✓] 2. git checkout feat/xpty                               (42ms)     │
│ [✓] 3. zig build test                                       (1.3s)     │
│        ├─ [▶] 48 passed, 0 failed (1,240 lines hidden)                 │ ◄ Collapsed Output
└────────────────────────────────────────────────────────────────────────┘
```

- **Collapsible / Expandable**: Large logs automatically collapse with summary badges; click `[▼]` or press hotkeys to inspect.
- **Isolated Scoping**: Workflows declare their own context (`cwd`, environment variables). Directory changes do not pollute the global shell session unless intended.
- **Replayability**: Entire command blocks can be re-run with one click or keybinding using their recorded starting conditions.
- **Exportable**: Workflows can be saved directly to `.tc` runnable recipe files or markdown blocks.

---

## 4. Execution Categories & Zero-ANSI Architecture

`tc-shell` executes three categories of programs without ever parsing ANSI escapes:

| Category | Transport / Wire | Presentation | Example Programs |
| :--- | :--- | :--- | :--- |
| **Native TC Programs** | Wayland Wire Socket (`$TC_WAYLAND_DISPLAY`) | Directly attaches `compact_v1` / `rich_v1` cell buffers or streams via `append_styled_text` | `monstar-ui`, `tc-fzf`, modern CLI tools |
| **Legacy VT / TUI Programs** | Slave PTY descriptor (`/dev/pts/N`) | `zterm_xpty_v1.attach_pty` hands PTY to compositor's isolated bridge | `vim`, `htop`, `less`, `nano` |
| **Standard Unix Pipeline** | OS Pipes (`pipe(2)`) | Pure binary byte streams between stages; endpoint attaches to `zterm_stream_surface_v1` | `grep`, `awk`, `jq`, `cat`, `sort` |

### How `tc-shell` Runs xpty Tools with Zero ANSI Parsing:
1. `tc-shell` allocates a `zterm_grid_surface_v1`.
2. It opens a standard POSIX pseudo-terminal pair via `openpty()`.
3. It calls `zterm_xpty_v1.attach_pty(grid_surface, pty_slave_fd)`.
4. It spawns the child process attached to `pty_slave_fd`.
5. **The Compositor’s xpty bridge** parses VT100 escapes and blits cell matrices. `tc-shell` never inspects a single escape byte.

---

## 5. Text Processing & Unix Pipes

Unix pipes are fundamental. `tc-shell` preserves standard POSIX semantics while removing the "ANSI pollution" dilemma:

### 5.1 Pure Byte Streaming Between Pipeline Stages
When running:
```bash
cat access.log | grep "500" | awk '{print $1}' | sort | uniq -c
```
- Standard OS pipes (`pipe(2)`) connect file descriptors `1` and `0` between child processes.
- Data flows at maximum kernel memory speed without any Wayland serialization overhead.

### 5.2 Stream Endpoints & Styled Text (`zterm_stream_surface_v1`)
The final stage of a pipeline connects to a `zterm_stream_surface_v1`:
- Native tools emit styled text via the protocol request:
  ```xml
  <request name="append_styled_text">
    <arg name="text" type="string"/>
    <arg name="fg" type="uint"/>
    <arg name="bg" type="uint"/>
    <arg name="flags" type="uint" enum="style_flags"/>
  </request>
  ```
- **Benefits:**
  - Styling (bold, colors, underline) is out-of-band and structured.
  - Piping styled output to a file or another command automatically strips formatting without needing `sed 's/\x1b\[[0-9;]*m//g'`.
  - The compositor rasterizes glyphs using its own configured fonts and DPI scaling.

---

## 6. Developer Experience: `libtc` Client SDK

Developers writing CLI or TUI tools should never need to manage font stacks, FreeType, HarfBuzz, or raw Wayland wire marshaling.

### 6.1 Simple Styled CLI Example (Zig)
```zig
const std = @import("std");
const tc = @import("libtc");

pub fn main() !void {
    var term = try tc.init();
    defer term.deinit();

    // Prints styled text natively in tc-shell, or falls back to ANSI / plain text
    try term.print("Status: ", .{});
    try term.styled("PASSED", .{ .fg = .green, .bold = true });
    try term.print(" in 12ms\n", .{});
}
```

### 6.2 2D Text Canvas / TUI Example (Zig)
```zig
const tc = @import("libtc");

pub fn main() !void {
    var app = try tc.GridApp.init(.{ .title = "Status Monitor" });
    defer app.deinit();

    while (app.running) {
        var canvas = app.beginFrame(); // Returns 2D grid slice of Cells
        canvas.drawText(0, 0, "CPU Usage: 42%", .{ .bold = true, .fg = .cyan });
        try app.commit(); // Atomic commit, zero tearing

        const ev = try app.nextEvent(); // Structured KeyEvents
        if (ev.isKey("q")) break;
    }
}
```

---

## 7. Implementation Roadmap

1. **Protocol Extension (`term-compositor-v1.xml`)**:
   - [x] Added `style_flags` enum to `zterm_stream_surface_v1`.
   - [x] Added `append_styled_text` request to `zterm_stream_surface_v1`.
2. **`libtc` SDK**:
   - Lightweight client library in Zig providing `Stream` and `GridApp` abstractions with auto-detection of `$TC_WAYLAND_DISPLAY`.
3. **`tc-shell` Prototype**:
   - REPL with a stationary prompt surface.
   - Command launcher with `xdg_shell` / `zterm_grid_surface_v1`.
   - Standard Unix pipeline execution.
   - `xpty` bridge hand-off for legacy tools.
4. **`notebook` Builtin**:
   - Block creation, folding, and workflow re-execution.
