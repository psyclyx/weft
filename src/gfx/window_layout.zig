//! window_layout — a recursive tree of editor panes ("what vim does").
//! Leaves are panes (a buffer + its own scroll); internal nodes split a
//! rect between two children along an axis. All geometry is delegated to
//! `region.Rect` (the pure split/contains primitive), so this module owns
//! only the *mutable* tree region.Tree can't hold: which buffer a leaf
//! shows, its scroll, and which leaf is focused.
//!
//! Structure invariant: `focused` always points at a `.leaf` node that
//! lives in `root`'s tree. Operations mutate nodes IN PLACE (splitFocused
//! turns a leaf into a split; closeFocused collapses a split into its
//! surviving child), so unrelated parent pointers stay valid across edits.

const std = @import("std");
const region = @import("region.zig");
const core = @import("../core/core.zig");

pub const Rect = region.Rect;
pub const Axis = region.Axis;

/// A direction for focus/move, resolved against pane geometry.
pub const Dir = enum { left, right, up, down };

/// A leaf pane: which buffer it shows and its own vertical scroll. The
/// focused pane's scroll mirrors `view.top_row`; every other pane keeps
/// its own here so a split can peek the same buffer at a different place.
pub const Pane = struct {
    buffer_id: core.Buffers.Id,
    top_row: usize = 0,
};

/// A leaf with its assigned rect + which edges want a divider — the unit
/// the render loop iterates (one `view.build` per slot).
pub const Slot = struct {
    pane: *Pane,
    rect: Rect,
    focused: bool,
    border: region.Edges,
};

/// Bounds the fixed collect/scan buffers. Far more panes than any human
/// tiles; the tree itself is unbounded (only these snapshots are capped).
pub const max_panes = 64;

const Node = union(enum) {
    leaf: Pane,
    split: Split,

    const Split = struct {
        axis: Axis,
        /// The first child's share of the split (0..1).
        frac: f32,
        first: *Node,
        second: *Node,
    };
};

