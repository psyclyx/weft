//! toolbar — the adaptive toolbar (doc/configs.md §3.6.2): a strip of
//! `action` nodes describing what the PRIMARY context offers right now.
//!
//! Nothing here knows a tool. The strip is
//!
//!   pinned entries (`weft.set("toolbar", "pinned", [...])`)  ∪
//!   every offer of the primary context that is not a `std.*` word,
//!
//! arranged by the offers' own presentation (`group`, `order`; the shared
//! `affordances` library), with a separator between groups. So a source file
//! shows the build/test/format actions a config provided for its language, a
//! files listing its "New file" node actions, a git status buffer git's
//! stage and commit — because those are what each context offers, not
//! because this file lists them. The `std.*` words are the grammar's key
//! vocabulary (navigation, line breaks); one shows here only when pinned.
//! A pinned entry names an intention (its availability is the offer's, and
//! an intention offered nowhere shows disabled) or a command (always there),
//! as `name` or `name\tLabel`.
//!
//! The strip lives in its own entry, shown in whatever viewport a config
//! presents it in (`config/toolbar.js` docks one text row at the top, taking
//! no focus). It redraws on `on_offers_changed` — the host's word that the
//! primary context's offers moved — and never otherwise: no polling, and a
//! caret move redraws nothing.
//!
//! A click runs the offer IN the primary context (`invokeIntentionIn`), so
//! Undo undoes the editor it describes; a refusal (Undo with nothing to
//! undo) is echoed with the reason, which is also why a disabled button
//! stays clickable rather than inert.
//!
//! Hover dispatches nothing yet (a moving pointer only updates the facts),
//! so the reason and provider ride on each button as scene facts for the
//! tooltip a hover door would show, rather than as a tooltip.

const std = @import("std");
const weft = @import("weft");
const affordances = @import("weft_affordances");
const Node = weft.semantic.scene.Node;
const NodeId = weft.semantic.scene.NodeId;
const Fact = weft.semantic.scene.Fact;

const entry_name = "*toolbar*";
const press_action = "toolbar.press";
const root_id: u64 = 1;

const Kind = enum { intention, command };

const Button = struct {
    id: u64,
    kind: Kind,
    name: []const u8,
    label: []const u8,
    group: []const u8,
    order: ?i32,
    provider: []const u8,
    /// The stable reason code when it cannot run; empty when it can.
    reason: []const u8,
};

var arena: std.heap.ArenaAllocator = undefined;
var buttons: std.ArrayList(Button) = .empty;
var view_ref: ?weft.semantic.view.Ref = null;
var revision: u32 = 0;

const cmds = [_]weft.CommandEntry{
    .{ .name = "toolbar-open", .call = open, .summary = "present the toolbar's entry (a viewport's presenting command)" },
    .{ .name = "toolbar-press", .call = press, .params = "button", .summary = "run a toolbar button in the primary context" },
};

comptime {
    weft.plugin(&cmds, .{ .init = init }).exportAll();
    weft.exportCallback("on_semantic_action", &onSemanticAction);
    weft.exportCallback("on_offers_changed", &onOffersChanged);
}

fn init() void {
    arena = std.heap.ArenaAllocator.init(weft.allocator);
    _ = weft.semanticActionProvider();
}

/// Make the strip's entry active, drawn: what a viewport presenting it with
/// `{command: "toolbar-open"}` then shows. The host puts the head back where
/// it was afterwards.
fn open() void {
    weft.focusOrCreateBuffer(entry_name);
    weft.toolBacking("toolbar");
    redraw();
    if (view_ref) |ref| _ = weft.semanticViewFocus(ref, null);
}

fn onOffersChanged() callconv(.c) void {
    // Before the strip is presented there is nothing to redraw into.
    if (view_ref == null) return;
    redraw();
}

fn isIntention(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "std.") or std.mem.startsWith(u8, name, "plugin.");
}

fn lastSegment(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    return name[dot + 1 ..];
}

/// One offer, copied out of the SDK's scratch (the next read reuses it).
const Found = struct { offer: weft.Offer, pinned: bool = false };

fn copyOffer(a: std.mem.Allocator, o: weft.Offer) !weft.Offer {
    return .{
        .intention = try a.dupe(u8, o.intention),
        .provider = try a.dupe(u8, o.provider),
        .availability = o.availability,
        .reason = try a.dupe(u8, o.reason),
        .label = try a.dupe(u8, o.label),
        .group = try a.dupe(u8, o.group),
        .order = o.order,
    };
}

fn fromOffer(id: u64, o: weft.Offer) Button {
    return .{
        .id = id,
        .kind = .intention,
        .name = o.intention,
        .label = o.label,
        .group = o.group,
        .order = o.order,
        .provider = o.provider,
        .reason = switch (o.availability) {
            .enabled => "",
            else => if (o.reason.len > 0) o.reason else "unavailable",
        },
    };
}

/// Rebuild the buttons from the primary context as it is now and publish.
fn redraw() void {
    _ = arena.reset(.retain_capacity);
    buttons = .empty;
    collect(arena.allocator()) catch return;
    publish(arena.allocator()) catch return;
}

