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
    const keysym = c.xkb_state_key_get_one_sym(state, keycode);
    const key = remapKey(
        evdevToKey(evdev_keycode),
        keysym,
    );
    self.updateModSides(key, action);

    const utf8_len_c = c.xkb_state_key_get_utf8(state, keycode, utf8_buf.ptr, utf8_buf.len);
    const utf8_len: usize = if (utf8_len_c > 0) @intCast(utf8_len_c) else 0;
    // Don't send most control characters as text; the encoder derives
    // them from the resolved key. Plain Tab is the exception: ghostty-vt's
    // legacy encoder expects the tab byte in utf8 when no modifiers are held.
    const utf8: []const u8 = if (utf8_len == 1 and utf8_buf[0] < 0x20 and utf8_buf[0] != '\t')
        ""
    else
        utf8_buf[0..utf8_len];

    // The encoder's base codepoint: a Kitty functional PUA code for entries
    // missing upstream, or the key's ordinary shift level 0 codepoint.
    const unshifted: u21 = unshifted: {
        // The pinned ghostty-vt predates some Kitty functional-key entries,
        // but its generic CSI-u fallback accepts their protocol PUA codes here.
        if (kittyFunctionalCode(keysym)) |code| break :unshifted code;

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

/// Use XKB remaps for functional keys while keeping writing-system keys
/// physical so shortcuts remain layout-independent.
fn remapKey(physical: vt.input.Key, keysym: c.xkb_keysym_t) vt.input.Key {
    const remapped = keyFromKeysym(keysym) orelse return physical;
    if (physical.shouldBeRemappable() or remapped.shouldBeRemappable()) return remapped;
    return physical;
}

fn keyFromKeysym(keysym: c.xkb_keysym_t) ?vt.input.Key {
    return switch (keysym) {
        c.XKB_KEY_Up => .arrow_up,
        c.XKB_KEY_Down => .arrow_down,
        c.XKB_KEY_Right => .arrow_right,
        c.XKB_KEY_Left => .arrow_left,
        c.XKB_KEY_Home => .home,
        c.XKB_KEY_End => .end,
        c.XKB_KEY_Insert => .insert,
        c.XKB_KEY_Delete => .delete,
        c.XKB_KEY_Caps_Lock, c.XKB_KEY_Shift_Lock => .caps_lock,
        c.XKB_KEY_Scroll_Lock => .scroll_lock,
        c.XKB_KEY_Num_Lock => .num_lock,
        c.XKB_KEY_Prior => .page_up,
        c.XKB_KEY_Next => .page_down,
        c.XKB_KEY_Escape => .escape,
        c.XKB_KEY_Return => .enter,
        c.XKB_KEY_Tab, c.XKB_KEY_ISO_Left_Tab => .tab,
        c.XKB_KEY_BackSpace => .backspace,
        c.XKB_KEY_Print => .print_screen,
        c.XKB_KEY_Pause => .pause,
        c.XKB_KEY_Menu, c.XKB_KEY_XF86ContextMenu => .context_menu,
        c.XKB_KEY_Help => .help,
        c.XKB_KEY_Henkan_Mode => .convert,
        c.XKB_KEY_Muhenkan => .non_convert,
        c.XKB_KEY_Kana_Lock,
        c.XKB_KEY_Kana_Shift,
        c.XKB_KEY_Hiragana_Katakana,
        => .kana_mode,

        c.XKB_KEY_F1 => .f1,
        c.XKB_KEY_F2 => .f2,
        c.XKB_KEY_F3 => .f3,
        c.XKB_KEY_F4 => .f4,
        c.XKB_KEY_F5 => .f5,
        c.XKB_KEY_F6 => .f6,
        c.XKB_KEY_F7 => .f7,
        c.XKB_KEY_F8 => .f8,
        c.XKB_KEY_F9 => .f9,
        c.XKB_KEY_F10 => .f10,
        c.XKB_KEY_F11 => .f11,
        c.XKB_KEY_F12 => .f12,
        c.XKB_KEY_F13 => .f13,
        c.XKB_KEY_F14 => .f14,
        c.XKB_KEY_F15 => .f15,
        c.XKB_KEY_F16 => .f16,
        c.XKB_KEY_F17 => .f17,
        c.XKB_KEY_F18 => .f18,
        c.XKB_KEY_F19 => .f19,
        c.XKB_KEY_F20 => .f20,
        c.XKB_KEY_F21 => .f21,
        c.XKB_KEY_F22 => .f22,
        c.XKB_KEY_F23 => .f23,
        c.XKB_KEY_F24 => .f24,
        c.XKB_KEY_F25 => .f25,
        // ghostty-vt's Key enum currently ends at F25. Returning unidentified
        // still lets an XKB remap override the original physical key while the
        // Kitty PUA code below carries the exact F26-F35 identity.
        c.XKB_KEY_F26,
        c.XKB_KEY_F27,
        c.XKB_KEY_F28,
        c.XKB_KEY_F29,
        c.XKB_KEY_F30,
        c.XKB_KEY_F31,
        c.XKB_KEY_F32,
        c.XKB_KEY_F33,
        c.XKB_KEY_F34,
        c.XKB_KEY_F35,
        => .unidentified,

        c.XKB_KEY_KP_0 => .numpad_0,
        c.XKB_KEY_KP_1 => .numpad_1,
        c.XKB_KEY_KP_2 => .numpad_2,
        c.XKB_KEY_KP_3 => .numpad_3,
        c.XKB_KEY_KP_4 => .numpad_4,
        c.XKB_KEY_KP_5 => .numpad_5,
        c.XKB_KEY_KP_6 => .numpad_6,
        c.XKB_KEY_KP_7 => .numpad_7,
        c.XKB_KEY_KP_8 => .numpad_8,
        c.XKB_KEY_KP_9 => .numpad_9,
        c.XKB_KEY_KP_Decimal => .numpad_decimal,
        c.XKB_KEY_KP_Divide => .numpad_divide,
        c.XKB_KEY_KP_Multiply => .numpad_multiply,
        c.XKB_KEY_KP_Subtract => .numpad_subtract,
        c.XKB_KEY_KP_Add => .numpad_add,
        c.XKB_KEY_KP_Enter => .numpad_enter,
        c.XKB_KEY_KP_Equal => .numpad_equal,
        c.XKB_KEY_KP_Separator => .numpad_separator,
        c.XKB_KEY_KP_Left => .numpad_left,
        c.XKB_KEY_KP_Right => .numpad_right,
        c.XKB_KEY_KP_Up => .numpad_up,
        c.XKB_KEY_KP_Down => .numpad_down,
        c.XKB_KEY_KP_Prior => .numpad_page_up,
        c.XKB_KEY_KP_Next => .numpad_page_down,
        c.XKB_KEY_KP_Home => .numpad_home,
        c.XKB_KEY_KP_End => .numpad_end,
        c.XKB_KEY_KP_Insert => .numpad_insert,
        c.XKB_KEY_KP_Delete => .numpad_delete,
        c.XKB_KEY_KP_Begin => .numpad_begin,

        c.XKB_KEY_Shift_L => .shift_left,
        c.XKB_KEY_Control_L => .control_left,
        c.XKB_KEY_Alt_L => .alt_left,
        c.XKB_KEY_Super_L => .meta_left,
        c.XKB_KEY_Shift_R => .shift_right,
        c.XKB_KEY_Control_R => .control_right,
        c.XKB_KEY_Alt_R => .alt_right,
        c.XKB_KEY_Super_R => .meta_right,

        c.XKB_KEY_XF86Back => .browser_back,
        c.XKB_KEY_XF86Favorites => .browser_favorites,
        c.XKB_KEY_XF86Forward => .browser_forward,
        c.XKB_KEY_XF86HomePage => .browser_home,
        c.XKB_KEY_XF86Refresh => .browser_refresh,
        c.XKB_KEY_XF86Search => .browser_search,
        c.XKB_KEY_XF86Stop => .browser_stop,
        c.XKB_KEY_XF86Eject => .eject,
        c.XKB_KEY_XF86MyComputer => .launch_app_1,
        c.XKB_KEY_XF86Calculator, c.XKB_KEY_XF86Calculater => .launch_app_2,
        c.XKB_KEY_XF86Mail => .launch_mail,
        c.XKB_KEY_XF86AudioPlay, c.XKB_KEY_XF86AudioPause => .media_play_pause,
        c.XKB_KEY_XF86AudioMedia => .media_select,
        c.XKB_KEY_XF86AudioStop => .media_stop,
        c.XKB_KEY_XF86AudioNext => .media_track_next,
        c.XKB_KEY_XF86AudioPrev => .media_track_previous,
        c.XKB_KEY_XF86PowerOff => .power,
        c.XKB_KEY_XF86Sleep => .sleep,
        c.XKB_KEY_XF86AudioLowerVolume => .audio_volume_down,
        c.XKB_KEY_XF86AudioMute => .audio_volume_mute,
        c.XKB_KEY_XF86AudioRaiseVolume => .audio_volume_up,
        c.XKB_KEY_XF86WakeUp => .wake_up,
        c.XKB_KEY_XF86Copy => .copy,
        c.XKB_KEY_XF86Cut => .cut,
        c.XKB_KEY_XF86Paste => .paste,
        c.XKB_KEY_XF86Fn => .@"fn",

        // Kitty distinguishes these media controls, but ghostty-vt's Key enum
        // does not yet. Keep them unidentified and carry the exact protocol
        // identity through kittyFunctionalCode.
        c.XKB_KEY_XF86AudioForward,
        c.XKB_KEY_XF86AudioRewind,
        c.XKB_KEY_XF86AudioRecord,
        => .unidentified,

        else => ascii: {
            const codepoint = c.xkb_keysym_to_utf32(keysym);
            if (codepoint > std.math.maxInt(u8)) break :ascii null;
            break :ascii vt.input.Key.fromASCII(@intCast(codepoint));
        },
    };
}

/// Kitty functional-key codes missing from the pinned ghostty-vt table.
/// Browser, power, clipboard, and other XF86 keys are intentionally absent:
/// the Kitty protocol does not assign functional codes to them.
fn kittyFunctionalCode(keysym: c.xkb_keysym_t) ?u21 {
    return switch (keysym) {
        c.XKB_KEY_Menu, c.XKB_KEY_XF86ContextMenu => 57363,
        c.XKB_KEY_F26 => 57389,
        c.XKB_KEY_F27 => 57390,
        c.XKB_KEY_F28 => 57391,
        c.XKB_KEY_F29 => 57392,
        c.XKB_KEY_F30 => 57393,
        c.XKB_KEY_F31 => 57394,
        c.XKB_KEY_F32 => 57395,
        c.XKB_KEY_F33 => 57396,
        c.XKB_KEY_F34 => 57397,
        c.XKB_KEY_F35 => 57398,
        c.XKB_KEY_XF86AudioPlay => 57428,
        c.XKB_KEY_XF86AudioPause => 57429,
        c.XKB_KEY_XF86AudioStop => 57432,
        c.XKB_KEY_XF86AudioForward => 57433,
        c.XKB_KEY_XF86AudioRewind => 57434,
        c.XKB_KEY_XF86AudioNext => 57435,
        c.XKB_KEY_XF86AudioPrev => 57436,
        c.XKB_KEY_XF86AudioRecord => 57437,
        c.XKB_KEY_XF86AudioLowerVolume => 57438,
        c.XKB_KEY_XF86AudioRaiseVolume => 57439,
        c.XKB_KEY_XF86AudioMute => 57440,
        else => null,
    };
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

fn testKeyboardWithOptions(options: [*:0]const u8) !Keyboard {
    var kb: Keyboard = try .init();
    errdefer kb.deinit();
    const names: c.xkb_rule_names = .{
        .rules = null,
        .model = null,
        .layout = "us",
        .variant = null,
        .options = options,
    };
    const keymap = c.xkb_keymap_new_from_names(kb.context, &names, c.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse
        return error.KeymapParseFailed;
    try kb.installKeymap(keymap);
    return kb;
}

test "xkb remaps functional keys but preserves physical writing keys" {
    try std.testing.expectEqual(vt.input.Key.escape, remapKey(.caps_lock, c.XKB_KEY_Escape));
    try std.testing.expectEqual(vt.input.Key.key_a, remapKey(.key_a, c.XKB_KEY_c));
    try std.testing.expectEqual(vt.input.Key.copy, remapKey(.unidentified, c.XKB_KEY_XF86Copy));
    try std.testing.expectEqual(vt.input.Key.browser_back, remapKey(.unidentified, c.XKB_KEY_XF86Back));
}

test "translate and encode: caps lock remapped to escape" {
    var kb = testKeyboardWithOptions("caps:escape") catch return error.SkipZigTest;
    defer kb.deinit();

    var utf8_buf: [16]u8 = undefined;
    const event = kb.translate(&utf8_buf, 58, .press).?;
    try std.testing.expectEqual(vt.input.Key.escape, event.key);
    try std.testing.expectEqualStrings("", event.utf8);

    var out_buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&out_buf);
    try vt.input.encodeKey(&writer, event, .{});
    try std.testing.expectEqualStrings("\x1b", writer.buffered());
}

test "translate and encode: Kitty media key" {
    var kb = testKeyboard() catch return error.SkipZigTest;
    defer kb.deinit();

    var utf8_buf: [16]u8 = undefined;
    // Linux KEY_VOLUMEUP is evdev 115 and maps to XF86AudioRaiseVolume.
    const event = kb.translate(&utf8_buf, 115, .press).?;
    try std.testing.expectEqual(vt.input.Key.audio_volume_up, event.key);
    try std.testing.expectEqual(@as(u21, 57439), event.unshifted_codepoint);

    var out_buf: [64]u8 = undefined;
    var legacy_writer: std.Io.Writer = .fixed(&out_buf);
    try vt.input.encodeKey(&legacy_writer, event, .{});
    try std.testing.expectEqualStrings("", legacy_writer.buffered());

    var writer: std.Io.Writer = .fixed(&out_buf);
    try vt.input.encodeKey(&writer, event, .{
        .kitty_flags = .{ .disambiguate = true },
    });
    try std.testing.expectEqualStrings("\x1b[57439u", writer.buffered());

    // Linux KEY_PLAYPAUSE is exposed by XKB as XF86AudioPlay. Keep the exact
    // MEDIA_PLAY code rather than collapsing it to MEDIA_PLAY_PAUSE.
    const play_event = kb.translate(&utf8_buf, 164, .press).?;
    try std.testing.expectEqual(vt.input.Key.media_play_pause, play_event.key);
    try std.testing.expectEqual(@as(u21, 57428), play_event.unshifted_codepoint);

    var play_writer: std.Io.Writer = .fixed(&out_buf);
    try vt.input.encodeKey(&play_writer, play_event, .{
        .kitty_flags = .{ .disambiguate = true },
    });
    try std.testing.expectEqualStrings("\x1b[57428u", play_writer.buffered());
}

test "Kitty protocol-only keysyms retain their functional code" {
    const key = remapKey(.f1, c.XKB_KEY_F26);
    const code = kittyFunctionalCode(c.XKB_KEY_F26).?;
    try std.testing.expectEqual(vt.input.Key.unidentified, key);
    try std.testing.expectEqual(@as(u21, 57389), code);
    try std.testing.expectEqual(@as(u21, 57437), kittyFunctionalCode(c.XKB_KEY_XF86AudioRecord).?);
    try std.testing.expectEqual(@as(?u21, null), kittyFunctionalCode(c.XKB_KEY_XF86Back));

    var out_buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&out_buf);
    try vt.input.encodeKey(&writer, .{
        .key = key,
        .unshifted_codepoint = code,
    }, .{
        .kitty_flags = .{ .disambiguate = true },
    });
    try std.testing.expectEqualStrings("\x1b[57389u", writer.buffered());
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
