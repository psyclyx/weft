//! labels — jump labels drawn over the text (doc/configs.md §0.3), for
//! whichever plugin wants "pick one of these places with a key or two":
//! helix's `gw`.
//!
//! A label is drawn as an `overlay` annotation at its target, over the
//! target's own cells, so no text moves and the caret is untouched. Labels
//! are one character (as many targets as the alphabet has letters) or two
//! (the square of it); with two, the first key narrows the set and redraws
//! the survivors with just the key still to type, and the second picks.
//!
//! The caller owns the targets and what choosing one means; this owns the
//! layer, the label text, and reading keys against it. Freestanding-wasm
//! shaped: fixed storage, one `Set` per use, no allocator.

const std = @import("std");
const weft = @import("weft");

/// The most targets one set labels: two-character labels over a 26-letter
/// alphabet.
pub const max_targets = 26 * 26;

/// The focused entry's compact id — the handle an annotation layer opens on.
pub fn activeEntry() ?u32 {
    var i: usize = 0;
    while (i < weft.bufferCount()) : (i += 1) {
        if (!weft.bufferActive(i)) continue;
        const id = weft.bufferId(i) orelse return null;
        return @intCast(id);
    }
    return null;
}

/// What a key did to a set of labels on screen.
pub const Outcome = union(enum) {
    /// It picked target `i` (an index into the offsets `show` took).
    chosen: usize,
    /// It narrowed a two-character set; the survivors are redrawn and the
    /// next key picks among them.
    pending,
    /// It named no label. The labels are gone.
    none,
};

pub const Set = struct {
    targets: [max_targets]usize = undefined,
    n: usize = 0,
    alphabet_buf: [64]u8 = undefined,
    alphabet_len: usize = 0,
    /// Characters per label, 1 or 2.
    width: usize = 1,
    /// The first key of a two-character label, once typed.
    first: ?u8 = null,
    layer: ?weft.Annotations = null,
    name: []const u8 = "labels",

    fn alphabet(self: *const Set) []const u8 {
        return self.alphabet_buf[0..self.alphabet_len];
    }

    /// How many targets `alphabet` can label at `width` characters each.
    pub fn capacity(alphabet_in: []const u8, width: usize) usize {
        const n = @min(alphabet_in.len, 64);
        return @min(max_targets, if (width == 2) n * n else n);
    }

    /// Label `offsets` (nearest first: the easiest labels go to them) on
    /// annotation layer `name` of the focused entry. Offsets past the
    /// capacity are not labelled. False when there is nothing to draw on —
    /// the caller then falls back.
    pub fn show(self: *Set, name: []const u8, offsets: []const usize, alphabet_in: []const u8, width: usize) bool {
        self.clear();
        self.name = name;
        self.width = if (width == 2) 2 else 1;
        self.alphabet_len = @min(alphabet_in.len, self.alphabet_buf.len);
        @memcpy(self.alphabet_buf[0..self.alphabet_len], alphabet_in[0..self.alphabet_len]);
        if (self.alphabet_len == 0) return false;
        self.n = @min(offsets.len, capacity(alphabet_in, self.width));
        @memcpy(self.targets[0..self.n], offsets[0..self.n]);
        self.first = null;
        const entry = activeEntry() orelse return false;
        self.layer = weft.Annotations.open(entry, name) orelse return false;
        return self.draw();
    }

    /// Label `i`'s text — one or two characters of the alphabet.
    pub fn label(self: *const Set, i: usize, out: *[2]u8) []const u8 {
        const a = self.alphabet();
        if (self.width == 1) {
            out[0] = a[i];
            return out[0..1];
        }
        out[0] = a[i / a.len];
        out[1] = a[i % a.len];
        return out[0..2];
    }

    fn draw(self: *Set) bool {
        const anno = self.layer orelse return false;
        if (!anno.begin()) {
            self.clear();
            return false;
        }
        for (self.targets[0..self.n], 0..) |off, i| {
            var buf: [2]u8 = undefined;
            const text = self.label(i, &buf);
            if (self.first) |f| {
                // Narrowed: only the labels that began with the typed key,
                // showing what is left to type.
                if (text[0] != f) continue;
                anno.span(off, off, .removed, .overlay, text[1..]);
            } else anno.span(off, off, .removed, .overlay, text);
        }
        return true;
    }

    /// Read one typed key against the labels on screen.
    pub fn press(self: *Set, key: []const u8) Outcome {
        if (key.len != 1 or self.n == 0) {
            self.clear();
            return .none;
        }
        const c = key[0];
        const a = self.alphabet();
        const at = std.mem.indexOfScalar(u8, a, c) orelse {
            self.clear();
            return .none;
        };
        if (self.width == 1) {
            self.clear();
            return if (at < self.n) .{ .chosen = at } else .none;
        }
        if (self.first) |f| {
            const i = (std.mem.indexOfScalar(u8, a, f) orelse 0) * a.len + at;
            self.clear();
            return if (i < self.n) .{ .chosen = i } else .none;
        }
        if (at * a.len >= self.n) {
            self.clear();
            return .none;
        }
        self.first = c;
        if (!self.draw()) return .none;
        return .pending;
    }

    /// Take the labels away.
    pub fn clear(self: *Set) void {
        if (self.layer) |anno| anno.close();
        self.layer = null;
        self.first = null;
    }
};
