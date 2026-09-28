//! symbols — the provider for the `symbols` projection (doc/model.md §2.4):
//! an entry's symbols as a tree of rows, each a jump to its symbol.
//!
//! It is presented as ANOTHER producer's projection of an entry —
//! `weft.present("outline", {subject: {context: "entry"}, as: "symbols"})` —
//! so what reaches it is the entry's own designation with `as=symbols`, and
//! core runs it with that entry active (`designation.openHeld`): the outline
//! it reads is the subject's. A viewport following the `entry` key presents
//! it again whenever the editor moves to another entry.
//!
//! Each subject's tree is its own entry (`*symbols*`, `*symbols:2*`, …),
//! designated once for its life: two viewports on two entries' symbols each
//! keep theirs, and presenting one never re-designates the other.
//!
//! The symbols are the grammar's OUTLINE (`weft.outline`, the configured
//! `outline.scm`, the same query the breadcrumbs read), nested by span:
//! nothing here knows a language. An entry with no grammar or no outline
//! query shows that it has no symbols rather than nothing at all.
//!
//! A row jumps: it opens the subject again (placement puts it in the primary
//! pane, never in the companion showing the tree) and moves the caret to the
//! symbol, leaving a jump behind.
//!
//! What it shows is read when it is presented, and again whenever the subject
//! reads differently: each tree WATCHES its subject (`weft.subjectWatch`), and
//! `on_subject_changed` — at the frame boundary, bound to the subject's entry
//! — re-reads the outline there, so an edit, or a parse that lands frames
//! after the tree was presented, shows without the subject coming to the
//! front and without anything polling. A re-read that finds the same symbols
//! publishes nothing.

const std = @import("std");
const weft = @import("weft");
const Node = weft.semantic.scene.Node;
const durable = weft.semantic.durable;

const kind = "symbols";
const jump_action = "symbols.jump";
const root_id: u64 = 1;
const row_base: u64 = 2;
/// The horizontal line each row sits in; never collides with a row.
const line_base: u64 = 1 << 32;

const max_symbols = 2048;

const Symbol = struct { name: []const u8, start: usize, depth: usize };

/// One subject's tree, in an entry of its own.
const Tree = struct {
    /// The subject's designation (without `as`), what a row reopens.
    subject: []u8,
    /// Its entry: `*symbols*`, then `*symbols:2*`, … (`instanceName`).
    name_buf: [48]u8 = undefined,
    name_len: usize = 0,
    arena: std.heap.ArenaAllocator,
    symbols: std.ArrayList(Symbol) = .empty,
    view: ?weft.semantic.view.Ref = null,
    revision: u32 = 0,
    /// What the read symbols hash to, so a re-read that finds the same ones
    /// publishes nothing.
    digest: u64 = 0,

    fn name(self: *const Tree) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    fn destroy(self: *Tree) void {
        self.arena.deinit();
        weft.allocator.free(self.subject);
        weft.allocator.destroy(self);
    }
};

var trees: std.ArrayList(*Tree) = .empty;

const cmds = [_]weft.CommandEntry{
    .{ .name = "symbols.present", .arity = .whole, .call = present, .params = "designation", .summary = "Present an entry's symbols (weft://…?as=symbols).", .internal = true },
    .{ .name = "symbols.jump", .arity = .one, .call = jump, .params = "offset", .summary = "Open the subject with the cursor at a symbol.", .internal = true },
};

comptime {
    weft.plugin(&cmds, .{ .init = init }).exportAll();
    weft.exportCallback("on_semantic_action", &onSemanticAction);
    weft.exportCallback("on_subject_changed", &onSubjectChanged);
}

fn init() void {
    _ = weft.semanticActionProvider();
    _ = weft.designationOpener(kind, "symbols.present");
}

/// The opener: `open <entry>?as=symbols`, run with that entry active.
fn present() void {
    const text = weft.argStr(0) orelse return;
    const d = durable.parse(text) orelse return weft.echo("symbols: not a designation");
    switch (d.kind) {
        // Its own designation names what it last showed, not something it
        // can read again without that entry in front of it.
        .projection => |k| if (std.mem.eql(u8, k, kind)) return weft.echo("symbols: present an entry as symbols ({subject, as: \"symbols\"})"),
        else => {},
    }
    const bare = d.bare().renderAlloc(weft.allocator) catch return;
    defer weft.allocator.free(bare);
    const tree = treeFor(bare) orelse return;
    // Read the subject while it is the active entry, before the tree's own
    // entry takes its place.
    collect(tree);
    weft.focusOrCreateBuffer(tree.name());
    weft.toolBacking(kind);
    designateFor(d);
    publish(tree) catch return;
    // Hear the subject change from here on; the watch's baseline is what
    // was just read.
    _ = weft.subjectWatch(tree.subject);
    if (tree.view) |ref| _ = weft.semanticViewFocus(ref, null);
}

/// Forget the trees whose entries were closed: their views went with them.
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

/// The tree for `subject`, made (under an entry name no live tree or entry
/// has) when there is none.
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

/// `weft://here/symbols/<subject kind><subject ref>` — what this entry is
/// the symbols of, in the only kind this plugin may declare.
fn designateFor(d: durable.Designation) void {
    var buf: [4096]u8 = undefined;
    const ref = std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ d.kind.name(), if (std.mem.startsWith(u8, d.ref, "/")) "" else "/", d.ref }) catch return;
    var out: [4200]u8 = undefined;
    const own: durable.Designation = .{ .authority = .here, .kind = .{ .projection = kind }, .ref = ref };
    _ = weft.designate(own.render(&out) catch return);
}

