//! undo_tree — the provider for the `undo-tree` projection (doc/undo.md): an
//! entry's undo history as the TREE it is, drawn as a graph — a dot per step,
//! lines from each step to the steps taken after it, a branch wherever a new
//! step followed an undo — with the step the entry is at marked.
//!
//! Like `symbols`, it is presented as a projection of ANOTHER entry —
//! `weft.present(<viewport>, {subject: {context: "entry"}, as: "undo-tree"})`
//! — so core runs the opener with that entry active and a viewport following
//! the `entry` key presents it again whenever the editor moves on. Each
//! subject's tree is its own entry (`*undo-tree*`, `*undo-tree:2*`, …), and
//! each WATCHES its subject: an edit, an undo or a jump there re-reads the
//! tree at the frame boundary, bound to the subject.
//!
//! The history is core's (`edit.undo-tree`, a data source; `edit.undo-to`,
//! the move). Every step is an ACTION node, so the standard vocabulary works
//! under any grammar with no key bound here: the grammar's up/down/left/right
//! move the focus from dot to dot, Return (`std.target.activate`) or a click
//! brings the subject to that step — undo to the common ancestor, redo down
//! the other branch. The move runs in the primary context when the subject
//! is what the editor shows (the tree keeps the focus, as vundo's does);
//! otherwise it opens the subject first.
//!
//! `undo-tree.open` shows the viewport the configuration names (`viewport`,
//! a `weft.set`), where it follows the editor; with none, it presents the
//! active entry's tree in place.
//!
//! Nothing here knows a grammar: what one step IS was the grammar's to
//! declare (`mode.set-undo-step`), and this only draws what came of it.

const std = @import("std");
const weft = @import("weft");
const Node = weft.semantic.scene.Node;
const Fact = weft.semantic.scene.Fact;
const durable = weft.semantic.durable;

const kind = "undo-tree";
const go_action = "undo-tree.go";

/// Cells a lane of the graph takes: a graph cell and the gap after it (the
/// presenter's `Graph.lane`).
const lane_cells: u16 = 4;

// Scene node ids, in disjoint ranges so none can collide.
const root_id: u64 = 1;
/// Step `k` of the history is node `step_base + k`.
const step_base: u64 = 2;
/// Row `r` of the graph (a row of steps, or the lines between two).
const row_base: u64 = 1 << 32;
/// The line cell in row `r`, lane `l`.
const line_base: u64 = 2 << 32;
/// The words beside row `r`.
const words_base: u64 = 3 << 32;

const Step = struct {
    parent: u32,
    current: bool,
    applied: bool,
    /// `text` is what the step took away (it wrote nothing).
    removal: bool,
    text: []const u8,
    inserted: []const u8,
    removed: []const u8,
    // Laid out.
    depth: u32 = 0,
    lane: u32 = 0,
    width: u32 = 1,
};

/// One subject's tree, in an entry of its own.
const Tree = struct {
    /// The subject's designation, what a step is moved in.
    subject: []u8,
    name_buf: [48]u8 = undefined,
    name_len: usize = 0,
    arena: std.heap.ArenaAllocator,
    steps: std.ArrayList(Step) = .empty,
    /// The listing the steps were read from (they borrow it).
    listing: std.ArrayList(u8) = .empty,
    view: ?weft.semantic.view.Ref = null,
    revision: u32 = 0,

    fn name(self: *const Tree) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    fn destroy(self: *Tree) void {
        self.arena.deinit();
        self.listing.deinit(weft.allocator);
        weft.allocator.free(self.subject);
        weft.allocator.destroy(self);
    }
};

var trees: std.ArrayList(*Tree) = .empty;

const cmds = [_]weft.CommandEntry{
    .{ .name = "undo-tree.open", .arity = .whole, .call = open, .summary = "Show the undo history as a tree: every step, every branch, and where you are.", .label = "Undo History", .menu = "Edit", .group = "history", .order = 40, .icon = "history" },
    .{ .name = "undo-tree.present", .arity = .whole, .call = present, .params = "designation", .summary = "Present an entry's undo history (weft://…?as=undo-tree).", .internal = true },
    .{ .name = "undo-tree.go", .arity = .one, .call = go, .params = "step", .summary = "Bring an entry to a step of its undo tree.", .internal = true },
};

