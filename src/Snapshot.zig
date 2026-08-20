//! Terminal binary snapshot encode and decode helpers.
//!
//! Provides transactional import, export, and incremental history ingestion
//! for Ghostty-compatible terminal snapshots.

const std = @import("std");
const vt = @import("ghostty-vt");
const Allocator = std.mem.Allocator;

pub const Continuation = vt.snapshot.Continuation;
pub const EncodeOptions = vt.snapshot.EncodeOptions;
pub const DecodeOptions = vt.snapshot.DecodeOptions;
pub const Decoded = vt.snapshot.Decoded;
pub const Decoder = vt.snapshot.Decoder;

pub const ExportOptions = struct {
    continuation: Continuation = .ground,
};

pub const ImportResult = struct {
    terminal: vt.Terminal,
    continuation: Continuation,
    history_rows: std.EnumMap(vt.ScreenSet.Key, u64),
    decoder: Decoder,

    pub fn deinit(self: *ImportResult, alloc: Allocator) void {
        switch (self.continuation) {
            .ground => {},
            .bytes => |bytes| alloc.free(bytes),
        }
        self.* = undefined;
    }
};

/// Encode a complete terminal snapshot (active screens + continuation + history) into any writer.
pub fn exportSnapshot(
    alloc: Allocator,
    destination: *std.Io.Writer,
    terminal: *const vt.Terminal,
    options: ExportOptions,
) vt.snapshot.EncodeError!void {
    try vt.snapshot.encode(alloc, destination, terminal, .{
        .continuation = options.continuation,
    });
}

/// Begin decoding from a stream or pipe.
/// Returns immediately once the READY marker is reached so the UI can render the active screen.
pub fn startImport(
    alloc: Allocator,
    io: std.Io,
    reader: *std.Io.Reader,
    max_continuation_bytes: usize,
) Decoder.ReadyError!ImportResult {
    var decoder = Decoder.init(reader);
    var decoded = try decoder.ready(alloc, io, .{
        .max_continuation_bytes = max_continuation_bytes,
    });
    errdefer decoded.deinit(alloc);

    return .{
        .terminal = decoded.toOwned(),
        .continuation = decoded.continuation,
        .history_rows = decoded.history_rows,
        .decoder = decoder,
    };
}

/// Incrementally pump scrollback history pages until FINISH is reached.
/// Returns true if more history pages are pending, or false when finished.
pub fn pumpHistory(
    alloc: Allocator,
    decoder: *Decoder,
    terminal: *vt.Terminal,
) Decoder.NextError!bool {
    if (try decoder.next(alloc, terminal)) |_| {
        return true;
    }
    return false;
}

test "snapshot export and import roundtrip" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var term: vt.Terminal = try .init(testing.io, alloc, .{ .cols = 40, .rows = 10 });
    defer term.deinit(alloc);

    // Populate active screen with some text
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("Hello from Monstar Snapshot!\r\nLine 2");

    // Export snapshot into an allocating buffer
    var buffer: std.Io.Writer.Allocating = .init(alloc);
    defer buffer.deinit();

    try exportSnapshot(alloc, &buffer.writer, &term, .{});

    // Import snapshot back
    var reader: std.Io.Reader = .fixed(buffer.written());
    var import_res = try startImport(alloc, testing.io, &reader, 64 * 1024);
    defer import_res.deinit(alloc);

    var restored = import_res.terminal;
    defer restored.deinit(alloc);

    try testing.expectEqual(@as(u16, 40), restored.cols);
    try testing.expectEqual(@as(u16, 10), restored.rows);

    // Drain history (which should reach FINISH immediately since no scrollback pages were created)
    const has_more = try pumpHistory(alloc, &import_res.decoder, &restored);
    try testing.expect(!has_more);
}
