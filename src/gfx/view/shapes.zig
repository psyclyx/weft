//! Shaped text, kept between frames. A frame lays out every pane, every
//! chrome label and every popup row again, and most of that text is what
//! the last frame shaped; shaping it once and keeping the glyphs (a bounded
//! `core.cache`, least recently used out first) leaves HarfBuzz the text that
//! changed.
//!
//! Glyphs are em-relative, so one entry serves every size. Only the View's
//! own two style sets are kept — their identity is the View's for its whole
//! life — and text in any other set is shaped as it always was. A caller
//! gets its own copy of the glyphs in the allocator it passes, as it would
//! from `text_engine.shape`: nothing it holds is the cache's, so no eviction
//! can pull a run out from under a frame.

const std = @import("std");
const Allocator = std.mem.Allocator;
const text_engine = @import("weft_text");
const core = @import("weft_core");
const fonts = @import("../fonts.zig");

const Glyph = text_engine.ShapedText.Glyph;

pub const Shapes = struct {
    /// About a few thousand screenfuls of rows and labels: enough that a
    /// frame's text is kept, never enough to matter.
    pub const limits: core.cache.Limits = .{ .bytes = 4 << 20, .entries = 16 * 1024 };

    const Faces = enum(u8) { mono, body };

    const Key = struct {
        faces: Faces,
        style: text_engine.FontStyle,
        text: []const u8,
    };

    const Ctx = struct {
        pub fn hash(_: Ctx, k: Key) u64 {
            const seed: u64 = @intFromEnum(k.faces) |
                @as(u64, @intFromEnum(k.style.weight)) << 8 |
                @as(u64, @intFromBool(k.style.italic)) << 16;
            return std.hash.Wyhash.hash(seed, k.text);
        }
        pub fn eql(_: Ctx, a: Key, b: Key) bool {
            return a.faces == b.faces and a.style.weight == b.style.weight and
                a.style.italic == b.style.italic and std.mem.eql(u8, a.text, b.text);
        }
        pub fn cost(_: Ctx, k: Key, v: []Glyph) usize {
            // The index's own share of an entry, on top of what it holds.
            const overhead = 96;
            return overhead + k.text.len + v.len * @sizeOf(Glyph);
        }
        pub fn release(_: Ctx, gpa: Allocator, k: Key, v: []Glyph) void {
            gpa.free(k.text);
            gpa.free(v);
        }
    };

    cache: core.cache.Bounded(Key, []Glyph, Ctx),

    pub fn init(gpa: Allocator) Shapes {
        return .{ .cache = .init(gpa, .{}, limits) };
    }

    pub fn deinit(self: *Shapes) void {
        self.cache.deinit();
    }

    /// `utf8` shaped in `faces`, its glyphs in `out` — `text_engine.shape`,
    /// from the cache when `faces` is one of `set`'s.
    pub fn shape(self: *Shapes, out: Allocator, set: *const fonts.FaceSet, faces: *const text_engine.StyleSet, utf8: []const u8, options: text_engine.ShapeOptions) !text_engine.ShapedText {
        const key: Key = .{
            .faces = which(set, faces) orelse return text_engine.shape(out, faces, utf8, options),
            .style = options.style,
            .text = utf8,
        };
        if (self.cache.get(key)) |glyphs| return .{ .allocator = out, .glyphs = try out.dupe(Glyph, glyphs.*) };
        const shaped = try text_engine.shape(out, faces, utf8, options);
        self.keep(key, shaped.glyphs);
        return shaped;
    }

    /// `utf8`'s advance in `faces`, per em (null when it cannot be shaped).
    pub fn advance(self: *Shapes, set: *const fonts.FaceSet, faces: *const text_engine.StyleSet, utf8: []const u8, options: text_engine.ShapeOptions) ?f32 {
        const gpa = self.cache.gpa;
        const key: Key = .{
            .faces = which(set, faces) orelse {
                var shaped = text_engine.shape(gpa, faces, utf8, options) catch return null;
                defer shaped.deinit();
                return shaped.advanceX();
            },
            .style = options.style,
            .text = utf8,
        };
        if (self.cache.get(key)) |glyphs| return sum(glyphs.*);
        var shaped = text_engine.shape(gpa, faces, utf8, options) catch return null;
        const width = shaped.advanceX();
        const text = gpa.dupe(u8, utf8) catch {
            shaped.deinit();
            return width;
        };
        self.cache.put(.{ .faces = key.faces, .style = key.style, .text = text }, shaped.glyphs) catch {};
        return width;
    }

    fn which(set: *const fonts.FaceSet, faces: *const text_engine.StyleSet) ?Faces {
        if (faces == &set.mono) return .mono;
        if (faces == &set.body) return .body;
        return null;
    }

    /// Keep a copy of `glyphs` for `key`. Keeping is an optimisation: when
    /// there is no memory for it, the text is shaped again next time.
    fn keep(self: *Shapes, key: Key, glyphs: []const Glyph) void {
        const gpa = self.cache.gpa;
        const text = gpa.dupe(u8, key.text) catch return;
        const kept = gpa.dupe(Glyph, glyphs) catch {
            gpa.free(text);
            return;
        };
        self.cache.put(.{ .faces = key.faces, .style = key.style, .text = text }, kept) catch {};
    }

    fn sum(glyphs: []const Glyph) f32 {
        var w: f32 = 0;
        for (glyphs) |g| w += g.x_advance;
        return w;
    }
};
