//! Visual command block in the tc-shell canvas.
//! Represents an executed or executing command invocation, its status, and its output.
//! Tagged as $1..$n and backed by an anonymous memfd for high-speed OS pipeline referencing.

const CommandBlock = @This();

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const abi = @import("../tc/abi.zig");
const CompactCell = abi.CompactCell;

pub const Status = enum {
    running,
    success,
    failed,
};

allocator: std.mem.Allocator,
id: usize,
command: []const u8,
status: Status = .running,
exit_code: ?u8 = null,
elapsed_ms: u64 = 0,
output_lines: std.ArrayList([]const u8) = .empty,
pending_line: std.ArrayList(u8) = .empty,
raw_output: std.ArrayList(u8) = .empty,
memfd: ?posix.fd_t = null,
folded: bool = false,
fullscreen: bool = false,

pub fn init(allocator: std.mem.Allocator, id: usize, command: []const u8) !*CommandBlock {
    const self = try allocator.create(CommandBlock);
    errdefer allocator.destroy(self);

    const duped_cmd = try allocator.dupe(u8, command);
    errdefer allocator.free(duped_cmd);

    var memfd: ?posix.fd_t = null;
    var name_buf: [32]u8 = undefined;
    const memfd_name = std.fmt.bufPrintZ(&name_buf, "tc-block-{d}", .{id}) catch "tc-block";
    if (posix.memfd_create(memfd_name, linux.MFD.CLOEXEC)) |fd| {
        memfd = fd;
    } else |_| {
        memfd = null;
    }

    self.* = .{
        .allocator = allocator,
        .id = id,
        .command = duped_cmd,
        .output_lines = .empty,
        .pending_line = .empty,
        .raw_output = .empty,
        .memfd = memfd,
        .folded = false,
        .fullscreen = false,
    };
    return self;
}

pub fn deinit(self: *CommandBlock) void {
    if (self.memfd) |fd| {
        _ = linux.close(fd);
        self.memfd = null;
    }
    self.allocator.free(self.command);
    for (self.output_lines.items) |line| {
        self.allocator.free(line);
    }
    self.output_lines.deinit(self.allocator);
    self.pending_line.deinit(self.allocator);
    self.raw_output.deinit(self.allocator);
    self.allocator.destroy(self);
}

pub fn appendOutput(self: *CommandBlock, text: []const u8) !void {
    if (text.len == 0) return;

    // Append to raw buffer
    try self.raw_output.appendSlice(self.allocator, text);

    // Stream into memory-backed fd if available
    if (self.memfd) |fd| {
        var written: usize = 0;
        while (written < text.len) {
            const rc = linux.write(fd, text[written..].ptr, text.len - written);
            if (linux.errno(rc) == .SUCCESS) {
                written += rc;
            } else {
                break;
            }
        }
    }

    // Split and maintain structured output lines with proper buffering
    for (text) |b| {
        if (b == '\n') {
            const line = try self.pending_line.toOwnedSlice(self.allocator);
            try self.output_lines.append(self.allocator, line);
            self.pending_line = .empty;
        } else {
            try self.pending_line.append(self.allocator, b);
        }
    }
}

pub fn finish(self: *CommandBlock, code: u8, duration_ms: u64) void {
    if (self.pending_line.items.len > 0) {
        const line = self.pending_line.toOwnedSlice(self.allocator) catch null;
        if (line) |l| {
            self.output_lines.append(self.allocator, l) catch {};
        }
        self.pending_line = .empty;
    }
    self.exit_code = code;
    self.status = if (code == 0) .success else .failed;
    self.elapsed_ms = duration_ms;
    self.rewindMemfd();
}

pub fn rewindMemfd(self: *CommandBlock) void {
    if (self.memfd) |fd| {
        _ = linux.lseek(fd, 0, linux.SEEK.SET);
    }
}

pub fn getMemfd(self: *CommandBlock) ?posix.fd_t {
    if (self.memfd == null and self.raw_output.items.len > 0) {
        var name_buf: [32]u8 = undefined;
        const memfd_name = std.fmt.bufPrintZ(&name_buf, "tc-block-{d}", .{self.id}) catch "tc-block";
        if (posix.memfd_create(memfd_name, linux.MFD.CLOEXEC)) |fd| {
            var written: usize = 0;
            const bytes = self.raw_output.items;
            while (written < bytes.len) {
                const rc = linux.write(fd, bytes[written..].ptr, bytes.len - written);
                if (linux.errno(rc) == .SUCCESS) {
                    written += rc;
                } else {
                    break;
                }
            }
            self.memfd = fd;
        } else |_| {}
    }
    self.rewindMemfd();
    return self.memfd;
}

pub fn getRawOutput(self: *const CommandBlock) []const u8 {
    return self.raw_output.items;
}

pub fn hide(self: *CommandBlock) void {
    self.folded = true;
}

pub fn show(self: *CommandBlock) void {
    self.folded = false;
}

pub fn toggleFold(self: *CommandBlock) void {
    self.folded = !self.folded;
}
