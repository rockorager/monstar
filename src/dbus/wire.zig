//! Bounds-checked D-Bus wire encoding and decoding.

const std = @import("std");

pub const max_message_size: usize = 16 * 1024 * 1024;
const max_container_depth = 32;

pub const Error = error{
    InvalidValue,
    InvalidString,
    InvalidObjectPath,
    InvalidSignature,
    InvalidMessage,
    MissingHeaderField,
    DuplicateHeaderField,
    WrongHeaderFieldType,
    MessageTooLarge,
    Overflow,
    EndOfMessage,
    TrailingData,
};

pub const MessageType = enum(u8) {
    method_call = 1,
    method_return = 2,
    error_reply = 3,
    signal = 4,
    _,
};

pub const ArrayBookmark = struct { length_offset: usize, content_offset: usize };

pub const Encoder = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8) = .empty,
    base_offset: usize,

    pub fn init(allocator: std.mem.Allocator) Encoder {
        return .{ .allocator = allocator, .base_offset = 0 };
    }

    pub fn initWithBase(allocator: std.mem.Allocator, base_offset: usize) Encoder {
        return .{ .allocator = allocator, .base_offset = base_offset };
    }

    pub fn deinit(self: *Encoder) void {
        self.buffer.deinit(self.allocator);
    }
    pub fn bytes(self: *const Encoder) []const u8 {
        return self.buffer.items;
    }

    fn reserve(self: *Encoder, count: usize) !void {
        const n = std.math.add(usize, self.buffer.items.len, count) catch return error.Overflow;
        if (n > max_message_size) return error.MessageTooLarge;
        try self.buffer.ensureTotalCapacity(self.allocator, n);
    }

    fn alignment(self: *Encoder, alignment_value: usize) !void {
        const global = std.math.add(usize, self.base_offset, self.buffer.items.len) catch return error.Overflow;
        const padding = (alignment_value - global % alignment_value) % alignment_value;
        try self.reserve(padding);
        self.buffer.appendNTimesAssumeCapacity(0, padding);
    }

    fn raw(self: *Encoder, value: []const u8) !void {
        try self.reserve(value.len);
        self.buffer.appendSliceAssumeCapacity(value);
    }

    pub fn byte(self: *Encoder, value: u8) !void {
        try self.raw(&.{value});
    }
    pub fn boolean(self: *Encoder, value: bool) !void {
        try self.uint32(@intFromBool(value));
    }
    pub fn int32(self: *Encoder, value: i32) !void {
        try self.integer(i32, value);
    }
    pub fn uint32(self: *Encoder, value: u32) !void {
        try self.integer(u32, value);
    }
    pub fn unixFd(self: *Encoder, index: u32) !void {
        try self.uint32(index);
    }
    pub fn double(self: *Encoder, value: f64) !void {
        try self.integer(u64, @bitCast(value));
    }

    fn integer(self: *Encoder, comptime T: type, value: T) !void {
        try self.alignment(@sizeOf(T));
        var data: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &data, value, .little);
        try self.raw(&data);
    }

    pub fn string(self: *Encoder, value: []const u8) !void {
        if (!validText(value)) return error.InvalidString;
        if (value.len > std.math.maxInt(u32)) return error.Overflow;
        try self.uint32(@intCast(value.len));
        try self.raw(value);
        try self.byte(0);
    }

    pub fn objectPath(self: *Encoder, value: []const u8) !void {
        if (!validObjectPath(value)) return error.InvalidObjectPath;
        try self.string(value);
    }

    pub fn signature(self: *Encoder, value: []const u8) !void {
        if (!validSignature(value, true)) return error.InvalidSignature;
        if (value.len > 255) return error.InvalidSignature;
        try self.byte(@intCast(value.len));
        try self.raw(value);
        try self.byte(0);
    }

    pub fn variantSignature(self: *Encoder, value: []const u8) !void {
        if (!validSignature(value, false)) return error.InvalidSignature;
        try self.signature(value);
    }

    pub fn structAlignment(self: *Encoder) !void {
        try self.alignment(8);
    }
    pub fn dictEntryAlignment(self: *Encoder) !void {
        try self.alignment(8);
    }

    pub fn beginArray(self: *Encoder, element_alignment: usize) !ArrayBookmark {
        if (element_alignment == 0 or element_alignment > 8 or !std.math.isPowerOfTwo(element_alignment)) return error.InvalidValue;
        try self.alignment(4);
        const length_offset = self.buffer.items.len;
        try self.raw(&.{ 0, 0, 0, 0 });
        try self.alignment(element_alignment);
        return .{ .length_offset = length_offset, .content_offset = self.buffer.items.len };
    }

    pub fn endArray(self: *Encoder, bookmark: ArrayBookmark) !void {
        if (bookmark.content_offset > self.buffer.items.len or bookmark.length_offset + 4 > bookmark.content_offset) return error.InvalidValue;
        const length = self.buffer.items.len - bookmark.content_offset;
        if (length > std.math.maxInt(u32)) return error.MessageTooLarge;
        std.mem.writeInt(u32, self.buffer.items[bookmark.length_offset..][0..4], @intCast(length), .little);
    }
};

