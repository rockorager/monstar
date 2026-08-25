# Terminal Compositing (TC) Protocol Specification

**Version:** 1.0.0-draft **Status:** Working Draft **Target Audience:** Terminal Emulator Developers, CLI Tool Authors, TUI Framework Maintainers

______________________________________________________________________

## 1. Abstract & Motivation

The terminal emulator ecosystem has traditionally relied on a single in-band stream (`/dev/tty` / serial discipline) where text characters, styling attributes, and cursor movements share the same linear channel.

Attempting to render modern UI elements (e.g., floating modal dialogs, cursor-anchored autocomplete dropdowns, command palettes, ephemeral toasts) using in-band ANSI escape sequences leads to:

1. **Screen Corruption**: Drawing over character cells destroys underlying scrollback history and cell state.
1. **Alternate Screen Trap**: Full-screen TUIs are forced into the alternate screen buffer (`\x1b[?1049h`), disabling native trackpad scrolling and terminal search.
1. **Escapes Desynchronization**: High-throughput terminal streams desynchronize and glitch when mixed with cursor-positioning escapes.

The **Terminal Compositing (TC)** Protocol standardizes an **out-of-band, multi-surface 2D compositing protocol** between CLI applications and terminal emulators.

Borrowing the architectural rigor of display servers like **Wayland**, TC models the terminal emulator as a multi-surface display server that arbitrates declarative overlay surfaces above the base PTY stream.

______________________________________________________________________

## 2. Core Architectural Principles

```
┌────────────────────────────────────────────────────────────────────────┐
│  APPLICATIONS, SHELLS & CLIENTS                                        │
│  • Legacy CLI/TUIs (bash, zsh, vim, htop) ──> PTY Stream (/dev/pts/N)  │
│  • Modern Tools (fzf, monstar-ui, sidecars)──> TC IPC ($TC_SOCK)       │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ Multiplexed Streams & IPC
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│  TERMINAL COMPOSITOR & DISPLAY SERVER                                  │
│                                                                        │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │ ROOT SCENE GRAPH (tc_scene / Unified Compositor Tree)            │  │
│  │                                                                  │  │
│  │  ├── Background Layer Tree (Theme Canvas Fill, Window Margins)   │  │
│  │  ├── Bottom Layer Tree (Status Strip, Keybind Hints, Mode Line)  │  │
│  │  ├── Normal / Workspace Surfaces Tree (Tiled/Tabbed Panes)       │  │
│  │  │    │                                                          │  │
│  │  │    ├── Pane A: tc_surface (pty) Scene Tree                    │  │
│  │  │    │    ├── Pane Decorations (Active Border, Path Bar, Badges)│  │
│  │  │    │    ├── Primary / Alternate Screen Cell Matrix            │  │
│  │  │    │    └── Surface-Scoped Layers (e.g. Autocomplete Dropdown)│  │
│  │  │    │                                                          │  │
│  │  │    └── Pane B: tc_surface (grid/stream) Scene Tree            │  │
│  │  │         ├── Pane Decorations (Inactive Border, Titlebar)      │  │
│  │  │         ├── Active Log Stream / 2D Grid Cell Matrix           │  │
│  │  │         └── Surface-Scoped Layers (e.g. Inline Toast / Lens)  │  │
│  │  │                                                               │  │
│  │  ├── Top Layer Tree (Terminal Tab Bar, Window Header)            │  │
│  │  └── Overlay Layer Tree (Command Palette, Modals, Search Bar)    │  │
│  └────────────────────────────────┬─────────────────────────────────┘  │
│                                   │                                    │
│                                   ▼                                    │
│                    2D Compositing & Blending Pass                      │
│              (Z-ordering, Backdrop Dim, Shadows, Layout)               │
│              • Native Font Rasterization (FreeType/HarfBuzz)           │
│              • Terminal Color Themes (Catppuccin, Nord, etc.)          │
│              • Fractional DPI & Coordinate Mapping                     │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ Pixel Blit (Direct Memory)
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│  FRAMEBUFFER / DISPLAY OUTPUT (Wayland / X11 / Metal / DirectX)        │
└────────────────────────────────────────────────────────────────────────┘
```

### 2.1 Deconstructing Legacy Primary vs. Alternate Screen: The Surface Model

In traditional terminal emulators, the binary switch between the "Primary Buffer" (with scrollback) and the "Alternate Screen Buffer" (`\x1b[?1049h` / `smcup`/`rmcup`) was an in-band hack created for single-wire serial terminals. It caused the **Alternate Screen Trap**:

- Native trackpad and mouse scrollback are disabled.
- Terminal search is broken or inspects the wrong buffer.
- Screen history cannot be multiplexed or split without escape desynchronization and ANSI corruption.

TC eliminates the global primary/alt screen toggle. Instead, **scrollback history and cell coordinate spaces are properties of individual, compositable surfaces**:

```
┌────────────────────────────────────────────────────────────────────────┐
│                        tc_surface (type="pty")                         │
│                                                                        │
│  PTY I/O Stream (/dev/pts/N) ──> Raw ANSI / UTF-8 Bytes                │
│                                    │                                   │
│                                    ▼                                   │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │ Encapsulated VT Parser & State Machine                           │  │
│  │ • Local cursor (x, y) & styles    • Mouse tracking modes         │  │
│  │ • Palette / OSC colors            • Bracketed paste & DEC modes  │  │
│  └──────────────────────────────────┬───────────────────────────────┘  │
│                                     │ switches active buffer           │
│                    ┌────────────────┴────────────────┐                 │
│                    ▼                                 ▼                 │
│  ┌─────────────────────────────────┐ ┌───────────────────────────────┐ │
│  │ Primary Buffer (Stream)         │ │ Alternate Buffer (Grid)       │ │
│  │ • 2D Viewport (Cols × Rows)     │ │ • Fixed 2D Grid (Cols × Rows) │ │
│  │ • Dedicated Scrollback Ring     │ │ • Zero Scrollback             │ │
│  │   (e.g., 10,000 lines)          │ │ • For vim, htop, less         │ │
│  └────────────────┬────────────────┘ └───────────────┬───────────────┘ │
│                   │                                  │                 │
│                   └─────────────────┬────────────────┘                 │
│                                     ▼                                  │
│                       Active Cell Matrix (Cols × Rows)                 │
│                                     │                                  │
│                 (Direct compositor blit to layout rect)                │
└────────────────────────────────────────────────────────────────────────┘
```

### 2.2 Surface Archetypes

TC formalizes four distinct surface archetypes:

1. **`pty` (Legacy PTY Surface Sandbox - "XWayland for Terminals")**:
   - Encapsulates an isolated VT parser instance and slave PTY (`/dev/pts/N` or Windows ConPTY).
   - Manages internal dual buffers (Primary with infinite scrollback + Alternate screen for legacy TUIs) in complete isolation.
   - **Strict Spatial Clamping**: Coordinates are constrained to $[0..W-1, 0..H-1]$. Escapes like `\x1b[2J` or rogue cursor moves cannot corrupt adjacent panes or sibling surfaces.
   - **Zero Upward Escapes**: Emits no ANSI escapes back to the compositor—only clean dirty-cell rectangles.
