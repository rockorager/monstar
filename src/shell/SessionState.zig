//! In-process session state machine for tc-shell.
//! Manages:
//! - Working directory tracking (cwd, old_pwd, cd navigation).
//! - Environment variable store (export, unset, child process envp).
//! - Builtin command parsing (cd, collapse, expand, fullscreen, edit, run, rm, copy, view, export, unset).
//! - Tag and pipeline reference resolution ($1..$n, $prev, $1.cmd, /proc/self/fd/<fd>).

const SessionState = @This();

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const CommandBlock = @import("CommandBlock.zig");

pub const Builtin = union(enum) {
    none,
    cd: ?[]const u8,
    export_var: struct { key: []const u8, value: []const u8 },
    unset_var: []const u8,
    collapse: []const u8,
    expand: []const u8,
    fullscreen: ?[]const u8,
    edit: []const u8,
    run: []const u8,
    rm: []const u8,
    copy: struct { target: []const u8, is_cmd: bool },
    view: []const u8,
    clear,
    exit,
};

allocator: std.mem.Allocator,
cwd: []u8,
old_pwd: ?[]u8 = null,
env_map: std.StringHashMapUnmanaged([]u8) = .empty,
next_block_id: usize = 1,

pub fn init(allocator: std.mem.Allocator) !*SessionState {
    const self = try allocator.create(SessionState);
    errdefer allocator.destroy(self);

    // Initial cwd
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const initial_cwd = if (std.c.getcwd(&cwd_buf, cwd_buf.len)) |ptr|
        std.mem.sliceTo(ptr, 0)
    else
        "/";
    const duped_cwd = try allocator.dupe(u8, initial_cwd);
    errdefer allocator.free(duped_cwd);

    self.* = .{
        .allocator = allocator,
        .cwd = duped_cwd,
        .old_pwd = null,
        .env_map = .empty,
        .next_block_id = 1,
    };

    // Populate environment from std.c.environ
    const envp = std.c.environ;
    var i: usize = 0;
    while (envp[i]) |entry_ptr| : (i += 1) {
        const entry = std.mem.sliceTo(entry_ptr, 0);
        if (std.mem.indexOfScalar(u8, entry, '=')) |eq_idx| {
            const key = entry[0..eq_idx];
            const val = entry[eq_idx + 1 ..];
            const duped_key = try allocator.dupe(u8, key);
            errdefer allocator.free(duped_key);
            const duped_val = try allocator.dupe(u8, val);
            errdefer allocator.free(duped_val);
            try self.env_map.put(allocator, duped_key, duped_val);
        }
    }

    // Ensure PWD is set
    try self.setEnv("PWD", self.cwd);

    return self;
}

pub fn deinit(self: *SessionState) void {
    self.allocator.free(self.cwd);
    if (self.old_pwd) |old| {
        self.allocator.free(old);
    }
    var iter = self.env_map.iterator();
    while (iter.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        self.allocator.free(entry.value_ptr.*);
    }
    self.env_map.deinit(self.allocator);
    self.allocator.destroy(self);
}

pub fn allocateBlockId(self: *SessionState) usize {
    const id = self.next_block_id;
    self.next_block_id += 1;
    return id;
}

pub fn getCwd(self: *const SessionState) []const u8 {
    return self.cwd;
}

pub fn getEnv(self: *const SessionState, key: []const u8) ?[]const u8 {
    return self.env_map.get(key);
}

pub fn setEnv(self: *SessionState, key: []const u8, value: []const u8) !void {
    if (self.env_map.getEntry(key)) |existing| {
        self.allocator.free(existing.value_ptr.*);
        existing.value_ptr.* = try self.allocator.dupe(u8, value);
    } else {
        const duped_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(duped_key);
        const duped_val = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(duped_val);
        try self.env_map.put(self.allocator, duped_key, duped_val);
    }
}

pub fn unsetEnv(self: *SessionState, key: []const u8) void {
    if (self.env_map.fetchRemove(key)) |entry| {
        self.allocator.free(entry.key);
        self.allocator.free(entry.value);
    }
}