comptime {
    weft.plugin(&cmds, .{ .init = init, .capabilities = &.{"designation/" ++ kind} }).exportAll();
    weft.exportCallback("on_semantic_action", &onSemanticAction);
    weft.exportCallback("on_subject_changed", &onSubjectChanged);
}

fn init() void {
    _ = weft.semanticActionProvider();
    _ = weft.designationOpener(kind, "undo-tree.present");
}

/// `undo-tree.open`: the configured viewport, shown or hidden (it follows the
/// editor there); with none, the active entry's tree in its place.
fn open() void {
    const viewport = weft.config("viewport");
    if (viewport.len > 0) return weft.runStr("viewport.toggle", viewport);
    const here = weft.designation() orelse return weft.echo("undo-tree: this entry has no history to show");
    var d = durable.parse(here) orelse return weft.echo("undo-tree: this entry has no history to show");
    d.params = "as=" ++ kind;
    var buf: [4200]u8 = undefined;
    weft.openDesignation(d.render(&buf) catch return);
}

/// The opener: `open <entry>?as=undo-tree`, run with that entry active.
fn present() void {
    const text = weft.argStr(0) orelse return;
    const d = durable.parse(text) orelse return weft.echo("undo-tree: not a designation");
    switch (d.kind) {
        .projection => |k| if (std.mem.eql(u8, k, kind)) return weft.echo("undo-tree: present an entry as its undo tree ({subject, as: \"undo-tree\"})"),
        else => {},
    }
    // The subject by the name core gives it — what `edit.undo-to` compares.
    const subject = weft.allocator.dupe(u8, weft.designation() orelse return) catch return;
    defer weft.allocator.free(subject);
    const tree = treeFor(subject) orelse return;
    // Read while the subject is the active entry, before the tree's own
    // entry takes its place.
    _ = read(tree);
    weft.focusOrCreateBuffer(tree.name());
    weft.toolBacking(kind);
    designateFor(d);
    publish(tree) catch return;
    _ = weft.subjectWatch(tree.subject);
    if (tree.view) |ref| _ = weft.semanticViewFocus(ref, currentNode(tree));
}

/// `on_subject_changed`: bound to the subject's entry — re-read its tree, and
/// publish only when the history moved.
fn onSubjectChanged() callconv(.c) void {
    prune();
    const here = weft.designation() orelse return;
    for (trees.items) |tree| {
        if (!std.mem.eql(u8, tree.subject, here)) continue;
        if (read(tree)) publish(tree) catch {};
    }
}

fn prune() void {
    var i: usize = 0;
    while (i < trees.items.len) {
        const tree = trees.items[i];
        if (weft.bufferNamed(tree.name())) {
            i += 1;
            continue;
        }
        _ = trees.swapRemove(i);
        weft.subjectUnwatch(tree.subject);
        tree.destroy();
    }
}

fn treeFor(subject: []const u8) ?*Tree {
    prune();
    for (trees.items) |tree| if (std.mem.eql(u8, tree.subject, subject)) return tree;
    const tree = weft.allocator.create(Tree) catch return null;
    const owned = weft.allocator.dupe(u8, subject) catch {
        weft.allocator.destroy(tree);
        return null;
    };
    tree.* = .{ .subject = owned, .arena = std.heap.ArenaAllocator.init(weft.allocator) };
    var n: u32 = 1;
    while (true) : (n += 1) {
        const taken = weft.instanceName(kind, n, &tree.name_buf) orelse {
            tree.destroy();
            return null;
        };
        if (weft.bufferNamed(taken)) continue;
        tree.name_len = taken.len;
        break;
    }
    trees.append(weft.allocator, tree) catch {
        tree.destroy();
        return null;
    };
    return tree;
}

/// `weft://here/undo-tree/<subject kind><subject ref>`.
fn designateFor(d: durable.Designation) void {
    var buf: [4096]u8 = undefined;
    const ref = std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ d.kind.name(), if (std.mem.startsWith(u8, d.ref, "/")) "" else "/", d.ref }) catch return;
    var out: [4200]u8 = undefined;
    const own: durable.Designation = .{ .authority = .here, .kind = .{ .projection = kind }, .ref = ref };
    _ = weft.designate(own.render(&out) catch return);
}

