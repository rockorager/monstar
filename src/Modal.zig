//! A keyboard-driven dialog drawn over the terminal: a title, an optional
//! detail shown exactly (such as a link target), a message, and a row of
//! choices. While a modal is open the terminal behind it gets no input.
//!
//! A modal owns copies of its text, so callers may build one from borrowed
//! strings and a raster job can render a clone while the App keeps handling
//! input. The App decides what each choice means; the modal only tracks the
//! focused choice and reports the one picked.

const Modal = @This();

const std = @import("std");
const vt = @import("ghostty-vt");

pub const Choice = struct {
    label: []const u8,
    /// Lower-case ASCII letter that picks this choice directly.
    key: ?u8 = null,
};

pub const Content = struct {
    title: []const u8,
    /// Shown exactly and wrapped at any character. Control, invisible, and
    /// bidirectional formatting characters, and invalid UTF-8, are shown as
    /// escapes so the text cannot hide or reorder part of itself.
    detail: ?[]const u8 = null,
    /// Explanation wrapped at spaces.
    message: []const u8 = "",
    choices: []const Choice,
    /// Choice focused when the modal opens.
    focused: usize,
    /// Choice Escape picks.
    cancel: usize,
};

pub const KeyResult = union(enum) {
    ignored,
    /// Focus moved; the modal needs a redraw.
    moved,
    /// The choice at this index was picked; the caller closes the modal.
    picked: usize,
};

/// One laid-out line: a prefix of the source text that fits the box. With
/// `ellipsis` the text was cut short and leaves one cell for the mark.
pub const Line = struct {
    text: []const u8 = "",
    ellipsis: bool = false,
};

pub const max_detail_rows = 6;
pub const max_message_rows = 6;
/// Blank cells on each side of a button label.
pub const button_padding = 2;
/// Blank cells between buttons.
pub const button_gap = 2;

const padding_x = 2;
const padding_y = 1;
const min_inner_width = 36;
const max_inner_width = 60;

/// Where everything goes, in grid cells. Rows and columns are absolute.
pub const Layout = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    inner_x: u16,
    inner_width: u16,
    title_y: u16,
    title: Line,
    detail_y: u16,
    detail: [max_detail_rows]Line = @splat(.{}),
    detail_len: u8 = 0,
    message_y: u16,
    message: [max_message_rows]Line = @splat(.{}),
    message_len: u8 = 0,
    buttons_y: u16,
    buttons_x: u16,
};

arena: std.heap.ArenaAllocator,
content: Content,
focused: usize,

pub fn init(gpa: std.mem.Allocator, content: Content) !Modal {
    std.debug.assert(content.choices.len > 0);
    std.debug.assert(content.focused < content.choices.len);
    std.debug.assert(content.cancel < content.choices.len);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const choices = try a.alloc(Choice, content.choices.len);
    for (choices, content.choices) |*dst, src| {
        std.debug.assert(src.key == null or std.ascii.isLower(src.key.?));
        dst.* = .{ .label = try a.dupe(u8, src.label), .key = src.key };
    }
    return .{
        .arena = arena,
        .content = .{
            .title = try a.dupe(u8, content.title),
            .detail = if (content.detail) |detail| try escapeDetail(a, detail) else null,
            .message = try a.dupe(u8, content.message),
            .choices = choices,
            .focused = content.focused,
            .cancel = content.cancel,
        },
        .focused = content.focused,
    };
}

pub fn deinit(self: *Modal) void {
    self.arena.deinit();
}

/// An independent copy, including the focused choice.
pub fn clone(self: *const Modal, gpa: std.mem.Allocator) !Modal {
    // Escaping the detail again is a no-op: escapes are printable ASCII.
    var copy = try init(gpa, self.content);
    copy.focused = self.focused;
    return copy;
}

pub fn eql(a: *const Modal, b: *const Modal) bool {
    if (a.focused != b.focused or a.content.cancel != b.content.cancel) return false;
    if (!std.mem.eql(u8, a.content.title, b.content.title)) return false;
    if (!std.mem.eql(u8, a.content.message, b.content.message)) return false;
    if ((a.content.detail == null) != (b.content.detail == null)) return false;
    if (a.content.detail) |detail| if (!std.mem.eql(u8, detail, b.content.detail.?)) return false;
    if (a.content.choices.len != b.content.choices.len) return false;
    for (a.content.choices, b.content.choices) |x, y| {
        if (x.key != y.key or !std.mem.eql(u8, x.label, y.label)) return false;
    }
    return true;
}

