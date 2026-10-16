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
//! designation (a sidebar revealing `{context: "place"}` in it) and, while it
//! is shown, republishes when the `places` key moves: a peer sharing a tree,
//! or an entry opening in a place the list lacks — neither of which need
//! move the primary `place`.

const std = @import("std");
const weft = @import("weft");
const files_guest = @import("weft_files_adapter");
const args = @import("weft_args");

var plugin: files_guest.Plugin = undefined;

const cmds = [_]weft.CommandEntry{
    .{ .name = "files.browse", .arity = .whole, .call = browse, .summary = "Browse a directory as a file tree.", .label = "Browse Files", .icon = "folder-tree" },
    .{ .name = "files.find", .arity = .whole, .call = find, .summary = "Find a file to edit.", .label = "Open File", .menu = "File", .group = "open", .order = 1, .icon = "file-search", .prompts = true },
    .{ .name = "files.places", .arity = .whole, .call = presentPlaces, .params = "designation", .summary = "List the places you are working in (weft://here/places/all).", .internal = true },
    .{ .name = "files.open-place", .arity = .whole, .call = openPlace, .params = "row", .summary = "Open the file tree of the place a row names.", .internal = true },
};

comptime {
    weft.plugin(&cmds, .{
        .perms = &.{ .fs_read, .fs_write },
        // The `places` projection is named for what it shows, not for us.
        .capabilities = &.{"designation/places"},
        .init = start,
        .poll = on_poll,
    }).exportAll();
}

// ── The places projection ───────────────────────────────────────────

const places_entry = "*places*";
const place_action = "files.open-place";
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

/// `files.open-place <row>`: that place's tree, where placement puts it.
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
        weft.runStr("files.open-place", std.fmt.bufPrint(&buf, "{d}", .{raw - place_row_base}) catch return true);
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
    if (!weft.contextChanged().any(&.{"places"})) return;
    publishPlaces() catch {};
}

// ── Open File ───────────────────────────────────────────────────────

/// The walk feeding the open finder, stopped when it is answered.
var finding: ?weft.Walk = null;

/// The one "open a file by name" picker every grammar and config binds: vim's
/// `SPC f f`, helix's `SPC f`, ide's C-p and the dashboard's "Open file".
/// The ordinary picker, fed the files of the place this dispatch runs in as
/// the walk finds them; the picker narrows them as you type. A typed name
/// that is not in the list opens too (a new file).
fn find() void {
    const spec: weft.SearchSpec = .{ .prompt = "open", .category = "file", .free_text = true, .per_query = false, .matched = false };
    if (!weft.search(spec, listFiles, openChosen)) weft.echo("files: could not open the finder");
}

fn listFiles(_: []const u8, feed: weft.Feed) void {
    stopFinding();
    // The place this dispatch runs in, named by core: its rows are relative to
    // it, which is what `open` resolves a typed name against.
    finding = weft.walkWith(weft.Feed, feed, .{}, Listing);
    if (finding == null) {
        weft.echo("files: this place has no local directory to list");
        feed.done();
    }
}

const Listing = struct {
    pub fn path(feed: weft.Feed, rel: []const u8) void {
        if (feed.push(rel, "")) return;
        // Refused: the pick is gone, or holds all the rows it can.
        feed.done();
        stopFinding();
    }
    pub fn end(feed: weft.Feed, cut: bool) void {
        finding = null;
        feed.done();
        if (cut) weft.echo("files: the list stops at 200000 files");
    }
};

fn stopFinding() void {
    if (finding) |w| w.stop();
    finding = null;
}

// ── arg/file ────────────────────────────────────────────────────────

/// An argument that takes a file is offered the files of the place it is
/// asked in: the same walk Open File lists, answered in parts as it finds
/// them. Paths are relative to the place, which is what a command handed a
/// typed name reads it against.
fn on_slot_fire(session: i32) callconv(.c) void {
    _ = args.question(@bitCast(session)) orelse return;
    const id: u32 = @bitCast(session);
    const w = weft.walkWith(u32, id, .{}, Offering) orelse {
        args.answer(id, &.{});
        return;
    };
    Offering.live.append(weft.allocator, .{ .session = id, .walk = w }) catch w.stop();
}

const Offering = struct {
    /// The walks answering an asker that is still asking.
    var live: std.ArrayList(struct { session: u32, walk: weft.Walk }) = .empty;
    /// The part found since the last answer: each path's end in `bytes`.
    var ends: std.ArrayList(usize) = .empty;
    var bytes: std.ArrayList(u8) = .empty;

    pub fn path(_: u32, rel: []const u8) void {
        bytes.appendSlice(weft.allocator, rel) catch return;
        ends.append(weft.allocator, bytes.items.len) catch return;
    }
    pub fn drained(session: u32) void {
        // The asker finished its question (chose, typed, or backed out):
        // nothing more is wanted, so the walk stops here.
        if (weft.slotName(session) == null) return forget(session, true);
        flush(session);
    }
    pub fn end(session: u32, _: bool) void {
        flush(session);
        forget(session, false);
    }

    fn flush(session: u32) void {
        defer {
            ends.clearRetainingCapacity();
            bytes.clearRetainingCapacity();
        }
        if (ends.items.len == 0) return;
        const rows = weft.allocator.alloc(args.Row, ends.items.len) catch return;
        defer weft.allocator.free(rows);
        var from: usize = 0;
        for (ends.items, rows) |stop, *r| {
            r.* = .{ .text = bytes.items[from..stop] };
            from = stop;
        }
        args.answer(session, rows);
    }

    fn forget(session: u32, stop: bool) void {
        ends.clearRetainingCapacity();
        bytes.clearRetainingCapacity();
        for (live.items, 0..) |o, i| if (o.session == session) {
            _ = live.swapRemove(i);
            if (stop) o.walk.stop();
            return;
        };
    }
};

fn openChosen(answer: weft.Answer) void {
    stopFinding();
    const trimmed = std.mem.trim(u8, answer.text(), " \t");
    if (trimmed.len > 0) weft.openTyped(trimmed);
}

fn start() void {
    places_arena = std.heap.ArenaAllocator.init(weft.allocator);
    args.offer("file");
    _ = weft.designationOpener("places", "files.places");
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

fn on_signal(id: i32) callconv(.c) void {
    if (id >= 0) plugin.signal(@intCast(id));
}

/// A directory a listing shows changed on disk (`wl_semantic_fs_watch`).
fn on_poll() void {
    plugin.poll();
}

comptime {
    weft.exportCallback("on_semantic_target_probe", &on_semantic_target_probe);
    weft.exportCallback("on_semantic_target_open", &on_semantic_target_open);
    weft.exportCallback("on_semantic_target_settle", &on_semantic_target_settle);
    weft.exportCallback("on_semantic_relation_query", &on_semantic_relation_query);
    weft.exportCallback("on_semantic_action", &on_semantic_action);
    weft.exportCallback("on_semantic_field_edit", &on_semantic_field_edit);
    weft.exportCallback("on_signal", &on_signal);
    weft.exportCallback("on_context_changed", &onContextChanged);
    weft.exportCallback("on_slot_fire", &on_slot_fire);
}
