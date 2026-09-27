//! Configured startup surface. Sections are semantic nodes; candidate sources
//! are ordinary string-result commands, the same lists a picker can consume.
const std = @import("std");
const weft = @import("weft");
const Node = weft.semantic.scene.Node;
const NodeId = weft.semantic.scene.NodeId;

const name = "*dashboard*";
const activate_action = "dashboard.activate";

const Section = struct {
    key: []const u8,
    title: []const u8,
    source: []const u8,
    command: []const u8,
    limit: usize,
};

const Item = struct {
    section: []const u8,
    label: []const u8,
    command: []const u8,
    arg: []const u8,
};

const Activation = struct {
    id: NodeId,
    command: []const u8,
    arg: []const u8,
};

/// The projection kind the dashboard is, and its one designation
/// (doc/model.md §2.1): opening it with no entry showing it re-runs `dashboard`.
const kind = "dashboard";
const designation = "weft://here/dashboard/main";

var arena: std.heap.ArenaAllocator = undefined;
var view_ref: ?weft.semantic.view.Ref = null;
var revision: u32 = 0;
var activations: std.ArrayList(Activation) = .empty;

const commands = [_]weft.CommandEntry{
    .{ .name = "dashboard.open", .arity = .whole, .call = openDashboard, .summary = "open the welcome dashboard" },
    .{ .name = "dashboard.activate", .arity = .one, .call = activate, .summary = "activate the selected dashboard item" },
};

comptime {
    weft.plugin(&commands, .{ .init = init }).exportAll();
    weft.exportCallback("on_semantic_action", &onSemanticAction);
}

fn init() void {
    arena = std.heap.ArenaAllocator.init(weft.allocator);
    _ = weft.semanticActionProvider();
    _ = weft.designationOpener(kind, "dashboard.open");
    weft.restingMode("dashboard");
    // The dashboard only specializes its small local vocabulary below. Keep
    // the ordinary workspace chords available for everything it does not
    // claim (SPC f f, buffer/window commands, the palette, ...).
    weft.setFallback("dashboard", "normal");
    weft.bindKey("dashboard", "j", "cursor.down");
    weft.bindKey("dashboard", "k", "cursor.up");
    weft.bindKey("dashboard", "Down", "cursor.down");
    weft.bindKey("dashboard", "Up", "cursor.up");
    weft.bindKey("dashboard", "Return", "dashboard.activate");
    weft.bindKey("dashboard", "o", "files.find");
    weft.bindKey("dashboard", "n", "buffer.scratch");
    weft.bindKey("dashboard", "q", "buffer.back");
}

fn fields(rec: []const u8, out: [][]const u8) void {
    @memset(out, "");
    var it = std.mem.splitScalar(u8, rec, '\t');
    for (out) |*field| field.* = it.next() orelse return;
}

fn configuredSections(a: std.mem.Allocator) ![]const Section {
    var sections: std.ArrayList(Section) = .empty;
    if (weft.configList("sections")) |list| {
        var it = list;
        while (it.next()) |raw| {
            const rec = try a.dupe(u8, raw);
            var parts: [5][]const u8 = undefined;
            fields(rec, &parts);
            if (parts[0].len == 0 or parts[1].len == 0) continue;
            const limit = std.fmt.parseInt(usize, parts[4], 10) catch 5;
            try sections.append(a, .{ .key = parts[0], .title = parts[1], .source = parts[2], .command = parts[3], .limit = @min(limit, 20) });
        }
    }
    if (sections.items.len == 0) try sections.append(a, .{ .key = "start", .title = "Start", .source = "", .command = "", .limit = 0 });
    return sections.toOwnedSlice(a);
}

