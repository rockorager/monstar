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

**`tc-shell`** redesigns the command shell for the **Terminal Compositor via Wayland (TC-Wayland)** era. It is a text-processing shell that unifies Fish-grade line editing, stateful POSIX pipelines, and Wayland subsurface isolation:
- **Zero ANSI bytestreams in the shell:** The shell core never parses or emits VT100/xterm escape codes.
- **Surface-per-command:** Every command execution runs in its own isolated Wayland subsurface (`$1`, `$2`, ..., `$n`).
- **Prompt-Centric Architecture (Zero Focus Management):** The user never toggles focus or navigates modal UI states. The stationary prompt is the single, persistent point of input.
- **Command-Driven Block Management:** All operations on past command blocks (`collapse`, `expand`, `fullscreen`, `edit`, `run`, `rm`, `copy`) are executed via regular prompt commands on block tags (`$1`, `$prev`).
- **First-Class Text Processing & Pipelining:** Subsequent commands reference previous outputs directly (`$1 | grep foo`, `$1 > file.txt`, `diff $1 $2`).
- **Fish-Grade Line Editor with Overlay Completions:** Real-time syntax highlighting, ghost auto-suggestions, and Tab completions presented as cursor-anchored Wayland overlays (`zterm_cursor_anchor_v1`) that never push canvas content down.
- **Sandboxed Legacy Tools (`xpty`):** Unmodified VT100 tools run via the compositor’s sandboxed PTY bridge without corrupting adjacent surfaces.

---

## 2. Core Architectural Pillars

```
┌────────────────────────────────────────────────────────────────────────┐
│ USER INTERACTION: STATIONARY PROMPT (Always Focused)                   │
│ • Fish-grade line editor (syntax highlighting, inline auto-suggestions)│
│ • Floating Tab completion overlay (zterm_cursor_anchor_v1)             │
│ • Block control commands (collapse $1, expand $1, edit $1, rm $1)      │
│ • Pipeline references ($1 | grep foo, $1 > file.txt, diff $1 $2)       │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ tc-shell ENGINE                                                        │
│ ┌────────────────────────┐ ┌────────────────────┐ ┌──────────────────┐ │
│ │ POSIX Parser & Pipes   │ │ Surface Controller │ │ State Manager    │ │
│ │ (fork, exec, pipe(2))  │ │ (Wayland Client)   │ │ (cwd, env vars)  │ │
│ └────────────────────────┘ └────────────────────┘ └──────────────────┘ │
└───────────────────┬───────────────────────────────────┬────────────────┘
                    │ Standard OS Pipes (Raw Data)      │ Wayland Wire IPC
                    ▼                                   ▼
┌───────────────────────────────┐     ┌──────────────────────────────────┐
│ UNIX DATA PIPELINE            │     │ MONSTAR / WAYLAND COMPOSITOR     │
│ • Intermediate stages: OS FDs │     │ • Stationary Prompt Surface      │
│ • Cached outputs (memfd)      │     │ • Command Blocks (Subsurfaces)   │
│ • Endpoint: zterm_stream or   │     │ • Cursor-Anchored Overlays       │
│   zterm_grid surface          │     │ • Sandboxed xpty Bridge (VT100)  │
└───────────────────────────────┘     └──────────────────────────────────┘
```

---

## 3. UX & Interaction Model

### 3.1 The Stationary Prompt: The Single Point of Interaction
In `tc-shell`, the prompt does not scroll away. It remains anchored and persistently focused.
- **Zero Focus Management:** The user never switches focus between panes, surfaces, or blocks. Keystrokes always target the prompt editor.
- **Zero Shell Pager / Scroll Modes:** The shell does not implement internal pager modes or modal `j`/`k` navigation. When a user wants to paginate, search, or inspect output, they use standard Unix tools directly from the prompt (`view $1` or `$1 | less`).
- **Syntax Highlighting:** Real-time tokenization as the user types (valid executables in green, invalid commands in red, flags in cyan, strings in yellow, pipes in purple).
- **Auto-Suggestions (Ghost Text):** Dimmed inline preview of history matches; press `Right Arrow` or `Ctrl+F` to accept.
- **Overlay Autocompletions:** Pressing `Tab` opens a floating completion menu positioned via `zterm_cursor_anchor_v1` directly beneath/above the cursor. It never pushes canvas text down or mutates scrollback.

### 3.2 Command Blocks & Prompt-Driven Actions
Every executed command and its output are placed inside an isolated Wayland subsurface tagged with an identifier (`$1`, `$2`, ..., `$n`) and alias `$prev`.

All block manipulations are performed purely through standard prompt commands:

