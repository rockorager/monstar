//! Pixel parity check between the CPU and Vulkan renderers
//! (`monstar --vk-parity [DIR]`, built with -Dbenchmarks).
//!
//! Drives one terminal through a fixed script of reference screens and
//! incremental updates. After every step it submits the same AsyncRaster job
//! to a CPU raster and to a Vulkan raster, reads the Vulkan canvas back, and
//! compares whole frames. Mismatching frames are written to DIR as PPM files
//! (CPU, GPU and an amplified difference) for inspection.

const std = @import("std");
const vt = @import("ghostty-vt");
const AsyncRaster = @import("AsyncRaster.zig");
const Config = @import("Config.zig");
const Font = @import("Font.zig");
const Renderer = @import("Renderer.zig");
const ScrollDetector = @import("ScrollDetector.zig");
const VulkanRenderer = @import("VulkanRenderer.zig");

const cols = 100;
const rows = 30;
const padding = 7;

const Step = struct {
    name: []const u8,
    input: []const u8 = "",
    detect_scroll: bool = false,
    focused: bool = true,
    overlays: Overlays = .{},
};

const Overlays = struct {
    preedit: ?[]const u8 = null,
    link_hint: ?[]const u8 = null,
    search: ?[]const u8 = null,
    scrollbar: ?Renderer.ScrollbarThumb = null,
    search_range: ?Renderer.LinkRange = null,
    link_range: ?Renderer.LinkRange = null,
    search_rows: ?[2]u16 = null,
    hyperlink_hints: bool = false,
};

const reset = "\x1b[0m\x1b[2J\x1b[H";

