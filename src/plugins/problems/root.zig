//! problems — the provider for the `diagnostics` projection (doc/model.md
//! §2.4): the diagnostics of a PLACE's open documents as one list, grouped
//! by file, in a panel. Return (or a click) on a row opens the file at the
//! diagnostic.
//!
//! `weft://here/diagnostics/<place directory>` is that list for one place —
//! rows under the place (and rows a source names relative to it) — and
//! `weft://here/diagnostics/all` every row. Another designation presented
//! `as: "diagnostics"` is the list for the place it names
//! (`{subject: {context: "place"}, as: "diagnostics"}`). `problems` brings
//! the list of the place it is run in into the panel; a place with no local
//! directory has no list, and says so.
//!
//! Each designation is its own entry (`*problems*`, `*problems:2*`, …), so
//! two viewports on two places' lists each keep theirs.
//!
//! The list is a semantic view (a scene of `action` rows under a heading per
//! file), so the rows answer the standard vocabulary — up/down move, Return
//! is `std.target.activate`, a click activates — under any grammar, with no
//! key bound here.
//!
//! **Where the rows come from is configuration.** `source` names a command
//! whose string result is one `path\tline\tcol\tseverity\tmessage` row per
//! diagnostic (default `diagnostics-list`, the `lsp` plugin's), and `signal`
//! the named signal that says they moved (default `diagnostics`, which `lsp`
//! raises). Nothing here knows a language server exists: a linter plugin
//! answering the same shape is a `weft.set` away.
//!
//! **Where the list shows is configuration too.** `problems` puts its entry in
//! the viewport named by `viewport` (default `panel`, declared by
//! `config/panel.js`) through core's generic `viewport-take`, replacing what
//! the panel showed. Without such a viewport it opens where it is run.

const std = @import("std");
const weft = @import("weft");
const Node = weft.semantic.scene.Node;
const NodeId = weft.semantic.scene.NodeId;

const activate_action = "problems.open";

/// One row's destination, by the scene node it was drawn as.
const Row = struct { id: NodeId, path: []const u8, line: usize, col: usize };

/// One place's list, in an entry of its own. A list is ONE designation for
/// its life: two viewports on two places' diagnostics hold two entries, and
/// presenting one never re-designates the other's (which is what made them
/// flip, each re-running the other's).
const List = struct {
    /// The place directory the list is scoped to; empty only for
    /// `diagnostics/all`, which asks for every row by name.
    scope: []u8,
    /// Its entry: `*problems*`, then `*problems:2*`, … (`instanceName`).
    name_buf: [48]u8 = undefined,
    name_len: usize = 0,
    arena: std.heap.ArenaAllocator,
    view: ?weft.semantic.view.Ref = null,
    revision: u32 = 0,
    rows: std.ArrayList(Row) = .empty,
    /// The source's last answer, to skip rebuilding a list that did not change.
    last: std.ArrayList(u8) = .empty,

    fn name(self: *const List) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    fn destroy(self: *List) void {
        self.arena.deinit();
        self.last.deinit(weft.allocator);
        weft.allocator.free(self.scope);
        weft.allocator.destroy(self);
    }
};

var lists: std.ArrayList(*List) = .empty;

fn orDefault(key: []const u8, default: []const u8) []const u8 {
    const v = weft.config(key);
    return if (v.len > 0) v else default;
}

fn init() void {
    _ = weft.semanticActionProvider();
    // The signal name is read ONCE, here: a subscription is for the life of
    // the plugin.
    _ = weft.signalSubscribe(orDefault("signal", "diagnostics"));
    _ = weft.designationOpener("diagnostics", "problems-present");
}

/// `problems`: the list of the place this runs in, shown in the panel and
/// focused there. A place with no local directory has no list here — never
/// every row in the workspace standing in for it.
fn open() void {
    const root = weft.placeRoot();
    if (root.len == 0) return weft.echo("problems: this place has no local directory");
    show(root);
    weft.runStr("viewport-take", orDefault("viewport", "panel"));
}

