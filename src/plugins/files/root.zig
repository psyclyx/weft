//! Sandboxed file-browser plugin.
//!
//! The internal `weft_files_guest` library composes the portable draft model,
//! semantic projection, and public target-scoped filesystem ABI. This root
//! contributes only wasm callbacks plus the user-facing launcher. It owns no
//! text projection, editor mode, keymap, shell command, syscall, or platform
//! policy.
//!
//! It also presents the `places` projection (doc/model.md §2.4):
//! `weft://here/places/all`, the places the workspace is working in — the
//! place of every open entry, every tree a peer shares with us — one row
//! each, a row opening that tree. It answers `view.reveal` for a place's
//! designation (a sidebar revealing `{context: "place"}` in it) and follows
//! the primary context's `place` while it is shown, since a new place is
//! usually a new row.

const std = @import("std");
const weft = @import("weft");
const files_guest = @import("weft_files_adapter");

var plugin: files_guest.Plugin = undefined;

const cmds = [_]weft.CommandEntry{
    .{ .name = "files", .call = browse, .summary = "browse a directory" },
    .{ .name = "files-enter", .call = enterRow, .summary = "open the focused entry" },
    .{ .name = "files-up", .call = stepOut, .summary = "browse the containing directory" },
    .{ .name = "files-apply", .call = applyFocused, .summary = "apply this directory's draft" },
    .{ .name = "files-places", .call = presentPlaces, .params = "designation", .summary = "list the places you are working in (weft://here/places/all)" },
    .{ .name = "files-place-open", .call = openPlace, .params = "row" },
};

comptime {
    weft.plugin(&cmds, .{
        .perms = &.{ .fs_read, .fs_write },
        .init = start,
        .arity = .whole,
    }).exportAll();
}

// ── The places projection ───────────────────────────────────────────

const places_entry = "*places*";
const place_action = "files.place.open";
const place_row_base: u64 = 2;

var places_arena: std.heap.ArenaAllocator = undefined;
var place_rows: std.ArrayList([]const u8) = .empty;
var places_view: ?weft.semantic.view.Ref = null;
var places_revision: u32 = 0;

fn presentPlaces() void {
    weft.focusOrCreateBuffer(places_entry);
    weft.toolBacking("places");
    _ = weft.designate("weft://here/places/all");
    publishPlaces() catch return;
    if (places_view) |v| _ = weft.semanticViewFocus(v, null);
}

/// A place as a row reads: a local tree by its path, a peer's by the peer.
fn placeLabel(a: std.mem.Allocator, text: []const u8) []const u8 {
    const d = weft.semantic.durable.parse(text) orelse return text;
    return switch (d.authority) {
        .here => d.ref,
        .peer => |fp| std.fmt.allocPrint(a, "{s}…:{s}", .{ fp[0..@min(fp.len, 8)], d.ref }) catch text,
        .shell => |host| std.fmt.allocPrint(a, "{s}:{s}", .{ host, d.ref }) catch text,
    };
}

fn publishPlaces() !void {
    _ = places_arena.reset(.retain_capacity);
    const a = places_arena.allocator();
    place_rows = .empty;
    var rows: std.ArrayList(weft.semantic.scene.Node) = .empty;
    var it = weft.places();
    while (it.next()) |text| {
        const owned = try a.dupe(u8, text);
        try rows.append(a, .{
            .id = @enumFromInt(place_row_base + place_rows.items.len),
            .role = "places.row",
            .focusable = true,
            .facts = try a.dupe(weft.semantic.scene.Fact, &.{.{ .name = "designation", .value = owned }}),
            .content = .{ .action = .{ .action = place_action, .label = placeLabel(a, owned) } },
        });
        try place_rows.append(a, owned);
    }
    if (place_rows.items.len == 0)
        try rows.append(a, .{ .id = @enumFromInt(place_row_base), .role = "muted", .content = .{ .label = "No places" } });
    const root: weft.semantic.scene.Node = .{ .id = @enumFromInt(1), .role = "places", .content = .{ .container = .{ .children = try rows.toOwnedSlice(a) } } };
    places_revision += 1;
    if (places_view) |ref| {
        if (weft.semanticViewReplace(ref, places_revision, root)) |_| return else |_| places_view = null;
    }
    places_view = try weft.semanticViewPublish(root, null, places_revision);
}