const steps = [_]Step{
    .{ .name = "prompt", .input = reset ++
        "\x1b[1;32muser@timbot\x1b[0m:\x1b[1;34m~/src/monstar\x1b[0m$ ls -la\r\n" ++
        "total 128\r\n" ++
        "drwxr-xr-x  8 user user  4096 Nov  7 06:16 \x1b[1;34m.\x1b[0m\r\n" ++
        "-rw-r--r--  1 user user  1062 Nov  7 06:16 \x1b[0mbuild.zig\r\n" ++
        "-rwxr-xr-x  1 user user 98304 Nov  7 06:16 \x1b[1;32mmonstar\x1b[0m\r\n" ++
        "lrwxrwxrwx  1 user user    11 Nov  7 06:16 \x1b[1;36mlatest\x1b[0m -> \x1b[1;34mzig-out\x1b[0m\r\n" ++
        "\x1b[1;32muser@timbot\x1b[0m:\x1b[1;34m~/src/monstar\x1b[0m$ " },
    .{ .name = "styles", .input = reset ++
        "plain \x1b[1mbold\x1b[0m \x1b[3mitalic\x1b[0m \x1b[1;3mbold-italic\x1b[0m \x1b[2mfaint\x1b[0m \x1b[7minverse\x1b[0m\r\n" ++
        "\x1b[4msingle\x1b[0m \x1b[4:2mdouble\x1b[0m \x1b[4:3mcurly\x1b[0m \x1b[4:4mdotted\x1b[0m \x1b[4:5mdashed\x1b[0m \x1b[9mstrike\x1b[0m \x1b[53moverline\x1b[0m\r\n" ++
        "\x1b[4:3;58;2;255;64;64mcolored curly underline\x1b[0m \x1b[38;2;255;128;0;48;2;20;40;80m truecolor \x1b[0m\r\n" ++
        "\x1b[30;47m black on white \x1b[0m \x1b[97;41m white on red \x1b[0m \x1b[33;44m yellow on blue \x1b[0m \x1b[38;5;214;48;5;23m 256 \x1b[0m\r\n" ++
        "\x1b[48;5;16m \x1b[48;5;52m \x1b[48;5;88m \x1b[48;5;124m \x1b[48;5;160m \x1b[48;5;196m \x1b[48;5;202m \x1b[48;5;208m \x1b[48;5;214m \x1b[48;5;220m \x1b[48;5;226m \x1b[0m\r\n" ++
        "\x1b[38;5;196mred\x1b[38;5;46m green\x1b[38;5;21m blue\x1b[38;5;201m magenta\x1b[38;5;51m cyan\x1b[38;5;244m gray\x1b[0m" ++
        "\x1b[10;5H\x1b[2;37;44mfaint on blue\x1b[0m \x1b[1;7;33minverse bold yellow\x1b[0m\x1b[12;1H" },
    .{ .name = "unicode", .input = reset ++
        "Accents: \u{c5}gjpq \u{c9}\u{d1}\u{d5} \u{1fa} \u{150} \u{102} \u{1e9e} e\u{301} a\u{308} n\u{303}\r\n" ++
        "Wide: \u{6f22}\u{5b57}\u{304b}\u{306a} \u{d55c}\u{ae00} | emoji \u{1f600}\u{1f389}\u{1f44d}\u{1f3fd} \u{2764}\u{fe0f}\r\n" ++
        "Box: \u{250c}\u{2500}\u{252c}\u{2500}\u{2510} \u{2554}\u{2550}\u{2557} \u{256d}\u{2500}\u{256e} blocks \u{2580}\u{2584}\u{2588}\u{258c}\u{2590}\u{2591}\u{2592}\u{2593}\r\n" ++
        "     \u{2502} \u{2502} \u{2502} \u{2551} \u{2551} \u{2570}\u{2500}\u{256f} braille \u{2801}\u{2803}\u{2807}\u{280f}\u{281f}\u{283f}\u{287f}\u{28ff}\r\n" ++
        "     \u{2514}\u{2500}\u{2534}\u{2500}\u{2518} \u{255a}\u{2550}\u{255d} powerline \x1b[44m main \x1b[34;43m\u{e0b0}\x1b[30m dirty \x1b[0;33m\u{e0b0}\x1b[0m \u{e0b6}\u{e0b4}\r\n" ++
        "Symbols: \u{f015} \u{f07c} \u{e7a8} \u{f121} -> => != === <= >= ... // \u{2192} \u{2260} \u{221e}\r\n" ++
        "\x1b[42;30m\u{c5}\u{d5}\u{150} on green\x1b[0m \x1b[3;45mitalic fffjjj on magenta\x1b[0m\r\n" },
    .{ .name = "cursor bar unfocused", .input = "\x1b[5 q", .focused = false },
    .{ .name = "cursor underline", .input = "\x1b[3 q" },
    .{ .name = "cursor block", .input = "\x1b[2 qtyped" },
    .{ .name = "typing 1", .input = "l" },
    .{ .name = "typing 2", .input = "s -" },
    .{ .name = "typing 3", .input = "\x08\x08 " },
    .{ .name = "tui redraw", .input = "\x1b[3;1HBox: \u{250c}\u{2500}\u{252c}\u{2500}\u{2510} \u{2554}\u{2550}\u{2557} CHANGED \u{2580}\u{2584}\u{2588}\x1b[9;1H" },
    .{ .name = "scroll 1", .input = "\x1b[30;1H\r\nline one \x1b[31mred\x1b[0m \u{c5}\u{d5}", .detect_scroll = true },
    .{ .name = "scroll 2", .input = "\r\nline two \x1b[42m green bg \x1b[0m gjpq", .detect_scroll = true },
    .{ .name = "scroll 3", .input = "\r\n\u{150}\u{102} overhang at bottom\r\nand one more \u{1f600}", .detect_scroll = true },
    .{ .name = "overlays", .overlays = .{
        .preedit = "\u{65e5}\u{672c}IME",
        .link_hint = "https://example.com/very/long/link",
        .search = "Search (2/7): line",
        .scrollbar = .{ .x = cols * 10, .y = 40.25, .width = 6, .height = 90, .alpha = 160 },
        .search_range = .{ .start = .{ .x = 0, .y = 27 }, .end = .{ .x = 3, .y = 27 } },
        .search_rows = .{ 20, 29 },
        .link_range = .{ .start = .{ .x = 5, .y = 1 }, .end = .{ .x = 20, .y = 1 } },
    } },
    .{ .name = "overlays removed", .input = "x" },
    .{ .name = "kitty", .input = reset ++ "Kitty images:\r\n" },
    .{ .name = "kitty text change", .input = "\x1b[3;1H\x1b[1mtext under and over images\x1b[0m" },
};

