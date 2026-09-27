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
//! The symbols are the grammar's OUTLINE (`weft.outline`, the configured
//! `outline.scm`, the same query the breadcrumbs read), nested by span:
//! nothing here knows a language. An entry with no grammar or no outline
//! query shows that it has no symbols rather than nothing at all.
//!
//! A row jumps: it opens the subject again (placement puts it in the primary
//! pane, never in the companion showing the tree) and moves the caret to the
//! symbol, leaving a jump behind.
//!
//! What it shows is read when it is presented. An edit to the subject does
//! not re-read it until the subject is presented again — the editor moving to
//! another entry and back, or `symbols-refresh`: there is no event for a
//! document's revision yet, and polling one is not an option.

const std = @import("std");
const weft = @import("weft");
const Node = weft.semantic.scene.Node;
const durable = weft.semantic.durable;

const kind = "symbols";
const entry_name = "*symbols*";
const jump_action = "symbols.jump";
const root_id: u64 = 1;
const row_base: u64 = 2;
/// The horizontal line each row sits in; never collides with a row.
const line_base: u64 = 1 << 32;

const max_symbols = 2048;

const Symbol = struct { name: []const u8, start: usize, depth: usize };

var arena: std.heap.ArenaAllocator = undefined;
var symbols: std.ArrayList(Symbol) = .empty;
/// The subject's designation (without `as`), what a row reopens.
var subject: std.ArrayList(u8) = .empty;
var view_ref: ?weft.semantic.view.Ref = null;
var revision: u32 = 0;

const cmds = [_]weft.CommandEntry{
    .{ .name = "symbols-present", .arity = .whole, .call = present, .params = "designation", .summary = "present an entry's symbols (weft://…?as=symbols)" },
    .{ .name = "symbols-refresh", .arity = .whole, .call = refresh, .summary = "read the presented entry's symbols again" },
    .{ .name = "symbols-jump", .arity = .one, .call = jump, .params = "offset" },
};

comptime {
    weft.plugin(&cmds, .{ .init = init }).exportAll();
    weft.exportCallback("on_semantic_action", &onSemanticAction);
}

fn init() void {
    arena = std.heap.ArenaAllocator.init(weft.allocator);
    _ = weft.semanticActionProvider();
    _ = weft.designationOpener(kind, "symbols-present");
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
    subject.clearRetainingCapacity();
    const bare = d.bare().renderAlloc(weft.allocator) catch return;
    defer weft.allocator.free(bare);
    subject.appendSlice(weft.allocator, bare) catch return;
    // Read the subject while it is the active entry, before this plugin's
    // own entry takes its place.
    collect();
    weft.focusOrCreateBuffer(entry_name);
    weft.toolBacking(kind);
    designateFor(d);
    publish() catch return;
    if (view_ref) |ref| _ = weft.semanticViewFocus(ref, null);
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

fn refresh() void {
    if (subject.items.len == 0) return;
    const text = weft.allocator.dupe(u8, subject.items) catch return;
    defer weft.allocator.free(text);
    weft.openDesignation(text);
    collect();
    publish() catch {};
}

/// The active entry's outline, nested by span: each item's depth is how many
/// of the items before it still enclose it.
fn collect() void {
    _ = arena.reset(.retain_capacity);
    symbols = .empty;
    const a = arena.allocator();
    const n = weft.outline(.{ .start = 0, .end = weft.byteLen() });
    var ends: std.ArrayList(usize) = .empty;
    var i: usize = 0;
    while (i < n and symbols.items.len < max_symbols) : (i += 1) {
        const c = weft.queryCapture(i) orelse continue;
        while (ends.items.len > 0 and ends.items[ends.items.len - 1] <= c.start) _ = ends.pop();
        symbols.append(a, .{ .name = a.dupe(u8, c.name) catch return, .start = c.start, .depth = ends.items.len }) catch return;
        ends.append(a, c.end) catch return;
    }
}

fn publish() !void {
    const a = arena.allocator();
    var rows: std.ArrayList(Node) = .empty;
    for (symbols.items, 0..) |s, i| {
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
        try rows.append(a, .{ .id = @enumFromInt(line_base + i), .content = .{ .container = .{ .axis = .horizontal, .children = cells } } });
    }
    if (symbols.items.len == 0)
        try rows.append(a, .{ .id = @enumFromInt(row_base), .role = "muted", .content = .{ .label = "No symbols" } });
    const root: Node = .{ .id = @enumFromInt(root_id), .role = "symbols", .content = .{ .container = .{ .children = try rows.toOwnedSlice(a) } } };
    revision += 1;
    if (view_ref) |ref| {
        if (weft.semanticViewReplace(ref, revision, root)) |_| return else |_| view_ref = null;
    }
    view_ref = try weft.semanticViewPublish(root, null, revision);
}

const depths = [_][]const u8{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "14", "15", "16" };

fn onSemanticAction() callconv(.c) void {
    var request = weft.semanticActionCurrent(weft.allocator) catch return;
    defer request.deinit();
    if (!std.mem.eql(u8, request.value.action, jump_action)) {
        _ = weft.semanticActionDecline();
        return;
    }
    const raw = @intFromEnum(request.value.subject);
    if (raw < row_base or raw >= row_base + symbols.items.len) {
        _ = weft.semanticActionDecline();
        return;
    }
    _ = weft.semanticActionHandled();
    var buf: [24]u8 = undefined;
    weft.runStr("symbols-jump", std.fmt.bufPrint(&buf, "{d}", .{symbols.items[@intCast(raw - row_base)].start}) catch return);
}

/// `symbols-jump <offset>`: the subject, the caret at the symbol.
fn jump() void {
    const arg = weft.argStr(0) orelse return;
    const offset = std.fmt.parseInt(usize, std.mem.trim(u8, arg, " "), 10) catch return;
    if (subject.items.len == 0) return;
    const text = weft.allocator.dupe(u8, subject.items) catch return;
    defer weft.allocator.free(text);
    weft.openDesignation(text);
    weft.jumpPush();
    weft.jump(offset);
}