pub const Metadata = struct {
    message_type: MessageType,
    flags: u8 = 0,
    path: ?[]const u8 = null,
    interface: ?[]const u8 = null,
    member: ?[]const u8 = null,
    error_name: ?[]const u8 = null,
    reply_serial: ?u32 = null,
    destination: ?[]const u8 = null,
    signature: []const u8 = "",
};

pub fn encodeMessage(allocator: std.mem.Allocator, metadata: Metadata, serial: u32, body: []const u8, unix_fd_count: u32) ![]u8 {
    if (serial == 0 or body.len > std.math.maxInt(u32) or !validSignature(metadata.signature, true)) return error.InvalidMessage;
    switch (metadata.message_type) {
        .method_call => if (metadata.path == null or metadata.member == null) return error.MissingHeaderField,
        .method_return => if (metadata.reply_serial == null) return error.MissingHeaderField,
        .error_reply => if (metadata.error_name == null or metadata.reply_serial == null) return error.MissingHeaderField,
        .signal => if (metadata.path == null or metadata.interface == null or metadata.member == null) return error.MissingHeaderField,
        else => return error.InvalidMessage,
    }
    // The encoded array includes the fixed header's u32 length at offset 12.
    var e = Encoder.initWithBase(allocator, 12);
    defer e.deinit();
    const fields = try e.beginArray(8);
    if (metadata.path) |v| try headerString(&e, 1, "o", v);
    if (metadata.interface) |v| try headerString(&e, 2, "s", v);
    if (metadata.member) |v| try headerString(&e, 3, "s", v);
    if (metadata.error_name) |v| try headerString(&e, 4, "s", v);
    if (metadata.reply_serial) |v| {
        try e.structAlignment();
        try e.byte(5);
        try e.variantSignature("u");
        try e.uint32(v);
    }
    if (metadata.destination) |v| try headerString(&e, 6, "s", v);
    if (metadata.signature.len != 0) {
        try e.structAlignment();
        try e.byte(8);
        try e.variantSignature("g");
        try e.signature(metadata.signature);
    }
    if (unix_fd_count != 0) {
        try e.structAlignment();
        try e.byte(9);
        try e.variantSignature("u");
        try e.uint32(unix_fd_count);
    }
    try e.endArray(fields);
    try e.alignment(8);
    const total = std.math.add(usize, 12 + e.bytes().len, body.len) catch return error.Overflow;
    if (total > max_message_size) return error.MessageTooLarge;
    const out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);
    out[0] = 'l';
    out[1] = @intFromEnum(metadata.message_type);
    out[2] = metadata.flags;
    out[3] = 1;
    std.mem.writeInt(u32, out[4..8], @intCast(body.len), .little);
    std.mem.writeInt(u32, out[8..12], serial, .little);
    @memcpy(out[12 .. 12 + e.bytes().len], e.bytes());
    @memcpy(out[12 + e.bytes().len ..], body);
    return out;
}

fn headerString(e: *Encoder, code: u8, sig: []const u8, value: []const u8) !void {
    try e.structAlignment();
    try e.byte(code);
    try e.variantSignature(sig);
    if (sig[0] == 'o') try e.objectPath(value) else try e.string(value);
}

pub const Header = struct {
    message_type: MessageType,
    flags: u8,
    serial: u32,
    path: ?[]const u8 = null,
    interface: ?[]const u8 = null,
    member: ?[]const u8 = null,
    error_name: ?[]const u8 = null,
    reply_serial: ?u32 = null,
    destination: ?[]const u8 = null,
    signature: []const u8 = "",
    unix_fd_count: u32 = 0,
};