pub fn run(init: std.process.Init) !void {
    const alloc = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const out_dir: ?[]const u8 = if (args.len > 2) args[2] else null;

    var config = Config.load(arena, init.minimal.environ);
    try config.resolveThemes(init.io, arena, init.minimal.environ);
    const font_size_px = Config.fontSizePixels(config.font_size, 120);
    var font: Font = try .init(alloc, config.font_family, font_size_px, config.metric_adjustments, config.fontThicken());
    defer font.deinit(alloc);

    var colors = try config.terminalColors(alloc, .dark);
    var term: vt.Terminal = vt.Terminal.init(init.io, alloc, .{ .cols = cols, .rows = rows, .colors = colors }) catch |err| {
        colors.palette.deinit(alloc);
        return err;
    };
    defer term.deinit(alloc);
    const grid_width = font.cell_width * cols;
    const grid_height = font.cell_height * rows;
    const width = grid_width + 2 * padding + 3;
    const height = grid_height + 2 * padding;
    term.width_px = grid_width;
    term.height_px = grid_height;
    var stream = term.vtStream();
    defer stream.deinit();
    var state: vt.RenderState = .empty;
    defer state.deinit(alloc);

    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &out_buf);
    const w = &stdout.interface;
    defer w.flush() catch {};
    try w.print("font {s} {d}px, cell {d}x{d}, surface {d}x{d}\n", .{ config.font_family, font_size_px, font.cell_width, font.cell_height, width, height });

    const vulkan = try VulkanRenderer.create(alloc, .{ .validation = std.mem.eql(u8, getenv(init, "MONSTAR_VK_VALIDATION"), "1") });
    defer vulkan.destroy();

    var total_bad: usize = 0;
    for ([_]u8{ 255, 200 }) |background_alpha| {
        try w.print("\nbackground alpha {d}\n", .{background_alpha});
        stream.nextSlice("\x1bc");
        state.deinit(alloc);
        state = .empty;
        var cpu = try AsyncRaster.init(font.discovery(), config.selection_background orelse Config.dark_theme.selection_background, null, null, null, background_alpha, false, &state);
        defer cpu.deinit();
        var gpu = try AsyncRaster.init(font.discovery(), config.selection_background orelse Config.dark_theme.selection_background, null, null, null, background_alpha, false, &state);
        defer gpu.deinit();
        try cpu.start();
        try gpu.start();

        const pixels = try alloc.alloc(u32, @as(usize, width) * height);
        defer alloc.free(pixels);
        const readback = try alloc.alloc(u32, pixels.len);
        defer alloc.free(readback);
        var detector: ScrollDetector = .{};
        defer detector.deinit(alloc);
        var previous: Overlays = .{};
        var search_mask: std.ArrayList(bool) = .empty;
        defer search_mask.deinit(alloc);

        for (steps, 0..) |step, step_index| {
            const old_cursor = state.cursor;
            stream.nextSlice(step.input);
            if (std.mem.eql(u8, step.name, "kitty")) try sendKittyImages(alloc, &stream);
            const scroll = if (step.detect_scroll and step_index > 0) try detector.detect(alloc, &state, &term) else null;
            try state.update(alloc, &term);
            if (scroll) |value| detector.prepare(&state, value, old_cursor);
            dirtyCursorRow(&state, old_cursor.viewport);
            dirtyCursorRow(&state, state.cursor.viewport);
            const items = try Renderer.collectKittyPlacements(&font, alloc, &term, &state);
            defer alloc.free(items);
            if (items.len > 0 and state.dirty != .false) state.dirty = .full;

            search_mask.clearRetainingCapacity();
            if (step.overlays.search_rows) |range| {
                try search_mask.appendNTimes(alloc, false, @as(usize, rows) * cols);
                for (range[0]..range[1]) |y| for (0..cols) |x| {
                    if ((x / 4) % 3 == 0) search_mask.items[y * cols + x] = true;
                };
            }
            var job: AsyncRaster.Job = .{
                .pixels = pixels,
                .source_pixels = null,
                .width = width,
                .stride = width,
                .height = height,
                .grid_x = padding,
                .grid_y = padding,
                .grid_width = grid_width,
                .grid_height = grid_height,
                .age = 1,
                .generation = step_index,
                .focused = step.focused,
                .hyperlink_hints = step.overlays.hyperlink_hints,
                .link_range = step.overlays.link_range,
                .search_range = step.overlays.search_range,
                .search_matches = search_mask.items,
                .search_background = .{ .r = 0xff, .g = 0xd7, .b = 0x00 },
                .search_foreground = .{ .r = 0, .g = 0, .b = 0 },
                .preedit = step.overlays.preedit,
                .link_hint = step.overlays.link_hint,
                .search = step.overlays.search,
                .search_no_match = false,
                .scrollbar = step.overlays.scrollbar,
                .kitty_items = items,
                .overlay_dirty = !std.meta.eql(previous, step.overlays) or items.len > 0,
                .scroll_shift = if (scroll) |value| value.shift else null,
                .repair = .none,
            };
            // Overlay removal repaints fully, as App does.
            if (previous.scrollbar != null and step.overlays.scrollbar == null) state.dirty = .full;
            previous = step.overlays;
            if (step_index == 0) state.dirty = .full;

            const cpu_damage = try runJob(&cpu, job);
            job.pixels = &.{};
            job.gpu = vulkan;
            const gpu_damage = try runJob(&gpu, job);
            try vulkan.readCanvas(readback);
            for (state.row_data.items(.dirty)) |*dirty| dirty.* = false;
            state.dirty = .false;

            const diff = compare(pixels, readback);
            try w.print("  {s:<22} damage cpu={s:<7} gpu={s:<7} differing {d:>6} px, max channel delta {d}", .{ step.name, @tagName(cpu_damage), @tagName(gpu_damage), diff.count, diff.max_delta });
            if (diff.count > 0) {
                try w.print(" (first at {d},{d}: cpu {x:0>8} gpu {x:0>8})", .{ diff.first % width, diff.first / width, pixels[diff.first], readback[diff.first] });
                total_bad += 1;
                if (out_dir) |dir| try writeDiff(init.io, alloc, dir, background_alpha, step_index, step.name, pixels, readback, width, height);
            }
            try w.writeAll("\n");
        }
    }
    try w.print("\n{d} mismatching frames\n", .{total_bad});
}