pub const Layout = struct {
    gpa: std.mem.Allocator,
    root: *Node,
    /// Always a `.leaf` node within `root`'s tree.
    focused: *Node,

    /// A single-leaf layout showing `buffer_id` — the ordinary, unsplit case.
    pub fn init(gpa: std.mem.Allocator, buffer_id: core.Buffers.Id) !Layout {
        const root = try gpa.create(Node);
        root.* = .{ .leaf = .{ .buffer_id = buffer_id } };
        return .{ .gpa = gpa, .root = root, .focused = root };
    }

    pub fn deinit(self: *Layout) void {
        freeNode(self.gpa, self.root);
        self.* = undefined;
    }

    pub fn focusedPane(self: *Layout) *Pane {
        return &self.focused.leaf;
    }

    /// Leaf count (== the number of panes on screen).
    pub fn count(self: *const Layout) usize {
        return countLeaves(self.root);
    }

    /// Visit every pane (leaf order). Used to keep panes in sync with the
    /// buffer table: reassign closed buffers, mirror the active buffer.
    pub fn eachPane(self: *Layout, ctx: anytype, comptime visit: fn (@TypeOf(ctx), *Pane) void) void {
        eachPaneRec(self.root, ctx, visit);
    }

    /// Split the focused pane in two along `axis`. The new pane shows the
    /// same buffer at the same scroll (its own copy thereafter); focus
    /// stays on the ORIGINAL half — the vim `:split` / `:vsplit` feel.
    pub fn splitFocused(self: *Layout, axis: Axis) !void {
        const old = self.focused.leaf;
        const first = try self.gpa.create(Node);
        errdefer self.gpa.destroy(first);
        const second = try self.gpa.create(Node);
        first.* = .{ .leaf = old }; // keeps the focus + scroll
        second.* = .{ .leaf = .{ .buffer_id = old.buffer_id, .top_row = old.top_row } };
        // Mutate the focused leaf into a split in place — no parent relink,
        // so pointers elsewhere in the tree stay valid.
        self.focused.* = .{ .split = .{ .axis = axis, .frac = 0.5, .first = first, .second = second } };
        self.focused = first;
    }

    /// Remove the focused pane, collapsing its parent split into the
    /// surviving sibling; focus moves to the first leaf of that sibling.
    /// No-op when it is the only pane.
    pub fn closeFocused(self: *Layout) void {
        const parent = findParent(self.root, self.focused) orelse return; // only pane
        const p = &parent.node.split;
        const sibling = if (parent.side_first) p.second else p.first;
        self.gpa.destroy(self.focused);
        // The parent BECOMES the sibling's content: copy the sibling value
        // up (its children pointers survive), then free the empty shell.
        const sib_val = sibling.*;
        self.gpa.destroy(sibling);
        parent.node.* = sib_val;
        self.focused = firstLeaf(parent.node);
    }

    /// The rect the focused pane occupies within `frame` (for click routing).
    pub fn focusedRect(self: *Layout, frame: Rect) Rect {
        return rectOfNode(self.root, frame, self.focused) orelse frame;
    }

    /// Assign each leaf its rect + divider mask within `frame`, into `out`
    /// (leaf order). Returns the count written (capped at `out.len`).
    pub fn collect(self: *Layout, frame: Rect, out: []Slot) usize {
        var n: usize = 0;
        collectRec(self.root, frame, frame, self.focused, out, &n);
        return n;
    }

    /// Focus the leaf whose rect contains (px,py). Returns true if focus
    /// actually moved (a click inside the already-focused pane is false).
    pub fn focusAt(self: *Layout, frame: Rect, px: f32, py: f32) bool {
        const hit = leafAt(self.root, frame, px, py) orelse return false;
        if (hit == self.focused) return false;
        self.focused = hit;
        return true;
    }

    /// Move focus to the nearest pane in `dir` (vim `C-w h/j/k/l`). Returns
    /// true if a neighbor existed and focus moved.
    pub fn focusNeighbor(self: *Layout, frame: Rect, dir: Dir) bool {
        const nb = self.neighborNode(frame, dir) orelse return false;
        self.focused = nb;
        return true;
    }

    /// Swap the focused pane's contents with the neighbor in `dir` (vim
    /// `C-w H/J/K/L`-ish). Semantics: swap the two leaves' {buffer_id,
    /// top_row} — a directional swap of adjacent panes, not a full
    /// rotation-to-edge. Focus stays put (now showing the neighbor's old
    /// content). Returns true if a neighbor existed.
    pub fn swapNeighbor(self: *Layout, frame: Rect, dir: Dir) bool {
        const nb = self.neighborNode(frame, dir) orelse return false;
        std.mem.swap(Pane, &self.focused.leaf, &nb.leaf);
        return true;
    }

    /// Focus the next leaf in tree order (wraps) — the legacy `focus-other`
    /// with more than two panes.
    pub fn focusNext(self: *Layout) bool {
        var buf: [max_panes]*Node = undefined;
        var n: usize = 0;
        leafNodes(self.root, &buf, &n);
        if (n < 2) return false;
        for (buf[0..n], 0..) |node, i| {
            if (node == self.focused) {
                self.focused = buf[(i + 1) % n];
                return true;
            }
        }
        return false;
    }

    // ── Internal ───────────────────────────────────────────────────────

    /// The leaf node nearest to the focused pane in `dir`, or null. Scored
    /// on pane rects: the along-axis gap plus the perpendicular offset of
    /// the candidate's center — so an adjacent pane straight ahead wins over
    /// a farther or more offset one.
    fn neighborNode(self: *Layout, frame: Rect, dir: Dir) ?*Node {
        const fr = self.focusedRect(frame);
        const fcx = fr.x + fr.w / 2;
        const fcy = fr.y + fr.h / 2;
        var buf: [max_panes]NodeRect = undefined;
        var n: usize = 0;
        leafRects(self.root, frame, &buf, &n);
        var best: ?*Node = null;
        var best_score: f32 = std.math.inf(f32);
        for (buf[0..n]) |nr| {
            if (nr.node == self.focused) continue;
            const cx = nr.rect.x + nr.rect.w / 2;
            const cy = nr.rect.y + nr.rect.h / 2;
            const along: f32, const perp: f32 = switch (dir) {
                .right => .{ nr.rect.x - (fr.x + fr.w), @abs(cy - fcy) },
                .left => .{ fr.x - (nr.rect.x + nr.rect.w), @abs(cy - fcy) },
                .down => .{ nr.rect.y - (fr.y + fr.h), @abs(cx - fcx) },
                .up => .{ fr.y - (nr.rect.y + nr.rect.h), @abs(cx - fcx) },
            };
            // Must lie in the direction: its center is past our edge.
            const beyond = switch (dir) {
                .right => cx > fcx,
                .left => cx < fcx,
                .down => cy > fcy,
                .up => cy < fcy,
            };
            if (!beyond) continue;
            const score = @max(along, 0) + perp;
            if (score < best_score) {
                best_score = score;
                best = nr.node;
            }
        }
        return best;
    }
};