// ── Reading and laying out ─────────────────────────────────────────────

/// Read the active entry's history into `tree`. False when it reads as it
/// did (nothing to publish).
fn read(tree: *Tree) bool {
    const listing = weft.callString("edit.undo-tree") orelse "";
    if (tree.view != null and std.mem.eql(u8, listing, tree.listing.items)) return false;
    tree.listing.clearRetainingCapacity();
    tree.listing.appendSlice(weft.allocator, listing) catch return false;
    _ = tree.arena.reset(.retain_capacity);
    tree.steps = .empty;
    parse(tree.arena.allocator(), tree.listing.items, &tree.steps) catch {
        tree.steps = .empty;
    };
    layout(tree.steps.items);
    return true;
}

/// `<id>\t<parent>\t<flags>\t<inserted>\t<removed>\t<text>` a line, ids in
/// order from 0; flags `c` current, `a` applied, `x` text removed
/// (`UndoLog.describe`).
fn parse(a: std.mem.Allocator, listing: []const u8, out: *std.ArrayList(Step)) !void {
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        const id = try std.fmt.parseInt(u32, f.next() orelse return error.Malformed, 10);
        if (id != out.items.len) return error.Malformed;
        const parent = try std.fmt.parseInt(u32, f.next() orelse return error.Malformed, 10);
        if (id != 0 and parent >= id) return error.Malformed;
        const flags = f.next() orelse return error.Malformed;
        const inserted = f.next() orelse return error.Malformed;
        const removed = f.next() orelse return error.Malformed;
        try out.append(a, .{
            .parent = parent,
            .current = std.mem.indexOfScalar(u8, flags, 'c') != null,
            .applied = std.mem.indexOfScalar(u8, flags, 'a') != null,
            .removal = std.mem.indexOfScalar(u8, flags, 'x') != null,
            .inserted = inserted,
            .removed = removed,
            .text = f.rest(),
        });
    }
}

/// Depth is distance from the root; a step's LANE is its parent's for the
/// first child, and just right of every lane an older sibling's subtree
/// takes for each later one — so subtrees never share a lane, and a line
/// from a parent to its children never crosses a step. Parents are older
/// than children, so one pass up (widths) and one down (lanes) suffice.
fn layout(steps: []Step) void {
    if (steps.len == 0) return;
    for (steps) |*s| s.width = 0;
    var i = steps.len;
    while (i > 1) {
        i -= 1;
        const s = &steps[i];
        if (s.width == 0) s.width = 1;
        steps[s.parent].width += s.width;
    }
    if (steps[0].width == 0) steps[0].width = 1;
    // Where the next child of each step goes, starting at its own lane.
    const next = weft.allocator.alloc(u32, steps.len) catch return;
    defer weft.allocator.free(next);
    steps[0].depth = 0;
    steps[0].lane = 0;
    next[0] = 0;
    for (steps[1..], 1..) |*s, k| {
        const p = steps[s.parent];
        s.depth = p.depth + 1;
        s.lane = next[s.parent];
        next[s.parent] += s.width;
        next[k] = s.lane;
    }
}

fn currentNode(tree: *const Tree) ?weft.semantic.scene.NodeId {
    for (tree.steps.items, 0..) |s, k| if (s.current) return @enumFromInt(step_base + k);
    return null;
}

// ── Drawing ─────────────────────────────────────────────────────────────