fn getenv(init: std.process.Init, name: []const u8) []const u8 {
    return init.minimal.environ.getPosix(name) orelse "";
}

fn runJob(raster: *AsyncRaster, job: AsyncRaster.Job) !AsyncRaster.Damage {
    try raster.submit(job);
    while (true) {
        var fds = [_]std.posix.pollfd{.{ .fd = raster.complete_fd, .events = std.posix.POLL.IN, .revents = 0 }};
        _ = try std.posix.poll(&fds, -1);
        if (raster.takeResult()) |result| {
            if (result.err) |err| return err;
            return result.damage;
        }
    }
}

fn dirtyCursorRow(state: *vt.RenderState, viewport: ?vt.RenderState.Cursor.Viewport) void {
    const row = viewport orelse return;
    if (row.y >= state.row_data.len) return;
    state.row_data.items(.dirty)[row.y] = true;
    if (state.dirty == .false) state.dirty = .partial;
}

const Diff = struct { count: usize = 0, max_delta: u8 = 0, first: usize = 0 };

fn compare(a: []const u32, b: []const u32) Diff {
    var diff: Diff = .{};
    for (a, b, 0..) |pa, pb, i| {
        if (pa == pb) continue;
        if (diff.count == 0) diff.first = i;
        diff.count += 1;
        inline for (.{ 0, 8, 16, 24 }) |shift| {
            const ca: i32 = @intCast(pa >> shift & 0xff);
            const cb: i32 = @intCast(pb >> shift & 0xff);
            diff.max_delta = @max(diff.max_delta, @as(u8, @intCast(@abs(ca - cb))));
        }
    }
    return diff;
}