/// Escape cancels, Enter or Space picks the focused choice, Tab and the
/// arrow keys move focus, and a choice's letter picks it directly. Until
/// `armed`, only cancelling works, so keys typed before the modal appeared
/// cannot pick a choice.
pub fn handleKey(self: *Modal, event: vt.input.KeyEvent, armed: bool) KeyResult {
    if (event.action == .release) return .ignored;
    const mods = event.mods;
    if (mods.alt or mods.super) return .ignored;
    if (mods.ctrl) return switch (event.unshifted_codepoint) {
        'c', 'g' => .{ .picked = self.content.cancel },
        else => .ignored,
    };
    if (event.key == .escape) return .{ .picked = self.content.cancel };
    if (!armed) return .ignored;
    switch (event.key) {
        .enter, .numpad_enter, .space => return .{ .picked = self.focused },
        .tab => return self.move(mods.shift),
        .arrow_left => return self.move(true),
        .arrow_right => return self.move(false),
        else => {},
    }
    const cp = event.unshifted_codepoint;
    if (cp == 0 or cp > 0x7f) return .ignored;
    const letter = std.ascii.toLower(@intCast(cp));
    for (self.content.choices, 0..) |choice, i| {
        if (choice.key == letter) return .{ .picked = i };
    }
    return .ignored;
}

fn move(self: *Modal, backward: bool) KeyResult {
    const n = self.content.choices.len;
    self.focused = if (backward) (self.focused + n - 1) % n else (self.focused + 1) % n;
    return .moved;
}

/// Total width of the button row in cells.
pub fn buttonsWidth(choices: []const Choice) u16 {
    var total: usize = 0;
    for (choices, 0..) |choice, i| {
        if (i > 0) total += button_gap;
        total += textWidth(choice.label) + 2 * button_padding;
    }
    return @intCast(@min(total, std.math.maxInt(u16)));
}

/// Center the box in a `cols`×`rows` grid, a little above the middle.
/// Long text wraps; when the grid is too short, the message loses rows first,
/// then the detail, and each cut line ends in an ellipsis.
pub fn layout(self: *const Modal, cols: u16, rows: u16) Layout {
    const content = &self.content;
    const buttons_width = buttonsWidth(content.choices);
    const detail = content.detail orelse "";

    const cap: usize = @min(max_inner_width, cols -| (2 * padding_x + 2));
    var inner: usize = @max(
        min_inner_width,
        textWidth(content.title),
        textWidth(detail),
        textWidth(content.message),
        buttons_width,
    );
    inner = @max(1, @min(inner, cap));

    var result: Layout = .{
        .x = 0,
        .y = 0,
        .width = @intCast(inner + 2 * padding_x),
        .height = 0,
        .inner_x = 0,
        .inner_width = @intCast(inner),
        .title_y = 0,
        .title = fitLine(content.title, inner),
        .detail_y = 0,
        .message_y = 0,
        .buttons_y = 0,
        .buttons_x = 0,
    };
    var detail_len = hardWrap(detail, inner, &result.detail);
    var message_len = wordWrap(content.message, inner, &result.message);

    var height = heightFor(detail_len, message_len);
    while (height > rows) {
        if (message_len > 0) {
            message_len -= 1;
            if (message_len > 0) result.message[message_len - 1] = cut(result.message[message_len - 1].text, inner);
        } else if (detail_len > 1) {
            detail_len -= 1;
            result.detail[detail_len - 1] = cut(result.detail[detail_len - 1].text, inner);
        } else break;
        height = heightFor(detail_len, message_len);
    }
    result.detail_len = @intCast(detail_len);
    result.message_len = @intCast(message_len);
    result.height = @intCast(height);

    result.x = (cols -| result.width) / 2;
    result.y = @intCast((@as(u32, rows -| result.height) * 2) / 5);
    result.inner_x = result.x + padding_x;
    var y = result.y + padding_y;
    result.title_y = y;
    y += 1;
    if (detail_len > 0) {
        result.detail_y = y + 1;
        y += 1 + @as(u16, @intCast(detail_len));
    }
    if (message_len > 0) {
        result.message_y = y + 1;
        y += 1 + @as(u16, @intCast(message_len));
    }
    result.buttons_y = y + 1;
    result.buttons_x = result.inner_x + @as(u16, @intCast(inner -| buttons_width));
    return result;
}

fn heightFor(detail_len: usize, message_len: usize) usize {
    var height: usize = 2 * padding_y + 1 + 2; // title, blank, buttons
    if (detail_len > 0) height += 1 + detail_len;
    if (message_len > 0) height += 1 + message_len;
    return height;
}

