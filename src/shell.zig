//! tc-shell module facade.
//! Separates shell runtime, stationary prompt launcher, and command blocks
//! from core TC-Wayland compositor logic.

pub const PromptSurface = @import("shell/PromptSurface.zig");
pub const CommandBlock = @import("shell/CommandBlock.zig");
pub const SessionState = @import("shell/SessionState.zig");
pub const TcShellApp = @import("shell/TcShellApp.zig");

test {
    _ = PromptSurface;
    _ = CommandBlock;
    _ = SessionState;
    _ = TcShellApp;
    _ = @import("shell/test_shell.zig");
}
