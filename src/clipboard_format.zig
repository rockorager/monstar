//! Pure clipboard and drag-and-drop MIME and text formatting policy, plus
//! shared local file URI decoding.

const std = @import("std");
const posix = std.posix;

pub const MimeMask = u32;

const paste_mime = "text/plain;charset=utf-8";
pub const uri_list_mime = "text/uri-list";
pub const paste_mime_preference = [_][:0]const u8{
    paste_mime,
    "text/plain",
    "UTF8_STRING",
    "TEXT",
    "STRING",
};
pub const dnd_mime_preference = [_][:0]const u8{
    uri_list_mime,
    paste_mime,
    "text/plain",
    "UTF8_STRING",
    "TEXT",
    "STRING",
};

pub fn mimeBit(preferences: []const [:0]const u8, mime_type: [*:0]const u8) ?MimeMask {
    const offered = std.mem.span(mime_type);
    for (preferences, 0..) |candidate, i| {
        if (std.mem.eql(u8, offered, candidate[0..candidate.len])) {
            return @as(MimeMask, 1) << @intCast(i);
        }
    }
    return null;
}

pub fn preferredMime(preferences: []const [:0]const u8, mask: MimeMask) ?[*:0]const u8 {
    for (preferences, 0..) |candidate, i| {
        if (mask & (@as(MimeMask, 1) << @intCast(i)) != 0) return candidate.ptr;
    }
    return null;
}

/// Decode an OSC 7 payload (`file://host/path`) into a local filesystem
/// path. Returns null for anything that is not an absolute path on this
/// machine: foreign schemes, remote hosts, malformed URIs.
pub fn osc7Path(arena: std.mem.Allocator, url: []const u8) std.mem.Allocator.Error!?[:0]const u8 {
    const uri = std.Uri.parse(url) catch return null;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "file")) return null;

    if (uri.host) |host| {
        const h = try host.toRawMaybeAlloc(arena);
        if (h.len > 0 and !std.mem.eql(u8, h, "localhost")) {
            var name_buf: [posix.HOST_NAME_MAX]u8 = undefined;
            const hostname = posix.gethostname(&name_buf) catch return null;
            if (!std.mem.eql(u8, h, hostname)) return null;
        }
    }

    const path = try uri.path.toRawMaybeAlloc(arena);
    if (path.len == 0 or path[0] != '/') return null;
    return try arena.dupeZ(u8, path);
}

pub fn formatUriListDrop(alloc: std.mem.Allocator, data: []const u8) ![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var writer: std.Io.Writer.Allocating = .init(alloc);
    errdefer writer.deinit();

    var first = true;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        const line = if (std.mem.endsWith(u8, raw_line, "\r"))
            raw_line[0 .. raw_line.len - 1]
        else
            raw_line;
        if (line.len == 0 or line[0] == '#') continue;
        const path = (try osc7Path(arena, line)) orelse continue;

        if (!first) try writer.writer.writeByte(' ');
        first = false;
        try writeShellQuoted(&writer.writer, path);
    }

    return writer.toOwnedSlice();
}

fn writeShellQuoted(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeByte('\'');
    for (text) |byte| {
        if (byte == '\'') {
            try writer.writeAll("'\\''");
        } else {
            try writer.writeByte(byte);
        }
    }
    try writer.writeByte('\'');
}

test "osc7Path decodes local file URIs" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "/home/tim",
        (try osc7Path(arena, "file:///home/tim")).?,
    );
    try std.testing.expectEqualStrings(
        "/home/tim",
        (try osc7Path(arena, "file://localhost/home/tim")).?,
    );
    try std.testing.expectEqualStrings(
        "/home/tim/my dir",
        (try osc7Path(arena, "file:///home/tim/my%20dir")).?,
    );

    // Remote hosts, foreign schemes, and junk must not produce a path.
    try std.testing.expectEqual(null, try osc7Path(arena, "file://otherhost.example/home/tim"));
    try std.testing.expectEqual(null, try osc7Path(arena, "https://example.com/x"));
    try std.testing.expectEqual(null, try osc7Path(arena, "not a uri"));
    try std.testing.expectEqual(null, try osc7Path(arena, "file://"));
}

test "formatUriListDrop shell quotes local file paths" {
    const text = try formatUriListDrop(
        std.testing.allocator,
        "# comment\r\nfile:///tmp/a%20b\r\nhttps://example.com/nope\nfile:///tmp/it%27s\n",
    );
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings("'/tmp/a b' '/tmp/it'\\''s'", text);
}