pub const Message = struct {
    allocator: std.mem.Allocator,
    data: []u8,
    fds: []std.posix.fd_t,
    header: Header,
    body_offset: usize,
    endian: std.builtin.Endian,
    pub fn deinit(self: *Message) void {
        for (self.fds) |fd| _ = std.os.linux.close(fd);
        self.allocator.free(self.fds);
        self.allocator.free(self.data);
        self.* = undefined;
    }
    pub fn body(self: *const Message) []const u8 {
        return self.data[self.body_offset..];
    }
    pub fn bodySignature(self: *const Message) []const u8 {
        return self.header.signature;
    }
    pub fn messageType(self: *const Message) MessageType {
        return self.header.message_type;
    }
    pub fn bodyDecoder(self: *const Message) Decoder {
        return .{ .data = self.body(), .endian = self.endian, .base_offset = 0 };
    }
};

pub fn messageLength(prefix: []const u8) !?usize {
    if (prefix.len < 16) return null;
    const endian: std.builtin.Endian = switch (prefix[0]) {
        'l' => .little,
        'B' => .big,
        else => return error.InvalidMessage,
    };
    if (prefix[3] != 1 or prefix[1] < 1 or prefix[1] > 4) return error.InvalidMessage;
    const body_len = readU32(prefix[4..8], endian);
    const fields_len = readU32(prefix[12..16], endian);
    const fields_end = std.math.add(usize, 16, fields_len) catch return error.Overflow;
    const body_start = alignForward(fields_end, 8) catch return error.Overflow;
    const total = std.math.add(usize, body_start, body_len) catch return error.Overflow;
    if (total > max_message_size) return error.MessageTooLarge;
    if (prefix.len < total) return null;
    return total;
}

pub fn parseMessage(allocator: std.mem.Allocator, data: []u8, fds: []std.posix.fd_t) !Message {
    const n = try messageLength(data) orelse return error.EndOfMessage;
    if (n != data.len) return error.TrailingData;
    const endian: std.builtin.Endian = if (data[0] == 'l') .little else .big;
    const fields_len: usize = readU32(data[12..16], endian);
    const body_offset = try alignForward(16 + fields_len, 8);
    for (data[16 + fields_len .. body_offset]) |v| if (v != 0) return error.InvalidMessage;
    var d: Decoder = .{ .data = data[16 .. 16 + fields_len], .endian = endian, .base_offset = 16 };
    var h: Header = .{ .message_type = @enumFromInt(data[1]), .flags = data[2], .serial = readU32(data[8..12], endian) };
    if (h.serial == 0) return error.InvalidMessage;
    var seen: u16 = 0;
    while (!d.finished()) {
        try d.structAlignment();
        const code = try d.byte();
        const sig = try d.variantSignature();
        if (code <= 9 and code != 7) {
            const bit: u16 = @as(u16, 1) << @intCast(code);
            if (seen & bit != 0) return error.DuplicateHeaderField;
            seen |= bit;
        }
        switch (code) {
            1 => {
                requireSig(sig, "o") catch return error.WrongHeaderFieldType;
                h.path = try d.objectPath();
            },
            2 => {
                requireSig(sig, "s") catch return error.WrongHeaderFieldType;
                h.interface = try d.string();
            },
            3 => {
                requireSig(sig, "s") catch return error.WrongHeaderFieldType;
                h.member = try d.string();
            },
            4 => {
                requireSig(sig, "s") catch return error.WrongHeaderFieldType;
                h.error_name = try d.string();
            },
            5 => {
                requireSig(sig, "u") catch return error.WrongHeaderFieldType;
                h.reply_serial = try d.uint32();
            },
            6 => {
                requireSig(sig, "s") catch return error.WrongHeaderFieldType;
                h.destination = try d.string();
            },
            8 => {
                requireSig(sig, "g") catch return error.WrongHeaderFieldType;
                h.signature = try d.signature();
            },
            9 => {
                requireSig(sig, "u") catch return error.WrongHeaderFieldType;
                h.unix_fd_count = try d.uint32();
            },
            else => try d.skipSignatureValue(sig),
        }
    }
    switch (h.message_type) {
        .method_call => if (h.path == null or h.member == null) return error.MissingHeaderField,
        .method_return => if (h.reply_serial == null) return error.MissingHeaderField,
        .error_reply => if (h.error_name == null or h.reply_serial == null) return error.MissingHeaderField,
        .signal => if (h.path == null or h.interface == null or h.member == null) return error.MissingHeaderField,
        else => return error.InvalidMessage,
    }
    if ((data.len - body_offset == 0) != (h.signature.len == 0)) return error.InvalidMessage;
    if (h.unix_fd_count != fds.len) return error.InvalidMessage;
    var body_decoder: Decoder = .{ .data = data[body_offset..], .endian = endian };
    var signature_index: usize = 0;
    while (signature_index < h.signature.len) try body_decoder.skipOne(h.signature, &signature_index, 0);
    try body_decoder.end();
    return .{ .allocator = allocator, .data = data, .fds = fds, .header = h, .body_offset = body_offset, .endian = endian };
}