fn collect(a: std.mem.Allocator) !void {
    var found: std.ArrayList(Found) = .empty;
    var offers = weft.offersIn(.primary);
    while (offers.next()) |o| try found.append(a, .{ .offer = try copyOffer(a, o) });

    var next_id: u64 = root_id + 1;
    // Pinned first, in the config's order; each takes the offer it names.
    if (weft.configList("pinned")) |list| {
        var it = list;
        while (it.next()) |raw| {
            const rec = try a.dupe(u8, raw);
            var parts = std.mem.splitScalar(u8, rec, '\t');
            const name = parts.next() orelse continue;
            if (name.len == 0) continue;
            const label = parts.next() orelse "";
            const id = next_id;
            next_id += 1;
            if (!isIntention(name)) {
                try buttons.append(a, .{ .id = id, .kind = .command, .name = name, .label = if (label.len > 0) label else name, .group = "", .order = null, .provider = "", .reason = "" });
                continue;
            }
            const hit = for (found.items) |*f| {
                if (std.mem.eql(u8, f.offer.intention, name)) break f;
            } else null;
            if (hit) |f| {
                f.pinned = true;
                var b = fromOffer(id, f.offer);
                b.group = "";
                if (label.len > 0) b.label = label;
                try buttons.append(a, b);
            } else {
                // Pinned but offered nowhere here: shown, and says so.
                try buttons.append(a, .{ .id = id, .kind = .intention, .name = name, .label = if (label.len > 0) label else lastSegment(name), .group = "", .order = null, .provider = "", .reason = "not-offered-here" });
            }
        }
    }

    // Then what the context offers beyond the grammar's own words.
    var items: std.ArrayList(affordances.Item) = .empty;
    var rest: std.ArrayList(Button) = .empty;
    for (found.items) |f| {
        if (f.pinned or std.mem.startsWith(u8, f.offer.intention, "std.")) continue;
        if (rest.items.len >= affordances.max_items) break;
        const seq: u32 = @intCast(rest.items.len);
        try rest.append(a, fromOffer(0, f.offer));
        try items.append(a, .{ .group = f.offer.group, .order = f.offer.order, .seq = seq });
    }
    affordances.arrange(items.items);
    for (items.items) |item| {
        var b = rest.items[item.seq];
        b.id = next_id;
        next_id += 1;
        try buttons.append(a, b);
    }
}

fn publish(a: std.mem.Allocator) !void {
    var nodes: std.ArrayList(Node) = .empty;
    var sep_id: u64 = 1 << 32; // separators never collide with a button
    for (buttons.items, 0..) |b, i| {
        if (i > 0 and !std.mem.eql(u8, buttons.items[i - 1].group, b.group)) {
            try nodes.append(a, .{ .id = @enumFromInt(sep_id), .facts = &.{.{ .name = "tone", .value = "muted" }}, .content = .{ .label = "│" } });
            sep_id += 1;
        }
        var facts: std.ArrayList(Fact) = .empty;
        try facts.append(a, .{ .name = "name", .value = b.name });
        if (b.provider.len > 0) try facts.append(a, .{ .name = "provider", .value = b.provider });
        if (b.reason.len > 0) {
            // Greyed by the presenter's `muted` tone; still clickable, so the
            // click can say why.
            try facts.append(a, .{ .name = "reason", .value = b.reason });
            try facts.append(a, .{ .name = "tone", .value = "muted" });
        }
        try nodes.append(a, .{
            .id = @enumFromInt(b.id),
            .role = "toolbar.button",
            .facts = try facts.toOwnedSlice(a),
            .content = .{ .action = .{ .action = press_action, .label = b.label } },
        });
    }
    const root: Node = .{
        .id = @enumFromInt(root_id),
        .role = "toolbar",
        .content = .{ .container = .{ .axis = .horizontal, .children = try nodes.toOwnedSlice(a) } },
    };
    revision += 1;
    if (view_ref) |ref| {
        if (weft.semanticViewReplace(ref, revision, root)) |_| return else |_| view_ref = null;
    }
    view_ref = try weft.semanticViewPublish(root, null, revision);
}

/// A click on a button (`pointer-click` through the strip). Semantic
/// callbacks are not dispatching entries, so the press runs as this plugin's
/// own command — which is.
fn onSemanticAction() callconv(.c) void {
    var request = weft.semanticActionCurrent(weft.allocator) catch return;
    defer request.deinit();
    if (!std.mem.eql(u8, request.value.action, press_action)) {
        _ = weft.semanticActionDecline();
        return;
    }
    _ = weft.semanticActionHandled();
    var buf: [24]u8 = undefined;
    const id = std.fmt.bufPrint(&buf, "{d}", .{@intFromEnum(request.value.subject)}) catch return;
    weft.runStr("toolbar-press", id);
}

fn press() void {
    const raw = weft.argStr(0) orelse return;
    const id = std.fmt.parseInt(u64, raw, 10) catch return;
    const b = for (buttons.items) |b| {
        if (b.id == id) break b;
    } else return;
    switch (b.kind) {
        .command => weft.run(b.name),
        // A refusal already says what refused and why.
        .intention => switch (weft.invokeIntentionIn(.primary, b.name)) {
            .invoked => {},
            .refused => |why| weft.echo(why),
            .unknown => echoWhy(b.label, "not-offered-here"),
        },
    }
}

fn echoWhy(label: []const u8, why: []const u8) void {
    var buf: [256]u8 = undefined;
    weft.echo(std.fmt.bufPrint(&buf, "{s}: {s}", .{ label, why }) catch return);
}
