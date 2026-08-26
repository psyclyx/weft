//! window_layout — a recursive tree of editor panes ("what vim does").
//! Leaves are panes (a buffer + its own scroll); internal nodes split a
//! rect between two children along an axis. All geometry is delegated to
//! `region.Rect` (the pure split/contains primitive), so this module owns
//! only the *mutable* tree region.Tree can't hold: which buffer a leaf
//! shows and its scroll.
//!
//! FOCUS is deliberately NOT part of `Layout`'s own storage
//! (doc/contextual-workspace-architecture.md §7): the split TREE is
//! session-scoped, shared by every head looking at it, but which leaf a
//! given head considers focused is per-head — two heads over the same
//! layout can focus different panes.
//!
//! Structure invariant: a focus value is always a `.leaf` node that lives in
//! `root`'s tree. Operations mutate nodes IN PLACE (splitFocused turns a leaf
//! into a split; closeFocused destroys the focused leaf AND its sibling node,
//! copying the sibling's CONTENT up into the parent), so unrelated parent
//! pointers stay valid across edits — but a `*Node` a caller was holding
//! onto over the same pane can be FREED or RETYPED by these same ops, if a
//! *different* head's focus (or an in-flight local) named it. A raw pointer
//! can't tell live from stale; dereferencing a stale one is undefined
//! behavior. So `core.Head` does not hold a `*Node` — it holds a
//! generation-checked HANDLE (`focused_pane`/`focused_pane_gen`, plain
//! `u32`s — core must not depend on gfx, but a handle needs no type erasure
//! to avoid that), and every mutating op here (`splitFocused`/`closeFocused`)
//! retires the slot(s) it frees-or-retypes and mints fresh ones for whatever
//! leaf now occupies each surviving address. `headFocus` is the SINGLE
//! validation point: a handle that fails (freed, or its slot's generation
//! moved on — a NORMAL event under multi-head, not a bug: e.g. another head
//! just closed the pane you were on) resolves through the same DEFINED
//! RECOVERY the acting head's own close already used — the tree's first
//! leaf — and re-homes the head's handle there. It never traps and never
//! dereferences a stale value; the only trap is an INTERNAL invariant
//! violation (a live slot naming a node that isn't a leaf), which would be
//! this module's own bug, not a cross-head race. See `headFocus`/
//! `setHeadFocus`/`PaneSlot` below.
//!
//! Boundary drawn for this stage: RENDERING still shows exactly one head's
//! panes (`app.FrameBuilder` builds one `Layout` and reads one head's focus
//! into it each frame — see its module doc) — a second rendered head is a
//! bigger, later change (a second `FrameBuilder`/window/swapchain). What's
//! true today, and proven by the two-head e2e gate
//! (doc/contextual-workspace-architecture.md §7 GATE,
//! `e2e/two_head_test.zig`): two heads can each hold an independent,
//! generation-checked handle into one shared tree; window commands
//! (split/close/focus/move) dispatched "as" one head never move the other's
//! focus; and when an ACTING head's structural op (a close) invalidates a
//! DIFFERENT head's handle, that head's next focus lookup recovers safely
//! (no dangling access) instead of reading through a freed/retyped node.

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
/// `id` names this pane in `Layout`'s slot table (`headFocus`/
/// `setHeadFocus`'s handle validation) — assigned when the pane is
/// (re)created, never chosen by a caller.
pub const Pane = struct {
    id: PaneId,
    buffer_id: core.Buffers.Id,
    top_row: usize = 0,
};

/// A slot-table index for a live pane — the numerator half of the
/// generation-checked handle `core.Head.focused_pane` holds (the other half,
/// `focused_pane_gen`, is validated against `Layout.PaneSlot.gen`).
pub const PaneId = u32;

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

/// A tree node — a pane leaf or a split of two children. Package-visible
/// only: nothing outside this module ever names `*Node` now (the app-layer
/// per-head extension point is a plain handle — `core.Head.focused_pane` —
/// not a pointer; see this file's module doc). `pub` only because `Slot`
/// (below) and a handful of return types cross the module boundary.
pub const Node = union(enum) {
    leaf: Pane,
    split: Split,

    const Split = struct {
        axis: Axis,
        /// The first child's share of the split (0..1).
        frac: f32,
        first: *Node,
        second: *Node,
    };

    /// The pane a (leaf) focus node names. Caller's responsibility that
    /// `self` is actually a leaf — true of every `*Node` this module hands
    /// back as a focus value.
    pub fn pane(self: *Node) *Pane {
        return &self.leaf;
    }
};

