//! window_layout — a recursive tree of editor panes ("what vim does").
//! Leaves are panes (a buffer + its own scroll); internal nodes split a
//! rect between two children — a `.split` by axis and fraction, a `.dock` by
//! frame EDGE and extent. All geometry is delegated to `region.Rect` (the
//! pure split/contains primitive), so this module owns only the *mutable*
//! tree region.Tree can't hold: which buffer a leaf shows, its scroll, and
//! its viewport attributes.
//!
//! A DOCK is not a second layout system: it is one more internal node kind,
//! walked by the same `children`/`childRects` pair every other operation
//! uses, so hit-testing, directional focus, rect assignment, and pruning got
//! docks for free rather than each learning about them. What the dock node
//! adds over a plain split is that the panel's side is DATA (`edge`) instead
//! of a convention, and that the leaf under it carries companion attributes
//! (`core.viewport.Attrs`) the structural operations here refuse to violate.
//! "Sidebar" is that bundle of attributes, declared per viewport — not a
//! kind this module knows (doc/cwa-config-decisions.md D1).
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
///
/// `attrs` are the workspace-enforced viewport attributes
/// (`core.viewport.Attrs`, §7): this module is where three of the four are
/// actually ENFORCED rather than merely declared — `cycles` by `focusNext`,
/// `dock` by the `.dock` node this pane hangs under, and the pair of them by
/// `splitFocused`/`swapNeighbor`/`closeFocused` refusing to restructure a
/// companion. `persistent` and `focus_source` are enforced one layer up
/// (`app/window_cmds.zig`), where the active entry and the focus feed live.
pub const Pane = struct {
    id: PaneId,
    buffer_id: core.Buffers.Id,
    top_row: usize = 0,
    attrs: core.viewport.Attrs = .tiled,
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
    dock: Dock,

    const Split = struct {
        axis: Axis,
        /// The first child's share of the split (0..1).
        frac: f32,
        first: *Node,
        second: *Node,
    };

    /// An edge-anchored panel plus everything else. Structurally a split
    /// whose geometry is stated as an EDGE and an extent rather than an axis
    /// and a fraction, so which side the panel sits on is data the tree
    /// carries instead of a convention every reader re-derives. `panel` is
    /// always a `.leaf` (a docked viewport is one pane, by construction);
    /// `rest` is an arbitrary subtree — nesting two docks is just two of
    /// these.
    const Dock = struct {
        edge: core.viewport.Edge,
        /// The panel's share of this rect (0..1).
        extent: f32,
        panel: *Node,
        rest: *Node,
    };

    /// The pane a (leaf) focus node names. Caller's responsibility that
    /// `self` is actually a leaf — true of every `*Node` this module hands
    /// back as a focus value.
    pub fn pane(self: *Node) *Pane {
        return &self.leaf;
    }
};

