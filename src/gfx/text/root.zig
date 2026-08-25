//! Weft's text-shaping facade.
//!
//! This module owns the narrow text vocabulary the view needs: fonts, styled
//! style sets, shaped glyphs with source clusters, and terminal-cell placement
//! metadata. HarfBuzz is an implementation detail. Rendering, Vulkan, and
//! platform input do not cross this boundary.

const std = @import("std");

const c = @cImport({
    @cInclude("hb.h");
    @cInclude("hb-ot.h");
});

const Allocator = std.mem.Allocator;

pub const SourceRange = struct {
    start: u32,
    end: u32,
};

pub const FontWeight = enum(u4) {
    thin = 1,
    extra_light = 2,
    light = 3,
    regular = 4,
    medium = 5,
    semi_bold = 6,
    bold = 7,
    extra_bold = 8,
    black = 9,
};

pub const FontStyle = struct {
    weight: FontWeight = .regular,
    italic: bool = false,
};

pub const Cell = struct {
    source: SourceRange,
    column: u32,
    color: [4]f32 = .{ 1, 1, 1, 1 },
};

pub const ShapedText = struct {
    allocator: Allocator,
    glyphs: []Glyph,

    pub const Glyph = struct {
        font_id: u32,
        glyph_id: u32,
        x_offset: f32,
        y_offset: f32,
        x_advance: f32,
        y_advance: f32,
        source_start: u32,
        source_end: u32,
    };

    pub fn advanceX(self: *const ShapedText) f32 {
        var result: f32 = 0;
        for (self.glyphs) |glyph| result += glyph.x_advance;
        return result;
    }

    pub fn advanceY(self: *const ShapedText) f32 {
        var result: f32 = 0;
        for (self.glyphs) |glyph| result += glyph.y_advance;
        return result;
    }

    pub fn deinit(self: *ShapedText) void {
        self.allocator.free(self.glyphs);
        self.* = undefined;
    }
};

pub const LineMetrics = struct {
    ascent: i32,
    descent: i32,
    line_gap: i32,
};

const FontStorage = struct {
    blob: *c.hb_blob_t,
    face: *c.hb_face_t,
    handle: *c.hb_font_t,
    upem: u32,
};

/// Parsed font borrowing bytes owned by the caller. The storage is deliberately
/// type-erased: HarfBuzz handles remain an implementation detail of this
/// module, while the public value exposes only shaping and metric operations.
pub const Font = struct {
    _storage: *anyopaque,

    fn storage(self: *const Font) *FontStorage {
        return @ptrCast(@alignCast(self._storage));
    }

    pub fn init(bytes: []const u8) !Font {
        return initFace(bytes, 0);
    }

    /// Parse one face from a standalone font or TTC/OTC collection.
    pub fn initFace(bytes: []const u8, face_index: u32) !Font {
        if (bytes.len == 0 or bytes.len > std.math.maxInt(c_uint)) return error.InvalidFont;
        const owned = try std.heap.c_allocator.create(FontStorage);
        errdefer std.heap.c_allocator.destroy(owned);
        const blob = c.hb_blob_create(
            @ptrCast(bytes.ptr),
            @intCast(bytes.len),
            c.HB_MEMORY_MODE_READONLY,
            null,
            null,
        ) orelse return error.InvalidFont;
        errdefer c.hb_blob_destroy(blob);
        const face = c.hb_face_create(blob, face_index) orelse return error.InvalidFont;
        errdefer c.hb_face_destroy(face);
        const handle = c.hb_font_create(face) orelse return error.InvalidFont;
        errdefer c.hb_font_destroy(handle);
        c.hb_ot_font_set_funcs(handle);
        const upem = c.hb_face_get_upem(face);
        if (upem == 0) return error.InvalidFont;
        c.hb_font_set_scale(handle, @intCast(upem), @intCast(upem));
        owned.* = .{ .blob = blob, .face = face, .handle = handle, .upem = upem };
        return .{ ._storage = owned };
    }

    pub fn deinit(self: *Font) void {
        const value = self.storage();
        c.hb_font_destroy(value.handle);
        c.hb_face_destroy(value.face);
        c.hb_blob_destroy(value.blob);
        std.heap.c_allocator.destroy(value);
        self.* = undefined;
    }

    pub fn unitsPerEm(self: *const Font) u32 {
        return self.storage().upem;
    }

    pub fn lineMetrics(self: *const Font) !LineMetrics {
        const blob = c.hb_face_reference_table(self.storage().face, tag("hhea")) orelse
            return error.NoHorizontalMetrics;
        defer c.hb_blob_destroy(blob);
        const data = try blobBytes(blob);
        if (data.len < 10) return error.NoHorizontalMetrics;
        return .{
            .ascent = readI16(data, 4),
            .descent = readI16(data, 6),
            .line_gap = readI16(data, 8),
        };
    }

    pub fn glyphIndex(self: *const Font, codepoint: u21) !u32 {
        var glyph: c.hb_codepoint_t = 0;
        if (c.hb_font_get_nominal_glyph(self.storage().handle, codepoint, &glyph) == 0)
            return error.MissingGlyph;
        return glyph;
    }

    pub fn advanceWidth(self: *const Font, glyph: u32) !i32 {
        const value = self.storage();
        if (glyph >= c.hb_face_get_glyph_count(value.face)) return error.MissingGlyph;
        const hhea_blob = c.hb_face_reference_table(value.face, tag("hhea")) orelse
            return error.NoHorizontalMetrics;
        defer c.hb_blob_destroy(hhea_blob);
        const hhea = try blobBytes(hhea_blob);
        if (hhea.len < 36) return error.NoHorizontalMetrics;
        const metric_count = readU16(hhea, 34);
        if (metric_count == 0) return error.NoHorizontalMetrics;

        const hmtx_blob = c.hb_face_reference_table(value.face, tag("hmtx")) orelse
            return error.NoHorizontalMetrics;
        defer c.hb_blob_destroy(hmtx_blob);
        const hmtx = try blobBytes(hmtx_blob);
        const metric_index = @min(glyph, @as(u32, metric_count) - 1);
        const offset = @as(usize, metric_index) * 4;
        if (offset + 2 > hmtx.len) return error.NoHorizontalMetrics;
        return readU16(hmtx, offset);
    }
};

