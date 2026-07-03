//! Keyboard state: wraps xkbcommon keymap/state handling and translates
//! Wayland key events into ghostty-vt KeyEvents.

const Keyboard = @This();

const std = @import("std");
const posix = std.posix;
const c = @import("c");
const vt = @import("ghostty-vt");

const log = std.log.scoped(.keyboard);

context: *c.xkb_context,
keymap: ?*c.xkb_keymap,
state: ?*c.xkb_state,
mod_indices: ModIndices,
mod_sides: ModSides,

/// Resolved xkb modifier indices for the current keymap.
const ModIndices = struct {
    shift: c.xkb_mod_index_t = c.XKB_MOD_INVALID,
    ctrl: c.xkb_mod_index_t = c.XKB_MOD_INVALID,
    alt: c.xkb_mod_index_t = c.XKB_MOD_INVALID,
    super: c.xkb_mod_index_t = c.XKB_MOD_INVALID,
    caps_lock: c.xkb_mod_index_t = c.XKB_MOD_INVALID,
    num_lock: c.xkb_mod_index_t = c.XKB_MOD_INVALID,
};

const ModSides = struct {
    shift_left: bool = false,
    shift_right: bool = false,
    ctrl_left: bool = false,
    ctrl_right: bool = false,
    alt_left: bool = false,
    alt_right: bool = false,
    super_left: bool = false,
    super_right: bool = false,
};

pub fn init() !Keyboard {
    const context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS) orelse
        return error.XkbInitFailed;
    return .{
        .context = context,
        .keymap = null,
        .state = null,
        .mod_indices = .{},
        .mod_sides = .{},
    };
}

pub fn deinit(self: *Keyboard) void {
    if (self.state) |state| c.xkb_state_unref(state);
    if (self.keymap) |keymap| c.xkb_keymap_unref(keymap);
    c.xkb_context_unref(self.context);
    self.* = undefined;
}

/// Load the keymap the compositor sent us (wl_keyboard.keymap event).
/// Takes ownership of `fd`.
pub fn setKeymap(self: *Keyboard, fd: i32, size: u32) !void {
    defer _ = std.os.linux.close(fd);

    const data = try posix.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
    defer posix.munmap(data);

    const keymap = c.xkb_keymap_new_from_buffer(
        self.context,
        data.ptr,
        // The size includes a terminating NUL that must be excluded.
        size - 1,
        c.XKB_KEYMAP_FORMAT_TEXT_V1,
        c.XKB_KEYMAP_COMPILE_NO_FLAGS,
    ) orelse return error.KeymapParseFailed;
    errdefer c.xkb_keymap_unref(keymap);

    try self.installKeymap(keymap);
    log.debug("keymap loaded", .{});
}

/// Take ownership of `keymap` and derive fresh state from it.
fn installKeymap(self: *Keyboard, keymap: *c.xkb_keymap) !void {
    const state = c.xkb_state_new(keymap) orelse return error.KeymapParseFailed;
    if (self.state) |old| c.xkb_state_unref(old);
    if (self.keymap) |old| c.xkb_keymap_unref(old);
    self.keymap = keymap;
    self.state = state;
    self.mod_sides = .{};
    self.mod_indices = .{
        .shift = c.xkb_keymap_mod_get_index(keymap, c.XKB_MOD_NAME_SHIFT),
        .ctrl = c.xkb_keymap_mod_get_index(keymap, c.XKB_MOD_NAME_CTRL),
        .alt = c.xkb_keymap_mod_get_index(keymap, c.XKB_MOD_NAME_ALT),
        .super = c.xkb_keymap_mod_get_index(keymap, c.XKB_MOD_NAME_LOGO),
        .caps_lock = c.xkb_keymap_mod_get_index(keymap, c.XKB_MOD_NAME_CAPS),
        .num_lock = c.xkb_keymap_mod_get_index(keymap, c.XKB_MOD_NAME_NUM),
    };
}

/// Whether the key should repeat while held (letters yes, shift no).
pub fn keyRepeats(self: *Keyboard, evdev_keycode: u32) bool {
    const keymap = self.keymap orelse return false;
    return c.xkb_keymap_key_repeats(keymap, evdev_keycode + 8) == 1;
}

/// Apply a wl_keyboard.modifiers event.
pub fn updateMods(self: *Keyboard, depressed: u32, latched: u32, locked: u32, group: u32) void {
    const state = self.state orelse return;
    _ = c.xkb_state_update_mask(state, depressed, latched, locked, 0, 0, group);
}