/// Display width in cells, one codepoint at a time.
pub fn textWidth(text: []const u8) usize {
    var width: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (it.nextCodepoint()) |cp| width += vt.unicode.codepointWidth(cp);
    return width;
}

/// Byte length of the longest prefix of `text` at most `width` cells wide,
/// keeping zero-width codepoints with the one before them.
fn fit(text: []const u8, width: usize) usize {
    var used: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    var end: usize = 0;
    while (it.nextCodepointSlice()) |slice| {
        const cp = std.unicode.utf8Decode(slice) catch unreachable;
        used += vt.unicode.codepointWidth(cp);
        if (used > width) break;
        end = it.i;
    }
    return end;
}

fn fitLine(text: []const u8, width: usize) Line {
    if (fit(text, width) == text.len) return .{ .text = text };
    return cut(text, width);
}

fn cut(text: []const u8, width: usize) Line {
    return .{ .text = text[0..fit(text, width -| 1)], .ellipsis = true };
}

fn hardWrap(text: []const u8, width: usize, out: []Line) usize {
    var rest = text;
    var n: usize = 0;
    while (rest.len > 0 and n < out.len) : (n += 1) {
        var len = fit(rest, width);
        // A codepoint wider than the box still takes a line of its own.
        if (len == 0) len = std.unicode.utf8ByteSequenceLength(rest[0]) catch 1;
        out[n] = .{ .text = rest[0..len] };
        rest = rest[len..];
    }
    if (rest.len > 0) out[n - 1] = cut(out[n - 1].text, width);
    return n;
}

fn wordWrap(text: []const u8, width: usize, out: []Line) usize {
    var rest = std.mem.trimStart(u8, text, " ");
    var n: usize = 0;
    while (rest.len > 0 and n < out.len) : (n += 1) {
        var len = fit(rest, width);
        if (len == 0) len = std.unicode.utf8ByteSequenceLength(rest[0]) catch 1;
        if (len < rest.len and rest[len] != ' ') {
            if (std.mem.lastIndexOfScalar(u8, rest[0..len], ' ')) |space| {
                if (space > 0) len = space;
            }
        }
        out[n] = .{ .text = std.mem.trimEnd(u8, rest[0..len], " ") };
        rest = std.mem.trimStart(u8, rest[len..], " ");
    }
    if (rest.len > 0) out[n - 1] = cut(out[n - 1].text, width);
    return n;
}

fn escapeDetail(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, text.len);
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 0;
        const cp: ?u21 = if (len != 0 and i + len <= text.len)
            std.unicode.utf8Decode(text[i..][0..len]) catch null
        else
            null;
        if (cp) |value| {
            if (hidesText(value)) {
                try out.print(a, "\\u{{{X}}}", .{value});
            } else {
                try out.appendSlice(a, text[i..][0..len]);
            }
            i += len;
        } else {
            try out.print(a, "\\x{{{X:0>2}}}", .{text[i]});
            i += 1;
        }
    }
    return out.items;
}

/// Characters that render as nothing, break lines, or reorder the text
/// around them.
fn hidesText(cp: u21) bool {
    return switch (cp) {
        0...0x1f, 0x7f...0x9f => true,
        0xad, 0x34f, 0x61c, 0x115f, 0x1160, 0x17b4, 0x17b5, 0x180b...0x180f => true,
        0x200b...0x200f, 0x2028...0x202e, 0x2060...0x206f => true,
        0x3164, 0xfe00...0xfe0f, 0xfeff, 0xffa0, 0xfff0...0xfffb => true,
        0xe0000...0xe0fff => true,
        else => false,
    };
}

fn testModal(detail: ?[]const u8, message: []const u8) !Modal {
    return init(std.testing.allocator, .{
        .title = "Open this link?",
        .detail = detail,
        .message = message,
        .choices = &.{ .{ .label = "Open", .key = 'o' }, .{ .label = "Copy", .key = 'c' }, .{ .label = "Cancel" } },
        .focused = 2,
        .cancel = 2,
    });
}

fn testKey(key: vt.input.Key, codepoint: u21, mods: vt.input.KeyMods) vt.input.KeyEvent {
    return .{ .action = .press, .key = key, .mods = mods, .unshifted_codepoint = codepoint };
}