fn tag(comptime name: *const [4:0]u8) c.hb_tag_t {
    return (@as(u32, name[0]) << 24) |
        (@as(u32, name[1]) << 16) |
        (@as(u32, name[2]) << 8) |
        @as(u32, name[3]);
}

fn blobBytes(blob: *c.hb_blob_t) ![]const u8 {
    var len: c_uint = 0;
    const raw = c.hb_blob_get_data(blob, &len) orelse return error.InvalidFont;
    return @as([*]const u8, @ptrCast(raw))[0..len];
}

fn readU16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .big);
}

fn readI16(bytes: []const u8, offset: usize) i16 {
    return @bitCast(readU16(bytes, offset));
}

pub const Face = struct {
    font: *const Font,
    font_id: u32,
    weight: FontWeight = .regular,
    italic: bool = false,
};

/// An ordered family of style alternatives. `shape` selects one face for the
/// complete input run; glyph fallback is intentionally not implied by this
/// type. A caller that needs script fallback itemizes runs before shaping.
pub const StyleSet = struct {
    _storage: *anyopaque,

    const Storage = struct {
        allocator: Allocator,
        entries: []Face,
    };

    fn storage(self: *const StyleSet) *Storage {
        return @ptrCast(@alignCast(self._storage));
    }

    pub fn build(allocator: Allocator, entries: []const Face) !StyleSet {
        if (entries.len == 0) return error.NoFaces;
        const owned = try allocator.dupe(Face, entries);
        errdefer allocator.free(owned);
        const value = try allocator.create(Storage);
        value.* = .{ .allocator = allocator, .entries = owned };
        return .{ ._storage = value };
    }

    pub fn deinit(self: *StyleSet) void {
        const value = self.storage();
        const allocator = value.allocator;
        allocator.free(value.entries);
        allocator.destroy(value);
        self.* = undefined;
    }

    fn select(self: *const StyleSet, style: FontStyle) Face {
        const entries = self.storage().entries;
        if (findStyle(entries, style)) |entry| return entry;
        if (style.italic and style.weight != .regular) {
            if (findStyle(entries, .{ .weight = style.weight })) |entry| return entry;
            if (findStyle(entries, .{ .italic = true })) |entry| return entry;
        }
        if (findStyle(entries, .{})) |entry| return entry;
        return entries[0];
    }
};

fn findStyle(entries: []const Face, style: FontStyle) ?Face {
    for (entries) |entry| {
        if (entry.weight == style.weight and entry.italic == style.italic) return entry;
    }
    return null;
}

pub const ShapeOptions = struct {
    style: FontStyle = .{},
};