const NodeRect = struct { node: *Node, rect: Rect };

fn freeNode(gpa: std.mem.Allocator, node: *Node) void {
    switch (node.*) {
        .leaf => {},
        .split => |s| {
            freeNode(gpa, s.first);
            freeNode(gpa, s.second);
        },
    }
    gpa.destroy(node);
}

fn countLeaves(node: *const Node) usize {
    return switch (node.*) {
        .leaf => 1,
        .split => |s| countLeaves(s.first) + countLeaves(s.second),
    };
}

fn eachPaneRec(node: *Node, ctx: anytype, comptime visit: fn (@TypeOf(ctx), *Pane) void) void {
    switch (node.*) {
        .leaf => visit(ctx, &node.leaf),
        .split => |s| {
            eachPaneRec(s.first, ctx, visit);
            eachPaneRec(s.second, ctx, visit);
        },
    }
}

const Parent = struct { node: *Node, side_first: bool };

/// The split node one of whose children == `target`, or null when target
/// is the root (has no parent).
fn findParent(node: *Node, target: *Node) ?Parent {
    switch (node.*) {
        .leaf => return null,
        .split => |s| {
            if (s.first == target) return .{ .node = node, .side_first = true };
            if (s.second == target) return .{ .node = node, .side_first = false };
            return findParent(s.first, target) orelse findParent(s.second, target);
        },
    }
}

fn firstLeaf(node: *Node) *Node {
    var cur = node;
    while (cur.* == .split) cur = cur.split.first;
    return cur;
}

fn rectOfNode(node: *Node, rect: Rect, target: *Node) ?Rect {
    if (node == target) return rect;
    return switch (node.*) {
        .leaf => null,
        .split => |s| blk: {
            const halves = rect.split(s.axis, s.frac);
            break :blk rectOfNode(s.first, halves[0], target) orelse rectOfNode(s.second, halves[1], target);
        },
    };
}

fn leafAt(node: *Node, rect: Rect, px: f32, py: f32) ?*Node {
    switch (node.*) {
        .leaf => return if (rect.contains(px, py)) node else null,
        .split => |s| {
            const halves = rect.split(s.axis, s.frac);
            return leafAt(s.first, halves[0], px, py) orelse leafAt(s.second, halves[1], px, py);
        },
    }
}

fn leafNodes(node: *Node, out: []*Node, n: *usize) void {
    switch (node.*) {
        .leaf => {
            if (n.* < out.len) {
                out[n.*] = node;
                n.* += 1;
            }
        },
        .split => |s| {
            leafNodes(s.first, out, n);
            leafNodes(s.second, out, n);
        },
    }
}

fn leafRects(node: *Node, rect: Rect, out: []NodeRect, n: *usize) void {
    switch (node.*) {
        .leaf => {
            if (n.* < out.len) {
                out[n.*] = .{ .node = node, .rect = rect };
                n.* += 1;
            }
        },
        .split => |s| {
            const halves = rect.split(s.axis, s.frac);
            leafRects(s.first, halves[0], out, n);
            leafRects(s.second, halves[1], out, n);
        },
    }
}

/// A rect edge is a divider exactly when it is off the outer frame (a
/// pane not touching the frame's left edge has a neighbor to its left).
fn edgesOf(rect: Rect, frame: Rect) region.Edges {
    const eps: f32 = 0.5;
    return .{
        .left = rect.x > frame.x + eps,
        .top = rect.y > frame.y + eps,
        .right = rect.x + rect.w < frame.x + frame.w - eps,
        .bottom = rect.y + rect.h < frame.y + frame.h - eps,
    };
}

