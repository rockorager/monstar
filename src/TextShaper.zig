//! HarfBuzz text shaping and shaped-run caching for terminal cell runs.
//!
//! Keys contain a face followed by run-relative (cluster, codepoint) pairs,
//! allowing identical text to reuse shaping results at any screen position.

const TextShaper = @This();

const std = @import("std");
const c = @import("c");
const Font = @import("Font.zig");

alloc: std.mem.Allocator,
font: *Font,
hb_buf: *c.hb_buffer_t,
/// HarfBuzz output keyed by face and run content.
cache: std.StringHashMapUnmanaged([]ShapedGlyph),
/// Scratch for the current run's cache key.
key: std.ArrayList(u32),
/// Cache counters for benchmarks/profiling. Production rendering does not
/// read these, so they stay deliberately cheap and approximate.
stats: ShapeStats = .{},

/// Cache entry limit; at ~300 bytes per typical entry the cache tops out
/// around a few megabytes before it resets.
const cache_max_entries = 8192;

/// Fallback candidates tried when a cluster shapes to .notdef before
/// accepting the tofu box.
const max_notdef_retries = 3;

pub const ShapedGlyph = struct {
    glyph: u32,
    /// Cell offset from the run start.
    cluster: u32,
    /// Face the glyph index belongs to. Usually the run's face; differs
    /// for clusters that shaped to .notdef and were repaired against a
    /// further fallback candidate.
    face: u16,
    x_advance: i32,
    x_offset: i32,
    y_offset: i32,
};

pub const ShapeStats = struct {
    cache_hits: usize = 0,
    cache_misses: usize = 0,
    shaped_cells: usize = 0,
    cache_clears: usize = 0,
};

pub fn init(alloc: std.mem.Allocator, font: *Font) !TextShaper {
    const hb_buf = c.hb_buffer_create() orelse return error.OutOfMemory;
    if (c.hb_buffer_allocation_successful(hb_buf) == 0) return error.OutOfMemory;
    return .{
        .alloc = alloc,
        .font = font,
        .hb_buf = hb_buf,
        .cache = .empty,
        .key = .empty,
        .stats = .{},
    };
}

pub fn deinit(self: *TextShaper) void {
    c.hb_buffer_destroy(self.hb_buf);
    self.clearCache();
    self.cache.deinit(self.alloc);
    self.key.deinit(self.alloc);
    self.* = undefined;
}

/// Drop all cached shaping results. Must be called when the font (and with it
/// the face set and metrics) changes.
pub fn clearCache(self: *TextShaper) void {
    var it = self.cache.iterator();
    while (it.next()) |entry| {
        self.alloc.free(entry.key_ptr.*);
        self.alloc.free(entry.value_ptr.*);
    }
    self.cache.clearRetainingCapacity();
}

pub fn resetStats(self: *TextShaper) void {
    self.stats = .{};
}

pub fn readStats(self: *const TextShaper) ShapeStats {
    return self.stats;
}

pub fn beginKey(self: *TextShaper, face_index: u16) !void {
    self.key.clearRetainingCapacity();
    try self.key.append(self.alloc, face_index);
}

pub fn appendKeyCodepoints(self: *TextShaper, cluster: u32, cp: u21, grapheme: []const u21) !void {
    try self.key.appendSlice(self.alloc, &.{ cluster, cp });
    for (grapheme) |extra| {
        try self.key.appendSlice(self.alloc, &.{ cluster, extra });
    }
}

pub fn keyItems(self: *const TextShaper) []const u32 {
    return self.key.items;
}

/// Shape the current key or return its cached result. The returned slice is
/// owned by this shaper and remains valid until a later shape call clears a
/// full cache, or until `clearCache` or `deinit` is called.
pub fn shape(self: *TextShaper, face_index: u16, style: Font.FaceStyle, shaped_cells: usize) ![]const ShapedGlyph {
    if (self.cache.get(std.mem.sliceAsBytes(self.key.items))) |cached| {
        // Steady-state rendering overwhelmingly reuses shaped runs. Keeping
        // the miss path out of line also keeps Renderer.drawRun compact.
        @branchHint(.likely);
        self.stats.cache_hits += 1;
        return cached;
    }
    self.stats.cache_misses += 1;
    self.stats.shaped_cells += shaped_cells;
    return self.shapeRun(face_index, style);
}