1. **`stream` (Pure Text / Log Stream Surface)**:
   - Structured, append-only sequential text stream with dedicated infinite scrollback, search, and text selection.
1. **`grid` (Programmatic 2D Cell Matrix)**:
   - Direct 2D addressable cell canvas $(W \\times H)$ for modern TUI engines and overlay surfaces that bypass ANSI escape serialization entirely.
1. **`pixel` (Continuous Raster Graphics / Image Surface)**:
   - Continuous 2D pixel buffer (PNG, JPEG, WebP, raw RGBA32, or shared memory `memfd`) composited directly by the display server.
   - Operates as an independent subsurface (`wl_subsurface` model) anchored to a cell coordinate in a parent `grid`/`pty` or a scrolling line in a `stream`.
   - Replaces in-band image hacks (Kitty Graphics Protocol, Sixel, iTerm2 inline images) with out-of-band, flicker-free composited graphics.

### 2.3 True Multiplexer Isolation

Because each `tc_surface` owns its own scrollback buffer, cursor state, and mode flags:

- Multiplexers (tiling window splits, tabs, sidebars) create $N$ distinct surfaces without interleaved escape parsing.
- Scrolling back 1,000 lines in Pane A has zero impact on Pane B running a real-time log feed or Pane C running `neovim` in an alternate buffer.
- Overlays and layers can attach globally to the workspace or scope locally to an individual surface.

### 2.4 Separation of Concerns: Display Server vs. Client-Side Toolkits

TC strictly separates the role of the display server/compositor from client-side UI toolkits (mirroring the architectural boundary of Wayland):

1. **The Compositor's Role (Display Server & Arbitration)**:
   - Manages surface life cycles, multiplexer pane layout, z-ordering tiers, clipping, and frame synchronization.
   - Manages overlay layers (`tc_layer`), coordinate anchoring (cursor-relative, pane-relative, centered), and visual effects (drop shadows, backdrop dimming, window borders).
   - Routes keyboard, mouse, and touch input to focused surfaces/layers.
   - Handles global out-of-band services: clipboard exchange, system notifications, window title negotiation, and color theme synchronization.
1. **The Client's Role (UI Rendering & Toolkit State)**:
   - Client applications (or client-side libraries like `monstar-ui`, `vaxis`, `ratatui`, `bubbletea`) retain full control over their UI logic, component trees, keyboard shortcuts, and layout algorithms.
   - Clients render into TC surfaces via programmatic cell matrices (`grid`), append-only text streams (`stream`), or pixel graphic buffers (`pixel`).
   - **Why No Server-Side Widgets**: Baking widgets into the core display server protocol forces the compositor into becoming a monolithic GUI toolkit with endless layout and styling variants. Keeping widgets client-side guarantees maximum client autonomy, rapid toolkit iteration, and a minimal, rock-solid compositor protocol.

### 2.5 Wayland-Inspired Asymmetric Request/Event Model

TC defines two distinct directions of asynchronous communication:

- **Requests (Client $\\to$ Server)**: Asynchronous instructions to create objects, configure properties, update surface buffers, and commit transactions.
- **Events (Server $\\to$ Client)**: Asynchronous notifications emitted by the terminal emulator (keyboard/mouse input, window focus changes, layer dismissal, terminal resize).

### 2.6 Optimistic Object Allocation & Atomic Transactions

- **Zero-Roundtrip Staging**: Clients allocate object IDs locally and immediately send configuration requests without waiting for server acknowledgments.
- **Atomic Commits (`commit`)**: Changes staged on a layer or surface do not render until the client sends a `commit` request, preventing visual tearing and partial updates.

### 2.7 The Scene Graph Hierarchy: Scenes, Surfaces, and Layers

To eliminate ambiguity between scenes, surfaces, and layers, TC adapts Wayland scene graph concepts (`wlr_scene` + `wlr-layer-shell`) directly to the realities of a modern terminal emulator:

```text
Root Scene Graph (1 Global tc_scene per Terminal Window/Compositor)
 │
 ├── 1. Background Layer Subtree
 │    └── Theme background canvas fill, padding/margins, acrylic/blur backdrop
 │
 ├── 2. Bottom Layer Subtree
 │    └── Persistent bottom status strip (e.g. mode line, keybind hints, tmux-style footer)
 │
 ├── 3. Normal / Workspace Surfaces Subtree (Active Tiled Panes & Splits)
 │    │
 │    ├── Pane 1: tc_surface Scene Tree (Active Shell / PTY)
 │    │    ├── Pane Decorations (Active border highlight, path/git header)
 │    │    ├── Primary / Alternate Screen Buffer Cell Matrix
 │    │    └── Surface-Scoped Layers (`tc_layer` parent_surface="pane_1")
 │    │         └── Autocomplete Dropdown (`tc_layer` + `grid` surface, cursor-anchored)
 │    │
 │    └── Pane 2: tc_surface Scene Tree (Build Log Stream / Compiler Output)
 │         ├── Pane Decorations (Inactive border, titlebar)
 │         ├── Text / Log Stream Matrix Buffer
 │         └── Surface-Scoped Layers (`tc_layer` parent_surface="pane_2")
 │              └── Inline Diagnostic Lens / Error Card (`tc_layer` + `grid` surface)
 │
 ├── 4. Top Layer Subtree
 │    └── Terminal Tab Bar, Breadcrumb Header, Window Title Strip
 │
 └── 5. Overlay Layer Subtree (Z-Top)
      ├── Global Command Palette (`Ctrl+Shift+P` search launcher)
      ├── Interactive Modal Dialogs (Confirmation prompts, Git commit popups)
      ├── Global Scrollback Search Overlay (`Ctrl+Shift+F`)
      └── Ephemeral Notification Toasts & Accessibility Highlights
```

#### Hierarchy Invariants & Roles:

1. **The Root Scene (`tc_scene`)**:
   - There is **exactly 1 root scene graph** per terminal compositor instance.
   - It maintains the unified 2D terminal grid coordinate system, tracks dirty/damaged character regions, manages opacity and shadows, and executes the final 2D rendering pass.
1. **Layer Stacking Tiers (`wlr-layer-shell` model)**:
   - Layers define canonical **z-order stacking tiers** tailored to terminal UI:
     - `Background`: Theme background fill and window padding/margins.
     - `Bottom`: Persistent bottom status strips, keybind helper docks, and footer info.
     - `Normal`: The primary tiling/tab workspace containing active shell sessions and tool panes.
     - `Top`: Terminal tab bar and window header.
     - `Overlay`: Window-wide modals, command palettes, search finders, and global toasts.
1. **Surface Scene Trees (`tc_surface`)**:
   - Each terminal pane or split is a **subordinate scene tree** attached to the Normal/Workspace tier.
   - A surface's tree encapsulates its visual borders/decorations, backing character cell matrices, and child overlays.
   - Resizing a pane, splitting the window, or switching tabs automatically transforms, clips, or hides all child decorations and surface-scoped overlays.
