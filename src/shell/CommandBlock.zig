//! Visual command block in the tc-shell canvas.
//! Represents an executed or executing command invocation, its status, and its output.

const CommandBlock = @This();

const std = @import("std");
const abi = @import("../tc/abi.zig");
const CompactCell = abi.CompactCell;

pub const Status = enum {
    running,
    success,
    failed,
};

allocator: std.mem.Allocator,
command: []const u8,
status: Status = .running,
exit_code: ?u8 = null,
elapsed_ms: u64 = 0,
output_lines: std.ArrayList([]const u8) = .empty,
folded: bool = false,

pub fn init(allocator: std.mem.Allocator, command: []const u8) !*CommandBlock {
    const self = try allocator.create(CommandBlock);
    self.* = .{
        .allocator = allocator,
        .command = try allocator.dupe(u8, command),
        .output_lines = .empty,
    };
    return self;
}

pub fn deinit(self: *CommandBlock) void {
    self.allocator.free(self.command);
    for (self.output_lines.items) |line| {
        self.allocator.free(line);
    }
    self.output_lines.deinit(self.allocator);
    self.allocator.destroy(self);
}

pub fn appendOutput(self: *CommandBlock, text: []const u8) !void {
    var iter = std.mem.splitScalar(u8, text, '\n');
    while (iter.next()) |line| {
        if (line.len == 0 and iter.peek() == null) break;
        const duped = try self.allocator.dupe(u8, line);
        try self.output_lines.append(self.allocator, duped);
    }
}

pub fn finish(self: *CommandBlock, code: u8, duration_ms: u64) void {
    self.exit_code = code;
    self.status = if (code == 0) .success else .failed;
    self.elapsed_ms = duration_ms;
}