pub const Decoder = struct {
    data: []const u8,
    position: usize = 0,
    endian: std.builtin.Endian,
    base_offset: usize = 0,
    pub fn finished(self: *const Decoder) bool {
        return self.position == self.data.len;
    }
    pub fn end(self: *const Decoder) !void {
        if (!self.finished()) return error.TrailingData;
    }
    fn alignment(self: *Decoder, a: usize) !void {
        const global = std.math.add(usize, self.base_offset, self.position) catch return error.Overflow;
        const padding = (a - global % a) % a;
        if (padding > self.data.len -| self.position) return error.EndOfMessage;
        for (self.data[self.position .. self.position + padding]) |v| if (v != 0) return error.InvalidMessage;
        self.position += padding;
    }
    fn take(self: *Decoder, n: usize) ![]const u8 {
        if (n > self.data.len -| self.position) return error.EndOfMessage;
        const out = self.data[self.position .. self.position + n];
        self.position += n;
        return out;
    }
    pub fn byte(self: *Decoder) !u8 {
        return (try self.take(1))[0];
    }
    pub fn uint32(self: *Decoder) !u32 {
        try self.alignment(4);
        return readU32(try self.take(4), self.endian);
    }
    pub fn int32(self: *Decoder) !i32 {
        return @bitCast(try self.uint32());
    }
    pub fn boolean(self: *Decoder) !bool {
        const v = try self.uint32();
        if (v > 1) return error.InvalidValue;
        return v == 1;
    }
    pub fn double(self: *Decoder) !f64 {
        try self.alignment(8);
        return @bitCast(readU64(try self.take(8), self.endian));
    }
    pub fn string(self: *Decoder) ![]const u8 {
        const n = try self.uint32();
        const value = try self.take(n);
        if ((try self.byte()) != 0 or !validText(value)) return error.InvalidString;
        return value;
    }
    pub fn objectPath(self: *Decoder) ![]const u8 {
        const v = try self.string();
        if (!validObjectPath(v)) return error.InvalidObjectPath;
        return v;
    }
    pub fn signature(self: *Decoder) ![]const u8 {
        const n = try self.byte();
        const value = try self.take(n);
        if ((try self.byte()) != 0 or !validSignature(value, true)) return error.InvalidSignature;
        return value;
    }
    pub fn variantSignature(self: *Decoder) ![]const u8 {
        const v = try self.signature();
        if (!validSignature(v, false)) return error.InvalidSignature;
        return v;
    }
    pub fn structAlignment(self: *Decoder) !void {
        try self.alignment(8);
    }
    pub fn beginArray(self: *Decoder, element_alignment: usize) !usize {
        const n = try self.uint32();
        try self.alignment(element_alignment);
        const end_pos = std.math.add(usize, self.position, n) catch return error.Overflow;
        if (end_pos > self.data.len) return error.EndOfMessage;
        return end_pos;
    }
    pub fn arrayFinished(self: *const Decoder, end_pos: usize) !bool {
        if (self.position > end_pos) return error.InvalidMessage;
        return self.position == end_pos;
    }
    pub fn endArray(self: *const Decoder, end_pos: usize) !void {
        if (self.position != end_pos) return error.InvalidMessage;
    }
    pub fn skipSignatureValue(self: *Decoder, signature_value: []const u8) Error!void {
        var index: usize = 0;
        try self.skipOne(signature_value, &index, 0);
        if (index != signature_value.len) return error.InvalidSignature;
    }
    fn skipOne(self: *Decoder, sig: []const u8, index: *usize, depth: usize) Error!void {
        if (depth >= max_container_depth or index.* >= sig.len) return error.InvalidSignature;
        const c = sig[index.*];
        index.* += 1;
        switch (c) {
            'y' => _ = try self.byte(),
            'b', 'u', 'i', 'h' => _ = try self.uint32(),
            'n', 'q' => {
                try self.alignment(2);
                _ = try self.take(2);
            },
            'x', 't', 'd' => {
                try self.alignment(8);
                _ = try self.take(8);
            },
            's' => _ = try self.string(),
            'o' => _ = try self.objectPath(),
            'g' => _ = try self.signature(),
            'v' => {
                const inner = try self.variantSignature();
                try self.skipSignatureValue(inner);
            },
            'a' => {
                const start = index.*;
                try signatureOne(sig, index, depth + 1, true);
                const alignment_value = typeAlignment(sig[start]);
                const end_pos = try self.beginArray(alignment_value);
                while (!(try self.arrayFinished(end_pos))) {
                    var child = start;
                    try self.skipOne(sig, &child, depth + 1);
                }
            },
            '(' => {
                try self.structAlignment();
                while (index.* < sig.len and sig[index.*] != ')') try self.skipOne(sig, index, depth + 1);
                if (index.* >= sig.len) return error.InvalidSignature;
                index.* += 1;
            },
            '{' => {
                try self.structAlignment();
                try self.skipOne(sig, index, depth + 1);
                try self.skipOne(sig, index, depth + 1);
                if (index.* >= sig.len or sig[index.*] != '}') return error.InvalidSignature;
                index.* += 1;
            },
            else => return error.InvalidSignature,
        }
    }
};