fn publish(tree: *Tree) !void {
    const a = tree.arena.allocator();
    const steps = tree.steps.items;
    var rows: std.ArrayList(Node) = .empty;
    if (steps.len == 0) {
        try rows.append(a, .{ .id = @enumFromInt(step_base), .role = "muted", .content = .{ .label = "No history" } });
    } else {
        var depth_max: u32 = 0;
        var lanes: u32 = 1;
        for (steps) |s| {
            depth_max = @max(depth_max, s.depth);
            lanes = @max(lanes, s.lane + 1);
        }
        // The words beside each row start past the widest lane.
        const words_column: u16 = @intCast(@min(lanes * lane_cells + 1, 200));
        var depth: u32 = 0;
        while (depth <= depth_max) : (depth += 1) {
            try rows.append(a, try stepRow(a, steps, depth, words_column));
            if (try linesRow(a, steps, depth)) |row| try rows.append(a, row);
        }
    }
    const root: Node = .{ .id = @enumFromInt(root_id), .role = "undo-tree", .content = .{ .container = .{ .children = try rows.toOwnedSlice(a) } } };
    tree.revision += 1;
    if (tree.view) |ref| {
        if (weft.semanticViewReplace(ref, tree.revision, root)) |_| return else |_| tree.view = null;
    }
    tree.view = try weft.semanticViewPublish(root, null, tree.revision);
}

/// The steps at `depth`, each a dot in its lane, with a line up to where it
/// came from and down to what followed it — then, in words, what each did.
fn stepRow(a: std.mem.Allocator, steps: []const Step, depth: u32, words_column: u16) !Node {
    var cells: std.ArrayList(Node) = .empty;
    var words: std.ArrayList(u8) = .empty;
    for (steps, 0..) |s, k| {
        if (s.depth != depth) continue;
        const has_children = for (steps[k + 1 ..]) |c| {
            if (c.parent == k) break true;
        } else false;
        const links: []const u8 = if (depth > 0 and has_children) "ns" else if (depth > 0) "n" else if (has_children) "s" else "";
        const what = try describe(a, k, s);
        try cells.append(a, .{
            .id = @enumFromInt(step_base + k),
            .role = "undo-tree.edge",
            .layout = .{ .column = @intCast(@min(s.lane * lane_cells, 60000)) },
            .focusable = true,
            .facts = try a.dupe(Fact, &.{
                .{ .name = "links", .value = links },
                .{ .name = "mark", .value = if (s.current) "current" else if (s.applied) "applied" else "hollow" },
                .{ .name = "tone", .value = if (s.applied) "accent" else "muted" },
            }),
            .content = .{ .action = .{ .action = go_action, .label = what } },
        });
        if (words.items.len > 0) try words.appendSlice(a, "   ");
        if (s.current) try words.appendSlice(a, "▸ ");
        try words.appendSlice(a, what);
    }
    try cells.append(a, .{
        .id = @enumFromInt(words_base + depth),
        .role = "muted",
        .layout = .{ .column = words_column },
        .content = .{ .label = try words.toOwnedSlice(a) },
    });
    return .{ .id = @enumFromInt(row_base + 2 * @as(u64, depth)), .content = .{ .container = .{ .axis = .horizontal, .children = try cells.toOwnedSlice(a) } } };
}

/// The lines from the steps at `depth` to their children: straight down to
/// a first child, and across then down to each later one. Null when no step
/// at `depth` has a child.
fn linesRow(a: std.mem.Allocator, steps: []const Step, depth: u32) !?Node {
    // Per lane: which sides its line cell links, as a bit set (n e s w).
    var links: std.AutoArrayHashMapUnmanaged(u32, u4) = .empty;
    for (steps, 0..) |s, k| {
        if (s.depth != depth) continue;
        // This step's children, by lane (the first shares the parent's).
        var last: ?u32 = null;
        for (steps[k + 1 ..]) |c| {
            if (c.parent != k) continue;
            last = @max(last orelse c.lane, c.lane);
        }
        const far = last orelse continue;
        try orLinks(a, &links, s.lane, 0b0101 | @as(u4, if (far > s.lane) 0b0010 else 0)); // n s (e)
        var lane = s.lane + 1;
        while (lane <= far) : (lane += 1) {
            const child = for (steps[k + 1 ..]) |c| {
                if (c.parent == k and c.lane == lane) break true;
            } else false;
            const across: u4 = if (lane < far) 0b1010 else 0b1000; // e w, or w
            try orLinks(a, &links, lane, across | @as(u4, if (child) 0b0100 else 0));
        }
    }
    if (links.count() == 0) return null;
    var cells: std.ArrayList(Node) = .empty;
    const lanes = try a.dupe(u32, links.keys());
    std.mem.sort(u32, lanes, {}, std.sort.asc(u32));
    for (lanes) |lane| {
        const bits = links.get(lane).?;
        var spelled: std.ArrayList(u8) = .empty;
        if (bits & 0b0001 != 0) try spelled.append(a, 'n');
        if (bits & 0b0010 != 0) try spelled.append(a, 'e');
        if (bits & 0b0100 != 0) try spelled.append(a, 's');
        if (bits & 0b1000 != 0) try spelled.append(a, 'w');
        try cells.append(a, .{
            .id = @enumFromInt(line_base + (@as(u64, depth) << 16) + lane),
            .role = "undo-tree.edge",
            .layout = .{ .column = @intCast(@min(lane * lane_cells, 60000)) },
            .facts = try a.dupe(Fact, &.{.{ .name = "links", .value = try spelled.toOwnedSlice(a) }}),
            .content = .{ .label = "" },
        });
    }
    return .{ .id = @enumFromInt(row_base + 2 * @as(u64, depth) + 1), .content = .{ .container = .{ .axis = .horizontal, .children = try cells.toOwnedSlice(a) } } };
}