1. **Layer Scoping & Clipping**:
   - **Global Layers** (`parent_surface = null`): Attach directly to the workspace-level `Top` or `Overlay` tiers. They are positioned relative to the full terminal window viewport (e.g. centered confirmation modals, global command palette).
   - **Surface-Scoped Layers** (`parent_surface = "<surface_id>"`): Attach as child nodes inside that surface's scene tree. They position relative to that surface's local origin or active text cursor (e.g. inline autocomplete menus) and are clipped to the surface's bounding box.

______________________________________________________________________

## 3. Protocol Definition Format: JSON Protocol Schema

Rather than using XML (which lacks native parser support in many modern toolchains including Zig's standard library), TC interfaces are formally specified using a standardized **JSON Protocol Schema** (inspired by Wayland XML and Language Server Protocol metamodels).

The canonical schema is maintained at \[`protocol/term-compositor.schema.json`\](file:///home/erock/dev/term/monstar/protocol/term-compositor.schema.json).

### 3.1 Schema Structure

The protocol specification JSON defines:

- **`interfaces`**: Top-level object interfaces (`tc_display`, `tc_compositor`, `tc_surface`, `tc_layer`).
- **`requests`**: Methods invoked by the client on a specific object.
- **`events`**: Notifications emitted by the server targeting a specific object.
- **`$defs`**: Shared data types, enums, style dictionaries, and accessibility attributes.

### 3.2 Protocol Code Generator (`tc-scanner`)

Like `wayland-scanner`, language-specific scanner tools (such as `tc-scanner` in Zig) parse the protocol schema and generate:

1. Type-safe message representations (enums, structs, unions).
1. Wire serialization and deserialization routines.
1. Server dispatch vtables and epoll socket scaffolding.
1. Client SDK bindings with high-level builders.

______________________________________________________________________

## 4. Transport, Discovery, & Remote SSH

### 4.1 Transport Framing

TC messages are transmitted over a stream socket using **newline-delimited JSON (`\n` / LF)** framing.

Each message is a single-line JSON object:

#### Request (Client $\\to$ Server):

```json
{"object": "<object_id>", "request": "<request_name>", "args": { ... }}
```

#### Event (Server $\\to$ Client):

```json
{"object": "<object_id>", "event": "<event_name>", "args": { ... }}
```

### 4.2 Discovery Environment Variable

When an TC-compliant terminal emulator spawns a child process or shell, it MUST export:

- **`TC_SOCK`** (Primary) or **`TERMINAL_COMPOSITOR_SOCK`**
- Unix/macOS: Path to Unix domain socket (e.g., `$XDG_RUNTIME_DIR/tc_<pid>.sock` or `/tmp/tc_<pid>.sock`)
- Windows: Named Pipe path (e.g., `\\.\pipe\tc_<pid>`)

### 4.3 Security & Permissions

- Sockets MUST be created with restricted file permissions (`0700` / `0600`), owned by the user's UID/GID.

### 4.4 100% SSH Forwarding Compatibility (No FD Passing)

Because TC transmits pure stream messages and **does not require Unix file descriptor passing (`SCM_RIGHTS`)**, it works transparently across OpenSSH Unix socket forwarding:

```ssh_config
# ~/.ssh/config snippet for TC Socket Forwarding:
Host *
    RemoteForward /tmp/tc_%u.sock %d/tc_%p.sock
    StreamLocalBindUnlink yes
```

Remote CLI tools write standard JSON requests to the forwarded socket. The remote host requires no display server, graphics stack, or compositor daemon.

### 4.5 Graceful Degradation

CLI tools MUST check for the presence and accessibility of `$TC_SOCK`. If absent or unreachable, applications MUST degrade gracefully to standard TTY/ANSI prompts without failing.

______________________________________________________________________

## 5. Core Protocol Interfaces

Below is the formal specification of core TC interfaces:

```
┌────────────────────────────────────────────────────────┐
│                      tc_display                        │
│          (Connection singleton, sync, errors)          │
└───────────────────────────┬────────────────────────────┘
                            │ creates
                            ▼
┌────────────────────────────────────────────────────────┐
│                     tc_compositor                      │
│             (Factory for surfaces and layers)          │
└─────────────┬────────────────────────────┬─────────────┘
              │ creates                    │ creates
              ▼                            ▼
┌───────────────────────────┐┌───────────────────────────┐
│        tc_surface         ││         tc_layer          │
│ • pty (VT Sandbox)        ││ • Overlay / Popup Shell   │
│ • grid (2D Cell Canvas)   ││ • Anchors & Stacking Tiers│
│ • stream (Log Stream)     ││ • Input Routing / Grabs   │
│ • pixel (Raster / SHM)    ││ • Attaches tc_surface     │
└─────────────┬─────────────┘└─────────────┬─────────────┘
              │                            │
              └──────── attaches to ───────┘
```

______________________________________________________________________

### 5.1 `tc_display` (Core Singleton Interface)

The global connection endpoint representing the terminal display server, session properties, and capability negotiation.

#### Requests:

- **`hello`**: Initial connection handshake sent by the client.
  - `client_name` (`string`): Identifying name of the client (e.g. `"fzf"`, `"monstar-ui"`, `"git-tool"`).
  - `client_version` (`string`, optional): Client version string.
  - `requested_interfaces` (`object`, optional): Map of interface names to client-supported max versions.
- **`sync`**: Requests a roundtrip synchronization point.
  - `callback_id` (`string`): Client-allocated ID for the `tc_callback` object.
- **`get_capabilities`**: Queries supported emulator capabilities, advertised interfaces, and security permissions.
- **`property_get`**: Queries active terminal/window/theme properties or feature flags.
  - `keys` (`array` of `string`): List of property keys to query (e.g. `["window.title", "features.clipboard_read"]`).
- **`property_set`**: Mutates writable terminal/window/theme properties.
  - `values` (`object`): Key-value dictionary of properties to set.
- **`property_watch`**: Subscribes to real-time asynchronous change notifications for specified properties or features.
  - `keys` (`array` of `string`): Properties or feature flags to watch.
- **`clipboard_get`**: Reads system clipboard or primary selection.
  - `target` (`string`): `"clipboard"` | `"primary"`.
  - `mime` (`string`): Preferred MIME type (default `"text/plain"`).
- **`clipboard_set`**: Writes data to system clipboard or primary selection.
  - `target` (`string`): `"clipboard"` | `"primary"`.
  - `mime` (`string`): Data MIME type.
  - `content` (`string`): Content string.
- **`system_bell`**: Triggers a system/visual terminal bell.
- **`system_notify`**: Posts a native desktop notification.
  - `title` (`string`)
  - `body` (`string`)
  - `urgency` (`string`, optional): `"low"` | `"normal"` | `"critical"`.

#### Events:

- **`capabilities`**: Response to `hello` / `get_capabilities`, broadcasting emulator metadata, active interface versions, and enabled feature flags.
  - `protocol_version` (`integer`)
  - `emulator` (`string`): Emulator name and version (e.g. `"monstar 1.1.0"`).
  - `interfaces` (`object`): Supported interfaces and version numbers (e.g. `{"tc_compositor":1,"tc_surface":1,"tc_layer":1}`).
  - `features` (`object`): Boolean/status flags for capabilities (e.g. `{"clipboard_read":true,"backdrop_blur":true}`).
- **`property_values`**: Response containing queried property values.
  - `values` (`object`): Key-value dictionary of resolved properties.
- **`property_changed`**: Asynchronous notification when a watched property or feature mutates.
  - `key` (`string`)
  - `value` (`any`)
- **`clipboard_data`**: Response containing requested clipboard data.
  - `target` (`string`)
  - `mime` (`string`)
  - `content` (`string`)
- **`error`**: Error notification on invalid requests or permission rejection.
  - `object_id` (`string`)
  - `code` (`integer`): Standardized error code (e.g. `403` for `PERMISSION_DENIED`, `404` for `UNKNOWN_PROPERTY`).
  - `name` (`string`): Error identifier symbol.
  - `message` (`string`): Human-readable error description.

______________________________________________________________________

### 5.2 `tc_compositor` (Surface & Layer Factory)

Factory interface for creating composited surfaces and overlay layers.

#### Requests:

- **`create_surface`**: Instantiates a new independent display surface (for multiplexer panes, standalone streams, programmatic grids, or raster pixel images).
  - `surface_id` (`string`): Unique client-allocated surface identifier.
  - `type` (`string`): `"pty"` | `"stream"` | `"grid"` | `"pixel"`. Default: `"pty"`.
  - `cols` (`integer`, min 1, optional): Initial width in character cells.
  - `rows` (`integer`, min 1, optional): Initial height in character cells.
  - `scrollback_max_lines` (`integer`, optional): Max scrollback buffer capacity. Default: `10000` (set `0` to disable scrollback).
  - `title` (`string`, optional): Surface title or tab label.
- **`create_layer`**: Instantiates a new overlay layer shell.
  - `layer_id` (`string`): Unique client-allocated layer identifier.
  - `type` (`string`): `"modal"` | `"popup"` | `"drawer"` | `"toast"` | `"custom"`. Default: `"modal"`.
  - `parent_surface` (`string`, optional): Target `surface_id` to scope and clip this layer to. If omitted, layers anchor to the global workspace window.

______________________________________________________________________

### 5.3 `tc_surface` (Composable Surface Interface)

Represents an independent rendering surface (such as a sandboxed legacy PTY pane, a text stream, a 2D grid canvas, or an anchored pixel graphic).

#### Requests:

- **`resize`**: Requests geometry resizing for this surface.
  - `cols` (`integer`, min 1)
  - `rows` (`integer`, min 1)
- **`set_title`**: Sets the surface or tab title.
  - `title` (`string`)
- **`clear_scrollback`**: Clears the scrollback history buffer for this surface without disturbing active cell contents.
- **`put_buffer`**: Updates character cells directly in a `grid` surface using a flat binary buffer ABI payload.
  - `x` (`integer`, default 0, optional): Starting column offset (0-indexed).
  - `y` (`integer`, default 0, optional): Starting row offset (0-indexed).
  - `cols` (`integer`, min 1): Width of the cell buffer region in character cells.
  - `rows` (`integer`, min 1): Height of the cell buffer region in character cells.
  - `format` (`string`): `"compact_v1"` | `"rich_v1"`.
  - `data` (`string`): Base64-encoded contiguous binary cell buffer conforming to the specified format ABI.
- **`write_text`**: Appends text content to a `stream` surface.
  - `text` (`string`): Text content to append.
- **`set_buffer`**: Uploads raster pixel bitmap data to a `pixel` surface.
  - `format` (`string`): `"png"` | `"jpeg"` | `"webp"` | `"rgba32"` | `"shm"`.
  - `data` (`string`): Base64-encoded image payload or shared memory handle token.
  - `width_px` (`integer`, optional): Explicit image width (required for `rgba32`).
  - `height_px` (`integer`, optional): Explicit image height (required for `rgba32`).
  - `stride_bytes` (`integer`, optional): Row byte stride for raw bitmap buffers.
- **`set_anchor`**: Anchors this surface as a subsurface to a parent surface (Wayland `wl_subsurface` model).
  - `parent_surface` (`string`): Target parent `tc_surface` ID.
  - `mode` (`string`): `"cell_relative"` | `"stream_line"` | `"cursor_relative"` | `"absolute_cells"`.
  - `col` (`integer`, optional): Character cell column anchor offset. Default: `0`.
  - `row` (`integer`, optional): Character cell row anchor offset. Default: `0`.
  - `line_id` (`string` | `integer`, optional): Logical line identifier in a `stream` surface (image scrolls smoothly with line history).
  - `z_index` (`integer`, optional): Stacking order relative to parent surface content (`-1` behind text, `1` above text). Default: `0`.
  - `offset_x_px` (`integer`, optional): Subpixel fine-tuning offset in physical pixels. Default: `0`.
  - `offset_y_px` (`integer`, optional): Subpixel fine-tuning offset in physical pixels. Default: `0`.
- **`set_scaling`**: Configures aspect ratio and scaling mode for `pixel` surfaces.
  - `scale_mode` (`string`): `"fit"` | `"fill"` | `"stretch"` | `"pixel_exact"`. Default: `"fit"`.
  - `width_cells` (`integer`, min 1, optional): Target layout bounding width in character cells.
  - `height_cells` (`integer`, min 1, optional): Target layout bounding height in character cells.
- **`set_a11y`**: Sets mandatory accessibility metadata and plain-text fallback representations for graphical surfaces.
  - `alt_text` (`string`): Mandatory human-readable description for screen readers.
  - `fallback_text` (`string`, optional): Plain text representation to emit when user text selections copy across the surface.
  - `role` (`string`, optional): Accessibility role override (default `"image"`).
- **`destroy`**: Destroys the surface, releases compositor memory/GPU textures, and closes any associated child PTY descriptors.

#### Events:

- **`configure`**: Emitted when the surface viewport geometry or cell size changes.
  - `grid_cols` (`integer`)
  - `grid_rows` (`integer`)
  - `cell_width_px` (`integer`)
  - `cell_height_px` (`integer`)
- **`cursor_position`**: Emitted when the surface's active text cursor position moves (useful for synchronizing cursor-anchored overlays).
  - `x` (`integer`): 0-indexed column coordinate.
  - `y` (`integer`): 0-indexed row coordinate.
  - `visible` (`boolean`): Cursor visibility state.
  - `shape` (`string`): `"block"` | `"beam"` | `"underline"`.
- **`buffer_swapped`**: Emitted when a `pty` surface transitions between primary and alternate buffers.
  - `active_buffer` (`string`): `"primary"` | `"alternate"`.
  - `title` (`string`)

______________________________________________________________________

### 5.3.1 Binary Buffer ABI Specification (`compact_v1` & `rich_v1`)

Rather than serializing thousands of nested JSON dictionaries per frame, TC standardizes **two contiguous binary memory ABIs** for updating 2D `grid` surfaces.

These binary buffers are Base64-encoded directly into the `data` field of a single-line `put_buffer` JSON request:

1. **100% SSH & Socket Forwarding Compatible**: Transmits over pure stream sockets without requiring Unix file descriptor passing (`SCM_RIGHTS`) or host-local shared memory.
1. **Zero-Allocation Deserialization**: The compositor decodes the Base64 bytes directly into cell memory in $O(1)$ allocations without traversing dynamic JSON object trees.
1. **SIMD Blitting**: Memory layouts are fixed-size and 32/64-bit aligned, allowing vectorized dirty-region diffing and GPU texture uploads.

Cells are laid out in **row-major order**: the cell at coordinate $(x, y)$ within the bounding box is at byte index: $$\\text{offset} = (y \\times \\text{cols} + x) \\times \\text{sizeof}(\\text{Cell})$$

```
┌────────────────────────────────────────────────────────────────────────┐
│ 1. Compact ABI (`compact_v1`) - 8 Bytes / Cell (Low Memory)            │
│ 0                   1                   2                   3          │
│ 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1        │
│+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+       │
│|                      Unicode Codepoint (u32)                  |       │
│+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+       │
│|   FG Color    |   BG Color    |       Style Flags (u16)       |       │
│+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+       │
└────────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────────┐
│ 2. Rich ABI (`rich_v1`) - 32 Bytes / Cell (Fully Featured)             │
│ 0                   1                   2                   3          │
│ 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1        │
│+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+       │
│|          Content (Codepoint or Grapheme Pool Offset) (u32)    |       │
│+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+       │
│|                     Foreground RGBA (u32)                     |       │
│+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+       │
│|                     Background RGBA (u32)                     |       │
│+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+       │
│|                  Underline Color RGBA (u32)                   |       │
│+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+       │
│|                     Hyperlink ID / Ref (u32)                  |       │
│+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+       │
│|                       Rich Flags (u32)                        |       │
│+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+       │
│| Width |                   Reserved (7 bytes)                  |       │
│+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+       │
└────────────────────────────────────────────────────────────────────────┘
```

#### Tier 1: `compact_v1` (8 Bytes per Cell)

Designed for ultra-low memory footprints, high-throughput log streams, and fast terminal scrolling.

```zig
pub const CompactCell = extern struct {
    /// Unicode scalar value (U+0000..U+10FFFF)
    codepoint: u32,
    /// Foreground ANSI 256-color palette index
    fg_color: u8,
    /// Background ANSI 256-color palette index
    bg_color: u8,
    /// Packed bitflags for styling and attributes
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
    fg_is_palette: bool = true, // 1 = 256-color palette index, 0 = default theme fg
    bg_is_palette: bool = true, // 1 = 256-color palette index, 0 = default theme bg
    reserved: u7 = 0,
};
```

#### Tier 2: `rich_v1` (32 Bytes per Cell)

Designed for modern graphical TUIs, full 24-bit TrueColor RGBA blending, dedicated underline coloring (undercurls), complex grapheme clusters (emojis, ZWJ sequences), and OSC 8 hyperlinks.

```zig
pub const RichCell = extern struct {
    /// Unicode scalar value OR 32-bit offset into attached grapheme cluster pool
    content: u32,
    /// 32-bit RGBA Foreground (0xRRGGBBAA)
    fg_rgba: u32,
    /// 32-bit RGBA Background (0xRRGGBBAA)
    bg_rgba: u32,
    /// 32-bit RGBA Underline color
    ul_rgba: u32,
    /// Hyperlink ID reference (0 = none, >0 references hyperlink URI string pool)
    hyperlink_id: u32,
    /// Extended style flags and underline styling
    flags: RichFlags,
    /// Visual character width (0 for continuation cell of wide glyphs, 1, 2)
    width: u8,
    /// Reserved padding for 64-bit alignment
    reserved: [7]u8 = [_]u8{0} ** 7,
};

pub const UnderlineStyle = enum(u3) {
    none = 0,
    straight = 1,
    double = 2,
    curly = 3,
    dotted = 4,
    dashed = 5,
};

pub const RichFlags = packed struct(u32) {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline_style: UnderlineStyle = .none,
    blink: bool = false,
    reverse: bool = false,
    strikethrough: bool = false,
    overline: bool = false,
    has_grapheme_cluster: bool = false, // 1 = content is string pool offset, 0 = raw codepoint
    is_protected: bool = false,         // Sensitive / password field mask
    reserved: u19 = 0,
};
```

______________________________________________________________________

### 5.4 `tc_layer` (Overlay Surface Interface)

Represents an active or staging overlay layer shell (adapting `wlr-layer-shell` to terminal compositing).

#### Requests:

- **`set_anchor`**: Defines positioning strategy relative to the parent surface or global workspace layout.
  - `mode` (`string`): `"center"` | `"top_left"` | `"top_right"` | `"bottom_left"` | `"bottom_right"` | `"cursor_relative"` | `"stream_inline"` | `"flex"`.
  - `parent_surface` (`string`, optional): Scopes placement and clipping to a specific `tc_surface`. If omitted, defaults to workspace root.
  - `offset_x` (`integer`): Character cell offset (or pixel offset when flagged). Default: `0`.
  - `offset_y` (`integer`): Character cell offset (or pixel offset when flagged). Default: `0`.
- **`set_size`**: Specifies bounding box dimensions in character grid units.
  - `cols` (`integer`, min 1)
  - `rows` (`integer`, min 1)
- **`set_style`**: Configures compositor-level decorative visual properties.
  - `border` (`string`): `"none"` | `"single"` | `"double"` | `"rounded"` | `"heavy"`.
  - `title` (`string`, optional): Header cutout title string.
  - `border_fg` (`string`, optional): Hex color (`"#89b4fa"`) or semantic token.
  - `bg` (`string`, optional): Background fill hex color (`"#1e1e2e"`) or semantic token.
  - `shadow` (`boolean`): Enables drop shadow rendering.
  - `backdrop_dim` (`number`, 0.0 - 1.0, optional): Screen luminance dimming factor.
- **`set_surface`**: Attaches a `tc_surface` (typically of type `grid` or `pixel`) as the visual content of this layer.
  - `surface_id` (`string`): Target `tc_surface` ID.
- **`set_grab`**: Requests modal input grabbing. When `true`, keyboard and pointer events are routed exclusively to this layer until released or dismissed.
  - `grab` (`boolean`): Default `false`.
- **`set_visible`**: Toggles visibility.
  - `visible` (`boolean`)
- **`seal_to_stream`**: Freezes/flattens the layer's current visual state into static text/cells in the target surface's scrollback stream and releases the active layer.
  - `target_surface` (`string`, optional): Target `surface_id` stream.
  - `fallback_text` (`string`, optional): Plain text representation to append to scrollback if cell capture is unavailable.
- **`commit`**: **Atomically commits** all staged changes to the compositor scene graph.
- **`destroy`**: Destroys the layer and frees server-side compositor resources.

#### Events:

- **`dismiss`**: Emitted when the layer is dismissed by user interaction.
  - `reason` (`string`): `"escape_key"` | `"backdrop_click"`.
- **`configure`**: Emitted when the terminal viewport geometry or cell size changes.
  - `grid_cols` (`integer`)
  - `grid_rows` (`integer`)
  - `cell_width_px` (`integer`)
  - `cell_height_px` (`integer`)
- **`key`**: Emitted when a keyboard event is routed to this layer.
  - `key` (`string`): Key symbol (e.g. `"Enter"`, `"Escape"`, `"Tab"`, `"ArrowDown"`, `"a"`).
  - `text` (`string`, optional): UTF-8 text payload if printable.
  - `modifiers` (`object`): `{ "ctrl": bool, "alt": bool, "shift": bool, "meta": bool }`.
- **`mouse`**: Emitted when mouse interaction occurs over this layer.
  - `action` (`string`): `"press"` | `"release"` | `"move"` | `"scroll"`.
  - `col` (`integer`): Layer-relative column coordinate.
  - `row` (`integer`): Layer-relative row coordinate.
  - `button` (`string`, optional): `"left"` | `"middle"` | `"right"`.
  - `modifiers` (`object`): Active keyboard modifiers.
- **`focus`**: Emitted when the layer gains input focus.
- **`blur`**: Emitted when the layer loses input focus.

______________________________________________________________________

## 6. Capability & Property Subsystem

The property and capability system replaces fragile in-band ANSI/OSC escapes (such as `OSC 10/11` color queries, `OSC 0/2` title setting, and `OSC 52` clipboard manipulation) with a structured, out-of-band negotiation and query/setter mechanism.

### 6.1 Connection Handshake & Capability Negotiation

When a client connects to `$TC_SOCK`, it initiates a handshake to discover active interfaces, supported versions, and security policies:

```
 CLIENT                                              TERMINAL COMPOSITOR
 ──────                                              ───────────────────
 [Request] tc_display.hello(client_name="fzf") ───>
                                                    (Evaluates client, config & permissions)
                                               <─── [Event] tc_display.capabilities({
                                                        "protocol_version": 1,
                                                        "emulator": "monstar 1.1.0",
                                                        "interfaces": { "tc_compositor": 1, "tc_surface": 1, "tc_layer": 1 },
                                                        "features": {
                                                          "window_title_mutation": true,
                                                          "theme_customization": true,
                                                          "clipboard_read": true,
                                                          "clipboard_write": true,
                                                          "system_notifications": true,
                                                          "accessibility_tree": true
                                                        }
                                                    })
```

### 6.2 Dynamic Feature Flags & Permissions

| Feature Flag                     | Type      | Description                                             |
| :------------------------------- | :-------- | :------------------------------------------------------ |
| `features.window_title_mutation` | `boolean` | Permission to change window title / subtitle            |
| `features.theme_customization`   | `boolean` | Permission to override theme colors                     |
| `features.clipboard_read`        | `boolean` | Permission to read system clipboard / primary selection |
| `features.clipboard_write`       | `boolean` | Permission to write to system clipboard                 |
| `features.system_notifications`  | `boolean` | Desktop notification capability                         |
| `features.backdrop_blur`         | `boolean` | GPU/software backdrop blur support                      |
| `features.accessibility_tree`    | `boolean` | Native OS accessibility bridge active                   |

If a client attempts to use a disabled or unauthorized capability, the server emits an explicit error event without crashing:

```json
{"object":"tc_display","event":"error","args":{"code":403,"name":"PERMISSION_DENIED","message":"Clipboard reading is disabled by user policy"}}
```

### 6.3 Property Namespaces

| Namespace       | Key                         | Type      | Access       | Description                               |
| :-------------- | :-------------------------- | :-------- | :----------- | :---------------------------------------- |
| **`window`**    | `window.title`              | `string`  | Read / Write | Main terminal window title                |
|                 | `window.subtitle`           | `string`  | Read / Write | Tab or pane subtitle / status line        |
|                 | `window.grid`               | `object`  | Read-only    | `{ "cols": 120, "rows": 40 }`             |
|                 | `window.cell_size`          | `object`  | Read-only    | `{ "width_px": 10, "height_px": 20 }`     |
|                 | `window.scale`              | `number`  | Read-only    | Fractional DPI scale factor (e.g. `1.5`)  |
|                 | `window.focused`            | `boolean` | Read / Watch | Active window focus state                 |
| **`theme`**     | `theme.name`                | `string`  | Read / Write | Active theme name (`"Catppuccin Mocha"`)  |
|                 | `theme.mode`                | `string`  | Read / Watch | Active color mode (`"dark"` \| `"light"`) |
|                 | `theme.bg`                  | `string`  | Read / Write | Default background color (`"#1e1e2e"`)    |
|                 | `theme.fg`                  | `string`  | Read / Write | Default foreground color (`"#cdd6f4"`)    |
|                 | `theme.cursor`              | `string`  | Read / Write | Cursor color hex                          |
|                 | `theme.ansi`                | `array`   | Read / Write | 16 ANSI color hex strings                 |
| **`clipboard`** | `clipboard.text`            | `string`  | Read / Write | System clipboard text                     |
|                 | `clipboard.primary`         | `string`  | Read / Write | Primary selection (middle-click)          |
| **`a11y`**      | `a11y.screen_reader_active` | `boolean` | Read / Watch | Active screen reader / AT-SPI detected    |
|                 | `a11y.high_contrast`        | `boolean` | Read / Watch | User requested high-contrast rendering    |
|                 | `a11y.reduced_motion`       | `boolean` | Read / Watch | User requested disabling animations/fades |

______________________________________________________________________

## 7. Theming, Styling & Cell Attributes

TC uses structured styling tokens and RGB color representations for out-of-band surfaces and layer chrome.

### 7.1 Semantic Theme Tokens

Color and style fields accept either explicit RGB hex strings (`"#89b4fa"`) or standard **Semantic Tokens** resolved dynamically by the terminal against the active user palette:

- **Surfaces**: `theme.bg.base`, `theme.bg.surface`, `theme.bg.elevated`
- **Typography**: `theme.fg.primary`, `theme.fg.muted`
- **Borders**: `theme.border.default`, `theme.border.focused`
- **Accents**: `theme.accent.primary`, `theme.accent.danger`, `theme.accent.warning`, `theme.accent.success`
- **ANSI Palette**: `ansi.<name>` (e.g., `ansi.red`, `ansi.bright_cyan`)

### 7.2 Cascading Priority & Automatic Theme Switching

Visual attributes are resolved in a clear cascading priority:

1. **Compositor Base Defaults**: Built-in fallbacks (e.g. rounded borders, 50% backdrop dim).
1. **Application Semantic Tokens**: App requests `bg: "theme.bg.surface"`, `border_fg: "theme.accent.primary"`.
1. **Application Explicit Overrides**: App specifies concrete RGB hex for syntax/artwork.
1. **End-User Configuration**: User preferences in emulator config (e.g. `monstar.conf`) override defaults.

When the user switches terminal themes (e.g. Dark $\\leftrightarrow$ Light mode), the compositor immediately redraws all token-backed surfaces and layers in the new palette with zero client roundtrips.

______________________________________________________________________

## 8. Accessibility & Assistive Technology (a11y)

Traditional terminals render flat character grids where screen readers (Orca, VoiceOver, NVDA) are blind to floating UI, dialogs, and popups.

Because TC models overlays as explicit layer shells with surface bindings, the terminal emulator directly exposes active layers to native OS accessibility buses (**Linux AT-SPI2 / D-Bus**, **macOS NSAccessibility**, and **Windows UI Automation**).

### 8.1 Layer-Level Semantic Roles

| Layer Type               | Inferred a11y Role  | Screen Reader Behavior                                     |
| :----------------------- | :------------------ | :--------------------------------------------------------- |
| `tc_layer(type="modal")` | `ROLE_DIALOG`       | Focus shifts to dialog; announces title and modal context. |
| `tc_layer(type="toast")` | `ROLE_NOTIFICATION` | Announced as an ephemeral live region event.               |
| `tc_layer(type="popup")` | `ROLE_POPUP_MENU`   | Announced as anchored menu / suggestion list.              |

### 8.2 Accessibility Requirements & Text Fallbacks for Graphics (`pixel` surfaces)

Because raw pixel buffers are opaque bitmaps, TC enforces strict accessibility and clipboard invariants:

1. **Mandatory `alt_text` Requirement**:
   - Every `pixel` surface MUST be configured with `set_a11y(alt_text="...")` upon attachment.
   - Screen readers navigating the character grid announce the alt text when the virtual cursor lands on the image's bounding box.
1. **Plain-Text Selection & Copy Fallback (`fallback_text`)**:
   - When a user highlights and copies terminal text across character cells occupied by a `pixel` surface, the compositor copies `fallback_text` (e.g. `"[Image: loss_chart.png]"`) rather than leaving empty whitespace.

______________________________________________________________________

## 9. End-to-End Interaction Examples

### 9.1 Modal Confirmation Dialog

```
 CLIENT                                              TERMINAL COMPOSITOR
 ──────                                              ───────────────────
 [Request] tc_compositor.create_surface("dlg_grid", type="grid", cols=42, rows=7)
 [Request] tc_compositor.create_layer("confirm_dlg", type="modal")
 [Request] tc_layer.set_surface("confirm_dlg", "dlg_grid")
 [Request] tc_layer.set_anchor("confirm_dlg", "center")
 [Request] tc_layer.set_size("confirm_dlg", 46, 9)
 [Request] tc_layer.set_style("confirm_dlg", border="rounded", title=" Deploy ", backdrop_dim=0.55, shadow=true)
 [Request] tc_layer.set_grab("confirm_dlg", true)
 [Request] tc_surface.put_buffer("dlg_grid", cols=42, rows=7, format="compact_v1", data="UkVBRE1FMjQ...")
 [Request] tc_layer.commit("confirm_dlg")
                                                  ───> (Renders centered modal with dimming)
                                                       (Orca announces dialog)
                                                       (User presses Tab / Enter)
                                                  <─── [Event] tc_layer.key("confirm_dlg", key="Enter")
 [Request] tc_layer.destroy("confirm_dlg")
 [Request] tc_surface.destroy("dlg_grid")
                                                  ───> (Overlays cleared, undamaged VT restored)
```

#### Wire Payloads:

**1. Client Staging & Commit:**

```json
{"object":"tc_compositor","request":"create_surface","args":{"surface_id":"dlg_grid","type":"grid","cols":42,"rows":7}}
{"object":"tc_compositor","request":"create_layer","args":{"layer_id":"confirm_dlg","type":"modal"}}
{"object":"confirm_dlg","request":"set_surface","args":{"surface_id":"dlg_grid"}}
{"object":"confirm_dlg","request":"set_anchor","args":{"mode":"center"}}
{"object":"confirm_dlg","request":"set_size","args":{"cols":46,"rows":9}}
{"object":"confirm_dlg","request":"set_style","args":{"border":"rounded","title":" Deploy to Production ","backdrop_dim":0.55,"shadow":true}}
{"object":"confirm_dlg","request":"set_grab","args":{"grab":true}}
{"object":"dlg_grid","request":"put_buffer","args":{"cols":42,"rows":7,"format":"compact_v1","data":"RAAAAAAAAP8BAAAAAAAAZQAAAAAAAP8BAAAAAAAAcAAAAAAAAP8BAAAAAAAAbAAAAAAAAAD/AQAAAAAAAG8AAAAAAAD/AQAAAAAAAHkAAAAAAAD/AQAAAAAAACAAAAAAAAAA/wEAAAAAAAB2AAAAAAAAAP8BAAAAAAAAMgAAAAAAAP8BAAAAAAAA..."}}
{"object":"confirm_dlg","request":"commit","args":{}}
```

**2. Compositor Event Dispatch (Input Routing):**

```json
{"object":"confirm_dlg","event":"key","args":{"key":"Enter","modifiers":{"ctrl":false,"alt":false,"shift":false,"meta":false}}}
```

**3. Cleanup:**

```json
{"object":"confirm_dlg","request":"destroy","args":{}}
{"object":"dlg_grid","request":"destroy","args":{}}
```

______________________________________________________________________

### 9.2 Cursor-Anchored Autocomplete Dropdown

For inline shell suggestions following active prompt coordinates:

**Client Request:**

```json
{"object":"tc_compositor","request":"create_surface","args":{"surface_id":"ac_grid","type":"grid","cols":30,"rows":4}}
{"object":"tc_compositor","request":"create_layer","args":{"layer_id":"ac_menu","type":"popup"}}
{"object":"ac_menu","request":"set_surface","args":{"surface_id":"ac_grid"}}
{"object":"ac_menu","request":"set_anchor","args":{"mode":"cursor_relative","offset_x":0,"offset_y":1}}
{"object":"ac_menu","request":"set_size","args":{"cols":32,"rows":6}}
{"object":"ac_menu","request":"set_style","args":{"border":"rounded","title":" Suggestions ","shadow":true}}
{"object":"ac_grid","request":"put_buffer","args":{"cols":30,"rows":4,"format":"rich_v1","data":"PgAAAAAAAAD6tIn/AAAAAP8BAAAAAAAAAAAAAAAAZwAAAAAAAAD6tIn/AAAAAP8BAAAAAAAAAAAAAAAAaQAAAAAAAAD6tIn/AAAAAP8BAAAAAAAAAAAAAAAA..."}}
{"object":"ac_menu","request":"commit","args":{}}
```

**Compositor Event on Keypress:**

```json
{"object":"ac_menu","event":"key","args":{"key":"ArrowDown","modifiers":{"ctrl":false,"alt":false,"shift":false,"meta":false}}}
```

______________________________________________________________________

### 9.3 Anchored Pixel Image Subsurface with Accessibility

Displaying an inline plot or diagram pinned to cell coordinates in a parent grid or scrolling log stream:

```json
{"object":"tc_compositor","request":"create_surface","args":{"surface_id":"loss_plot","type":"pixel"}}
{"object":"loss_plot","request":"set_buffer","args":{"format":"png","data":"iVBORw0KGgoAAAANSUhEUgAA..."}}
{"object":"loss_plot","request":"set_scaling","args":{"scale_mode":"fit","width_cells":50,"height_cells":18}}
{"object":"loss_plot","request":"set_anchor","args":{"parent_surface":"main_pane","mode":"cell_relative","col":10,"row":4,"z_index":1}}
{"object":"loss_plot","request":"set_a11y","args":{"alt_text":"Training loss curve decreasing from 2.45 to 0.18 over 50 epochs","fallback_text":"[Plot: epoch_loss.png]"}}
```

______________________________________________________________________

## 10. Protocol Extensibility, Versioning & Evolution

To avoid the stagnation of legacy ANSI sequences while preventing fragmentation across terminal emulators, TC defines a formal extensibility architecture inspired by Wayland protocol development.

### 10.1 The Three-Tier Extensibility Model

Rather than forcing every feature, permission, or hardware capability into the interface registry, TC maintains a strict separation of concerns across three distinct mechanisms:

| Mechanism                           | What It Represents                                                                            | When to Use                                                                                               | Wire Negotiation                                        | Examples                                                                      |
| :---------------------------------- | :-------------------------------------------------------------------------------------------- | :-------------------------------------------------------------------------------------------------------- | :------------------------------------------------------ | :---------------------------------------------------------------------------- |
| **1. Interface Extensions**         | New message types (requests/events), object lifecycles, or architectural abstractions.        | Adding new protocols or subsystem factories (e.g. workspace management, session locking, custom shaders). | Handshake `interfaces` map in `hello` / `capabilities`. | `ext_workspace_v1`, `ext_session_lock_v1`, `zmonstar_blur_v1`                 |
| **2. Capabilities & Feature Flags** | Platform, hardware, or user-security gating on *existing* interfaces without grammar changes. | Gating features that may not be supported on all OS platforms or may be disabled by user security policy. | `features` dictionary in `capabilities` event.          | `features.clipboard_read`, `features.backdrop_blur`, `features.shm_zero_copy` |
| **3. Dynamic Properties**           | Mutable runtime session and terminal state.                                                   | State values that can be queried, mutated, or continuously monitored.                                     | `property_get`, `property_set`, `property_watch`.       | `window.title`, `theme.mode`, `a11y.high_contrast`                            |

#### Architectural Decision Matrix:

- **"Does the feature require new requests, events, or object IDs?"** $\\implies$ **New Interface Extension**.
- **"Does the feature toggle existing request behavior based on user permissions or hardware capabilities?"** $\\implies$ **Feature Flag / Capability**.
- **"Is the value dynamic state that changes during execution?"** $\\implies$ **Dynamic Property**.

______________________________________________________________________

### 10.2 Interface Versioning & Negotiation

Each interface defines an integer version number (starting at `1`). Interface updates follow strict append-only evolution:

1. **The Append-Only Rule**:
   - Version $N+1$ of an interface MAY add new requests and events.
   - Version $N+1$ MUST NOT remove, reorder, or alter the signature of any request or event defined in version $\\le N$.
1. **Version Negotiation**:
   - During the initial connection handshake (`tc_display.hello`), the client provides its supported maximum version for each interface via `requested_interfaces`:
     ```json
     {"object":"tc_display","request":"hello","args":{"client_name":"fzf","requested_interfaces":{"tc_compositor":2,"ext_workspace_v1":1}}}
     ```
   - The server replies in `tc_display.capabilities` with the supported maximum version of each interface available on the host:
     ```json
     {"object":"tc_display","event":"capabilities","args":{"protocol_version":1,"emulator":"monstar 1.1.0","interfaces":{"tc_compositor":2,"tc_surface":1,"tc_layer":1,"ext_workspace_v1":1}}}
     ```
   - The agreed operating version for each interface is $\\min(V\_{\\text{client}}, V\_{\\text{server}})$. Clients and servers MUST NOT emit messages introduced in versions higher than the agreed version.

______________________________________________________________________

### 10.3 Extension Naming & Staging Lifecycle

To allow rapid experimentation without creating permanent legacy baggage, extensions move through three governance tiers (mirroring the Wayland / Khronos staging model):

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. EXPERIMENTAL / VENDOR PROTOTYPES (z<vendor>_<name>_v<N>)     │
│    • Sandbox for new ideas (e.g. zmonstar_color_grading_v1)     │
│    • Breaking changes allowed between minor drafts              │
└────────────────────────────────┬────────────────────────────────┘
                                 │ Consensus & Multi-Emulator Adoption
                                 ▼
┌─────────────────────────────────────────────────────────────────┐
│ 2. STAGED / MULTI-VENDOR EXTENSIONS (ext_<name>_v<N>)           │
│    • Standardized cross-emulator specifications                 │
│    • Joint maintenance (Monstar, Ghostty, WezTerm, Alacritty)   │
│    • Locked wire format, strictly append-only                   │
└────────────────────────────────┬────────────────────────────────┘
                                 │ Universal Industry Adoption
                                 ▼
┌─────────────────────────────────────────────────────────────────┐
│ 3. CORE PROTOCOL (tc_*)                                         │
│    • Foundational primitives (tc_display, tc_surface, tc_layer) │
│    • Guaranteed availability on all TC-compliant display servers│
└─────────────────────────────────────────────────────────────────┘
```

#### Naming Conventions:

- **`tc_*`**: Core specification interfaces. Guaranteed to be present on any compliant terminal compositor.
- **`ext_*`**: Standardized, vendor-neutral extension interfaces approved by the terminal compositor working group (e.g. `ext_workspace_v1`, `ext_palette_v1`).
- **`z<vendor>_*`**: Unstable or experimental vendor extensions (e.g. `zmonstar_custom_shader_v1`). The leading `z` explicitly denotes unstable/draft status.

______________________________________________________________________

### 10.4 Schema Extensibility & Scanner Tooling (`tc-scanner`)

Extension protocols are specified using the same JSON Protocol Schema format as core interfaces. Protocol scanners (such as `tc-scanner` in Zig):

1. Ingest core and extension schema files (e.g. `term-compositor.schema.json` + `ext-workspace-v1.json`).
1. Generate modular, type-safe IPC dispatch tables and client SDK bindings.
1. Automatically generate runtime version negotiation guards so applications gracefully fall back when running against compositors that lack specific extensions.

______________________________________________________________________

## 11. Reference Implementations

- **Protocol Reference Implementation**: Monstar \[`src/compositor/`\](file:///home/erock/dev/term/monstar/src/compositor/) (Zig)
- **High-Throughput PTY Isolation Invariant Suite**: \[`src/compositor/Compositor.zig`\](file:///home/erock/dev/term/monstar/src/compositor/Compositor.zig)
- **Interactive Python Validation Client**: \[`scripts/demo_overlay.py`\](file:///home/erock/dev/term/monstar/scripts/demo_overlay.py)
- **Command Palette Companion**: \[`scripts/command_palette.py`\](file:///home/erock/dev/term/monstar/scripts/command_palette.py)