fn readU32(data: []const u8, endian: std.builtin.Endian) u32 {
    return std.mem.readInt(u32, @ptrCast(data.ptr), endian);
}
fn readU64(data: []const u8, endian: std.builtin.Endian) u64 {
    return std.mem.readInt(u64, @ptrCast(data.ptr), endian);
}
fn alignForward(value: usize, a: usize) !usize {
    return std.math.add(usize, value, (a - value % a) % a);
}
fn requireSig(got: []const u8, wanted: []const u8) !void {
    if (!std.mem.eql(u8, got, wanted)) return error.InvalidSignature;
}
fn validText(value: []const u8) bool {
    return std.mem.indexOfScalar(u8, value, 0) == null and std.unicode.utf8ValidateSlice(value);
}
fn validObjectPath(value: []const u8) bool {
    if (value.len == 0 or value[0] != '/' or (value.len > 1 and value[value.len - 1] == '/')) return false;
    if (value.len == 1) return true;
    var component = false;
    for (value[1..]) |c| {
        if (c == '/') {
            if (!component) return false;
            component = false;
        } else {
            if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
            component = true;
        }
    }
    return component;
}
fn validSignature(value: []const u8, allow_empty: bool) bool {
    if (value.len > 255 or (!allow_empty and value.len == 0)) return false;
    var i: usize = 0;
    var count: usize = 0;
    while (i < value.len) : (count += 1) signatureOne(value, &i, 0, false) catch return false;
    return allow_empty or count == 1;
}
fn signatureOne(sig: []const u8, i: *usize, depth: usize, dict_allowed: bool) !void {
    if (depth >= max_container_depth or i.* >= sig.len) return error.InvalidSignature;
    const c = sig[i.*];
    i.* += 1;
    switch (c) {
        'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'd', 's', 'o', 'g', 'h', 'v' => {},
        'a' => {
            if (i.* >= sig.len) return error.InvalidSignature;
            try signatureOne(sig, i, depth + 1, true);
        },
        '(' => {
            const start = i.*;
            while (i.* < sig.len and sig[i.*] != ')') try signatureOne(sig, i, depth + 1, false);
            if (i.* == start or i.* >= sig.len) return error.InvalidSignature;
            i.* += 1;
        },
        '{' => {
            if (!dict_allowed or i.* >= sig.len or std.mem.indexOfScalar(u8, "ybnqiuxtdsogh", sig[i.*]) == null) return error.InvalidSignature;
            i.* += 1;
            try signatureOne(sig, i, depth + 1, false);
            if (i.* >= sig.len or sig[i.*] != '}') return error.InvalidSignature;
            i.* += 1;
        },
        else => return error.InvalidSignature,
    }
}
fn typeAlignment(c: u8) usize {
    return switch (c) {
        'y', 'g', 'v' => 1,
        'n', 'q' => 2,
        'b', 'i', 'u', 'h', 's', 'o', 'a' => 4,
        else => 8,
    };
}

