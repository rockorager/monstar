//! Owns scrollback search state and the terminal resources needed to restore
//! the viewport safely when a search ends.

const ScrollbackSearch = @This();

const std = @import("std");
const vt = @import("ghostty-vt");

query: std.ArrayList(u8) = .empty,
engine: ?vt.search.Screen = null,
engine_key: vt.ScreenSet.Key = .primary,
engine_generation: usize = 0,
complete: bool = true,
original_screen: *vt.Screen,
original_key: vt.ScreenSet.Key,
original_generation: usize,
original_viewport: vt.PageList.Viewport,
original_pin: ?*vt.Pin,

pub fn init(term: *vt.Terminal) !ScrollbackSearch {
    const key = term.screens.active_key;
    const screen = term.screens.active;
    const viewport = screen.pages.viewport;
    return .{
        .original_screen = screen,
        .original_key = key,
        .original_generation = term.screens.generation(key),
        .original_viewport = viewport,
        .original_pin = if (viewport == .pin)
            try screen.pages.trackPin(screen.pages.getTopLeft(.viewport))
        else
            null,
    };
}

fn screenValid(
    term: *const vt.Terminal,
    key: vt.ScreenSet.Key,
    generation: usize,
    screen: *const vt.Screen,
) bool {
    return term.screens.generation(key) == generation and
        term.screens.get(key) == screen;
}

pub fn engineValid(self: *const ScrollbackSearch, term: *const vt.Terminal) bool {
    const engine = self.engine orelse return false;
    return screenValid(term, self.engine_key, self.engine_generation, engine.screen);
}

pub fn deinitEngine(self: *ScrollbackSearch, term: *vt.Terminal) void {
    if (self.engine) |*engine| {
        if (self.engineValid(term))
            engine.deinit()
        else
            engine.deinitScreenInvalid();
        self.engine = null;
    }
    self.complete = true;
}

pub fn restoreViewport(self: *ScrollbackSearch, term: *vt.Terminal) void {
    if (term.screens.active_key != self.original_key or
        !screenValid(term, self.original_key, self.original_generation, self.original_screen))
    {
        return;
    }
    switch (self.original_viewport) {
        .active => self.original_screen.pages.scroll(.active),
        .top => self.original_screen.pages.scroll(.top),
        .pin => self.original_screen.pages.scroll(.{ .pin = self.original_pin.?.* }),
    }
}

pub fn deinit(self: *ScrollbackSearch, alloc: std.mem.Allocator, term: *vt.Terminal) void {
    self.deinitEngine(term);
    if (self.original_pin) |pin| {
        if (screenValid(term, self.original_key, self.original_generation, self.original_screen)) {
            self.original_screen.pages.untrackPin(pin);
        }
    }
    self.query.deinit(alloc);
}

test "releases an engine after its screen is removed" {
    const alloc = std.testing.allocator;
    var term: vt.Terminal = try .init(std.testing.io, alloc, .{ .cols = 10, .rows = 3 });
    defer term.deinit(alloc);
    _ = try term.switchScreen(.alternate);

    var search: ScrollbackSearch = try .init(&term);
    defer search.deinit(alloc, &term);
    try search.query.appendSlice(alloc, "needle");
    search.engine = try .init(alloc, term.screens.active, search.query.items);
    search.engine_key = .alternate;
    search.engine_generation = term.screens.generation(.alternate);
    search.complete = false;

    _ = try term.switchScreen(.primary);
    term.screens.remove(alloc, .alternate);
    try std.testing.expect(!search.engineValid(&term));
}