/// One slot in `Layout`'s pane table: the pane's CURRENT node address (null
/// once freed) and a generation bumped every time this id's occupancy
/// changes — on free (`closeFocused`) and on retype (`splitFocused` turns a
/// leaf into a split), so a handle recorded before either can never read
/// through the result. A freed id is recycled (`Layout.free`); the bump
/// means a handle naming the OLD occupant still correctly fails against the
/// NEW one even though the numeric id is reused (the standard
/// generational-index trick — no ABA hazard).
const PaneSlot = struct {
    node: ?*Node,
    gen: u32 = 0,
};

/// The pane THIS HEAD is focused on, resolving `head`'s handle through
/// `layout`'s slot table — the SINGLE validation point for every reader
/// (rendering, click routing, window commands). A handle that fails to
/// validate (never set, or its slot's generation moved on since — e.g. a
/// DIFFERENT head closed this pane) is a NORMAL multi-head event, not a
/// bug: it recovers to the tree's first leaf, exactly the same "collapse to
/// a survivor" `closeFocused` already does for the ACTING head, and re-homes
/// `head`'s handle there so the NEXT lookup validates cleanly. Never a trap,
/// never a dereference of anything unvalidated. The only trap here is an
/// IMPOSSIBLE state — a live slot whose node isn't a `.leaf`, which would be
/// this module's own bookkeeping bug (every slot is minted pointing at a
/// freshly-written leaf and retired before its address stops being one),
/// not a cross-head race.
pub fn headFocus(layout: *Layout, head: *core.Head) *Node {
    if (layout.resolve(head.focused_pane, head.focused_pane_gen)) |n| {
        std.debug.assert(n.* == .leaf);
        return n;
    }
    const recovered = firstLeaf(layout.root);
    setHeadFocus(head, recovered, layout);
    return recovered;
}

/// Record `node` (must be a live leaf in `layout`'s tree) as `head`'s
/// window-layout focus handle: its slot id plus that slot's CURRENT
/// generation.
pub fn setHeadFocus(head: *core.Head, node: *Node, layout: *const Layout) void {
    const id = node.leaf.id;
    head.focused_pane = id;
    head.focused_pane_gen = layout.slots.items[id].gen;
}