fn writeDiff(io: std.Io, alloc: std.mem.Allocator, dir: []const u8, alpha: u8, index: usize, name: []const u8, cpu: []const u32, gpu: []const u32, width: u31, height: u31) !void {
    const delta = try alloc.alloc(u32, cpu.len);
    defer alloc.free(delta);
    for (delta, cpu, gpu) |*d, a, b| {
        var out: u32 = 0;
        inline for (.{ 0, 8, 16 }) |shift| {
            const ca: i32 = @intCast(a >> shift & 0xff);
            const cb: i32 = @intCast(b >> shift & 0xff);
            out |= @as(u32, @min(255, @abs(ca - cb) * 64)) << shift;
        }
        if (a >> 24 != b >> 24) out |= 0xff00ff;
        d.* = out;
    }
    for ([_][]const u8{ "cpu", "gpu", "diff" }, [_][]const u32{ cpu, gpu, delta }) |kind, px| {
        var name_buf: [256]u8 = undefined;
        const clean = try alloc.dupe(u8, name);
        defer alloc.free(clean);
        for (clean) |*ch| if (ch.* == ' ') {
            ch.* = '-';
        };
        const path = try std.fmt.bufPrint(&name_buf, "{s}/a{d}-{d:0>2}-{s}-{s}.ppm", .{ dir, alpha, index, clean, kind });
        try writePpm(io, alloc, path, px, width, height);
    }
}

fn writePpm(io: std.Io, alloc: std.mem.Allocator, path: []const u8, pixels: []const u32, width: u31, height: u31) !void {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(alloc);
    try data.print(alloc, "P6\n{d} {d}\n255\n", .{ width, height });
    for (pixels) |px| try data.appendSlice(alloc, &.{ @truncate(px >> 16), @truncate(px >> 8), @truncate(px) });
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, data.items);
}

/// Three placements of one 24×16 RGBA image with an alpha ramp: unscaled
/// above text, scaled over 12×3 cells below text, and scaled below the
/// cell backgrounds.
fn sendKittyImages(alloc: std.mem.Allocator, stream: anytype) !void {
    const iw = 24;
    const ih = 16;
    var rgba: [iw * ih * 4]u8 = undefined;
    for (0..ih) |y| for (0..iw) |x| {
        const p = rgba[(y * iw + x) * 4 ..][0..4];
        p[0] = @intCast(x * 10);
        p[1] = @intCast(y * 15);
        p[2] = @intCast(255 - x * 10);
        p[3] = @intCast(if (x < 4) 255 else @min(255, (y * iw + x) % 256));
    };
    const encoder = std.base64.standard.Encoder;
    const encoded = try alloc.alloc(u8, encoder.calcSize(rgba.len));
    defer alloc.free(encoded);
    _ = encoder.encode(encoded, &rgba);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.print(alloc, "\x1b_Ga=t,f=32,i=7,s={d},v={d},q=2;{s}\x1b\\", .{ iw, ih, encoded });
    try buf.appendSlice(alloc, "\x1b[2;40H\x1b_Ga=p,i=7,p=1,q=2\x1b\\");
    try buf.appendSlice(alloc, "\x1b[2;2H\x1b_Ga=p,i=7,p=2,c=12,r=3,z=-1,q=2\x1b\\");
    try buf.appendSlice(alloc, "\x1b[2;20H\x1b_Ga=p,i=7,p=3,c=8,r=4,z=-1073741825,q=2\x1b\\");
    try buf.appendSlice(alloc, "\x1b[3;1H\x1b[44mtext under and over images, \x1b[0mwith a blue bg\x1b[8;1H");
    stream.nextSlice(buf.items);
}
