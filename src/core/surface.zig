//! surface — a retained, host-owned overlay a plugin populates (which-key, the
//! picker, files, git …) through the `surfaceBegin/Row/Span/End` membrane.
//!
//! Guests are event-dispatched — there is no per-frame render export — so a
//! guest cannot draw immediate-mode. Instead it pushes a surface DURING a guest
//! call (an `on_menu`, an `on_command`); the host retains it and the view draws
//! it every frame until the guest `close`s it. This is the same retained-mode
//! shape the picker already uses, generalized so UI stops being baked per
//! feature in core: which-key, files, git, transcript viewers are all plugins
//! over this one door.
//!
//! Spans carry a SEMANTIC color role (resolved against the Theme at draw time),
//! never an RGB — so a colorscheme restyles every surface for free, and the
//! membrane validates the small role set once instead of trusting guest bytes.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Where the surface docks. `bottom` is the one dock arbitrated against the
/// picker/which-key (priority in the view); `corner`/`center` overlay the body
/// and never reflow it. `caret` anchors at a document offset (`anchor`)
/// instead — the completion popup and hover box, which track the caret
/// rather than a fixed region.
pub const Placement = enum(u32) { bottom = 0, corner = 1, center = 2, caret = 3 };

/// A span's semantic color role; the view maps each to a Theme field. Keeping
/// this an enum (not a raw color) is what lets a theme recolor every surface.
pub const Role = enum(u32) {
    normal = 0,
    accent = 1,
    /// A which-key/menu GROUP (a key that opens a submenu) — colored distinctly
    /// from a leaf command, the user's explicit ask.
    group = 2,
    /// A leaf command / terminal action.
    leaf = 3,
    /// A side-effecting action (run/shell/etc.).
    effect = 4,
    muted = 5,
    /// A dimmed ANNOTATION beside a row's main content — a completion item's
    /// kind/detail note, a which-key hint's trailing comment. Distinct from
    /// `muted` (a generically de-emphasized row) so a future colorscheme can
    /// tell "this whole row is secondary" from "this column is a side note"
    /// apart; today both resolve to the same comment color (rendering P2 —
    /// see doc/rendering.md). Column-driven callers (`Pick.buildSurface`)
    /// tag column-1+ spans with this instead of leaning on the renderer to
    /// dim by column position, so the color is DATA the surface carries, not
    /// a layout side effect the drawer infers.
    annotation = 6,
    _,

    pub fn fromInt(v: u32) Role {
        return switch (v) {
            0, 1, 2, 3, 4, 5, 6 => @enumFromInt(v),
            else => .normal,
        };
    }
};

/// `column` is a layout hint for a `caret`-placed surface: spans sharing a
/// column across rows are aligned to the same x (0 = main content, 1 = a
/// dimmed annotation beside it — the completion popup's item/note pair).
/// Ignored (all 0) by the corner/center renderer, which lays a row out
/// left-to-right with no alignment.
pub const Span = struct { text: []u8, role: Role, column: u8 = 0 };

pub const Row = struct {
    spans: std.ArrayList(Span) = .empty,

    fn deinit(self: *Row, gpa: Allocator) void {
        for (self.spans.items) |s| gpa.free(s.text);
        self.spans.deinit(gpa);
    }
};