/// `files-place-open <row>`: that place's tree, where placement puts it.
fn openPlace() void {
    const raw = weft.argStr(0) orelse return;
    const index = std.fmt.parseInt(usize, raw, 10) catch return;
    if (index >= place_rows.items.len) return;
    const text = weft.allocator.dupe(u8, place_rows.items[index]) catch return;
    defer weft.allocator.free(text);
    weft.openDesignation(text);
}

/// The places view's own actions; false when the request is not for it.
fn placesAction() bool {
    const view = places_view orelse return false;
    var request = weft.semanticActionCurrent(weft.allocator) catch return false;
    defer request.deinit();
    if (!request.value.view.eql(view)) return false;
    const action = request.value.action;
    if (std.mem.eql(u8, action, place_action)) {
        const raw = @intFromEnum(request.value.subject);
        if (raw < place_row_base or raw >= place_row_base + place_rows.items.len) {
            _ = weft.semanticActionDecline();
            return true;
        }
        _ = weft.semanticActionHandled();
        var buf: [24]u8 = undefined;
        weft.runStr("files-place-open", std.fmt.bufPrint(&buf, "{d}", .{raw - place_row_base}) catch return true);
        return true;
    }
    if (std.mem.eql(u8, action, weft.semantic.action.standard.reveal)) {
        const want = weft.semantic.durable.parse(request.value.argument) orelse {
            _ = weft.semanticActionDecline();
            return true;
        };
        for (place_rows.items, 0..) |text, i| {
            const have = weft.semantic.durable.parse(text) orelse continue;
            if (!have.designates(want)) continue;
            _ = weft.semanticActionFocus(@enumFromInt(place_row_base + i));
            return true;
        }
    }
    _ = weft.semanticActionDecline();
    return true;
}

fn onContextChanged() callconv(.c) void {
    if (places_view == null) return;
    if (!weft.contextChanged().any(&.{"place"})) return;
    publishPlaces() catch {};
}

fn enterRow() void {
    weft.run("target-open-focused");
}
fn stepOut() void {
    weft.run("hierarchy-step-out");
}
fn applyFocused() void {
    _ = weft.semanticAction(weft.semantic.action.standard.apply);
}

fn start() void {
    places_arena = std.heap.ArenaAllocator.init(weft.allocator);
    _ = weft.designationOpener("places", "files-places");
    files_guest.Plugin.provideRowVerbs();
    plugin = .init(weft.allocator);
    // The launcher remains usable in a command-only host. Target callbacks
    // decline until the generic semantic services become available.
    plugin.start() catch {};
}

fn browse() void {
    // The browser opens WHERE the dispatch is (`doc/place.md`): the project the
    // focused file belongs to, not the directory the editor was launched in.
    // By its designation: the listing then IS that `dir`, and titles itself
    // absolute (doc/model.md §2.1).
    var named: [4096]u8 = undefined;
    const directory = weft.placeDesignation(&named) orelse {
        weft.echo("files: this place has no local directory to browse");
        return;
    };
    weft.openDesignation(directory);
}

fn on_semantic_target_probe(token: u32) callconv(.c) void {
    plugin.targetProbe(token);
}

fn on_semantic_target_open(token: u32) callconv(.c) void {
    plugin.targetOpen(token);
}

fn on_semantic_target_settle(token: u32, authority: u32, slot: u32, generation: u32, outcome: u32) callconv(.c) void {
    if (generation == 0 or outcome > 1) return;
    plugin.targetSettle(token, .{
        .authority = @enumFromInt(authority),
        .slot = slot,
        .generation = generation,
    }, outcome == 0);
}

fn on_semantic_relation_query(token: u32) callconv(.c) void {
    plugin.relationQuery(token);
}

fn on_semantic_action() callconv(.c) void {
    if (placesAction()) return;
    plugin.semanticAction();
}

fn on_semantic_field_edit(token: u32) callconv(.c) void {
    plugin.fieldEdit(token);
}

comptime {
    weft.exportCallback("on_semantic_target_probe", &on_semantic_target_probe);
    weft.exportCallback("on_semantic_target_open", &on_semantic_target_open);
    weft.exportCallback("on_semantic_target_settle", &on_semantic_target_settle);
    weft.exportCallback("on_semantic_relation_query", &on_semantic_relation_query);
    weft.exportCallback("on_semantic_action", &on_semantic_action);
    weft.exportCallback("on_semantic_field_edit", &on_semantic_field_edit);
    weft.exportCallback("on_context_changed", &onContextChanged);
}