test "modal detail escapes characters that hide or reorder text" {
    var modal = try testModal("https://a.example/\u{202e}gpj.exe\x1b[0m\xff", "");
    defer modal.deinit();
    try std.testing.expectEqualStrings(
        "https://a.example/\\u{202E}gpj.exe\\u{1B}[0m\\x{FF}",
        modal.content.detail.?,
    );
    var copy = try modal.clone(std.testing.allocator);
    defer copy.deinit();
    try std.testing.expect(copy.eql(&modal));
}

test "modal keys move focus, pick by letter, and cancel" {
    var modal = try testModal(null, "");
    defer modal.deinit();
    // Before arming, only cancelling works.
    try std.testing.expectEqual(KeyResult.ignored, modal.handleKey(testKey(.tab, '\t', .{}), false));
    try std.testing.expectEqual(KeyResult.ignored, modal.handleKey(testKey(.key_o, 'o', .{}), false));
    try std.testing.expectEqual(@as(usize, 2), modal.focused);
    try std.testing.expectEqual(KeyResult{ .picked = 2 }, modal.handleKey(testKey(.escape, 0, .{}), false));
    try std.testing.expectEqual(KeyResult{ .picked = 2 }, modal.handleKey(testKey(.enter, 0, .{}), true));
    try std.testing.expectEqual(KeyResult.moved, modal.handleKey(testKey(.tab, '\t', .{}), true));
    try std.testing.expectEqual(@as(usize, 0), modal.focused);
    try std.testing.expectEqual(KeyResult.moved, modal.handleKey(testKey(.tab, '\t', .{ .shift = true }), true));
    try std.testing.expectEqual(KeyResult.moved, modal.handleKey(testKey(.arrow_left, 0, .{}), true));
    try std.testing.expectEqual(KeyResult{ .picked = 1 }, modal.handleKey(testKey(.space, ' ', .{}), true));
    try std.testing.expectEqual(KeyResult{ .picked = 1 }, modal.handleKey(testKey(.key_c, 'c', .{ .shift = true }), true));
    // Ctrl+C cancels rather than picking Copy, and Ctrl+O does nothing.
    try std.testing.expectEqual(KeyResult{ .picked = 2 }, modal.handleKey(testKey(.key_c, 'c', .{ .ctrl = true }), true));
    try std.testing.expectEqual(KeyResult.ignored, modal.handleKey(testKey(.key_o, 'o', .{ .ctrl = true }), true));
    try std.testing.expectEqual(KeyResult{ .picked = 2 }, modal.handleKey(testKey(.escape, 0, .{}), true));
    try std.testing.expectEqual(KeyResult.ignored, modal.handleKey(testKey(.key_x, 'x', .{}), true));
}

test "modal layout wraps the detail and gives up message rows first" {
    const uri = "steam://run/440//-novid%20-console%20+connect%20203.0.113.7:27015%20+password%20hunter2";
    const message = "Links like this open in whichever app handles them, and the text on screen can differ from where they go.";
    var modal = try testModal(uri, message);
    defer modal.deinit();

    const roomy = modal.layout(120, 40);
    try std.testing.expectEqual(@as(u16, 60), roomy.inner_width);
    try std.testing.expectEqual(@as(u8, 2), roomy.detail_len);
    try std.testing.expectEqualStrings(uri[0..60], roomy.detail[0].text);
    try std.testing.expectEqualStrings(uri[60..], roomy.detail[1].text);
    try std.testing.expectEqual(@as(u8, 2), roomy.message_len);
    try std.testing.expectEqualStrings("Links like this open in whichever app handles them, and the", roomy.message[0].text);
    try std.testing.expect(!roomy.message[1].ellipsis);
    try std.testing.expectEqual(@as(u16, (120 - 64) / 2), roomy.x);
    // Buttons end at the inner right edge.
    try std.testing.expectEqual(roomy.inner_x + roomy.inner_width, roomy.buttons_x + buttonsWidth(modal.content.choices));

    // Narrow and short: the detail wraps more, then rows are cut from the
    // message before the detail, each cut row ending in an ellipsis.
    const tight = modal.layout(30, 9);
    try std.testing.expectEqual(@as(u16, 24), tight.inner_width);
    try std.testing.expectEqual(@as(u8, 0), tight.message_len);
    try std.testing.expectEqual(@as(u8, 3), tight.detail_len);
    try std.testing.expectEqualStrings(uri[24..48], tight.detail[1].text);
    try std.testing.expectEqualStrings(uri[48..71], tight.detail[2].text);
    try std.testing.expect(tight.detail[2].ellipsis);
    try std.testing.expectEqual(@as(u16, 9), tight.height);
}