/// Translate a wl_keyboard.key event into a ghostty-vt KeyEvent.
/// `utf8_buf` backs the returned event's utf8 slice.
pub fn translate(
    self: *Keyboard,
    utf8_buf: []u8,
    evdev_keycode: u32,
    action: vt.input.KeyAction,
) ?vt.input.KeyEvent {
    const state = self.state orelse return null;
    const keymap = self.keymap orelse return null;
    const keycode: c.xkb_keycode_t = evdev_keycode + 8;
    const key = evdevToKey(evdev_keycode);
    self.updateModSides(key, action);

    const utf8_len_c = c.xkb_state_key_get_utf8(state, keycode, utf8_buf.ptr, utf8_buf.len);
    const utf8_len: usize = if (utf8_len_c > 0) @intCast(utf8_len_c) else 0;
    // Don't send most control characters as text; the encoder derives
    // them from the physical key. Plain Tab is the exception: ghostty-vt's
    // legacy encoder expects the tab byte in utf8 when no modifiers are held.
    const utf8: []const u8 = if (utf8_len == 1 and utf8_buf[0] < 0x20 and utf8_buf[0] != '\t')
        ""
    else
        utf8_buf[0..utf8_len];

    // The codepoint this key produces with no modifiers (shift level 0).
    const unshifted: u21 = unshifted: {
        const layout = c.xkb_state_key_get_layout(state, keycode);
        var syms: [*c]const c.xkb_keysym_t = undefined;
        const n = c.xkb_keymap_key_get_syms_by_level(keymap, keycode, layout, 0, &syms);
        if (n < 1) break :unshifted 0;
        break :unshifted @intCast(c.xkb_keysym_to_utf32(syms[0]) & 0x1f_ffff);
    };

    const consumed_mask = c.xkb_state_key_get_consumed_mods2(
        state,
        keycode,
        c.XKB_CONSUMED_MODE_GTK,
    );

    return .{
        .action = action,
        .key = key,
        .mods = self.currentModsForKey(key, action),
        .consumed_mods = self.modsFromMask(consumed_mask),
        .composing = false,
        .utf8 = utf8,
        .unshifted_codepoint = unshifted,
    };
}

pub fn currentMods(self: *Keyboard) vt.input.KeyMods {
    const state = self.state orelse return .{};
    const mask = c.xkb_state_serialize_mods(state, c.XKB_STATE_MODS_EFFECTIVE);
    var mods = self.modsFromMask(mask);
    self.applyTrackedSides(&mods);
    return mods;
}

fn currentModsForKey(self: *Keyboard, key: vt.input.Key, action: vt.input.KeyAction) vt.input.KeyMods {
    var mods = self.currentMods();
    const pressed = action != .release;
    switch (key) {
        .shift_left => {
            mods.shift = pressed;
            mods.sides.shift = .left;
        },
        .shift_right => {
            mods.shift = pressed;
            mods.sides.shift = .right;
        },
        .control_left => {
            mods.ctrl = pressed;
            mods.sides.ctrl = .left;
        },
        .control_right => {
            mods.ctrl = pressed;
            mods.sides.ctrl = .right;
        },
        .alt_left => {
            mods.alt = pressed;
            mods.sides.alt = .left;
        },
        .alt_right => {
            mods.alt = pressed;
            mods.sides.alt = .right;
        },
        .meta_left => {
            mods.super = pressed;
            mods.sides.super = .left;
        },
        .meta_right => {
            mods.super = pressed;
            mods.sides.super = .right;
        },
        else => {},
    }
    return mods;
}

fn updateModSides(self: *Keyboard, key: vt.input.Key, action: vt.input.KeyAction) void {
    const pressed = action != .release;
    switch (key) {
        .shift_left => self.mod_sides.shift_left = pressed,
        .shift_right => self.mod_sides.shift_right = pressed,
        .control_left => self.mod_sides.ctrl_left = pressed,
        .control_right => self.mod_sides.ctrl_right = pressed,
        .alt_left => self.mod_sides.alt_left = pressed,
        .alt_right => self.mod_sides.alt_right = pressed,
        .meta_left => self.mod_sides.super_left = pressed,
        .meta_right => self.mod_sides.super_right = pressed,
        else => {},
    }
}

fn applyTrackedSides(self: *Keyboard, mods: *vt.input.KeyMods) void {
    if (mods.shift) mods.sides.shift = if (self.mod_sides.shift_right) .right else .left;
    if (mods.ctrl) mods.sides.ctrl = if (self.mod_sides.ctrl_right) .right else .left;
    if (mods.alt) mods.sides.alt = if (self.mod_sides.alt_right) .right else .left;
    if (mods.super) mods.sides.super = if (self.mod_sides.super_right) .right else .left;
}

fn modsFromMask(self: *Keyboard, mask: c.xkb_mod_mask_t) vt.input.KeyMods {
    const idx = self.mod_indices;
    return .{
        .shift = bitSet(mask, idx.shift),
        .ctrl = bitSet(mask, idx.ctrl),
        .alt = bitSet(mask, idx.alt),
        .super = bitSet(mask, idx.super),
        .caps_lock = bitSet(mask, idx.caps_lock),
        .num_lock = bitSet(mask, idx.num_lock),
    };
}

