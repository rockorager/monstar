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
    var open_parens: usize = 0;
    var close_parens: usize = 0;
    var open_brackets: usize = 0;
    var close_brackets: usize = 0;
    var open_braces: usize = 0;
    var close_braces: usize = 0;
    for (text[payload_start..end_]) |byte| switch (byte) {
        '(' => open_parens += 1,
        ')' => close_parens += 1,
        '[' => open_brackets += 1,
        ']' => close_brackets += 1,
        '{' => open_braces += 1,
        '}' => close_braces += 1,
        else => {},
    };

    var end = end_;
    while (end > payload_start) {
        switch (text[end - 1]) {
            '.', ',' => end -= 1,
            ')' => if (close_parens > open_parens) {
                end -= 1;
                close_parens -= 1;
            } else return end,
            ']' => if (close_brackets > open_brackets) {
                end -= 1;
                close_brackets -= 1;
            } else return end,
            '}' => if (close_braces > open_braces) {
                end -= 1;
                close_braces -= 1;
            } else return end,
            else => return end,
        }
    }
    return end;
}

fn expectMatch(input: []const u8, expected: []const u8) !void {
    const start = std.mem.indexOf(u8, input, expected) orelse return error.InvalidTest;
    const match = find(input, 0) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(start, match.start);
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
    try std.testing.expectEqual(null, find("prefixhttps://example.com", 0));
    try std.testing.expectEqual(null, find("www.example.com", 0));
    try std.testing.expectEqual(null, find("user@example.com", 0));
    try std.testing.expectEqual(null, find("/tmp/example", 0));
    try std.testing.expectEqual(null, find("https://", 0));
    try std.testing.expectEqual(null, find("https:///path", 0));
    try expectMatch("<https://example.com/path>", "https://example.com/path");
    try expectMatch("'mailto:user@example.com'", "mailto:user@example.com");
}

test "automatic link ranges and next link" {
    const text = "before https://example.com then mailto:user@example.com after";
    const first = find(text, 0).?;
    try std.testing.expectEqualStrings("https://example.com", text[first.start..first.end]);
    try std.testing.expectEqual(@as(usize, 7), first.start);
    try std.testing.expectEqual(@as(usize, 26), first.end);

    const second = find(text, first.end).?;
    try std.testing.expectEqualStrings("mailto:user@example.com", text[second.start..second.end]);
    try std.testing.expectEqual(null, find(text, second.end));
    try std.testing.expectEqual(null, find(text, text.len));
}

test "automatic links accept UTF-8 and valid percent escapes" {
    try expectMatch("https://example.com/東京?q=%E2%9C%93", "https://example.com/東京?q=%E2%9C%93");
    try expectMatch("https://example.com/ok%zz", "https://example.com/ok");
}
