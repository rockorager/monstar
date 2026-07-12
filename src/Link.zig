//! Automatic links derived from visible terminal text.

const std = @import("std");

pub const Match = struct {
    start: usize,
    end: usize,
};

const SchemeKind = enum {
    authority,
    file,
    opaque_uri,
};

const Scheme = struct {
    prefix: []const u8,
    kind: SchemeKind,
};

// Keep this in step with the useful URI subset Ghostty recognizes. File
// paths without a scheme are deliberately excluded: opening those correctly
// also requires working-directory resolution and filesystem checks.
const schemes = [_]Scheme{
    .{ .prefix = "https://", .kind = .authority },
    .{ .prefix = "http://", .kind = .authority },
    .{ .prefix = "mailto:", .kind = .opaque_uri },
    .{ .prefix = "ftp://", .kind = .authority },
    .{ .prefix = "file:/", .kind = .file },
    .{ .prefix = "ssh://", .kind = .authority },
    .{ .prefix = "ssh:", .kind = .opaque_uri },
    .{ .prefix = "git://", .kind = .authority },
    .{ .prefix = "tel:", .kind = .opaque_uri },
    .{ .prefix = "magnet:", .kind = .opaque_uri },
    .{ .prefix = "ipfs://", .kind = .authority },
    .{ .prefix = "ipns://", .kind = .authority },
    .{ .prefix = "gemini://", .kind = .authority },
    .{ .prefix = "gopher://", .kind = .authority },
    .{ .prefix = "news:", .kind = .opaque_uri },
};

/// Return the automatic link containing `byte_index`, if any. Matches are
/// byte ranges so callers can use ghostty-vt's byte-to-cell maps directly.
pub fn matchAt(text: []const u8, byte_index: usize) ?Match {
    if (byte_index >= text.len) return null;

    var offset: usize = 0;
    while (find(text, offset)) |match| {
        if (byte_index < match.start) return null;
        if (byte_index < match.end) return match;
        offset = match.end;
    }
    return null;
}

/// Find the first automatic link at or after `offset`.
pub fn find(text: []const u8, offset: usize) ?Match {
    var start = offset;
    while (start < text.len) : (start += 1) {
        if (!std.ascii.isAlphabetic(text[start])) continue;
        if (!hasLeftBoundary(text, start)) continue;

        for (schemes) |scheme| {
            if (start + scheme.prefix.len > text.len) continue;
            if (!std.ascii.eqlIgnoreCase(
                text[start .. start + scheme.prefix.len],
                scheme.prefix,
            )) continue;

            if (matchScheme(text, start, scheme)) |match| return match;
        }
    }
    return null;
}

fn matchScheme(text: []const u8, start: usize, scheme: Scheme) ?Match {
    const payload_start = start + scheme.prefix.len;
    if (payload_start >= text.len) return null;
    if (scheme.kind == .authority and !isAuthorityStart(text[payload_start])) return null;

    var end = payload_start;
    while (end < text.len) {
        const byte = text[end];
        if (byte == '%') {
            if (end + 2 >= text.len or
                !std.ascii.isHex(text[end + 1]) or
                !std.ascii.isHex(text[end + 2])) break;
            end += 3;
            continue;
        }
        if (!isUriByte(byte)) break;
        end += 1;
    }

    end = trimEnd(text, payload_start, end);
    if (end == payload_start) return null;
    return .{ .start = start, .end = end };
}

fn hasLeftBoundary(text: []const u8, start: usize) bool {
    if (start == 0) return true;
    const byte = text[start - 1];
    return byte < 0x80 and
        !std.ascii.isAlphanumeric(byte) and
        byte != '_' and byte != '+' and byte != '-' and byte != '.';
}

fn isAuthorityStart(byte: u8) bool {
    return isUriByte(byte) and switch (byte) {
        '/', ':', '?', '#', ')', ']', '}' => false,
        else => true,
    };
}

