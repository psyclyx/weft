//! Font-set ownership and style selection over a platform font provider.
//!
//! The editor needs a monospace face for code/HUD and a proportional
//! sans family (regular/bold/italic/bold-italic) for markdown prose.
//! `FontStyle` selects only on weight+italic, so mono and
//! sans-regular — both "regular" — would collide in one style chain.
//! Hence TWO `StyleSet`s: `mono` (code, unchanged behavior) and `body`
//! (the styled sans chain, one `shape(style=…)` picks the variant).
//!
//! Optional face bytes come from the platform-selected `weft_font_provider`.
//! The caller's mono bytes are the reliable base and the fallback for any face
//! the active provider cannot resolve.

const std = @import("std");
const Allocator = std.mem.Allocator;

const text = @import("weft_text");
const font_provider = @import("weft_font_provider");

// Stable source font ids. Mono is 1 (kept first so plain Latin in
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
    /// Heap-allocated for stable addresses (StyleSet borrows these pointers).
    fonts: [5]*text.Font,
    /// Owned font file bytes, one per font (Font borrows them).
    bytes: [5][]u8,
    /// Face index within each standalone font or TTC/OTC collection.
    face_indices: [5]u32,
    mono: text.StyleSet,
    body: text.StyleSet,

    /// Resolve the face set. `mono_bytes` is the caller-owned monospace
    /// source (embedded or `--font`); it is copied so the set owns a
    /// uniform lifetime, and it backs any sans variant fontconfig misses.
    pub fn init(gpa: Allocator, mono_bytes: []const u8) !FaceSet {
        var bytes: [5][]u8 = undefined;
        var face_indices: [5]u32 = @splat(0);
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
            if (font_provider.loadFace(gpa, .{
                .family = "sans-serif",
                .bold = w.bold,
                .italic = w.italic,
            }) catch null) |loaded| {
                bytes[i] = loaded.bytes;
                face_indices[i] = loaded.face_index;
            } else {
                bytes[i] = try gpa.dupe(u8, mono_bytes);
            }
            filled = i + 1;
        }

        // Heap fonts for stable addresses.
        var fonts: [5]*text.Font = undefined;
        var nf: usize = 0;
        errdefer for (fonts[0..nf]) |f| {
            f.deinit();
            gpa.destroy(f);
        };
        for (0..5) |i| {
            const f = try gpa.create(text.Font);
            errdefer gpa.destroy(f);
            f.* = try text.Font.initFace(bytes[i], face_indices[i]);
            fonts[i] = f;
            nf = i + 1;
        }

        var mono = try text.StyleSet.build(gpa, &.{
            .{ .font = fonts[fontIndex(font_id_mono)], .font_id = font_id_mono },
        });
        errdefer mono.deinit();
        const body = try text.StyleSet.build(gpa, &.{
            .{ .font = fonts[fontIndex(font_id_body)], .font_id = font_id_body, .weight = .regular, .italic = false },
            .{ .font = fonts[fontIndex(font_id_body_bold)], .font_id = font_id_body_bold, .weight = .bold, .italic = false },
            .{ .font = fonts[fontIndex(font_id_body_italic)], .font_id = font_id_body_italic, .weight = .regular, .italic = true },
            .{ .font = fonts[fontIndex(font_id_body_bolditalic)], .font_id = font_id_body_bolditalic, .weight = .bold, .italic = true },
        });

        return .{
            .gpa = gpa,
            .fonts = fonts,
            .bytes = bytes,
            .face_indices = face_indices,
            .mono = mono,
            .body = body,
        };
    }

    pub fn deinit(self: *FaceSet) void {
        self.body.deinit();
        self.mono.deinit();
        for (self.fonts) |f| {
            f.deinit();
            self.gpa.destroy(f);
        }
        for (self.bytes) |b| self.gpa.free(b);
        self.* = undefined;
    }

    pub fn monoFont(self: *const FaceSet) *text.Font {
        return self.fonts[fontIndex(font_id_mono)];
    }
};