/// The opener: `open weft://here/diagnostics/<place>`, or a place's
/// designation `?as=diagnostics` — the list for that place, active.
fn present() void {
    const text = weft.argStr(0) orelse return;
    const d = weft.semantic.durable.parse(text) orelse return weft.echo("problems: not a designation");
    var buf: [4096]u8 = undefined;
    const dir: []const u8 = switch (d.kind) {
        .projection => |k| if (!std.mem.eql(u8, k, "diagnostics"))
            return weft.echo("problems: present a place as diagnostics")
        else if (std.mem.eql(u8, d.ref, "all"))
            ""
        else
            weft.placeOf(d, &buf) orelse return weft.echo("problems: only a local place has diagnostics here"),
        .directory => if (d.authority == .here) d.ref else return weft.echo("problems: only a local place has diagnostics here"),
        else => return weft.echo("problems: present a place as diagnostics"),
    };
    show(dir);
}

/// Forget the lists whose entries were closed: their views went with them.
fn prune() void {
    var i: usize = 0;
    while (i < lists.items.len) {
        const l = lists.items[i];
        if (weft.bufferNamed(l.name())) {
            i += 1;
            continue;
        }
        _ = lists.swapRemove(i);
        l.destroy();
    }
}

/// The list for `scope`, made (under an entry name no live list or entry
/// has) when there is none.
fn listFor(scope: []const u8) ?*List {
    prune();
    for (lists.items) |l| if (std.mem.eql(u8, l.scope, scope)) return l;
    const l = weft.allocator.create(List) catch return null;
    const owned = weft.allocator.dupe(u8, scope) catch {
        weft.allocator.destroy(l);
        return null;
    };
    l.* = .{ .scope = owned, .arena = std.heap.ArenaAllocator.init(weft.allocator) };
    var n: u32 = 1;
    while (true) : (n += 1) {
        const taken = weft.instanceName("problems", n, &l.name_buf) orelse {
            l.destroy();
            return null;
        };
        if (weft.bufferNamed(taken)) continue;
        l.name_len = taken.len;
        break;
    }
    lists.append(weft.allocator, l) catch {
        l.destroy();
        return null;
    };
    return l;
}

/// Make `scope`'s list active, drawn, and named by the place it lists.
fn show(scope: []const u8) void {
    const l = listFor(scope) orelse return;
    weft.focusOrCreateBuffer(l.name());
    weft.toolBacking("problems");
    // The entry IS this place's diagnostics (doc/model.md §2.1), re-run by
    // name. Its designation never changes: another place is another list.
    var named: [4200]u8 = undefined;
    const trimmed = std.mem.trimStart(u8, l.scope, "/");
    const d: weft.semantic.durable.Designation = .{ .kind = .{ .projection = "diagnostics" }, .ref = if (trimmed.len == 0) "all" else trimmed };
    _ = weft.designate(d.render(&named) catch return);
    const text = weft.allocator.dupe(u8, source()) catch return;
    defer weft.allocator.free(text);
    rebuild(l, text, true);
    if (l.view) |ref| _ = weft.semanticViewFocus(ref, null);
}

/// Whether a row's path is in `l`'s place: under it, or named relative to
/// it. Every row, for `diagnostics/all`.
fn inScope(l: *const List, path: []const u8) bool {
    if (l.scope.len == 0 or !std.fs.path.isAbsolutePosix(path)) return true;
    const base = std.mem.trimEnd(u8, l.scope, "/");
    return std.mem.startsWith(u8, path, base) and path.len > base.len and path[base.len] == '/';
}

/// The source's rows now, borrowed until the next call into the host.
fn source() []const u8 {
    return weft.callString(orDefault("source", "diagnostics-list")) orelse "";
}

/// `problems-refresh`, and the signal: every open list, re-read from one
/// answer of the source. Only lists that exist are refreshed — hearing about
/// diagnostics never opens one.
fn refresh() void {
    prune();
    if (lists.items.len == 0) return;
    const text = weft.allocator.dupe(u8, source()) catch return;
    defer weft.allocator.free(text);
    for (lists.items) |l| rebuild(l, text, false);
}

fn onSignal(id: i32) callconv(.c) void {
    _ = id;
    refresh();
}

/// The row's color, as a `tone` the scene renderer knows.
fn severityTone(sev: []const u8) []const u8 {
    if (std.mem.eql(u8, sev, "error")) return "negative";
    if (std.mem.eql(u8, sev, "warning")) return "warning";
    return "normal";
}