pub fn changeDirectory(self: *SessionState, maybe_target: ?[]const u8) !void {
    const target = if (maybe_target) |t| std.mem.trim(u8, t, " \t\r\n") else "";

    var new_dest: []const u8 = undefined;
    var allocated_dest: ?[]u8 = null;
    defer {
        if (allocated_dest) |d| self.allocator.free(d);
    }

    if (target.len == 0 or std.mem.eql(u8, target, "~")) {
        new_dest = self.getEnv("HOME") orelse "/";
    } else if (std.mem.eql(u8, target, "-")) {
        new_dest = self.old_pwd orelse return error.NoPreviousDirectory;
    } else if (std.mem.startsWith(u8, target, "~/")) {
        const home = self.getEnv("HOME") orelse "/";
        allocated_dest = try std.fs.path.join(self.allocator, &[_][]const u8{ home, target[2..] });
        new_dest = allocated_dest.?;
    } else if (std.fs.path.isAbsolute(target)) {
        new_dest = target;
    } else {
        allocated_dest = try std.fs.path.join(self.allocator, &[_][]const u8{ self.cwd, target });
        new_dest = allocated_dest.?;
    }

    // Resolve destination path cleanly
    const resolved = try std.fs.path.resolve(self.allocator, &[_][]const u8{new_dest});
    defer self.allocator.free(resolved);

    // Change posix process directory
    const resolved_z = try self.allocator.dupeZ(u8, resolved);
    defer self.allocator.free(resolved_z);

    const rc = linux.chdir(resolved_z.ptr);
    if (linux.errno(rc) != .SUCCESS) {
        return error.DirectoryChangeFailed;
    }

    // Update old_pwd and cwd
    if (self.old_pwd) |old| self.allocator.free(old);
    self.old_pwd = self.cwd;
    self.cwd = try self.allocator.dupe(u8, resolved);

    try self.setEnv("OLDPWD", self.old_pwd.?);
    try self.setEnv("PWD", self.cwd);
}

/// Parses a command line to see if it's a tc-shell builtin.
pub fn parseBuiltin(cmd: []const u8) Builtin {
    const trimmed = std.mem.trim(u8, cmd, " \t\r\n");
    if (trimmed.len == 0) return .none;

    var iter = std.mem.tokenizeAny(u8, trimmed, " \t");
    const first = iter.next() orelse return .none;
    const rest = std.mem.trim(u8, trimmed[first.len..], " \t");

    if (std.mem.eql(u8, first, "clear")) {
        return .clear;
    }
    if (std.mem.eql(u8, first, "exit") or std.mem.eql(u8, first, "quit")) {
        return .exit;
    }
    if (std.mem.eql(u8, first, "cd")) {
        return .{ .cd = if (rest.len > 0) rest else null };
    }
    if (std.mem.eql(u8, first, "export")) {
        if (rest.len == 0) return .none;
        if (std.mem.indexOfScalar(u8, rest, '=')) |eq_idx| {
            const key = rest[0..eq_idx];
            const val = rest[eq_idx + 1 ..];
            return .{ .export_var = .{ .key = key, .value = val } };
        }
        return .none;
    }
    if (std.mem.eql(u8, first, "unset")) {
        if (rest.len == 0) return .none;
        return .{ .unset_var = rest };
    }
    if (std.mem.eql(u8, first, "collapse")) {
        return .{ .collapse = if (rest.len > 0) rest else "$prev" };
    }
    if (std.mem.eql(u8, first, "expand")) {
        return .{ .expand = if (rest.len > 0) rest else "$prev" };
    }
    if (std.mem.eql(u8, first, "fullscreen") or std.mem.eql(u8, first, "fg")) {
        return .{ .fullscreen = if (rest.len > 0) rest else null };
    }
    if (std.mem.eql(u8, first, "edit")) {
        return .{ .edit = if (rest.len > 0) rest else "$prev" };
    }
    if (std.mem.eql(u8, first, "run")) {
        return .{ .run = if (rest.len > 0) rest else "$prev" };
    }
    if (std.mem.eql(u8, first, "rm")) {
        return .{ .rm = if (rest.len > 0) rest else "$prev" };
    }
    if (std.mem.eql(u8, first, "view")) {
        return .{ .view = if (rest.len > 0) rest else "$prev" };
    }
    if (std.mem.eql(u8, first, "copy")) {
        const target_token = if (rest.len > 0) rest else "$prev";
        if (std.mem.endsWith(u8, target_token, ".cmd")) {
            return .{ .copy = .{
                .target = target_token[0 .. target_token.len - 4],
                .is_cmd = true,
            } };
        }
        return .{ .copy = .{
            .target = target_token,
            .is_cmd = false,
        } };
    }

    return .none;
}