/// Shape UTF-8 into em-relative positioned glyphs. Source ranges remain byte
/// offsets into `utf8`; consumers never need to understand HarfBuzz clusters.
pub fn shape(allocator: Allocator, faces: *const StyleSet, utf8: []const u8, options: ShapeOptions) !ShapedText {
    if (utf8.len > std.math.maxInt(c_int)) return error.TextTooLong;
    _ = std.unicode.Utf8View.init(utf8) catch return error.InvalidUtf8;
    const selected = faces.select(options.style);
    const buffer = c.hb_buffer_create() orelse return error.OutOfMemory;
    defer c.hb_buffer_destroy(buffer);
    c.hb_buffer_set_cluster_level(buffer, c.HB_BUFFER_CLUSTER_LEVEL_MONOTONE_CHARACTERS);
    c.hb_buffer_add_utf8(buffer, @ptrCast(utf8.ptr), @intCast(utf8.len), 0, @intCast(utf8.len));
    c.hb_buffer_guess_segment_properties(buffer);
    c.hb_shape(selected.font.storage().handle, buffer, null, 0);

    var count: c_uint = 0;
    const infos = c.hb_buffer_get_glyph_infos(buffer, &count);
    const positions = c.hb_buffer_get_glyph_positions(buffer, &count);
    if (count != 0 and (infos == null or positions == null)) return error.ShapeFailed;
    const glyphs = try allocator.alloc(ShapedText.Glyph, count);
    errdefer allocator.free(glyphs);
    const cluster_starts = try allocator.alloc(u32, count);
    defer allocator.free(cluster_starts);
    for (cluster_starts, 0..) |*start, index| {
        start.* = @intCast(@min(infos[index].cluster, utf8.len));
    }
    std.mem.sort(u32, cluster_starts, {}, std.sort.asc(u32));

    const upem: f32 = @floatFromInt(selected.font.unitsPerEm());
    var pen_x: i64 = 0;
    var pen_y: i64 = 0;
    for (glyphs, 0..) |*out, index| {
        const info = infos[index];
        const pos = positions[index];
        const cluster: u32 = @intCast(@min(info.cluster, utf8.len));
        const cluster_end = nextClusterStart(cluster_starts, cluster, @intCast(utf8.len));
        out.* = .{
            .font_id = selected.font_id,
            .glyph_id = info.codepoint,
            .x_offset = @as(f32, @floatFromInt(pen_x + pos.x_offset)) / upem,
            .y_offset = -@as(f32, @floatFromInt(pen_y + pos.y_offset)) / upem,
            .x_advance = @as(f32, @floatFromInt(pos.x_advance)) / upem,
            .y_advance = -@as(f32, @floatFromInt(pos.y_advance)) / upem,
            .source_start = cluster,
            .source_end = cluster_end,
        };
        pen_x += pos.x_advance;
        pen_y += pos.y_advance;
    }
    return .{ .allocator = allocator, .glyphs = glyphs };
}

fn nextClusterStart(sorted: []const u32, cluster: u32, text_len: u32) u32 {
    var lo: usize = 0;
    var hi: usize = sorted.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (sorted[mid] <= cluster) lo = mid + 1 else hi = mid;
    }
    return if (lo < sorted.len) sorted[lo] else text_len;
}

test "shape exposes glyph clusters and em-relative advances" {
    const gpa = std.testing.allocator;
    const bytes = @embedFile("font_mono");
    var font = try Font.init(bytes);
    defer font.deinit();
    var faces = try StyleSet.build(gpa, &.{.{ .font = &font, .font_id = 7 }});
    defer faces.deinit();
    var shaped = try shape(gpa, &faces, "abc", .{});
    defer shaped.deinit();
    try std.testing.expectEqual(@as(usize, 3), shaped.glyphs.len);
    try std.testing.expect(shaped.advanceX() > 0);
    try std.testing.expectEqual(@as(u32, 7), shaped.glyphs[0].font_id);
    try std.testing.expectEqual(@as(u32, 0), shaped.glyphs[0].source_start);
}

fn expectValidSourceRanges(text: []const u8, shaped: *const ShapedText) !void {
    for (shaped.glyphs) |glyph| {
        try std.testing.expect(glyph.source_start < glyph.source_end);
        try std.testing.expect(glyph.source_end <= text.len);
        _ = std.unicode.Utf8View.init(text[glyph.source_start..glyph.source_end]) catch
            return error.TestInvalidClusterRange;
    }
}

test "shape reports valid UTF-8 byte ranges for complex clusters and RTL" {
    const gpa = std.testing.allocator;
    var font = try Font.init(@embedFile("font_mono"));
    defer font.deinit();
    var faces = try StyleSet.build(gpa, &.{.{ .font = &font, .font_id = 7 }});
    defer faces.deinit();

    for ([_][]const u8{ "aé", "e\u{0301}", "ffi", "سلام" }) |input| {
        var shaped = try shape(gpa, &faces, input, .{});
        defer shaped.deinit();
        try std.testing.expect(shaped.glyphs.len != 0);
        try expectValidSourceRanges(input, &shaped);
    }
}

test "shape rejects invalid UTF-8" {
    const gpa = std.testing.allocator;
    var font = try Font.init(@embedFile("font_mono"));
    defer font.deinit();
    var faces = try StyleSet.build(gpa, &.{.{ .font = &font, .font_id = 7 }});
    defer faces.deinit();
    try std.testing.expectError(error.InvalidUtf8, shape(gpa, &faces, "\xff", .{}));
}

test "style selection uses the requested face without exposing shaper state" {
    const gpa = std.testing.allocator;
    var regular = try Font.init(@embedFile("font_mono"));
    defer regular.deinit();
    var bold = try Font.init(@embedFile("font_mono"));
    defer bold.deinit();
    var faces = try StyleSet.build(gpa, &.{
        .{ .font = &regular, .font_id = 1 },
        .{ .font = &bold, .font_id = 2, .weight = .bold },
    });
    defer faces.deinit();
    var shaped = try shape(gpa, &faces, "x", .{ .style = .{ .weight = .bold } });
    defer shaped.deinit();
    try std.testing.expectEqual(@as(u32, 2), shaped.glyphs[0].font_id);
    try std.testing.expect(!@hasField(Font, "handle"));
    try std.testing.expect(!@hasField(StyleSet, "entries"));
}