/// (Re)publish `l`'s scene from the source's `text`. `force` rebuilds even
/// when the source answered the same rows (an open wants a view either way).
fn rebuild(l: *List, text: []const u8, force: bool) void {
    if (!force and l.view != null and std.mem.eql(u8, text, l.last.items)) return;
    l.last.clearRetainingCapacity();
    l.last.appendSlice(weft.allocator, text) catch {};

    _ = l.arena.reset(.retain_capacity);
    const a = l.arena.allocator();
    l.rows = .empty;
    var nodes: std.ArrayList(Node) = .empty;
    var next_id: u64 = 2;
    var current_path: []const u8 = "";
    var count: usize = 0;

    var lines = std.mem.splitScalar(u8, l.last.items, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        const path = f.next() orelse continue;
        const line_no = std.fmt.parseInt(usize, f.next() orelse continue, 10) catch continue;
        const col = std.fmt.parseInt(usize, f.next() orelse continue, 10) catch continue;
        const sev = f.next() orelse continue;
        const msg = f.rest();
        if (!inScope(l, path)) continue;
        if (!std.mem.eql(u8, path, current_path)) {
            // Rows arrive grouped by file (one source session per document);
            // a heading starts each group.
            current_path = path;
            nodes.append(a, .{
                .id = @enumFromInt(next_id),
                .role = "accent",
                .content = .{ .label = a.dupe(u8, path) catch return },
            }) catch return;
            next_id += 1;
        }
        const id: NodeId = @enumFromInt(next_id);
        next_id += 1;
        const label = std.fmt.allocPrint(a, "  {d}:{d}  {s}  {s}", .{ line_no, col, sev, msg }) catch return;
        nodes.append(a, .{
            .id = id,
            .role = "problems.row",
            .focusable = true,
            .facts = a.dupe(weft.semantic.scene.Fact, &.{.{ .name = "tone", .value = severityTone(sev) }}) catch return,
            .content = .{ .action = .{ .action = activate_action, .label = label } },
        }) catch return;
        l.rows.append(a, .{ .id = id, .path = a.dupe(u8, path) catch return, .line = line_no, .col = col }) catch return;
        count += 1;
    }
    if (count == 0) {
        nodes.append(a, .{ .id = @enumFromInt(next_id), .role = "muted", .content = .{ .label = "No problems" } }) catch return;
    }
    const root: Node = .{ .id = @enumFromInt(1), .role = "problems", .content = .{ .container = .{ .children = nodes.toOwnedSlice(a) catch return } } };
    l.revision += 1;
    if (l.view) |old| {
        if (weft.semanticViewReplace(old, l.revision, root)) |_| return else |_| l.view = null;
    }
    l.view = weft.semanticViewPublish(root, null, l.revision) catch null;
}

fn onSemanticAction() callconv(.c) void {
    var request = weft.semanticActionCurrent(weft.allocator) catch return;
    defer request.deinit();
    if (!std.mem.eql(u8, request.value.action, activate_action)) {
        _ = weft.semanticActionDecline();
        return;
    }
    for (lists.items) |l| {
        const view = l.view orelse continue;
        if (!request.value.view.eql(view)) continue;
        for (l.rows.items) |row| {
            if (row.id != request.value.subject) continue;
            _ = weft.semanticActionHandled();
            jumpTo(row);
            return;
        }
    }
    _ = weft.semanticActionDecline();
}

/// Open the row's file (placement puts it in the primary pane, never in the
/// panel) and put the caret at its line and column.
fn jumpTo(row: Row) void {
    weft.openTyped(row.path);
    weft.jumpPush();
    var off: usize = 0;
    var line: usize = 1;
    const len = weft.byteLen();
    while (line < row.line) : (line += 1) {
        const l = weft.lineAt(off);
        if (l.end >= len) break;
        off = l.end + 1;
    }
    const l = weft.lineAt(off);
    weft.jump(@min(off + (row.col -| 1), l.end));
}

const cmds = [_]weft.CommandEntry{
    .{ .name = "problems", .arity = .whole, .call = open, .summary = "list this place's diagnostics in the panel" },
    .{ .name = "problems-present", .arity = .whole, .call = present, .params = "designation", .summary = "present a place's diagnostics (weft://here/diagnostics/<place>)" },
    .{ .name = "problems-refresh", .arity = .whole, .call = refresh, .summary = "re-read the problems lists' source now" },
};

comptime {
    weft.plugin(&cmds, .{ .init = init, .capabilities = &.{"designation/diagnostics"} }).exportAll();
    weft.exportCallback("on_semantic_action", &onSemanticAction);
    weft.exportCallback("on_signal", &onSignal);
}