/// `on_subject_changed`: a watched subject reads differently, and this call
/// is bound to its entry — the outline read here is the subject's, whatever
/// is in front. Re-read its tree; publish only when the symbols moved.
fn onSubjectChanged() callconv(.c) void {
    prune();
    const here = weft.designation() orelse return;
    for (trees.items) |tree| {
        if (!std.mem.eql(u8, tree.subject, here)) continue;
        const was = tree.digest;
        collect(tree);
        if (tree.digest != was) publish(tree) catch {};
    }
}

/// The active entry's outline, nested by span: each item's depth is how many
/// of the items before it still enclose it.
fn collect(tree: *Tree) void {
    defer tree.digest = digestOf(tree.symbols.items);
    _ = tree.arena.reset(.retain_capacity);
    tree.symbols = .empty;
    const a = tree.arena.allocator();
    const n = weft.outline(.{ .start = 0, .end = weft.byteLen() });
    var ends: std.ArrayList(usize) = .empty;
    var i: usize = 0;
    while (i < n and tree.symbols.items.len < max_symbols) : (i += 1) {
        const c = weft.queryCapture(i) orelse continue;
        while (ends.items.len > 0 and ends.items[ends.items.len - 1] <= c.start) _ = ends.pop();
        tree.symbols.append(a, .{ .name = a.dupe(u8, c.name) catch return, .start = c.start, .depth = ends.items.len }) catch return;
        ends.append(a, c.end) catch return;
    }
}

fn digestOf(symbols: []const Symbol) u64 {
    var h = std.hash.Wyhash.init(0);
    for (symbols) |s| {
        h.update(s.name);
        h.update(std.mem.asBytes(&s.start));
        h.update(std.mem.asBytes(&s.depth));
    }
    return h.final();
}

fn publish(tree: *Tree) !void {
    const a = tree.arena.allocator();
    var rows: std.ArrayList(Node) = .empty;
    for (tree.symbols.items, 0..) |s, i| {
        // Nesting is the row's column, so the name reads as the button.
        const depth: u16 = @intCast(@min(s.depth, 16));
        const cells = try a.alloc(Node, 1);
        cells[0] = .{
            .id = @enumFromInt(row_base + i),
            .role = "symbols.row",
            .facts = try a.dupe(weft.semantic.scene.Fact, &.{.{ .name = "depth", .value = depths[depth] }}),
            .layout = .{ .column = depth * 2 },
            .focusable = true,
            .content = .{ .action = .{ .action = jump_action, .label = s.name } },
        };
        // The row says how much of its column is depth, so a narrow outline
        // gives the depth back before it cuts a name.
        const indent = try a.dupe(weft.semantic.scene.Fact, &.{.{ .name = "indent", .value = try std.fmt.allocPrint(a, "{d}", .{depth * 2}) }});
        try rows.append(a, .{ .id = @enumFromInt(line_base + i), .facts = indent, .content = .{ .container = .{ .axis = .horizontal, .children = cells } } });
    }
    if (tree.symbols.items.len == 0)
        try rows.append(a, .{ .id = @enumFromInt(row_base), .role = "muted", .content = .{ .label = "No symbols" } });
    const root: Node = .{ .id = @enumFromInt(root_id), .role = "symbols", .content = .{ .container = .{ .children = try rows.toOwnedSlice(a) } } };
    tree.revision += 1;
    if (tree.view) |ref| {
        if (weft.semanticViewReplace(ref, tree.revision, root)) |_| return else |_| tree.view = null;
    }
    tree.view = try weft.semanticViewPublish(root, null, tree.revision);
}

const depths = [_][]const u8{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "14", "15", "16" };

fn onSemanticAction() callconv(.c) void {
    var request = weft.semanticActionCurrent(weft.allocator) catch return;
    defer request.deinit();
    if (!std.mem.eql(u8, request.value.action, jump_action)) {
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
    if (raw < row_base or raw >= row_base + tree.symbols.items.len) {
        _ = weft.semanticActionDecline();
        return;
    }
    _ = weft.semanticActionHandled();
    // The row's tree names its subject: `<offset>\t<subject>`.
    const arg = std.fmt.allocPrint(weft.allocator, "{d}\t{s}", .{ tree.symbols.items[@intCast(raw - row_base)].start, tree.subject }) catch return;
    defer weft.allocator.free(arg);
    weft.runStr("symbols.jump", arg);
}

/// `symbols.jump <offset>\t<subject>`: the subject, the caret at the symbol.
fn jump() void {
    const arg = weft.argStr(0) orelse return;
    const tab = std.mem.indexOfScalar(u8, arg, '\t') orelse return weft.echo("symbols.jump: <offset>\\t<subject>");
    const offset = std.fmt.parseInt(usize, std.mem.trim(u8, arg[0..tab], " "), 10) catch return;
    const subject = weft.allocator.dupe(u8, arg[tab + 1 ..]) catch return;
    defer weft.allocator.free(subject);
    if (subject.len == 0) return;
    weft.openDesignation(subject);
    weft.jumpPush();
    weft.jump(offset);
}
