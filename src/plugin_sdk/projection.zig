//! `projection` — publish a node tree; the host owns every offset.
//!
//! The shape a tool plugin wanted all along. You describe rows: each has a KEY
//! you chose, a ROLE saying what it is, its text, and its parent. You commit.
//! Afterwards you ask only which key the cursor is on, and which lines of a key
//! a selection covers.
//!
//! What you no longer write, because the host does it once for every producer:
//!
//!   - emitting text while tracking your own output offset;
//!   - a parallel `[start,end)` table per node, and the linear scan that
//!     hit-tests the cursor back through it;
//!   - `styleClear` plus a `style(start, end, class)` per span;
//!   - `foldClear` plus a `fold(start, end)` per collapsed row, and the bounded
//!     set of collapsed paths that survives a refresh;
//!   - capturing a target and a fallback offset before a rebuild, then
//!     re-finding it after, so the cursor lands on the same ROW;
//!   - reading a selection's byte range back into line ordinals.
//!
//! And the thing you cannot do: name an offset. There is no door here that
//! takes one or returns one, so "acted on whatever row a stale offset now
//! covers" stops being a bug you can write.

const std = @import("std");
const weft = @import("root.zig");
const e = @import("externs.zig");

fn p(x: anytype) u32 {
    return @intCast(@intFromPtr(x));
}

/// An ordinal in the open build — what a child names as its parent. Opaque:
/// it is meaningful only until the commit that consumes it.
pub const Ordinal = u32;

/// One row.
pub const Node = struct {
    /// YOUR identity for this row: a path, an OID, a section name. Fold state
    /// and cursor restoration are keyed by it, so a row that keeps its key
    /// across a rebuild keeps its fold and keeps the cursor.
    key: []const u8,
    /// What this row IS — `git.file`, `fs.directory`, `dap.frame`. Styling
    /// resolves through it, and it is what another plugin attaches to when it
    /// wants to add a verb or a decoration to rows it did not produce.
    role: []const u8 = "",
    /// The row's text, verbatim, including any indentation you want. A
    /// trailing newline is added if you leave it off. Empty text makes a pure
    /// container: it occupies no row and folds its children.
    text: []const u8 = "",
    parent: ?Ordinal = null,
    /// Whether this row.s children may be hidden.
    foldable: bool = false,
    /// Whether the cursor may REST here. Structure rows (a title, a header)
    /// leave this false so a fresh render lands on something a verb can act on.
    focusable: bool = false,
    /// WHICH PART of this row the user may type into, or null for none.
    ///
    /// A span, not a flag: a row is not all name. `  ▸ src` is an indent, a
    /// glyph and a name, and only the last is the user.s to change — whole-row
    /// editing let a keystroke at the row start turn the glyph into text and
    /// rename the entry to something nobody typed. `projectionRows` reports
    /// this span, and nothing else.
    editable: ?struct { start: usize, end: usize } = null,
};

/// A build in progress. Open one with `begin`, `add` rows, then `commit`.
pub const Builder = struct {
    /// Add a row; returns the ordinal a child names as its parent. Null when
    /// the host refused it (no open build, or a parent that does not exist).
    pub fn add(self: Builder, node: Node) ?Ordinal {
        _ = self;
        const flags: u32 = (if (node.foldable) @as(u32, 1) else 0) |
            (if (node.focusable) @as(u32, 2) else 0) |
            (if (node.editable != null) @as(u32, 4) else 0);
        const parent: i32 = if (node.parent) |ord| @intCast(ord) else -1;
        const ordinal = e.wl_proj_node(
            p(node.key.ptr),
            @intCast(node.key.len),
            p(node.role.ptr),
            @intCast(node.role.len),
            p(node.text.ptr),
            @intCast(node.text.len),
            parent,
            flags,
            if (node.editable) |e2| @intCast(e2.start) else 0,
            if (node.editable) |e2| @intCast(e2.end) else 0,
        );
        return if (ordinal < 0) null else @intCast(ordinal);
    }

    /// `add`, with the text formatted. The formatted bytes live only for the
    /// call — the host copies them.
    pub fn addFmt(self: Builder, node: Node, comptime fmt: []const u8, args: anytype) ?Ordinal {
        var buf: [4096]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt, args) catch return null;
        var with_text = node;
        with_text.text = text;
        return self.add(with_text);
    }

    /// Style `[start,end)` of `node`'s OWN text with `role`.
    ///
    /// The offsets index the text you just passed to `add`, not the document —
    /// so this is the one place a projection producer counts bytes, and it
    /// counts bytes it wrote. `grep` emphasises the matched substring of a
    /// result line with it; before, that meant `weft.style(base + content_start
    /// + off, …)`, three offsets added together with one of them recovered by
    /// re-scanning the rendered row.
    ///
    /// Clamped to the node, so a producer that miscounts shortens its own
    /// emphasis rather than painting its neighbours.
    pub fn span(self: Builder, node: Ordinal, start: usize, end: usize, role: []const u8) void {
        _ = self;
        e.wl_proj_span(
            @intCast(node),
            @intCast(start),
            @intCast(end),
            p(role.ptr),
            @intCast(role.len),
        );
    }

    /// Render the tree into the buffer, repaint styles and folds, and land the
    /// cursor on the key it was on. Returns the new revision — the number a
    /// decision made against this tree should carry, so one made against an
    /// older tree can be refused.
    pub fn commit(self: Builder) ?u32 {
        _ = self;
        const revision = e.wl_proj_commit();
        return if (revision < 0) null else @bitCast(revision);
    }
};

