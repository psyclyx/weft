//! Font resolution via fontconfig.
//!
//! The editor needs a monospace face for code/HUD and a proportional
//! sans family (regular/bold/italic/bold-italic) for markdown prose.
//! `FontStyle` in snail selects only on weight+italic, so mono and
//! sans-regular — both "regular" — would collide in one style chain.
//! Hence TWO `Faces` sets: `mono` (code, unchanged behavior) and `body`
//! (the styled sans chain, one `shape(style=…)` picks the variant).
//!
//! Faces come from the *system* via fontconfig (real italic, the user's
//! configured fonts) — a deliberate break from the repo's otherwise
//! hermetic pinning; rendered frames now depend on installed fonts. The
//! caller's mono bytes (embedded DejaVu, or `--font`) are the reliable
//! base and the fallback for any face fontconfig can't resolve.

const std = @import("std");
const Allocator = std.mem.Allocator;

const snail = @import("snail");
const core = @import("../core/core.zig");

const c = @cImport({
    @cInclude("fontconfig/fontconfig.h");
});

// Stable atlas/source font ids. Mono is 1 (kept first so plain Latin in
// the mono set never falls back elsewhere); the sans family is 2‑5.
pub const font_id_mono: u32 = 1;
pub const font_id_body: u32 = 2;
pub const font_id_body_bold: u32 = 3;
pub const font_id_body_italic: u32 = 4;
pub const font_id_body_bolditalic: u32 = 5;

/// Which of the five owned fonts a face id maps to (index into `fonts`).
fn fontIndex(id: u32) usize {
    return id - 1;
}

pub const FaceSet = struct {
    gpa: Allocator,
    /// Heap-allocated for stable addresses (Faces borrows these pointers).
    fonts: [5]*snail.Font,
    /// Owned font file bytes, one per font (Font borrows them).
    bytes: [5][]u8,
    mono: snail.Faces,
    body: snail.Faces,

    /// Resolve the face set. `mono_bytes` is the caller-owned monospace
    /// source (embedded or `--font`); it is copied so the set owns a
    /// uniform lifetime, and it backs any sans variant fontconfig misses.
    pub fn init(gpa: Allocator, mono_bytes: []const u8) !FaceSet {
        _ = c.FcInit(); // idempotent; safe to call repeatedly

        var bytes: [5][]u8 = undefined;
        var filled: usize = 0;
        errdefer for (bytes[0..filled]) |b| gpa.free(b);

        // Mono (id 1): the caller's bytes, owned by the set.
        bytes[0] = try gpa.dupe(u8, mono_bytes);
        filled = 1;

        // Sans family (ids 2‑5) from fontconfig; fall back to the mono
        // bytes on any miss so markdown still renders (sans-less).
        const want = [_]struct { bold: bool, italic: bool }{
            .{ .bold = false, .italic = false },
            .{ .bold = true, .italic = false },
            .{ .bold = false, .italic = true },
            .{ .bold = true, .italic = true },
        };
        for (want, 1..) |w, i| {
            bytes[i] = (loadFace(gpa, "sans-serif", w.bold, w.italic) catch null) orelse
                try gpa.dupe(u8, mono_bytes);
            filled = i + 1;
        }

        // Heap fonts for stable addresses.
        var fonts: [5]*snail.Font = undefined;
        var nf: usize = 0;
        errdefer for (fonts[0..nf]) |f| gpa.destroy(f);
        for (0..5) |i| {
            const f = try gpa.create(snail.Font);
            errdefer gpa.destroy(f);
            f.* = try snail.Font.init(bytes[i]);
            fonts[i] = f;
            nf = i + 1;
        }

        var mono = try snail.Faces.build(gpa, &.{
            .{ .font = fonts[fontIndex(font_id_mono)], .font_id = font_id_mono },
        });
        errdefer mono.deinit();
        const body = try snail.Faces.build(gpa, &.{
            .{ .font = fonts[fontIndex(font_id_body)], .font_id = font_id_body, .weight = .regular, .italic = false },
            .{ .font = fonts[fontIndex(font_id_body_bold)], .font_id = font_id_body_bold, .weight = .bold, .italic = false },
            .{ .font = fonts[fontIndex(font_id_body_italic)], .font_id = font_id_body_italic, .weight = .regular, .italic = true },
            .{ .font = fonts[fontIndex(font_id_body_bolditalic)], .font_id = font_id_body_bolditalic, .weight = .bold, .italic = true },
        });

        return .{ .gpa = gpa, .fonts = fonts, .bytes = bytes, .mono = mono, .body = body };
    }

    pub fn deinit(self: *FaceSet) void {
        self.body.deinit();
        self.mono.deinit();
        for (self.fonts) |f| self.gpa.destroy(f);
        for (self.bytes) |b| self.gpa.free(b);
        self.* = undefined;
    }

    pub fn monoFont(self: *const FaceSet) *snail.Font {
        return self.fonts[fontIndex(font_id_mono)];
    }

    /// The prepare/upload sources: every font id that can appear in a
    /// shaped run (mono + the sans family), each with a distinct cache key.
    pub fn sources(self: *const FaceSet) [5]snail.FontSource {
        var out: [5]snail.FontSource = undefined;
        for (0..5) |i| {
            const id: u32 = @intCast(i + 1);
            out[i] = .{ .font_id = id, .font = self.fonts[i], .cache_key = @splat(@intCast(id)) };
        }
        return out;
    }
};

/// Resolve one family+style to a file via fontconfig and read its bytes.
/// Returns null on any fontconfig failure so the caller can fall back.
fn loadFace(gpa: Allocator, family: [:0]const u8, bold: bool, italic: bool) !?[]u8 {
    const pat = c.FcPatternCreate() orelse return null;
    defer c.FcPatternDestroy(pat);
    _ = c.FcPatternAddString(pat, c.FC_FAMILY, @ptrCast(family.ptr));
    _ = c.FcPatternAddInteger(pat, c.FC_WEIGHT, if (bold) c.FC_WEIGHT_BOLD else c.FC_WEIGHT_REGULAR);
    _ = c.FcPatternAddInteger(pat, c.FC_SLANT, if (italic) c.FC_SLANT_ITALIC else c.FC_SLANT_ROMAN);
    _ = c.FcConfigSubstitute(null, pat, c.FcMatchPattern);
    c.FcDefaultSubstitute(pat);

    var result: c.FcResult = undefined;
    const match = c.FcFontMatch(null, pat, &result) orelse return null;
    defer c.FcPatternDestroy(match);

    var file: [*c]c.FcChar8 = undefined;
    if (c.FcPatternGetString(match, c.FC_FILE, 0, &file) != c.FcResultMatch) return null;
    const path = std.mem.span(@as([*:0]const u8, @ptrCast(file)));
    return try core.file.readAlloc(gpa, path);
}