| Command | Action | Example |
| :--- | :--- | :--- |
| **`collapse`** | Folds the block's output into a compact 1-line badge. Defaults to `$prev`. | `collapse $1`, `collapse` |
| **`expand`** | Unfolds a collapsed block's output back to view. | `expand $1`, `expand` |
| **`fullscreen`** / **`fg`** | Re-expands an xpty interactive tool or zooms a block. | `fullscreen $2`, `fg` |
| **`edit`** | Populates the prompt input buffer with the block's command text for tweaking. | `edit $1` |
| **`run`** | Re-executes the command as a new block. | `run $1` |
| **`rm`** | Deletes the block and its output entirely from the visual canvas. | `rm $1` |
| **`copy`** | Copies the block's output (or `.cmd`) to the system clipboard. | `copy $1`, `copy $1.cmd` |
| **`view`** | Streams the block's output into the system pager (`less`). | `view $1` |

### 3.3 Text Processing & Output Referencing
`tc-shell` treats command outputs as reusable data sources:
- **Pipes:** `$1 | grep "ERROR" | wc -l`
- **Redirection:** `$1 > bundle.log`
- **Arguments / Process Substitution:** `diff $1 $2`
- Outputs are cached in anonymous `memfd` descriptors, enabling instantaneous re-use without re-running long commands.

### 3.4 Interactive Full-Screen Programs (`xpty`)
When running interactive TUI applications (`nvim`, `htop`, `less`):
- `tc-shell` runs the tool in an isolated `zterm_xpty_v1` surface that expands to full screen.
- Standard Unix job suspension (`Ctrl+Z`) drops back to the stationary prompt, leaving the tool running as a minimized block.
- Typing `fg` or `fullscreen $N` restores the application to full screen.
- Upon process exit, control returns cleanly to the stationary prompt with no residual escape sequence debris.

### 3.5 The Surface Hierarchy: Document Canvas vs. OS Workspaces
To avoid window-manager clutter and runaway complexity, `tc-shell` strictly delineates between **internal document blocks** and **external OS window management**:

1. **Subsurfaces (`wl_subsurface`), Not OS Windows:**
   - Every command block is an internal Wayland `wl_subsurface` anchored inside a parent document canvas.
   - Command blocks do **not** register as `xdg_toplevel` windows; they do not appear in Alt-Tab switchers or flood tiling trees.
   - The shell session is presented as **one single application window** to the host desktop window manager (Sway, Niri, Hyprland).
2. **Monstar as a Document Compositor (Not a Window Manager):**
   - Monstar GUI does not implement window manager logic (floating window dragging, tiling split trees, focus policies).
   - Monstar simply calculates a 1D vertical flow layout (`y_offset += block.height`) for subsurfaces. When blocks collapse (`collapse $1`) or are removed (`rm $1`), adjacent blocks slide smoothly into place.
3. **Translating Terminal Multiplexing to OS Workspaces:**
   - Traditional multiplexers (`tmux`, `zellij`) build an insulated "OS inside an OS", hiding sessions, tabs, and splits from the host desktop.
   - Under TC-Wayland, terminal multiplexing delegates directly to native OS workspaces:
     - New shell workspaces or project sessions are created as first-class `xdg_toplevel` windows or mapped directly to desktop workspaces (via Wayland `ext-workspace-v1` or compositor IPC).
     - In standalone Monstar (e.g. on macOS without a native Wayland WM), Monstar provides the outer tab/workspace container.

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
   - [x] Cursor-anchored overlays (`zterm_cursor_anchor_v1`).
2. **Fish-Grade Prompt Surface (`PromptSurface.zig`)**:
   - Stationary prompt (always focused, zero focus-state management).
   - Real-time syntax highlighting (commands, flags, strings, pipes).
   - Dimmed inline auto-suggestions (accept with `Right Arrow` or `Ctrl+F`).
   - Floating Tab completion popup overlay anchored via `zterm_cursor_anchor_v1`.
3. **Stateful Execution Engine & Block Management**:
   - In-process session state (`cwd`, `export`, `unset`, aliases).
   - Subsurface command blocks tagged `$1..$n` and `$prev` backed by anonymous `memfd` buffers.
   - Prompt-driven block built-ins: `collapse`, `expand`, `fullscreen` / `fg`, `edit`, `run`, `rm`, `copy`, `view`.
   - Output referencing in pipelines (`$1 | grep foo`, `$1 > file.txt`, `diff $1 $2`).
4. **`xpty` Integration**:
   - Fullscreen auto-expansion for interactive TUIs (`nvim`, `htop`).
   - Standard `Ctrl+Z` suspension to background block; re-expansion via `fullscreen $N` or `fg`.