/// One plugin's retained overlay. Built with begin → (row → span…)… → end,
/// double-buffered so a rebuild mid-frame never shows a half-populated surface:
/// `end` swaps the freshly-built rows in and marks it active atomically.
pub const Surface = struct {
    active: bool = false,
    placement: Placement = .bottom,
    selected: ?usize = null,
    /// The live, drawn rows.
    rows: std.ArrayList(Row) = .empty,
    /// The rows being assembled between begin and end (swapped into `rows`).
    scratch_rows: std.ArrayList(Row) = .empty,
    building: bool = false,
    /// Doc offset to anchor at when `placement == .caret`. Null for the
    /// dock/corner/center placements, which never read it.
    anchor: ?usize = null,
    /// A linked side panel (e.g. the selected row's full documentation),
    /// shown beside/below a `caret` surface by the caret-surface renderer.
    /// Owned by whichever allocator built the surface (the persistent gpa for
    /// membrane surfaces; the per-frame arena for pick/hover scratch builds).
    /// Empty when there's nothing to show.
    info: []u8 = &.{},

    pub fn deinit(self: *Surface, gpa: Allocator) void {
        freeRows(gpa, &self.rows);
        freeRows(gpa, &self.scratch_rows);
        gpa.free(self.info);
        self.* = .{};
    }

    fn freeRows(gpa: Allocator, rows: *std.ArrayList(Row)) void {
        for (rows.items) |*r| r.deinit(gpa);
        rows.deinit(gpa);
    }

    /// Start (re)building a surface at `placement`. Discards any prior in-flight
    /// build; the currently-drawn `rows` stay live until `end`.
    pub fn begin(self: *Surface, gpa: Allocator, placement: Placement) void {
        freeRows(gpa, &self.scratch_rows);
        self.scratch_rows = .empty;
        self.placement = placement;
        self.building = true;
    }

    pub fn addRow(self: *Surface, gpa: Allocator) void {
        if (!self.building) return;
        self.scratch_rows.append(gpa, .{}) catch {};
    }

    pub fn addSpan(self: *Surface, gpa: Allocator, text: []const u8, role: Role) void {
        self.addSpanCol(gpa, text, role, 0);
    }

    /// Like `addSpan`, tagging the span with a layout column (see `Span`) so
    /// a `caret` surface's renderer aligns it with the same column in every
    /// other row.
    pub fn addSpanCol(self: *Surface, gpa: Allocator, text: []const u8, role: Role, column: u8) void {
        if (!self.building or self.scratch_rows.items.len == 0) return;
        const owned = gpa.dupe(u8, text) catch return;
        const row = &self.scratch_rows.items[self.scratch_rows.items.len - 1];
        row.spans.append(gpa, .{ .text = owned, .role = role, .column = column }) catch gpa.free(owned);
    }

    /// Set the linked side panel text (replaces any prior copy). Kept out of
    /// begin/row/span/end: the info panel is keyed to the SELECTED row alone
    /// and can change without a full rebuild.
    pub fn setInfo(self: *Surface, gpa: Allocator, text: []const u8) void {
        gpa.free(self.info);
        self.info = gpa.dupe(u8, text) catch &.{};
    }

    /// Commit the built rows atomically and mark the surface active. `selected`
    /// is the highlighted row index (e.g. a picker/files cursor), or null.
    pub fn end(self: *Surface, gpa: Allocator, selected: ?usize) void {
        if (!self.building) return;
        freeRows(gpa, &self.rows);
        self.rows = self.scratch_rows;
        self.scratch_rows = .empty;
        self.selected = selected;
        self.building = false;
        self.active = true;
    }

    /// Hide the surface (the guest is done with it). Frees the drawn rows.
    pub fn close(self: *Surface, gpa: Allocator) void {
        freeRows(gpa, &self.rows);
        self.rows = .empty;
        gpa.free(self.info);
        self.info = &.{};
        self.active = false;
        self.selected = null;
        self.anchor = null;
    }
};

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "surface: begin/row/span/end retains rows; close clears; rebuild is atomic" {
    const gpa = t.allocator;
    var s: Surface = .{};
    defer s.deinit(gpa);

    try t.expect(!s.active);
    s.begin(gpa, .corner);
    s.addRow(gpa);
    s.addSpan(gpa, "f", .group);
    s.addSpan(gpa, "find-file", .leaf);
    s.addRow(gpa);
    s.addSpan(gpa, "g", .group);
    // Not visible until end.
    try t.expect(!s.active);
    s.end(gpa, 1);

    try t.expect(s.active);
    try t.expectEqual(Placement.corner, s.placement);
    try t.expectEqual(@as(usize, 2), s.rows.items.len);
    try t.expectEqual(@as(?usize, 1), s.selected);
    try t.expectEqualStrings("f", s.rows.items[0].spans.items[0].text);
    try t.expectEqual(Role.group, s.rows.items[0].spans.items[0].role);
    try t.expectEqualStrings("find-file", s.rows.items[0].spans.items[1].text);

    // A rebuild swaps atomically; the old rows are gone, new ones live.
    s.begin(gpa, .bottom);
    s.addRow(gpa);
    s.addSpan(gpa, "only", .normal);
    s.end(gpa, null);
    try t.expectEqual(@as(usize, 1), s.rows.items.len);
    try t.expectEqual(Placement.bottom, s.placement);
    try t.expectEqual(@as(?usize, null), s.selected);

    s.close(gpa);
    try t.expect(!s.active);
    try t.expectEqual(@as(usize, 0), s.rows.items.len);
}

test "surface: spans/rows are ignored outside a begin/end build" {
    const gpa = t.allocator;
    var s: Surface = .{};
    defer s.deinit(gpa);

    // No begin → dropped, no crash.
    s.addRow(gpa);
    s.addSpan(gpa, "x", .normal);
    s.end(gpa, null);
    try t.expect(!s.active);

    // Span before any row → dropped.
    s.begin(gpa, .bottom);
    s.addSpan(gpa, "orphan", .normal);
    s.end(gpa, null);
    try t.expect(s.active);
    try t.expectEqual(@as(usize, 0), s.rows.items.len);
}

test "surface: caret placement carries an anchor, column tags, and a linked info panel" {
    const gpa = t.allocator;
    var s: Surface = .{};
    defer s.deinit(gpa);

    s.begin(gpa, .caret);
    s.addRow(gpa);
    s.addSpanCol(gpa, "alpine", .normal, 0); // main
    s.addSpanCol(gpa, "kw variable", .muted, 1); // annotation, aligned across rows
    s.addRow(gpa);
    s.addSpan(gpa, "alphabet", .normal); // addSpan still defaults to column 0
    s.end(gpa, 0);
    s.anchor = 42;
    s.setInfo(gpa, "the alpine candidate's docs");

    try t.expect(s.active);
    try t.expectEqual(Placement.caret, s.placement);
    try t.expectEqual(@as(?usize, 42), s.anchor);
    try t.expectEqualStrings("the alpine candidate's docs", s.info);
    try t.expectEqual(@as(u8, 0), s.rows.items[0].spans.items[0].column);
    try t.expectEqual(@as(u8, 1), s.rows.items[0].spans.items[1].column);
    try t.expectEqual(@as(u8, 0), s.rows.items[1].spans.items[0].column);

    // A second `setInfo` replaces (not leaks) the prior copy.
    s.setInfo(gpa, "updated");
    try t.expectEqualStrings("updated", s.info);

    // close() clears the anchor + info alongside the rows — a re-`begin` on
    // a reused Surface starts from a clean slate.
    s.close(gpa);
    try t.expectEqual(@as(?usize, null), s.anchor);
    try t.expectEqual(@as(usize, 0), s.info.len);
}

test {
    std.testing.refAllDecls(@This());
}