pub const Layout = struct {
    gpa: std.mem.Allocator,
    root: *Node,
    /// Pane slot table (`headFocus`/`setHeadFocus`'s handle validation) —
    /// indexed by `PaneId`. `free` recycles retired ids.
    slots: std.ArrayList(PaneSlot) = .empty,
    free: std.ArrayList(PaneId) = .empty,

    /// A single-leaf layout showing `buffer_id` — the ordinary, unsplit case.
    /// The caller's head(s) start focused on the root pane by default
    /// (`headFocus`'s fallback resolves an unset/stale handle to the tree's
    /// first leaf) — nothing to set here.
    pub fn init(gpa: std.mem.Allocator, buffer_id: core.Buffers.Id) !Layout {
        var self: Layout = .{ .gpa = gpa, .root = undefined };
        const root = try gpa.create(Node);
        errdefer gpa.destroy(root);
        const id = try self.allocSlot(root);
        root.* = .{ .leaf = .{ .id = id, .buffer_id = buffer_id } };
        self.root = root;
        return self;
    }

    pub fn deinit(self: *Layout) void {
        freeNode(self.gpa, self.root);
        self.slots.deinit(self.gpa);
        self.free.deinit(self.gpa);
        self.* = undefined;
    }

    /// Resolve a handle {id, gen} to its current node, or null when stale
    /// (never allocated, freed, or a generation mismatch — this id was
    /// retired and possibly reissued to a different pane since).
    fn resolve(self: *const Layout, id: PaneId, gen: u32) ?*Node {
        if (id >= self.slots.items.len) return null;
        const slot = self.slots.items[id];
        if (slot.gen != gen) return null;
        return slot.node;
    }

    /// Mint a slot for a freshly-created (or freshly-relocated) leaf at
    /// `node`'s address, reusing a retired id when one is free. (If a caller
    /// allocs TWO slots and the second alloc fails, a recycled first id is
    /// left pointing at the about-to-be-destroyed node without returning to
    /// the free list — gen-safe (no live handle carries its gen) and OOM-only,
    /// same bounded leak class as `freeSlot`'s append-fails note.)
    fn allocSlot(self: *Layout, node: *Node) !PaneId {
        if (self.free.pop()) |id| {
            self.slots.items[id].node = node;
            return id;
        }
        const id: PaneId = @intCast(self.slots.items.len);
        try self.slots.append(self.gpa, .{ .node = node });
        return id;
    }

    /// Retire `id`: its node no longer holds (or no longer IS) this pane.
    /// Bumps the generation (so a handle naming the old occupant fails even
    /// if this id is reused) and offers it back for reuse. `free.append`
    /// failing is not a correctness problem — worst case this one id is
    /// never recycled (a bounded, harmless growth of the slot table over a
    /// very long split/close-heavy session), never a stale-handle escape.
    fn freeSlot(self: *Layout, id: PaneId) void {
        self.slots.items[id].node = null;
        self.slots.items[id].gen +%= 1;
        self.free.append(self.gpa, id) catch {};
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

    /// Split `focused` in two along `axis`. The new pane shows the same
    /// buffer at the same scroll (its own copy thereafter); returns the new
    /// focus — the ORIGINAL half (the vim `:split` / `:vsplit` feel).
    ///
    /// `focused`'s address is RETYPED in place (leaf → split): any handle
    /// naming it — including this same head's own, and ANY other head that
    /// happened to be focused on this exact pane — must stop resolving to
    /// it. So the old id is retired (generation bumped) BEFORE the retype,
    /// and both surviving leaves (`first`, which keeps the content/scroll;
    /// `second`, the new peek) mint FRESH ids at their own new addresses —
    /// no id "follows" the old one across the relocation, deliberately: a
    /// structural change always earns a fresh handle, never a silent carry.
    pub fn splitFocused(self: *Layout, focused: *Node, axis: Axis) !*Node {
        const old = focused.leaf;
        const first = try self.gpa.create(Node);
        errdefer self.gpa.destroy(first);
        const second = try self.gpa.create(Node);
        errdefer self.gpa.destroy(second);
        const first_id = try self.allocSlot(first);
        const second_id = try self.allocSlot(second);
        first.* = .{ .leaf = .{ .id = first_id, .buffer_id = old.buffer_id, .top_row = old.top_row } }; // keeps the focus + scroll
        second.* = .{ .leaf = .{ .id = second_id, .buffer_id = old.buffer_id, .top_row = old.top_row } };
        self.freeSlot(old.id); // retire the pre-split identity — only now that the new slots are committed
        // Mutate the focused leaf into a split in place — no parent relink,
        // so pointers elsewhere in the tree stay valid.
        focused.* = .{ .split = .{ .axis = axis, .frac = 0.5, .first = first, .second = second } };
        return first;
    }

    /// Remove `focused`, collapsing its parent split into the surviving
    /// sibling; returns the new focus (the first leaf of that sibling), or
    /// `focused` unchanged when it is the only pane (no-op).
    ///
    /// TWO nodes are freed here — `focused` AND its sibling shell (the
    /// sibling's CONTENT survives, copied up into the parent's address, but
    /// the sibling's own node struct does not) — so any handle naming
    /// EITHER is retired: `focused`'s id is freed outright; if the sibling
    /// was itself a leaf, its id is freed too and the parent's (reused)
    /// address mints a FRESH id for the relocated content — same "no id
    /// follows a relocation" policy as `splitFocused`. A head that was
    /// focused on this pane (or, transitively, one whose handle simply went
    /// stale from EITHER retirement) recovers on its next `headFocus` call —
    /// this function only fixes up the ACTING head's own `focused`
    /// parameter/return value; it does not, and cannot, know about every
    /// OTHER head that might be holding a handle into this tree.
    pub fn closeFocused(self: *Layout, focused: *Node) !*Node {
        const parent = findParent(self.root, focused) orelse return focused; // only pane
        const p = &parent.node.split;
        const sibling = if (parent.side_first) p.second else p.first;
        const sib_val = sibling.*;
        // Mint the surviving content's new identity at the parent's
        // (about-to-be-overwritten) address FIRST, so a failure here leaves
        // the tree completely untouched — nothing destroyed, no slot retired.
        const relocated_id: ?PaneId = if (sib_val == .leaf) try self.allocSlot(parent.node) else null;
        self.freeSlot(focused.leaf.id);
        if (sib_val == .leaf) self.freeSlot(sib_val.leaf.id);
        self.gpa.destroy(focused);
        // The parent BECOMES the sibling's content: copy the sibling value
        // up (its children pointers survive), then free the empty shell.
        self.gpa.destroy(sibling);
        parent.node.* = sib_val;
        if (relocated_id) |id| parent.node.leaf.id = id;
        return firstLeaf(parent.node);
    }

    /// The rect `focused` occupies within `frame` (for click routing).
    pub fn focusedRect(self: *const Layout, focused: *Node, frame: Rect) Rect {
        return rectOfNode(self.root, frame, focused) orelse frame;
    }

    /// Assign each leaf its rect + divider mask within `frame`, into `out`
    /// (leaf order); `focused` marks the slot whose `.focused` is true.
    /// Returns the count written (capped at `out.len`).
    pub fn collect(self: *Layout, focused: *Node, frame: Rect, out: []Slot) usize {
        var n: usize = 0;
        collectRec(self.root, frame, frame, focused, out, &n);
        return n;
    }

    /// The leaf whose rect contains (px,py), or null (frame miss). Caller
    /// compares against its own current focus to decide if focus moved.
    pub fn focusAt(self: *Layout, frame: Rect, px: f32, py: f32) ?*Node {
        return leafAt(self.root, frame, px, py);
    }

    /// The nearest pane to `focused` in `dir` (vim `C-w h/j/k/l`), or null
    /// if none exists.
    pub fn focusNeighbor(self: *Layout, focused: *Node, frame: Rect, dir: Dir) ?*Node {
        return self.neighborNode(focused, frame, dir);
    }

    /// Swap `focused`'s contents with the neighbor in `dir` (vim `C-w H/J/K/L`-
    /// ish). Semantics: swap the two leaves' {buffer_id, top_row} ONLY — a
    /// directional swap of adjacent panes' CONTENT, not a full
    /// rotation-to-edge, and NOT an identity swap (`id` stays put on each
    /// address; a handle any head holds into either pane still resolves to
    /// the same physical slot it did before — the pane just shows different
    /// content now, exactly as if the user had switched buffers in place).
    /// The caller's focus stays put (now showing the neighbor's old
    /// content). Returns true if a neighbor existed.
    pub fn swapNeighbor(self: *Layout, focused: *Node, frame: Rect, dir: Dir) bool {
        const nb = self.neighborNode(focused, frame, dir) orelse return false;
        const fb = focused.leaf.buffer_id;
        const ft = focused.leaf.top_row;
        focused.leaf.buffer_id = nb.leaf.buffer_id;
        focused.leaf.top_row = nb.leaf.top_row;
        nb.leaf.buffer_id = fb;
        nb.leaf.top_row = ft;
        return true;
    }

    /// The next leaf after `focused` in tree order (wraps) — the legacy
    /// `focus-other` with more than two panes. Null if fewer than two panes.
    pub fn focusNext(self: *Layout, focused: *Node) ?*Node {
        var buf: [max_panes]*Node = undefined;
        var n: usize = 0;
        leafNodes(self.root, &buf, &n);
        if (n < 2) return null;
        for (buf[0..n], 0..) |node, i| {
            if (node == focused) return buf[(i + 1) % n];
        }
        return null;
    }

    // ── Internal ───────────────────────────────────────────────────────

    /// The leaf node nearest to `focused` in `dir`, or null. Scored on pane
    /// rects: the along-axis gap plus the perpendicular offset of the
    /// candidate's center — so an adjacent pane straight ahead wins over a
    /// farther or more offset one.
    fn neighborNode(self: *Layout, focused: *Node, frame: Rect, dir: Dir) ?*Node {
        const fr = self.focusedRect(focused, frame);
        const fcx = fr.x + fr.w / 2;
        const fcy = fr.y + fr.h / 2;
        var buf: [max_panes]NodeRect = undefined;
        var n: usize = 0;
        leafRects(self.root, frame, &buf, &n);
        var best: ?*Node = null;
        var best_score: f32 = std.math.inf(f32);
        for (buf[0..n]) |nr| {
            if (nr.node == focused) continue;
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
    try t.expectEqual(@as(core.Buffers.Id, 7), l.root.pane().buffer_id);
    const focused = try l.closeFocused(l.root); // only pane: no-op
    try t.expectEqual(l.root, focused);
    try t.expectEqual(@as(usize, 1), l.count());

    const frame: Rect = .{ .x = 0, .y = 0, .w = 200, .h = 100 };
    var slots: [max_panes]Slot = undefined;
    const n = l.collect(focused, frame, &slots);
    try t.expectEqual(@as(usize, 1), n);
    try t.expectEqual(frame, slots[0].rect);
    try t.expect(slots[0].focused);
    try t.expectEqual(region.Edges{}, slots[0].border); // fills the frame
}

test "split then close collapses back to one pane" {
    var l = try Layout.init(t.allocator, 1);
    defer l.deinit();
    var focused = try l.splitFocused(l.root, .vertical); // side-by-side
    try t.expectEqual(@as(usize, 2), l.count());

    const frame: Rect = .{ .x = 0, .y = 0, .w = 200, .h = 100 };
    var slots: [max_panes]Slot = undefined;
    var n = l.collect(focused, frame, &slots);
    try t.expectEqual(@as(usize, 2), n);
    // Left half is focused (the original), right half is the new peek.
    try t.expectEqual(Rect{ .x = 0, .y = 0, .w = 100, .h = 100 }, slots[0].rect);
    try t.expect(slots[0].focused);
    try t.expect(slots[0].border.right); // internal edge → divider
    try t.expect(slots[1].border.left);

    focused = try l.closeFocused(focused);
    try t.expectEqual(@as(usize, 1), l.count());
    n = l.collect(focused, frame, &slots);
    try t.expectEqual(frame, slots[0].rect);
}

test "focus + swap by geometry" {
    var l = try Layout.init(t.allocator, 10);
    defer l.deinit();
    l.root.pane().top_row = 3;
    var focused = try l.splitFocused(l.root, .vertical); // focus on left (buf 10)
    // Give the right pane a distinct buffer to prove the swap.
    const frame: Rect = .{ .x = 0, .y = 0, .w = 200, .h = 100 };
    var slots: [max_panes]Slot = undefined;
    _ = l.collect(focused, frame, &slots);
    slots[1].pane.buffer_id = 20;

    // Right neighbor exists; left does not.
    try t.expectEqual(@as(?*Node, null), l.focusNeighbor(focused, frame, .left));
    focused = l.focusNeighbor(focused, frame, .right) orelse return error.TestUnexpectedResult;
    try t.expectEqual(@as(core.Buffers.Id, 20), focused.pane().buffer_id);
    // Back to the left pane, then swap its content with the right.
    focused = l.focusNeighbor(focused, frame, .left) orelse return error.TestUnexpectedResult;
    try t.expectEqual(@as(core.Buffers.Id, 10), focused.pane().buffer_id);
    try t.expect(l.swapNeighbor(focused, frame, .right));
    try t.expectEqual(@as(core.Buffers.Id, 20), focused.pane().buffer_id);
}

test "click focus + focusNext" {
    var l = try Layout.init(t.allocator, 1);
    defer l.deinit();
    const top = try l.splitFocused(l.root, .horizontal); // stacked: top focused, bottom peek
    const frame: Rect = .{ .x = 0, .y = 0, .w = 200, .h = 100 };
    // A click in the top half hits the top pane; in the bottom half, the other.
    try t.expectEqual(top, l.focusAt(frame, 10, 10));
    const bottom = l.focusAt(frame, 10, 90) orelse return error.TestUnexpectedResult;
    try t.expect(bottom != top);
    try t.expectEqual(top, l.focusAt(frame, 10, 10)); // back to top
    try t.expectEqual(bottom, l.focusNext(top)); // wraps to the other pane
}

test "headFocus/setHeadFocus: closing a pane invalidates ANOTHER head's handle — recovers, never dereferences" {
    var l = try Layout.init(t.allocator, 1);
    defer l.deinit();
    var head_a: core.Head = .empty;
    defer head_a.deinit(t.allocator);
    var head_b: core.Head = .empty;
    defer head_b.deinit(t.allocator);

    const left = try l.splitFocused(l.root, .vertical); // A on the kept half
    const frame: Rect = .{ .x = 0, .y = 0, .w = 200, .h = 100 };
    const right = l.focusNeighbor(left, frame, .right) orelse return error.TestUnexpectedResult;
    setHeadFocus(&head_a, left, &l);
    setHeadFocus(&head_b, right, &l); // B focused on the OTHER pane

    // A closes ITS OWN pane. `closeFocused`'s doc: this frees TWO node
    // addresses — `left` (A's) AND `right` (B's sibling shell) — a raw
    // pointer B held to `right` would now be a dangling/reused address. B
    // never touched `closeFocused` at all.
    const nf = try l.closeFocused(left);
    setHeadFocus(&head_a, nf, &l); // the acting head's own fixup, as today

    // B's handle is now stale (its slot was retired by the close). The
    // SINGLE validation point, `headFocus`, must not dereference anything
    // freed — it recovers to a valid leaf (here, the sole survivor) and
    // re-homes B's handle there, exactly like `closeFocused` itself
    // recovers for the acting head.
    try t.expectEqual(@as(usize, 1), l.count());
    const b_focus = headFocus(&l, &head_b);
    try t.expectEqual(l.root, b_focus); // the survivor (only pane left)
    try t.expectEqual(nf, b_focus); // same pane A ended up on, too

    // B's handle is now freshly valid — the NEXT lookup resolves directly,
    // no repeated recovery.
    try t.expectEqual(b_focus, headFocus(&l, &head_b));
}

test {
    std.testing.refAllDecls(@This());
}