fn isUriByte(byte: u8) bool {
    if (byte >= 0x80 or std.ascii.isAlphanumeric(byte)) return true;
    return switch (byte) {
        '-',
        '.',
        '_',
        '~',
        ':',
        '/',
        '?',
        '#',
        '[',
        ']',
        '@',
        '!',
        '$',
        '&',
        '*',
        '+',
        ',',
        ';',
        '=',
        '(',
        ')',
        '{',
        '}',
        => true,
        else => false,
    };
}

fn trimEnd(text: []const u8, payload_start: usize, end_: usize) usize {
    var end = end_;
    while (end > payload_start) {
        switch (text[end - 1]) {
            '.', ',' => end -= 1,
            ')' => if (count(text[payload_start..end], ')') > count(text[payload_start..end], '(')) {
                end -= 1;
            } else return end,
            ']' => if (count(text[payload_start..end], ']') > count(text[payload_start..end], '[')) {
                end -= 1;
            } else return end,
            '}' => if (count(text[payload_start..end], '}') > count(text[payload_start..end], '{')) {
                end -= 1;
            } else return end,
            else => return end,
        }
    }
    return end;
}

fn count(text: []const u8, needle: u8) usize {
    var result: usize = 0;
    for (text) |byte| result += @intFromBool(byte == needle);
    return result;
}

fn expectMatch(input: []const u8, expected: []const u8) !void {
    const start = std.mem.indexOf(u8, input, expected) orelse return error.InvalidTest;
    const match = matchAt(input, start + expected.len / 2) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(expected, input[match.start..match.end]);
}

test "automatic link schemes" {
    const cases = [_][]const u8{
        "https://example.com/a?b=c#d",
        "http://[::1]:8080/",
        "mailto:user@example.com",
        "ftp://example.com/pub/file",
        "file:///tmp/example.txt",
        "ssh:user@example.com",
        "ssh://user@example.com:22",
        "git://example.com/repo.git",
        "tel:+18005551234",
        "magnet:?xt=urn:btih:1234",
        "ipfs://QmHash",
        "ipns://example.com",
        "gemini://example.com/page",
        "gopher://example.com/1",
        "news:comp.infosystems.www.servers.unix",
    };
    for (cases) |case| try expectMatch(case, case);
    try expectMatch("open HTTPS://EXAMPLE.COM/Path", "HTTPS://EXAMPLE.COM/Path");
}

test "automatic links trim prose punctuation and unmatched brackets" {
    try expectMatch("see https://example.com.", "https://example.com");
    try expectMatch("see (https://example.com), now", "https://example.com");
    try expectMatch(
        "https://en.wikipedia.org/wiki/Rust_(video_game)",
        "https://en.wikipedia.org/wiki/Rust_(video_game)",
    );
    try expectMatch("[https://example.com/a[b]]", "https://example.com/a[b]");
}

test "automatic links respect boundaries and delimiters" {
    try std.testing.expectEqual(null, matchAt("prefixhttps://example.com", 12));
    try std.testing.expectEqual(null, matchAt("www.example.com", 4));
    try std.testing.expectEqual(null, matchAt("user@example.com", 6));
    try std.testing.expectEqual(null, matchAt("/tmp/example", 6));
    try std.testing.expectEqual(null, matchAt("https://", 2));
    try std.testing.expectEqual(null, matchAt("https:///path", 9));
    try expectMatch("<https://example.com/path>", "https://example.com/path");
    try expectMatch("'mailto:user@example.com'", "mailto:user@example.com");
}

test "automatic link match contains only its cells" {
    const text = "before https://example.com after";
    try std.testing.expectEqual(null, matchAt(text, 2));
    const match = matchAt(text, 15).?;
    try std.testing.expectEqualStrings("https://example.com", text[match.start..match.end]);
    try std.testing.expectEqual(null, matchAt(text, match.end));
}

test "automatic links accept UTF-8 and valid percent escapes" {
    try expectMatch("https://example.com/東京?q=%E2%9C%93", "https://example.com/東京?q=%E2%9C%93");
    try expectMatch("https://example.com/ok%zz", "https://example.com/ok");
}
