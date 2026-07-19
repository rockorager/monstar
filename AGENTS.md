# AGENTS.md

## Amp Orb Environment

If `hostname` is `e2b.local` or `/proc/1/mountinfo` contains `/e2b/`, you are
running in an Amp orb. Treat it as a disposable Linux sandbox, not the user's
local machine.

For new orbs, `.agents/setup` provisions Zig and the headless Wayland debugging
stack. After setup, use `monstar-sway-headless` to start a Sway/wlroots
headless compositor. Useful client-side tools include `grim` for screenshots,
`wf-recorder` for recordings, `wtype` for virtual keyboard input, and
`wl-vptr-click` for virtual pointer clicks.

When recording UI demos in an orb, run the compositor in the shared `dev` tmux
session and point clients at its runtime, usually:

```bash
XDG_RUNTIME_DIR=/tmp/monstar-wayland-run WAYLAND_DISPLAY=wayland-1
```

Save user-reviewable recordings under `.amp/in/artifacts/`. Prefer recording
MP4 with `wf-recorder -f .amp/in/artifacts/name.mp4`; if the video should render
inline on GitHub, also make a small GIF with `ffmpeg` and embed that with
Markdown image syntax. GitHub's public CLI/API does not expose the web UI's
`user-attachments` upload endpoint; a practical CLI-only workaround is to upload
demo media as release assets and link/embed those URLs in the PR body.

## Zig Development

Use `zigdoc` to discover current APIs for the Zig standard library and any third-party dependencies before coding.

Examples:
```bash
zigdoc std.fs
zigdoc std.posix.getuid
zigdoc vaxis.Window
```

## Current Zig Patterns

**ArrayList:**
```zig
var list: std.ArrayList(u32) = .empty;
defer list.deinit(allocator);
try list.append(allocator, 42);
```

**HashMap/StringHashMap (default to unmanaged):**
```zig
var map: std.StringHashMapUnmanaged(u32) = .empty;
defer map.deinit(allocator);
try map.put(allocator, "key", 42);
```

**stdout/stderr writer:**
```zig
var buf: [4096]u8 = undefined;
var writer = std.fs.File.stdout().writer(&buf);
defer writer.interface.flush() catch {};
try writer.interface.print("hello {s}\n", .{"world"});
```

**build.zig executable:**
```zig
b.addExecutable(.{
    .name = "foo",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
```

**JSON writing:**
```zig
var buf: [4096]u8 = undefined;
var writer = std.fs.File.stdout().writer(&buf);
defer writer.interface.flush() catch {};

var jw: std.json.Stringify = .{
    .writer = &writer.interface,
    .options = .{ .whitespace = .indent_2 },
};
try jw.write(my_struct);
```

**Allocating writer:**
```zig
var writer: std.Io.Writer.Allocating = .init(allocator);
defer writer.deinit();
try writer.writer.print("hello {s}", .{"world"});
const output = try writer.toOwnedSlice();
```

## Zig Style

- `camelCase` for functions and methods
- lower-case `snake_case` for variables, parameters, and constants
- `PascalCase` for types, structs, and enums
- prefer `const foo: Type = .{ .field = value };` over `const foo = Type{ .field = value };`
- pass allocators explicitly; use `errdefer` for cleanup on error
- keep tests inline with the code they cover; register them in `src/main.zig`

### Files and Types

- Treat every `.zig` file as a namespace. Make the file itself a type only when
  its root represents one primary stateful abstraction with fields and methods.
- Name a file-backed type `PascalCase.zig`, import it directly with
  `const Widget = @import("Widget.zig");`, and begin it with an optional `//!`
  container doc followed by `const Widget = @This();`. Prefer the concrete type
  name over `Self` so signatures remain clear out of context.
- Use lower-case `snake_case.zig` for namespace modules: related free functions,
  constants, multiple peer types, or package facades. Export named types from
  these modules and import them as `@import("widget.zig").Widget`.
- Do not put a sole `pub const Widget = struct { ... };` inside `Widget.zig`;
  the file root already provides that container. Conversely, do not create a
  file-backed type merely to enforce one-type-per-file organization.
- Preferred file start: `//!` container docs when needed, the file-backed type
  alias when applicable, imports and local aliases, then a scoped logger.

### Comments and Documentation

- Use `//!` at the start of a nontrivial file to document the root namespace or
  file-backed type: its purpose, conceptual model, and major invariants. Omit it
  for trivial facades whose exports make the purpose obvious.
- Use `///` for declaration-level contracts. Document public APIs when the name
  and signature do not fully convey ownership and lifetime, allocation,
  mutation or pointer invalidation, errors or nullability, units and ranges,
  thread safety, side effects, or asserted preconditions. Simple re-exports and
  self-explanatory declarations do not need filler documentation.
- Use `//` for implementation rationale, state invariants, workarounds, and
  signposts for non-obvious algorithm phases. Do not narrate syntax or restate
  the code. Doc comments must not contain notes intended only for maintainers.
- Keep comments accurate when behavior changes. Prefer deleting a stale or
  redundant comment over expanding it.

### File Size

- Cohesion, not line count, decides when to split a file. As review triggers,
  prefer hand-written files below roughly 1,000 lines, actively look for a
  cohesive extraction once a file crosses that size, and treat files above
  roughly 2,000 lines as exceptional. These are not hard limits.
- Split when a file contains independently nameable responsibilities, disjoint
  subsystems, or helpers with their own invariants. Extract a real subordinate
  type, parser, formatter, platform backend, or pure algorithm rather than an
  arbitrary range of methods.
- Keep a large file intact when its declarations jointly implement one cohesive
  type and splitting would add forwarding APIs or make invariants harder to
  follow. Generated code, data tables, and version-specific compatibility
  snapshots are exempt from the size guidance.

## Safety

- Add assertions at API boundaries and state transitions; avoid trivial assertions.
- Keep functions small and push pure computation into helpers.
