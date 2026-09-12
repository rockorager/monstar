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

/// Encode UTF-8 as an ICCCM STRING selection (Latin-1 plus TAB and NEWLINE).
/// The caller owns the result. Null means the text cannot be represented
/// losslessly and STRING must not be offered for this selection.
pub fn encodeLatin1(alloc: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!?[]u8 {
    const view = std.unicode.Utf8View.init(text) catch return null;
    var it = view.iterator();
    var len: usize = 0;
    while (it.nextCodepoint()) |cp| {
        if (!(cp == '\t' or cp == '\n' or
            (cp >= 0x20 and cp <= 0x7e) or (cp >= 0xa0 and cp <= 0xff))) return null;
        len += 1;
    }
    const result = try alloc.alloc(u8, len);
    it = view.iterator();
    for (result) |*byte| byte.* = @intCast(it.nextCodepoint().?);
    return result;
}

/// Decode an ICCCM STRING selection to UTF-8 for ordinary terminal paste.
/// The caller owns the result; MIME-preserving transfers keep the original bytes.
pub fn decodeLatin1(alloc: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]u8 {
    var len = text.len;
    for (text) |byte| if (byte >= 0x80) {
        len += 1;
    };
    const result = try alloc.alloc(u8, len);
    var offset: usize = 0;
    for (text) |byte| {
        offset += std.unicode.utf8Encode(byte, result[offset..]) catch unreachable;
    }
    return result;
}

test "STRING selections use Latin-1 without replacing unrepresentable text" {
    const cases = [_]struct { text: []const u8, expected: []const u8 }{
        .{ .text = "", .expected = "" },
        .{ .text = "plain\ttext\n", .expected = "plain\ttext\n" },
        .{ .text = "café £ÿ", .expected = "caf\xe9 \xa3\xff" },
    };
    for (cases) |case| {
        const encoded = (try encodeLatin1(std.testing.allocator, case.text)).?;
        defer std.testing.allocator.free(encoded);
        try std.testing.expectEqualStrings(case.expected, encoded);
    }
    for ([_][]const u8{ "€", "Ā", "🙂", "\x00", "\r", "\x7f", "\u{85}", "\xff" }) |text| {
        try std.testing.expectEqual(null, try encodeLatin1(std.testing.allocator, text));
    }
}

/// Decode an OSC 7 payload (`file://host/path`) into a local filesystem
/// path. Returns null for anything that is not an absolute path on this
/// machine: foreign schemes, remote hosts, malformed URIs.
pub fn osc7Path(arena: std.mem.Allocator, url: []const u8) std.mem.Allocator.Error!?[:0]const u8 {
    const uri = std.Uri.parse(url) catch return null;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "file")) return null;

    if (uri.host) |host| {
        const h = try host.toRawMaybeAlloc(arena);
        if (h.len > 0 and !std.ascii.eqlIgnoreCase(h, "localhost")) {
            var name_buf: [posix.HOST_NAME_MAX]u8 = undefined;
            const hostname = posix.gethostname(&name_buf) catch return null;
            if (!std.ascii.eqlIgnoreCase(h, hostname)) return null;
        }
    }

    const path = try uri.path.toRawMaybeAlloc(arena);
    if (path.len == 0 or path[0] != '/' or std.mem.indexOfScalar(u8, path, 0) != null) return null;
    return try arena.dupeZ(u8, path);
}

/// Format a hyperlink for the clipboard, reducing local file URIs to paths.
/// The caller owns the returned text.
pub fn formatLinkCopy(alloc: std.mem.Allocator, url: []const u8) ![:0]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();

    const path = try osc7Path(arena_state.allocator(), url);
    return alloc.dupeZ(u8, path orelse url);
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
        const text = (try osc7Path(arena, line)) orelse uri: {
            _ = std.Uri.parse(line) catch continue;
            if (std.mem.indexOfScalar(u8, line, 0) != null) continue;
            break :uri line;
        };

        if (!first) try writer.writer.writeByte(' ');
        first = false;
        try writeShellQuoted(&writer.writer, text);
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
        "/home/tim",
        (try osc7Path(arena, "file://LOCALHOST/home/tim")).?,
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
    try std.testing.expectEqual(null, try osc7Path(arena, "file:///tmp%00/other"));
}

test "formatLinkCopy reduces local file URIs and preserves other links" {
    const local = try formatLinkCopy(std.testing.allocator, "file://localhost/home/tim/my%20dir");
    defer std.testing.allocator.free(local);
    try std.testing.expectEqualStrings("/home/tim/my dir", local);

    var name_buf: [posix.HOST_NAME_MAX]u8 = undefined;
    const hostname = try posix.gethostname(&name_buf);
    const local_url = try std.fmt.allocPrint(std.testing.allocator, "file://{s}/home/tim", .{hostname});
    defer std.testing.allocator.free(local_url);
    const actual_host = try formatLinkCopy(std.testing.allocator, local_url);
    defer std.testing.allocator.free(actual_host);
    try std.testing.expectEqualStrings("/home/tim", actual_host);

    const remote = try formatLinkCopy(std.testing.allocator, "file://server.example/home/tim");
    defer std.testing.allocator.free(remote);
    try std.testing.expectEqualStrings("file://server.example/home/tim", remote);

    const web = try formatLinkCopy(std.testing.allocator, "https://example.com/a%20b");
    defer std.testing.allocator.free(web);
    try std.testing.expectEqualStrings("https://example.com/a%20b", web);
}

test "formatUriListDrop shell quotes local paths and preserves other URIs" {
    const text = try formatUriListDrop(
        std.testing.allocator,
        "# comment\r\nfile:///tmp/a%20b\r\nhttps://example.com/a?q=one%20two\nfile:///tmp/it%27s\nnot a URI\n",
    );
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings(
        "'/tmp/a b' 'https://example.com/a?q=one%20two' '/tmp/it'\\''s'",
        text,
    );
}