/// Shape the run described by key with HarfBuzz and cache the result under a
/// copy of the key. Clusters that shape to .notdef are re-resolved against
/// further fallback candidates before caching. The returned slice has the same
/// lifetime as one returned by `shape`.
pub fn shapeRun(self: *TextShaper, face_index: u16, style: Font.FaceStyle) ![]ShapedGlyph {
    const key = self.key.items;
    const face = self.font.face(face_index);

    c.hb_buffer_clear_contents(self.hb_buf);
    var i: usize = 1;
    while (i + 1 < key.len) : (i += 2) {
        c.hb_buffer_add(self.hb_buf, key[i + 1], key[i]);
    }
    c.hb_buffer_set_content_type(self.hb_buf, c.HB_BUFFER_CONTENT_TYPE_UNICODE);
    c.hb_buffer_guess_segment_properties(self.hb_buf);
    c.hb_shape(face.hb_font, self.hb_buf, null, 0);

    var glyph_count: c_uint = 0;
    const infos = c.hb_buffer_get_glyph_infos(self.hb_buf, &glyph_count);
    const positions = c.hb_buffer_get_glyph_positions(self.hb_buf, &glyph_count);

    var shaped = try self.alloc.alloc(ShapedGlyph, glyph_count);
    errdefer self.alloc.free(shaped);
    var has_notdef = false;
    if (glyph_count > 0) {
        for (shaped, infos[0..glyph_count], positions[0..glyph_count]) |*sg, info, pos| {
            sg.* = .{
                .glyph = info.codepoint,
                .cluster = info.cluster,
                .face = face_index,
                .x_advance = pos.x_advance >> 6,
                .x_offset = pos.x_offset >> 6,
                .y_offset = pos.y_offset >> 6,
            };
            if (info.codepoint == 0) has_notdef = true;
        }
    }
    if (has_notdef) shaped = try self.repairNotdefClusters(shaped, face_index, style);

    // Full cache: reset wholesale. Terminal content is repetitive enough that
    // the working set repopulates within a frame or two.
    if (self.cache.count() >= cache_max_entries) {
        self.stats.cache_clears += 1;
        self.clearCache();
    }
    const owned_key = try self.alloc.dupe(u8, std.mem.sliceAsBytes(key));
    errdefer self.alloc.free(owned_key);
    try self.cache.put(self.alloc, owned_key, shaped);
    return shaped;
}

/// Replaces .notdef glyphs in a freshly shaped run by re-resolving the failing
/// clusters against further fallback candidates and re-shaping each in
/// isolation. Cluster origins snap to their cells at draw time, so per-cluster
/// splices cannot disturb the rest of the run. Frees `shaped` and returns the
/// corrected run; clusters no candidate can shape keep their original .notdef
/// glyphs.
fn repairNotdefClusters(
    self: *TextShaper,
    shaped: []ShapedGlyph,
    face_index: u16,
    style: Font.FaceStyle,
) ![]ShapedGlyph {
    const key = self.key.items;
    var out: std.ArrayList(ShapedGlyph) = .empty;
    errdefer out.deinit(self.alloc);
    var cps: std.ArrayList(u21) = .empty;
    defer cps.deinit(self.alloc);
    // Clusters already replaced, in case HarfBuzz reordered one into
    // non-contiguous groups; later fragments are dropped.
    var repaired: std.ArrayList(u32) = .empty;
    defer repaired.deinit(self.alloc);

    var i: usize = 0;
    while (i < shaped.len) {
        const cluster = shaped[i].cluster;
        var end = i + 1;
        var has_notdef = shaped[i].glyph == 0;
        while (end < shaped.len and shaped[end].cluster == cluster) : (end += 1) {
            if (shaped[end].glyph == 0) has_notdef = true;
        }
        if (std.mem.findScalar(u32, repaired.items, cluster) != null) {
            i = end;
            continue;
        }
        if (!has_notdef) {
            try out.appendSlice(self.alloc, shaped[i..end]);
            i = end;
            continue;
        }

        cps.clearRetainingCapacity();
        var k: usize = 1;
        while (k + 1 < key.len) : (k += 2) {
            if (key[k] == cluster) try cps.append(self.alloc, @intCast(key[k + 1]));
        }

        var fixed = false;
        if (cps.items.len > 0) {
            var candidates = self.font.clusterCandidates(cps.items, style);
            var attempts: usize = 0;
            while (attempts < max_notdef_retries) {
                const candidate = candidates.next(self.alloc) orelse break;
                if (candidate == face_index) continue;
                attempts += 1;
                if (try self.shapeClusterWith(candidate, cluster, cps.items, &out)) {
                    fixed = true;
                    break;
                }
            }
        }
        if (fixed) {
            try repaired.append(self.alloc, cluster);
        } else {
            try out.appendSlice(self.alloc, shaped[i..end]);
        }
        i = end;
    }

    self.alloc.free(shaped);
    return out.toOwnedSlice(self.alloc);
}

/// Shapes `cps` as one isolated cluster with `face_index`, appending the
/// glyphs to `out`. Returns false (leaving `out` untouched) when the result
/// still contains .notdef.
fn shapeClusterWith(
    self: *TextShaper,
    face_index: u16,
    cluster: u32,
    cps: []const u21,
    out: *std.ArrayList(ShapedGlyph),
) !bool {
    const face = self.font.face(face_index);
    c.hb_buffer_clear_contents(self.hb_buf);
    for (cps) |cp| c.hb_buffer_add(self.hb_buf, cp, cluster);
    c.hb_buffer_set_content_type(self.hb_buf, c.HB_BUFFER_CONTENT_TYPE_UNICODE);
    c.hb_buffer_guess_segment_properties(self.hb_buf);
    c.hb_shape(face.hb_font, self.hb_buf, null, 0);

    var glyph_count: c_uint = 0;
    const infos = c.hb_buffer_get_glyph_infos(self.hb_buf, &glyph_count);
    const positions = c.hb_buffer_get_glyph_positions(self.hb_buf, &glyph_count);
    for (infos[0..glyph_count]) |info| {
        if (info.codepoint == 0) return false;
    }

    const start = out.items.len;
    errdefer out.shrinkRetainingCapacity(start);
    for (infos[0..glyph_count], positions[0..glyph_count]) |info, pos| {
        try out.append(self.alloc, .{
            .glyph = info.codepoint,
            .cluster = cluster,
            .face = face_index,
            .x_advance = pos.x_advance >> 6,
            .x_offset = pos.x_offset >> 6,
            .y_offset = pos.y_offset >> 6,
        });
    }
    return true;
}