/// Resolves a block target string ($1, 1, $prev, prev) to a CommandBlock.
pub fn resolveBlock(blocks: []const *CommandBlock, raw_target: []const u8) ?*CommandBlock {
    if (blocks.len == 0) return null;
    const target = std.mem.trim(u8, raw_target, " \t");

    if (target.len == 0 or std.mem.eql(u8, target, "$prev") or std.mem.eql(u8, target, "prev")) {
        return blocks[blocks.len - 1];
    }

    const num_str = if (std.mem.startsWith(u8, target, "$")) target[1..] else target;
    const id = std.fmt.parseInt(usize, num_str, 10) catch return null;

    for (blocks) |b| {
        if (b.id == id) return b;
    }
    return null;
}

/// Finds the index in blocks for a given target.
pub fn findBlockIndex(blocks: []const *CommandBlock, raw_target: []const u8) ?usize {
    if (blocks.len == 0) return null;
    const target = std.mem.trim(u8, raw_target, " \t");

    if (target.len == 0 or std.mem.eql(u8, target, "$prev") or std.mem.eql(u8, target, "prev")) {
        return blocks.len - 1;
    }

    const num_str = if (std.mem.startsWith(u8, target, "$")) target[1..] else target;
    const id = std.fmt.parseInt(usize, num_str, 10) catch return null;

    for (blocks, 0..) |b, i| {
        if (b.id == id) return i;
    }
    return null;
}

/// Expands block references in command string for OS pipelines.
/// E.g.:
///   "$1 | grep foo" -> "cat /proc/self/fd/<fd1> | grep foo"
///   "$1 > out.txt"   -> "cat /proc/self/fd/<fd1> > out.txt"
///   "diff $1 $2"    -> "diff /proc/self/fd/<fd1> /proc/self/fd/<fd2>"
pub fn expandPipeline(
    allocator: std.mem.Allocator,
    blocks: []const *CommandBlock,
    cmd: []const u8,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const trimmed = std.mem.trim(u8, cmd, " \t\r\n");

    // Check if command starts with "$N |" or "$prev |" or "$N >" or "$prev >"
    var is_leading_pipe_or_redir = false;
    var leading_target: []const u8 = "";
    var rest_offset: usize = 0;

    var iter = std.mem.tokenizeAny(u8, trimmed, " \t");
    if (iter.next()) |first_tok| {
        if (std.mem.startsWith(u8, first_tok, "$")) {
            var skip = first_tok.len;
            while (skip < trimmed.len and (trimmed[skip] == ' ' or trimmed[skip] == '\t')) : (skip += 1) {}
            const after_first = trimmed[skip..];
            if (std.mem.startsWith(u8, after_first, "|") or std.mem.startsWith(u8, after_first, ">")) {
                is_leading_pipe_or_redir = true;
                leading_target = first_tok;
                rest_offset = first_tok.len;
            }
        }
    }

    if (is_leading_pipe_or_redir) {
        if (resolveBlock(blocks, leading_target)) |block| {
            if (block.getMemfd()) |fd| {
                var writer = std.Io.Writer.Allocating.init(allocator);
                defer writer.deinit();
                try writer.writer.print("cat /proc/self/fd/{d}", .{fd});
                const cat_str = try writer.toOwnedSlice();
                defer allocator.free(cat_str);
                try out.appendSlice(allocator, cat_str);
                try out.appendSlice(allocator, trimmed[rest_offset..]);
                return out.toOwnedSlice(allocator);
            }
        }
    }

    // Scan for $1..$n or $prev argument references
    var i: usize = 0;
    while (i < trimmed.len) {
        if (trimmed[i] == '$' and (i == 0 or std.ascii.isWhitespace(trimmed[i - 1]))) {
            const start = i;
            var end = i + 1;
            while (end < trimmed.len and (std.ascii.isAlphanumeric(trimmed[end]) or trimmed[end] == '_')) : (end += 1) {}
            const token = trimmed[start..end];

            if (std.mem.eql(u8, token, "$prev") or (token.len > 1 and std.ascii.isDigit(token[1]))) {
                if (resolveBlock(blocks, token)) |block| {
                    if (block.getMemfd()) |fd| {
                        var writer = std.Io.Writer.Allocating.init(allocator);
                        defer writer.deinit();
                        try writer.writer.print("/proc/self/fd/{d}", .{fd});
                        const fd_path = try writer.toOwnedSlice();
                        defer allocator.free(fd_path);
                        try out.appendSlice(allocator, fd_path);
                        i = end;
                        continue;
                    }
                }
            }
        }
        try out.append(allocator, trimmed[i]);
        i += 1;
    }

    return out.toOwnedSlice(allocator);
}