fn collectRec(node: *Node, rect: Rect, frame: Rect, focused: *Node, out: []Slot, n: *usize) void {
    switch (node.*) {
        .leaf => {
            if (n.* < out.len) {
                out[n.*] = .{
                    .pane = &node.leaf,
                    .rect = rect,
                    .focused = node == focused,
                    .border = edgesOf(rect, frame),
                };
                n.* += 1;
            }
        },
        .split => |s| {
            const halves = rect.split(s.axis, s.frac);
            collectRec(s.first, halves[0], frame, focused, out, n);
            collectRec(s.second, halves[1], frame, focused, out, n);
        },
    }
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "single leaf: one pane, no dividers, close is a no-op" {
    var l = try Layout.init(t.allocator, 7);
    defer l.deinit();
    try t.expectEqual(@as(usize, 1), l.count());
    try t.expectEqual(@as(core.Buffers.Id, 7), l.focusedPane().buffer_id);
    l.closeFocused(); // only pane: no-op
    try t.expectEqual(@as(usize, 1), l.count());

    const frame: Rect = .{ .x = 0, .y = 0, .w = 200, .h = 100 };
    var slots: [max_panes]Slot = undefined;
    const n = l.collect(frame, &slots);
    try t.expectEqual(@as(usize, 1), n);
    try t.expectEqual(frame, slots[0].rect);
    try t.expect(slots[0].focused);
    try t.expectEqual(region.Edges{}, slots[0].border); // fills the frame
}

test "split then close collapses back to one pane" {
    var l = try Layout.init(t.allocator, 1);
    defer l.deinit();
    try l.splitFocused(.vertical); // side-by-side
    try t.expectEqual(@as(usize, 2), l.count());

    const frame: Rect = .{ .x = 0, .y = 0, .w = 200, .h = 100 };
    var slots: [max_panes]Slot = undefined;
    var n = l.collect(frame, &slots);
    try t.expectEqual(@as(usize, 2), n);
    // Left half is focused (the original), right half is the new peek.
    try t.expectEqual(Rect{ .x = 0, .y = 0, .w = 100, .h = 100 }, slots[0].rect);
    try t.expect(slots[0].focused);
    try t.expect(slots[0].border.right); // internal edge → divider
    try t.expect(slots[1].border.left);

    l.closeFocused();
    try t.expectEqual(@as(usize, 1), l.count());
    n = l.collect(frame, &slots);
    try t.expectEqual(frame, slots[0].rect);
}

test "focus + swap by geometry" {
    var l = try Layout.init(t.allocator, 10);
    defer l.deinit();
    l.focusedPane().top_row = 3;
    try l.splitFocused(.vertical); // focus on left (buf 10)
    // Give the right pane a distinct buffer to prove the swap.
    const frame: Rect = .{ .x = 0, .y = 0, .w = 200, .h = 100 };
    var slots: [max_panes]Slot = undefined;
    _ = l.collect(frame, &slots);
    slots[1].pane.buffer_id = 20;

    // Right neighbor exists; left does not.
    try t.expect(!l.focusNeighbor(frame, .left));
    try t.expect(l.focusNeighbor(frame, .right));
    try t.expectEqual(@as(core.Buffers.Id, 20), l.focusedPane().buffer_id);
    // Back to the left pane, then swap its content with the right.
    try t.expect(l.focusNeighbor(frame, .left));
    try t.expectEqual(@as(core.Buffers.Id, 10), l.focusedPane().buffer_id);
    try t.expect(l.swapNeighbor(frame, .right));
    try t.expectEqual(@as(core.Buffers.Id, 20), l.focusedPane().buffer_id);
}

test "click focus + focusNext" {
    var l = try Layout.init(t.allocator, 1);
    defer l.deinit();
    try l.splitFocused(.horizontal); // stacked: top focused, bottom peek
    const frame: Rect = .{ .x = 0, .y = 0, .w = 200, .h = 100 };
    // A click in the bottom half moves focus; in the top half it doesn't.
    try t.expect(!l.focusAt(frame, 10, 10));
    try t.expect(l.focusAt(frame, 10, 90));
    try t.expect(l.focusAt(frame, 10, 10)); // back to top
    try t.expect(l.focusNext()); // wraps to the other pane
}

test {
    std.testing.refAllDecls(@This());
}