fn orLinks(a: std.mem.Allocator, links: *std.AutoArrayHashMapUnmanaged(u32, u4), lane: u32, bits: u4) !void {
    const gop = try links.getOrPut(a, lane);
    gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* | bits else bits;
}

/// A step in words: its number and what it wrote (or took away).
fn describe(a: std.mem.Allocator, k: usize, s: Step) ![]const u8 {
    if (k == 0) return "original";
    // Whole scalars only.
    var end = @min(s.text.len, 24);
    while (end > 0 and !std.unicode.utf8ValidateSlice(s.text[0..end])) end -= 1;
    const shown = s.text[0..end];
    if (shown.len > 0) return std.fmt.allocPrint(a, "{d} {s}{s}", .{ k, if (s.removal) "−" else "+", shown });
    return std.fmt.allocPrint(a, "{d} +{s}/−{s}", .{ k, s.inserted, s.removed });
}

// ── Moving ──────────────────────────────────────────────────────────────

fn onSemanticAction() callconv(.c) void {
    var request = weft.semanticActionCurrent(weft.allocator) catch return;
    defer request.deinit();
    if (!std.mem.eql(u8, request.value.action, go_action)) {
        _ = weft.semanticActionDecline();
        return;
    }
    const tree = for (trees.items) |tree| {
        const view = tree.view orelse continue;
        if (request.value.view.eql(view)) break tree;
    } else {
        _ = weft.semanticActionDecline();
        return;
    };
    const raw = @intFromEnum(request.value.subject);
    if (raw < step_base or raw >= step_base + tree.steps.items.len) {
        _ = weft.semanticActionDecline();
        return;
    }
    _ = weft.semanticActionHandled();
    // The move runs as this plugin's own command — a dispatching entry, as
    // the action callback is not. The step names its tree: `<step>\t<subject>`.
    const arg = std.fmt.allocPrint(weft.allocator, "{d}\t{s}", .{ raw - step_base, tree.subject }) catch return;
    defer weft.allocator.free(arg);
    weft.runStr("undo-tree.go", arg);
}

/// `undo-tree.go <step>\t<subject>`: bring the subject to that step. Where the
/// editor shows the subject it moves there and the focus stays in the tree;
/// otherwise the subject is brought up first.
fn go() void {
    const arg = weft.argStr(0) orelse return;
    const tab = std.mem.indexOfScalar(u8, arg, '\t') orelse return weft.echo("undo-tree.go: <step>\\t<subject>");
    const step = weft.allocator.dupe(u8, arg[0..tab]) catch return;
    defer weft.allocator.free(step);
    const subject = weft.allocator.dupe(u8, arg[tab + 1 ..]) catch return;
    defer weft.allocator.free(subject);
    const primary = weft.contextGet("entry") orelse "";
    if (std.mem.eql(u8, primary, subject)) {
        if (weft.runArgsIn(.primary, "edit.undo-to", &.{ step, subject })) return;
    }
    weft.openDesignation(subject);
    weft.runArgs("edit.undo-to", &.{ step, subject });
}