fn bitSet(mask: c.xkb_mod_mask_t, index: c.xkb_mod_index_t) bool {
    if (index == c.XKB_MOD_INVALID) return false;
    return mask & (@as(c.xkb_mod_mask_t, 1) << @intCast(index)) != 0;
}

/// Map an evdev keycode (linux/input-event-codes.h) to the physical key
/// enum used by ghostty-vt. Unknown keys become .unidentified, which is
/// fine: the encoder falls back to the utf8/codepoint fields.
fn evdevToKey(keycode: u32) vt.input.Key {
    return switch (keycode) {
        1 => .escape,
        2 => .digit_1,
        3 => .digit_2,
        4 => .digit_3,
        5 => .digit_4,
        6 => .digit_5,
        7 => .digit_6,
        8 => .digit_7,
        9 => .digit_8,
        10 => .digit_9,
        11 => .digit_0,
        12 => .minus,
        13 => .equal,
        14 => .backspace,
        15 => .tab,
        16 => .key_q,
        17 => .key_w,
        18 => .key_e,
        19 => .key_r,
        20 => .key_t,
        21 => .key_y,
        22 => .key_u,
        23 => .key_i,
        24 => .key_o,
        25 => .key_p,
        26 => .bracket_left,
        27 => .bracket_right,
        28 => .enter,
        29 => .control_left,
        30 => .key_a,
        31 => .key_s,
        32 => .key_d,
        33 => .key_f,
        34 => .key_g,
        35 => .key_h,
        36 => .key_j,
        37 => .key_k,
        38 => .key_l,
        39 => .semicolon,
        40 => .quote,
        41 => .backquote,
        42 => .shift_left,
        43 => .backslash,
        44 => .key_z,
        45 => .key_x,
        46 => .key_c,
        47 => .key_v,
        48 => .key_b,
        49 => .key_n,
        50 => .key_m,
        51 => .comma,
        52 => .period,
        53 => .slash,
        54 => .shift_right,
        55 => .numpad_multiply,
        56 => .alt_left,
        57 => .space,
        58 => .caps_lock,
        59 => .f1,
        60 => .f2,
        61 => .f3,
        62 => .f4,
        63 => .f5,
        64 => .f6,
        65 => .f7,
        66 => .f8,
        67 => .f9,
        68 => .f10,
        69 => .num_lock,
        70 => .scroll_lock,
        71 => .numpad_7,
        72 => .numpad_8,
        73 => .numpad_9,
        74 => .numpad_subtract,
        75 => .numpad_4,
        76 => .numpad_5,
        77 => .numpad_6,
        78 => .numpad_add,
        79 => .numpad_1,
        80 => .numpad_2,
        81 => .numpad_3,
        82 => .numpad_0,
        83 => .numpad_decimal,
        87 => .f11,
        88 => .f12,
        96 => .numpad_enter,
        97 => .control_right,
        98 => .numpad_divide,
        99 => .print_screen,
        100 => .alt_right,
        102 => .home,
        103 => .arrow_up,
        104 => .page_up,
        105 => .arrow_left,
        106 => .arrow_right,
        107 => .end,
        108 => .arrow_down,
        109 => .page_down,
        110 => .insert,
        111 => .delete,
        119 => .pause,
        125 => .meta_left,
        126 => .meta_right,
        127 => .context_menu,
        else => .unidentified,
    };
}

test "evdev mapping covers the basics" {
    try std.testing.expectEqual(vt.input.Key.key_a, evdevToKey(30));
    try std.testing.expectEqual(vt.input.Key.enter, evdevToKey(28));
    try std.testing.expectEqual(vt.input.Key.arrow_up, evdevToKey(103));
    try std.testing.expectEqual(vt.input.Key.unidentified, evdevToKey(9999));
}

test "keyboard init" {
    var kb: Keyboard = try .init();
    defer kb.deinit();
    try std.testing.expect(kb.state == null);
}