/// Open a build over the named buffer. The entry is captured NOW, so nothing
/// that happens while you build — a focus change, another plugin's fill — can
/// redirect where the projection lands. Null when there is no such buffer.
pub fn begin(buffer: []const u8) ?Builder {
    if (e.wl_proj_begin(p(buffer.ptr), @intCast(buffer.len)) != 0) return null;
    return .{};
}

var key_scratch: [1024]u8 = undefined;

/// The key of the innermost row the cursor is on, or null for no row. This is
/// the ONE question a verb asks, and its answer is an identity — the offset
/// that produced it never crosses.
pub fn atCursor() ?[]const u8 {
    const n = e.wl_proj_at_cursor(p(&key_scratch), key_scratch.len);
    if (n <= 0) return null;
    return key_scratch[0..@intCast(n)];
}

/// Flip a row's fold and re-render. No producer is consulted: a fold changes
/// the view, never the model, so nothing is re-gathered.
pub fn toggleFold(key: []const u8) ?u32 {
    const revision = e.wl_proj_toggle(p(key.ptr), @intCast(key.len));
    return if (revision < 0) null else @bitCast(revision);
}

/// Which body LINES of `key` the selection covers, as ordinals within that row.
/// Null when the selection touches none of it.
///
/// Ordinals, not offsets. "Lines 2 through 4 of this row" survives a re-render
/// and is refused outright once the revision moves; a byte range silently means
/// something else.
pub fn selectedLines(key: []const u8) ?struct { lo: usize, hi: usize } {
    var out: [8]u8 = undefined;
    const n = e.wl_proj_selection(p(key.ptr), @intCast(key.len), p(&out), out.len);
    if (n < 8) return null;
    return .{
        .lo = std.mem.readInt(u32, out[0..4], .little),
        .hi = std.mem.readInt(u32, out[4..8], .little),
    };
}

/// One published row, as it reads NOW.
pub const Row = struct {
    /// The key this producer gave the row. Borrows the scratch below.
    key: []const u8,
    /// What the row says after whatever the user typed. Empty when the row was
    /// deleted or blanked — which is how "dropped" is spelled, and why a
    /// producer that treats empty as "unchanged" will silently keep something
    /// the user meant to remove.
    text: []const u8,
};

/// Scratch for one `rows()` read. A row list is bounded by what the producer
/// published, and a producer that published more than this has bigger problems
/// than the truncation.
var rows_buf: [1 << 16]u8 = undefined;

/// Every EDITABLE row, in rendered order, as it reads now.
///
/// This is the other half of `Node.editable`, and it is what lets a row be text
/// AND have an identity — doc/plugin-api.md §F2's fork, from the text side. The
/// user reorders a rebase plan, renames a file in a listing, blanks a line; a
/// producer asks what each row it published has become, addressed by the KEY it
/// chose. Not by position: the host tracks each row with anchors the document
/// shifts, so nothing here depends on a line having stayed where it was put.
///
/// A row the user SPLIT reads to its first newline. The remainder is a line
/// this producer never published, and it is not reported as one — a new row is
/// the producer's own business to notice, out of the buffer's text.
///
/// The slices borrow a shared scratch; copy anything that must outlive the
/// next call.
pub fn rows(out: []Row) []const Row {
    const n = e.wl_proj_rows(p(&rows_buf), @intCast(rows_buf.len));
    if (n <= 0) return out[0..0];
    var count: usize = 0;
    var i: usize = 0;
    const bytes = rows_buf[0..@intCast(n)];
    while (i < bytes.len and count < out.len) {
        const k_end = std.mem.indexOfScalarPos(u8, bytes, i, 0) orelse break;
        const t_end = std.mem.indexOfScalarPos(u8, bytes, k_end + 1, 0) orelse break;
        out[count] = .{ .key = bytes[i..k_end], .text = bytes[k_end + 1 .. t_end] };
        count += 1;
        i = t_end + 1;
    }
    return out[0..count];
}

/// Select `[start,end)` of `node`'s OWN text — the companion to
/// `Builder.span`, and the thing a producer needs right after creating a row:
/// the new name is a PLACEHOLDER, so the next keystroke should replace it
/// rather than append to it.
///
/// Node-relative, like every other position here. A selection named in document
/// coordinates would be the stale-offset hazard wearing a different hat.
pub fn select(node: Ordinal, start: usize, end: usize) void {
    e.wl_proj_select(@intCast(node), @intCast(start), @intCast(end));
}
