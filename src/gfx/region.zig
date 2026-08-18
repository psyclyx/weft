//! Layout regions — the frame is carved into a tree of rectangles, and
//! every element renders into its own rect. No element computes an offset
//! against the whole frame, so two elements can never claim the same space
//! (the class of bug where which-key overwrote the status line). Pure
//! geometry in pixels; the view and main place content into the rects.

const std = @import("std");

pub const Axis = enum {
    /// Children stacked top-to-bottom (a horizontal divider).
    horizontal,
    /// Children side-by-side left-to-right (a vertical divider).
    vertical,
};

/// Which edges of a pane's rect are internal (shared with a neighbor) and
/// so should get a divider line — an edge is internal exactly when it does
/// not lie on the outer frame boundary. Pure geometry: the window layout
/// computes it, the view draws a 1px line on the marked edges.
pub const Edges = packed struct {
    left: bool = false,
    top: bool = false,
    right: bool = false,
    bottom: bool = false,
};

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn contains(self: Rect, px: f32, py: f32) bool {
        return px >= self.x and px < self.x + self.w and
            py >= self.y and py < self.y + self.h;
    }

    const Cut = struct { strip: Rect, rest: Rect };

    /// Slice `amount` pixels off the top edge (clamped): `strip` is the
    /// slice, `rest` is what remains below.
    pub fn cutTop(self: Rect, amount: f32) Cut {
        const a = std.math.clamp(amount, 0, self.h);
        return .{
            .strip = .{ .x = self.x, .y = self.y, .w = self.w, .h = a },
            .rest = .{ .x = self.x, .y = self.y + a, .w = self.w, .h = self.h - a },
        };
    }

    /// Slice `amount` pixels off the bottom edge; `rest` is above it.
    pub fn cutBottom(self: Rect, amount: f32) Cut {
        const a = std.math.clamp(amount, 0, self.h);
        return .{
            .strip = .{ .x = self.x, .y = self.y + self.h - a, .w = self.w, .h = a },
            .rest = .{ .x = self.x, .y = self.y, .w = self.w, .h = self.h - a },
        };
    }

    /// Slice `amount` pixels off the left edge; `rest` is to its right.
    pub fn cutLeft(self: Rect, amount: f32) Cut {
        const a = std.math.clamp(amount, 0, self.w);
        return .{
            .strip = .{ .x = self.x, .y = self.y, .w = a, .h = self.h },
            .rest = .{ .x = self.x + a, .y = self.y, .w = self.w - a, .h = self.h },
        };
    }

    /// Split into two along `axis`, the first taking `frac` of the size.
    pub fn split(self: Rect, axis: Axis, frac: f32) [2]Rect {
        const f = std.math.clamp(frac, 0, 1);
        return switch (axis) {
            .vertical => blk: {
                const c = self.cutLeft(self.w * f);
                break :blk .{ c.strip, c.rest };
            },
            .horizontal => blk: {
                const c = self.cutTop(self.h * f);
                break :blk .{ c.strip, c.rest };
            },
        };
    }
};

/// A binary layout tree. Leaves are panes (a caller-defined slot index);
/// internal nodes split their rect between two children. Built on the
/// stack — children are borrowed pointers, valid for the walk.
pub const Tree = union(enum) {
    leaf: usize,
    split: Split,

    pub const Split = struct {
        axis: Axis,
        /// The first child's share of the split (0..1).
        frac: f32,
        first: *const Tree,
        second: *const Tree,
    };

    /// Assign each leaf its rect, calling `visit(slot, rect)` in order.
    pub fn each(self: *const Tree, rect: Rect, ctx: anytype, comptime visit: fn (@TypeOf(ctx), usize, Rect) void) void {
        switch (self.*) {
            .leaf => |slot| visit(ctx, slot, rect),
            .split => |s| {
                const halves = rect.split(s.axis, s.frac);
                s.first.each(halves[0], ctx, visit);
                s.second.each(halves[1], ctx, visit);
            },
        }
    }

    /// The leaf slot whose rect contains (px,py), or null.
    pub fn hit(self: *const Tree, rect: Rect, px: f32, py: f32) ?usize {
        return switch (self.*) {
            .leaf => |slot| if (rect.contains(px, py)) slot else null,
            .split => |s| blk: {
                const halves = rect.split(s.axis, s.frac);
                break :blk s.first.hit(halves[0], px, py) orelse s.second.hit(halves[1], px, py);
            },
        };
    }

    /// The rect assigned to `slot` (first match), or null.
    pub fn rectOf(self: *const Tree, rect: Rect, slot: usize) ?Rect {
        return switch (self.*) {
            .leaf => |s| if (s == slot) rect else null,
            .split => |s| blk: {
                const halves = rect.split(s.axis, s.frac);
                break :blk s.first.rectOf(halves[0], slot) orelse s.second.rectOf(halves[1], slot);
            },
        };
    }
};

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "rect: edge cuts partition without overlap or gap" {
    const r: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 80 };
    const top = r.cutTop(20);
    try t.expectEqual(Rect{ .x = 0, .y = 0, .w = 100, .h = 20 }, top.strip);
    try t.expectEqual(Rect{ .x = 0, .y = 20, .w = 100, .h = 60 }, top.rest);
    const bot = r.cutBottom(20);
    try t.expectEqual(Rect{ .x = 0, .y = 60, .w = 100, .h = 20 }, bot.strip);
    try t.expectEqual(Rect{ .x = 0, .y = 0, .w = 100, .h = 60 }, bot.rest);
    // Over-cut clamps (never negative).
    const big = r.cutTop(999);
    try t.expectEqual(@as(f32, 80), big.strip.h);
    try t.expectEqual(@as(f32, 0), big.rest.h);
}

test "tree: leaves tile the rect; hit-test and rectOf agree" {
    // vertical split: left half is leaf 0, right half splits into 1 (top)
    // and 2 (bottom).
    const l0: Tree = .{ .leaf = 0 };
    const l1: Tree = .{ .leaf = 1 };
    const l2: Tree = .{ .leaf = 2 };
    const right: Tree = .{ .split = .{ .axis = .horizontal, .frac = 0.5, .first = &l1, .second = &l2 } };
    const root: Tree = .{ .split = .{ .axis = .vertical, .frac = 0.5, .first = &l0, .second = &right } };
    const frame: Rect = .{ .x = 0, .y = 0, .w = 200, .h = 100 };

    // rectOf for each leaf.
    try t.expectEqual(Rect{ .x = 0, .y = 0, .w = 100, .h = 100 }, root.rectOf(frame, 0).?);
    try t.expectEqual(Rect{ .x = 100, .y = 0, .w = 100, .h = 50 }, root.rectOf(frame, 1).?);
    try t.expectEqual(Rect{ .x = 100, .y = 50, .w = 100, .h = 50 }, root.rectOf(frame, 2).?);

    // hit-test maps points to the right leaf.
    try t.expectEqual(@as(?usize, 0), root.hit(frame, 10, 10));
    try t.expectEqual(@as(?usize, 1), root.hit(frame, 150, 10));
    try t.expectEqual(@as(?usize, 2), root.hit(frame, 150, 80));
    try t.expectEqual(@as(?usize, null), root.hit(frame, 500, 500));
}

test {
    std.testing.refAllDecls(@This());
}