/// Carve `rect` for a dock: the panel takes `extent` off `edge`, the rest
/// keeps the remainder. The single place edge-to-geometry is decided.
fn dockHalves(d: Node.Dock, rect: Rect) struct { panel: Rect, rest: Rect } {
    const axis: Axis = switch (d.edge) {
        .left, .right => .vertical,
        .top, .bottom => .horizontal,
    };
    const panel_first = d.edge == .left or d.edge == .top;
    const halves = rect.split(axis, if (panel_first) d.extent else 1 - d.extent);
    return if (panel_first)
        .{ .panel = halves[0], .rest = halves[1] }
    else
        .{ .panel = halves[1], .rest = halves[0] };
}

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
    // Recovery lands on an EDITING pane when one exists: a head whose handle
    // went stale must never wake up inside a companion it never focused.
    const recovered = firstPrimaryLeaf(layout.root) orelse firstLeaf(layout.root);
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

    /// Leaf count (== the number of panes on screen, docked panels
    /// included).
    pub fn count(self: *const Layout) usize {
        return countLeaves(self.root);
    }

    /// How many panes can host an ordinary workspace entry. Distinct from
    /// `count` on purpose: "may I close this?" and "is anything left to
    /// edit in?" are different questions the moment a companion exists.
    pub fn primaryCount(self: *const Layout) usize {
        return countPrimary(self.root);
    }

    /// The pane an entry with no viewport of its own belongs in — the first
    /// primary-eligible leaf, or null when the workspace is all companions.
    pub fn primaryPane(self: *Layout) ?*Node {
        return firstPrimaryLeaf(self.root);
    }

    /// Anchor a new panel to `edge`, taking `extent` (0..1) of the frame,
    /// showing `buffer_id` under `attrs`; returns the panel leaf.
    ///
    /// Nothing existing MOVES: the fresh `.dock` node becomes the new root
    /// and adopts the old root as its `rest`, so every live pane keeps its
    /// address and every head's focus handle keeps resolving. (Copying the
    /// old root's value into a new node instead would retire its slot and
    /// scatter focus for no reason — see `splitFocused`'s note on why a
    /// relocation always earns a fresh handle.)
    pub fn dock(
        self: *Layout,
        edge: core.viewport.Edge,
        extent: f32,
        buffer_id: core.Buffers.Id,
        attrs: core.viewport.Attrs,
    ) !*Node {
        const panel = try self.gpa.create(Node);
        errdefer self.gpa.destroy(panel);
        const node = try self.gpa.create(Node);
        errdefer self.gpa.destroy(node);
        const id = try self.allocSlot(panel);
        var docked = attrs;
        docked.dock = edge; // the tree and the attributes cannot disagree
        panel.* = .{ .leaf = .{ .id = id, .buffer_id = buffer_id, .attrs = docked } };
        node.* = .{ .dock = .{ .edge = edge, .extent = extent, .panel = panel, .rest = self.root } };
        self.root = node;
        return panel;
    }

    /// The docked panel on `edge`, or null. Panels are identified by their
    /// edge because that is what a config fragment names them by.
    pub fn dockedPanel(self: *Layout, edge: core.viewport.Edge) ?*Node {
        return findDock(self.root, edge);
    }

    /// The live leaf a pane id names, or null once it is gone. The read-only
    /// counterpart of the `headFocus` handle check, for callers that hold an
    /// id but no generation (a materialized viewport, a feed event): a
    /// retired id resolves to nothing rather than to whoever recycled it,
    /// because `freeSlot` clears the node before offering the id back.
    pub fn paneById(self: *Layout, id: PaneId) ?*Node {
        if (id >= self.slots.items.len) return null;
        const node = self.slots.items[id].node orelse return null;
        return if (node.* == .leaf) node else null;
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
        // A companion is one pane by construction: splitting a sidebar would
        // make "the sidebar" ambiguous for every later placement decision.
        if (!old.attrs.isPrimary()) return error.NotSplittable;
        const first = try self.gpa.create(Node);
        errdefer self.gpa.destroy(first);
        const second = try self.gpa.create(Node);
        errdefer self.gpa.destroy(second);
        const first_id = try self.allocSlot(first);
        const second_id = try self.allocSlot(second);
        first.* = .{ .leaf = .{ .id = first_id, .buffer_id = old.buffer_id, .top_row = old.top_row, .attrs = old.attrs } }; // keeps the focus + scroll
        second.* = .{ .leaf = .{ .id = second_id, .buffer_id = old.buffer_id, .top_row = old.top_row, .attrs = old.attrs } };
        self.freeSlot(old.id); // retire the pre-split identity — only now that the new slots are committed
        // Mutate the focused leaf into a split in place — no parent relink,
        // so pointers elsewhere in the tree stay valid.
        focused.* = .{ .split = .{ .axis = axis, .frac = 0.5, .first = first, .second = second } };
        return first;
    }

    /// Remove `focused`, collapsing its parent split (or dock) into the
    /// surviving sibling; returns the new focus (the first leaf of that
    /// sibling), or `focused` unchanged when it is the only pane, or when
    /// closing it would leave nothing to edit in (a workspace of nothing but
    /// companions is not a state the user can get back out of).
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
        if (focused.leaf.attrs.isPrimary() and countPrimary(self.root) == 1) return focused;
        const sibling = parent.sibling();
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
        // A companion owns its subject: moving an editor entry INTO a sidebar
        // (or its tree out of one) is exactly the misplacement the attributes
        // exist to make unrepresentable.
        if (!focused.leaf.attrs.isPrimary() or !nb.leaf.attrs.isPrimary()) return false;
        const fb = focused.leaf.buffer_id;
        const ft = focused.leaf.top_row;
        focused.leaf.buffer_id = nb.leaf.buffer_id;
        focused.leaf.top_row = nb.leaf.top_row;
        nb.leaf.buffer_id = fb;
        nb.leaf.top_row = ft;
        return true;
    }

    /// The next CYCLING leaf after `focused` in tree order (wraps) — the
    /// legacy `focus-other` with more than two panes. Null if fewer than two
    /// panes take part.
    ///
    /// Panes whose `cycles` attribute is false are not in the rotation, which
    /// is the whole of "a sidebar does not appear in `focus-other`": it is
    /// enforced here, once, rather than by every caller remembering to skip
    /// it. `focused` itself may be one (cycling OUT of a companion is fine —
    /// it is cycling INTO one that is unwanted).
    pub fn focusNext(self: *Layout, focused: *Node) ?*Node {
        var buf: [max_panes]*Node = undefined;
        var n: usize = 0;
        leafNodes(self.root, &buf, &n);
        var start: ?usize = null;
        for (buf[0..n], 0..) |node, i| {
            if (node == focused) start = i;
        }
        const from = start orelse return null;
        for (1..n) |step| {
            const cand = buf[(from + step) % n];
            if (cand != focused and cand.leaf.attrs.cycles) return cand;
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
    if (children(node)) |pair| {
        freeNode(gpa, pair[0]);
        freeNode(gpa, pair[1]);
    }
    gpa.destroy(node);
}

fn countLeaves(node: *const Node) usize {
    return switch (node.*) {
        .leaf => 1,
        .split => |s| countLeaves(s.first) + countLeaves(s.second),
        .dock => |d| countLeaves(d.rest) + countLeaves(d.panel),
    };
}

fn countPrimary(node: *const Node) usize {
    return switch (node.*) {
        .leaf => |p| @intFromBool(p.attrs.isPrimary()),
        .split => |s| countPrimary(s.first) + countPrimary(s.second),
        .dock => |d| countPrimary(d.rest) + countPrimary(d.panel),
    };
}

fn eachPaneRec(node: *Node, ctx: anytype, comptime visit: fn (@TypeOf(ctx), *Pane) void) void {
    const pair = children(node) orelse return visit(ctx, &node.leaf);
    eachPaneRec(pair[0], ctx, visit);
    eachPaneRec(pair[1], ctx, visit);
}

/// `side_first` says the target was the first of this node's children in
/// `children` order — a split's `first`, or a dock's `rest`.
const Parent = struct {
    node: *Node,
    side_first: bool,

    /// The child that survives when the target is closed.
    fn sibling(self: Parent) *Node {
        return switch (self.node.*) {
            .leaf => unreachable,
            .split => |s| if (self.side_first) s.second else s.first,
            .dock => |d| if (self.side_first) d.panel else d.rest,
        };
    }
};

/// The internal node one of whose children == `target`, or null when target
/// is the root (has no parent).
fn findParent(node: *Node, target: *Node) ?Parent {
    const pair = children(node) orelse return null;
    if (pair[0] == target) return .{ .node = node, .side_first = true };
    if (pair[1] == target) return .{ .node = node, .side_first = false };
    return findParent(pair[0], target) orelse findParent(pair[1], target);
}

/// An internal node's two children in traversal order — `rest` BEFORE
/// `panel` for a dock, so pane order (and therefore `firstLeaf`) stays the
/// editing side no matter which edge a companion is anchored to.
fn children(node: *Node) ?[2]*Node {
    return switch (node.*) {
        .leaf => null,
        .split => |s| .{ s.first, s.second },
        .dock => |d| .{ d.rest, d.panel },
    };
}

/// The same pair with each child's rect — the geometry half of `children`.
fn childRects(node: *Node, rect: Rect) ?[2]NodeRect {
    return switch (node.*) {
        .leaf => null,
        .split => |s| blk: {
            const halves = rect.split(s.axis, s.frac);
            break :blk .{ .{ .node = s.first, .rect = halves[0] }, .{ .node = s.second, .rect = halves[1] } };
        },
        .dock => |d| blk: {
            const halves = dockHalves(d, rect);
            break :blk .{ .{ .node = d.rest, .rect = halves.rest }, .{ .node = d.panel, .rect = halves.panel } };
        },
    };
}

fn firstLeaf(node: *Node) *Node {
    var cur = node;
    while (children(cur)) |pair| cur = pair[0];
    return cur;
}

/// The first leaf that can host an ordinary workspace entry, or null.
fn firstPrimaryLeaf(node: *Node) ?*Node {
    switch (node.*) {
        .leaf => return if (node.leaf.attrs.isPrimary()) node else null,
        else => {
            const pair = children(node).?;
            return firstPrimaryLeaf(pair[0]) orelse firstPrimaryLeaf(pair[1]);
        },
    }
}

fn findDock(node: *Node, edge: core.viewport.Edge) ?*Node {
    switch (node.*) {
        .leaf => return null,
        .dock => |d| {
            if (d.edge == edge) return d.panel;
            return findDock(d.rest, edge) orelse findDock(d.panel, edge);
        },
        .split => |s| return findDock(s.first, edge) orelse findDock(s.second, edge),
    }
}

fn rectOfNode(node: *Node, rect: Rect, target: *Node) ?Rect {
    if (node == target) return rect;
    const pair = childRects(node, rect) orelse return null;
    return rectOfNode(pair[0].node, pair[0].rect, target) orelse
        rectOfNode(pair[1].node, pair[1].rect, target);
}

fn leafAt(node: *Node, rect: Rect, px: f32, py: f32) ?*Node {
    const pair = childRects(node, rect) orelse
        return if (rect.contains(px, py)) node else null;
    return leafAt(pair[0].node, pair[0].rect, px, py) orelse
        leafAt(pair[1].node, pair[1].rect, px, py);
}

fn leafNodes(node: *Node, out: []*Node, n: *usize) void {
    const pair = children(node) orelse {
        if (n.* < out.len) {
            out[n.*] = node;
            n.* += 1;
        }
        return;
    };
    leafNodes(pair[0], out, n);
    leafNodes(pair[1], out, n);
}

fn leafRects(node: *Node, rect: Rect, out: []NodeRect, n: *usize) void {
    const pair = childRects(node, rect) orelse {
        if (n.* < out.len) {
            out[n.*] = .{ .node = node, .rect = rect };
            n.* += 1;
        }
        return;
    };
    leafRects(pair[0].node, pair[0].rect, out, n);
    leafRects(pair[1].node, pair[1].rect, out, n);
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
    const pair = childRects(node, rect) orelse {
        if (n.* < out.len) {
            out[n.*] = .{
                .pane = &node.leaf,
                .rect = rect,
                .focused = node == focused,
                .border = edgesOf(rect, frame),
            };
            n.* += 1;
        }
        return;
    };
    collectRec(pair[0].node, pair[0].rect, frame, focused, out, n);
    collectRec(pair[1].node, pair[1].rect, frame, focused, out, n);
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

test "dock: an edge-anchored panel takes its extent and leaves the rest tiled" {
    var l = try Layout.init(t.allocator, 1);
    defer l.deinit();
    const editor = l.root;
    const panel = try l.dock(.left, 0.25, 99, .sidebar(.left));
    // Nothing relocated: the pre-existing pane kept its exact address, so
    // every head's focus handle still resolves.
    try t.expectEqual(editor, l.root.dock.rest);
    try t.expectEqual(@as(usize, 2), l.count());
    try t.expectEqual(@as(usize, 1), l.primaryCount());
    try t.expectEqual(editor, l.primaryPane().?);
    try t.expectEqual(panel, l.dockedPanel(.left).?);
    try t.expectEqual(@as(?*Node, null), l.dockedPanel(.right));

    const frame: Rect = .{ .x = 0, .y = 0, .w = 200, .h = 100 };
    var slots: [max_panes]Slot = undefined;
    const n = l.collect(editor, frame, &slots);
    try t.expectEqual(@as(usize, 2), n);
    // Pane order stays editor-first whichever edge the panel is on.
    try t.expectEqual(Rect{ .x = 50, .y = 0, .w = 150, .h = 100 }, slots[0].rect);
    try t.expectEqual(Rect{ .x = 0, .y = 0, .w = 50, .h = 100 }, slots[1].rect);
    try t.expectEqual(@as(core.Buffers.Id, 99), slots[1].pane.buffer_id);
    // Hit-testing and rect assignment agree about the panel's strip.
    try t.expectEqual(panel, l.focusAt(frame, 10, 50).?);
    try t.expectEqual(editor, l.focusAt(frame, 120, 50).?);
    try t.expectEqual(slots[1].rect, l.focusedRect(panel, frame));
}

test "dock: a bottom panel anchors to the far edge" {
    var l = try Layout.init(t.allocator, 1);
    defer l.deinit();
    const panel = try l.dock(.bottom, 0.2, 5, .sidebar(.bottom));
    const frame: Rect = .{ .x = 0, .y = 0, .w = 200, .h = 100 };
    try t.expectEqual(Rect{ .x = 0, .y = 80, .w = 200, .h = 20 }, l.focusedRect(panel, frame));
    try t.expectEqual(panel, l.focusAt(frame, 100, 90).?);
}

test "dock: the workspace enforces the attributes the panel declares" {
    var l = try Layout.init(t.allocator, 1);
    defer l.deinit();
    const editor = l.root;
    const panel = try l.dock(.left, 0.25, 99, .sidebar(.left));
    const frame: Rect = .{ .x = 0, .y = 0, .w = 200, .h = 100 };

    // Cycling never lands IN the companion, but always lets you back OUT of
    // one: `focus-other` from the editor has nowhere to go, and from the
    // sidebar returns to the editor.
    try t.expectEqual(@as(?*Node, null), l.focusNext(editor));
    try t.expectEqual(editor, l.focusNext(panel).?);

    // Directional focus still reaches it — geometry is not membership.
    try t.expectEqual(panel, l.focusNeighbor(editor, frame, .left).?);
    try t.expectEqual(editor, l.focusNeighbor(panel, frame, .right).?);

    // A companion is one pane, and its content never trades places with an
    // editor pane's.
    try t.expectError(error.NotSplittable, l.splitFocused(panel, .vertical));
    try t.expect(!l.swapNeighbor(editor, frame, .left));
    try t.expect(!l.swapNeighbor(panel, frame, .right));
    try t.expectEqual(@as(core.Buffers.Id, 99), panel.leaf.buffer_id);

    // Closing the last editing pane is a no-op: a workspace of nothing but
    // companions is not a state a user can get back out of.
    try t.expectEqual(editor, try l.closeFocused(editor));
    try t.expectEqual(@as(usize, 2), l.count());

    // A split beside the sidebar cycles normally, and now the editor pane
    // CAN be closed — the dock is untouched by either.
    const left = try l.splitFocused(editor, .vertical);
    try t.expectEqual(@as(usize, 2), l.primaryCount());
    const other = l.focusNext(left).?;
    try t.expect(other != panel);
    try t.expectEqual(left, l.focusNext(other).?);
    _ = try l.closeFocused(left);
    try t.expectEqual(@as(usize, 2), l.count());
    try t.expectEqual(panel, l.dockedPanel(.left).?);
}

test "dock: closing the panel collapses the dock and recovery avoids companions" {
    var l = try Layout.init(t.allocator, 1);
    defer l.deinit();
    var head: core.Head = .empty;
    defer head.deinit(t.allocator);
    const panel = try l.dock(.left, 0.25, 99, .sidebar(.left));

    // A head parked in the sidebar whose handle goes stale recovers onto the
    // EDITING pane, never into a companion it never chose.
    setHeadFocus(&head, panel, &l);
    const editor = try l.closeFocused(panel);
    try t.expectEqual(@as(usize, 1), l.count());
    try t.expectEqual(l.root, editor);
    try t.expectEqual(editor, headFocus(&l, &head));
}

test {
    std.testing.refAllDecls(@This());
}