/// Build a keyboard with the system default (US-ish) keymap, no compositor.
fn testKeyboard() !Keyboard {
    var kb: Keyboard = try .init();
    errdefer kb.deinit();
    const keymap = c.xkb_keymap_new_from_names(kb.context, null, c.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse
        return error.KeymapParseFailed;
    try kb.installKeymap(keymap);
    return kb;
}

test "translate and encode: plain, shifted, control" {
    const vt_input = vt.input;
    var kb = testKeyboard() catch return error.SkipZigTest;
    defer kb.deinit();

    var utf8_buf: [16]u8 = undefined;
    var out_buf: [64]u8 = undefined;

    // Plain 'a' (evdev 30).
    {
        const event = kb.translate(&utf8_buf, 30, .press).?;
        try std.testing.expectEqualStrings("a", event.utf8);
        try std.testing.expectEqual(vt_input.Key.key_a, event.key);
        try std.testing.expectEqual(@as(u21, 'a'), event.unshifted_codepoint);

        var writer: std.Io.Writer = .fixed(&out_buf);
        try vt_input.encodeKey(&writer, event, .{});
        try std.testing.expectEqualStrings("a", writer.buffered());
    }

    // Shift+a -> "A" (left shift is evdev 42, xkb keycode 50).
    {
        _ = c.xkb_state_update_key(kb.state.?, 42 + 8, c.XKB_KEY_DOWN);
        defer _ = c.xkb_state_update_key(kb.state.?, 42 + 8, c.XKB_KEY_UP);
        _ = kb.translate(&utf8_buf, 42, .press).?;

        const event = kb.translate(&utf8_buf, 30, .press).?;
        try std.testing.expectEqualStrings("A", event.utf8);
        try std.testing.expect(event.mods.shift);
        try std.testing.expectEqual(.left, event.mods.sides.shift);
        try std.testing.expect(event.consumed_mods.shift);

        var writer: std.Io.Writer = .fixed(&out_buf);
        try vt_input.encodeKey(&writer, event, .{});
        try std.testing.expectEqualStrings("A", writer.buffered());
    }

    // Ctrl+a -> 0x01 (left ctrl is evdev 29).
    {
        _ = c.xkb_state_update_key(kb.state.?, 29 + 8, c.XKB_KEY_DOWN);
        defer _ = c.xkb_state_update_key(kb.state.?, 29 + 8, c.XKB_KEY_UP);

        const event = kb.translate(&utf8_buf, 30, .press).?;
        try std.testing.expect(event.mods.ctrl);

        var writer: std.Io.Writer = .fixed(&out_buf);
        try vt_input.encodeKey(&writer, event, .{});
        try std.testing.expectEqualStrings("\x01", writer.buffered());
    }

    // Enter (evdev 28) -> CR.
    {
        const event = kb.translate(&utf8_buf, 28, .press).?;
        var writer: std.Io.Writer = .fixed(&out_buf);
        try vt_input.encodeKey(&writer, event, .{});
        try std.testing.expectEqualStrings("\r", writer.buffered());
    }

    // Tab (evdev 15) must keep its C0 utf8 byte; ghostty-vt's
    // legacy encoder uses it for unmodified Tab.
    {
        const event = kb.translate(&utf8_buf, 15, .press).?;
        try std.testing.expectEqualStrings("\t", event.utf8);
        try std.testing.expectEqual(vt_input.Key.tab, event.key);

        var writer: std.Io.Writer = .fixed(&out_buf);
        try vt_input.encodeKey(&writer, event, .{});
        try std.testing.expectEqualStrings("\t", writer.buffered());
    }

    // Shift+Tab -> CSI Z.
    {
        _ = c.xkb_state_update_key(kb.state.?, 42 + 8, c.XKB_KEY_DOWN);
        defer _ = c.xkb_state_update_key(kb.state.?, 42 + 8, c.XKB_KEY_UP);
        _ = kb.translate(&utf8_buf, 42, .press).?;

        const event = kb.translate(&utf8_buf, 15, .press).?;
        try std.testing.expect(event.mods.shift);
        try std.testing.expectEqual(.left, event.mods.sides.shift);

        var writer: std.Io.Writer = .fixed(&out_buf);
        try vt_input.encodeKey(&writer, event, .{});
        try std.testing.expectEqualStrings("\x1b[Z", writer.buffered());
    }

    // Right Shift is preserved in the side metadata too.
    {
        _ = c.xkb_state_update_key(kb.state.?, 54 + 8, c.XKB_KEY_DOWN);
        defer _ = c.xkb_state_update_key(kb.state.?, 54 + 8, c.XKB_KEY_UP);
        _ = kb.translate(&utf8_buf, 54, .press).?;

        const event = kb.translate(&utf8_buf, 15, .press).?;
        try std.testing.expect(event.mods.shift);
        try std.testing.expectEqual(.right, event.mods.sides.shift);

        var writer: std.Io.Writer = .fixed(&out_buf);
        try vt_input.encodeKey(&writer, event, .{});
        try std.testing.expectEqualStrings("\x1b[Z", writer.buffered());
    }

    // Arrow up (evdev 103) -> CSI A.
    {
        const event = kb.translate(&utf8_buf, 103, .press).?;
        var writer: std.Io.Writer = .fixed(&out_buf);
        try vt_input.encodeKey(&writer, event, .{});
        try std.testing.expectEqualStrings("\x1b[A", writer.buffered());
    }
}
