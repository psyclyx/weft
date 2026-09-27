//! problems — every diagnostic of the open documents as one list, grouped by
//! file, in a panel. Return (or a click) on a row opens the file at the
//! diagnostic.
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

const buffer_name = "*problems*";
const activate_action = "problems.open";

/// One row's destination, by the scene node it was drawn as.
const Row = struct { id: NodeId, path: []const u8, line: usize, col: usize };

var arena: std.heap.ArenaAllocator = undefined;
var view_ref: ?weft.semantic.view.Ref = null;
var revision: u32 = 0;
var rows: std.ArrayList(Row) = .empty;
/// The source's last answer, to skip rebuilding a list that did not change.
var last: std.ArrayList(u8) = .empty;

fn orDefault(key: []const u8, default: []const u8) []const u8 {
    const v = weft.config(key);
    return if (v.len > 0) v else default;
}

fn init() void {
    arena = std.heap.ArenaAllocator.init(weft.allocator);
    _ = weft.semanticActionProvider();
    // The signal name is read ONCE, here: a subscription is for the life of
    // the plugin.
    _ = weft.signalSubscribe(orDefault("signal", "diagnostics"));
    _ = weft.designationOpener("problems", "problems");
}

/// `problems`: show the list in the panel and focus it there.
fn open() void {
    weft.focusOrCreateBuffer(buffer_name);
    weft.toolBacking("problems");
    // The entry IS the problems list (doc/model.md §2.1), re-run by name.
    _ = weft.designate("weft://here/problems/all");
    rebuild(true);
    if (view_ref) |ref| _ = weft.semanticViewFocus(ref, null);
    weft.runStr("viewport-take", orDefault("viewport", "panel"));
}

/// `problems-refresh`: re-read the source now (what the signal does).
fn refresh() void {
    rebuild(false);
}

/// The signal said the rows moved. Only a list that exists is refreshed —
/// hearing about diagnostics never opens one.
fn onSignal(id: i32) callconv(.c) void {
    _ = id;
    if (view_ref != null) rebuild(false);
}

/// The row's color, as a `tone` the scene renderer knows.
fn severityTone(sev: []const u8) []const u8 {
    if (std.mem.eql(u8, sev, "error")) return "negative";
    if (std.mem.eql(u8, sev, "warning")) return "warning";
    return "normal";
}

/// Read the source and (re)publish the scene. `force` rebuilds even when the
/// source answered the same rows (an open wants a view either way).
fn rebuild(force: bool) void {
    const text = weft.callString(orDefault("source", "diagnostics-list")) orelse "";
    if (!force and view_ref != null and std.mem.eql(u8, text, last.items)) return;
    last.clearRetainingCapacity();
    last.appendSlice(weft.allocator, text) catch {};

    _ = arena.reset(.retain_capacity);
    const a = arena.allocator();
    rows = .empty;
    var nodes: std.ArrayList(Node) = .empty;
    var next_id: u64 = 2;
    var current_path: []const u8 = "";
    var count: usize = 0;

    var lines = std.mem.splitScalar(u8, last.items, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        const path = f.next() orelse continue;
        const line_no = std.fmt.parseInt(usize, f.next() orelse continue, 10) catch continue;
        const col = std.fmt.parseInt(usize, f.next() orelse continue, 10) catch continue;
        const sev = f.next() orelse continue;
        const msg = f.rest();
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
        rows.append(a, .{ .id = id, .path = a.dupe(u8, path) catch return, .line = line_no, .col = col }) catch return;
        count += 1;
    }
    if (count == 0) {
        nodes.append(a, .{ .id = @enumFromInt(next_id), .role = "muted", .content = .{ .label = "No problems" } }) catch return;
    }
    const root: Node = .{ .id = @enumFromInt(1), .role = "problems", .content = .{ .container = .{ .children = nodes.toOwnedSlice(a) catch return } } };
    revision += 1;
    if (view_ref) |old| {
        if (weft.semanticViewReplace(old, revision, root)) |_| return else |_| view_ref = null;
    }
    view_ref = weft.semanticViewPublish(root, null, revision) catch null;
}

fn onSemanticAction() callconv(.c) void {
    var request = weft.semanticActionCurrent(weft.allocator) catch return;
    defer request.deinit();
    if (!std.mem.eql(u8, request.value.action, activate_action)) {
        _ = weft.semanticActionDecline();
        return;
    }
    for (rows.items) |row| {
        if (row.id != request.value.subject) continue;
        _ = weft.semanticActionHandled();
        jumpTo(row);
        return;
    }
    _ = weft.semanticActionDecline();
}

/// Open the row's file (placement puts it in the primary pane, never in the
/// panel) and put the caret at its line and column.
fn jumpTo(row: Row) void {
    weft.openUnder(weft.placeRoot(), row.path);
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
    .{ .name = "problems", .call = open, .summary = "list the diagnostics of the open documents in the panel" },
    .{ .name = "problems-refresh", .call = refresh, .summary = "re-read the problems list's source now" },
};

comptime {
    weft.plugin(&cmds, .{ .init = init }).exportAll();
    weft.exportCallback("on_semantic_action", &onSemanticAction);
    weft.exportCallback("on_signal", &onSignal);
}