fn configuredItems(a: std.mem.Allocator, fallback: bool) ![]const Item {
    var items: std.ArrayList(Item) = .empty;
    if (weft.configList("items")) |list| {
        var it = list;
        while (it.next()) |raw| {
            const rec = try a.dupe(u8, raw);
            var parts: [4][]const u8 = undefined;
            fields(rec, &parts);
            if (parts[0].len == 0 or parts[1].len == 0 or parts[2].len == 0) continue;
            try items.append(a, .{ .section = parts[0], .label = parts[1], .command = parts[2], .arg = parts[3] });
        }
    }
    if (items.items.len == 0 and fallback) {
        try items.append(a, .{ .section = "start", .label = "Open file", .command = "files.find", .arg = "" });
        try items.append(a, .{ .section = "start", .label = "New buffer", .command = "buffer.scratch", .arg = "" });
    }
    return items.toOwnedSlice(a);
}

fn appendAction(a: std.mem.Allocator, nodes: *std.ArrayList(Node), next_id: *u64, label: []const u8, command: []const u8, arg: []const u8) !void {
    const id: NodeId = @enumFromInt(next_id.*);
    next_id.* += 1;
    try nodes.append(a, .{
        .id = id,
        .role = "action",
        .layout = .{ .column = 2 },
        .focusable = true,
        .actions = &.{.{ .id = activate_action, .label = "Open" }},
        .content = .{ .label = try a.dupe(u8, label) },
    });
    try activations.append(a, .{ .id = id, .command = try a.dupe(u8, command), .arg = try a.dupe(u8, arg) });
}

fn openDashboard() void {
    weft.focusOrCreateBuffer(name);
    weft.toolBacking("dashboard");
    // The entry IS the dashboard: re-run by name, never remembered by slot.
    _ = weft.designate(designation);
    weft.setMode("dashboard");

    arena.deinit();
    arena = std.heap.ArenaAllocator.init(weft.allocator);
    const a = arena.allocator();
    activations = .empty;
    const sections = configuredSections(a) catch return;
    const items = configuredItems(a, sections.len == 1 and std.mem.eql(u8, sections[0].key, "start")) catch return;
    var nodes: std.ArrayList(Node) = .empty;
    var next_id: u64 = 2;
    for (sections) |section| {
        const section_start = nodes.items.len;
        const heading: Node = .{ .id = @enumFromInt(next_id), .role = "accent", .layout = .{ .column = 0 }, .content = .{ .label = section.title } };
        next_id += 1;
        nodes.append(a, heading) catch return;
        for (items) |item| {
            if (std.mem.eql(u8, item.section, section.key)) appendAction(a, &nodes, &next_id, item.label, item.command, item.arg) catch return;
        }
        if (section.source.len != 0 and section.command.len != 0) {
            if (weft.callString(section.source)) |candidates| {
                var lines = std.mem.splitScalar(u8, candidates, '\n');
                var shown: usize = 0;
                while (lines.next()) |candidate| {
                    if (shown >= section.limit) break;
                    if (candidate.len == 0) continue;
                    appendAction(a, &nodes, &next_id, candidate, section.command, candidate) catch return;
                    shown += 1;
                }
            }
        }
        if (nodes.items.len == section_start + 1) nodes.items.len = section_start;
    }
    const root: Node = .{ .id = @enumFromInt(1), .role = "dashboard", .content = .{ .container = .{ .children = nodes.toOwnedSlice(a) catch return } } };
    revision += 1;
    if (view_ref) |old| {
        if (weft.semanticViewReplace(old, revision, root)) |_| {
            _ = weft.semanticViewFocus(old, null);
            return;
        } else |_| view_ref = null;
    }
    view_ref = weft.semanticViewPublish(root, null, revision) catch return;
    _ = weft.semanticViewFocus(view_ref.?, null);
}

fn activate() void {
    _ = weft.semanticAction(activate_action);
}

fn onSemanticAction() callconv(.c) void {
    var request = weft.semanticActionCurrent(weft.allocator) catch return;
    defer request.deinit();
    if (!std.mem.eql(u8, request.value.action, activate_action)) {
        _ = weft.semanticActionDecline();
        return;
    }
    for (activations.items) |entry| {
        if (entry.id != request.value.subject) continue;
        _ = weft.semanticActionHandled();
        if (entry.arg.len == 0) weft.run(entry.command) else weft.runStr(entry.command, entry.arg);
        return;
    }
    _ = weft.semanticActionDecline();
}