test "method call round trip and fragmented prefix" {
    const a = std.testing.allocator;
    var body = Encoder.init(a);
    defer body.deinit();
    try body.string("hello");
    const bytes = try encodeMessage(a, .{ .message_type = .method_call, .path = "/org/test", .interface = "org.test", .member = "Hello", .destination = "org.test", .signature = "s" }, 7, body.bytes(), 0);
    try std.testing.expect((try messageLength(bytes[0..15])) == null);
    const owned = try a.dupe(u8, bytes);
    a.free(bytes);
    var message = try parseMessage(a, owned, try a.alloc(std.posix.fd_t, 0));
    defer message.deinit();
    var d = message.bodyDecoder();
    try std.testing.expectEqualStrings("hello", try d.string());
    try d.end();
}

test "nested dictionary variant alignment and unix fds" {
    const a = std.testing.allocator;
    var body = Encoder.init(a);
    defer body.deinit();
    const array = try body.beginArray(8);
    try body.dictEntryAlignment();
    try body.string("answer");
    try body.variantSignature("u");
    try body.uint32(42);
    try body.endArray(array);
    const bytes = try encodeMessage(a, .{ .message_type = .method_call, .path = "/x", .member = "M", .signature = "a{sv}" }, 1, body.bytes(), 2);
    defer a.free(bytes);
    // Parse with harmless negative descriptors; Linux close rejects them.
    const owned = try a.dupe(u8, bytes);
    const fds = try a.dupe(std.posix.fd_t, &.{ -1, -1 });
    var m = try parseMessage(a, owned, fds);
    defer m.deinit();
    try std.testing.expectEqual(@as(u32, 2), m.header.unix_fd_count);
    var d = m.bodyDecoder();
    const end_pos = try d.beginArray(8);
    try d.structAlignment();
    try std.testing.expectEqualStrings("answer", try d.string());
    try std.testing.expectEqualStrings("u", try d.variantSignature());
    try std.testing.expectEqual(@as(u32, 42), try d.uint32());
    try d.endArray(end_pos);
}

test "big endian incoming and malformed variant" {
    var data = [_]u8{ 'B', 2, 0, 1, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0 };
    // Header field: reply serial, variant u, value 1.
    data[16] = 5;
    data[17] = 1;
    data[18] = 'u';
    data[19] = 0;
    data[23] = 1;
    const a = std.testing.allocator;
    var m = try parseMessage(a, try a.dupe(u8, &data), try a.alloc(std.posix.fd_t, 0));
    defer m.deinit();
    try std.testing.expectEqual(@as(u32, 1), m.header.reply_serial.?);
    var bad = data;
    bad[19] = 1;
    const bad_owned = try a.dupe(u8, &bad);
    defer a.free(bad_owned);
    const bad_fds = try a.alloc(std.posix.fd_t, 0);
    defer a.free(bad_fds);
    try std.testing.expectError(error.InvalidSignature, parseMessage(a, bad_owned, bad_fds));
}

test "invalid values and oversized prefix" {
    const a = std.testing.allocator;
    var e = Encoder.init(a);
    defer e.deinit();
    try std.testing.expectError(error.InvalidObjectPath, e.objectPath("bad"));
    try std.testing.expectError(error.InvalidSignature, e.signature("a"));
    var h = [_]u8{ 'l', 1, 0, 1 } ++ [_]u8{0} ** 12;
    std.mem.writeInt(u32, h[4..8], @intCast(max_message_size), .little);
    try std.testing.expectError(error.MessageTooLarge, messageLength(&h));
}

test "dictionary entries are only valid as array elements" {
    var e = Encoder.init(std.testing.allocator);
    defer e.deinit();

    try std.testing.expectError(error.InvalidSignature, e.signature("({sv})"));
    try std.testing.expectError(error.InvalidSignature, e.signature("a{s{sv}}"));
    try e.signature("a{sv}");
    try e.signature("(a{sv})");
}
