//! Window-layout commands. Core commands only RECORD intent on a
//! `WindowCtx`; the frame loop applies them (split/close/focus/move by
//! pane geometry) and keeps the focused pane == the active buffer.

const std = @import("std");
const core = @import("weft_core");
const view_mod = @import("weft_gfx").view;
const region = @import("weft_gfx").region;
const window_layout = @import("weft_gfx").window_layout;
const semantic_model = @import("weft_semantic");
const ok_echo = @import("handler.zig").ok_echo;

/// Window-layout intents; applied in the frame loop (which owns the pane
/// tree + scroll/build state). Commands only record intent — the loop
/// mutates the layout and keeps the focused pane == the active buffer.
pub const WindowCtx = struct {
    split: ?region.Axis = null, // request a split of the focused pane
    close: bool = false,
    focus_dir: ?window_layout.Dir = null,
    move_dir: ?window_layout.Dir = null,
    focus_next: bool = false, // cycle focus (`window.focus-next`)
};

/// Which window operation a bound command requests (mapped to a WindowCtx
/// field in windowActionHandler). vim `:split` is a horizontal divider
/// (stacked rows); `:vsplit` a vertical one (side-by-side columns).
pub const WindowAction = enum {
    split,
    vsplit,
    close,
    focus_next,
    focus_left,
    focus_right,
    focus_up,
    focus_down,
    move_left,
    move_right,
    move_up,
    move_down,
};

/// A command → intent binding: which WindowCtx to poke and how. Held in a
/// stable array so `command.bind`'s data pointer stays valid for the run.
pub const WindowActionCtx = struct { win: *WindowCtx, action: WindowAction };

/// The window-layout command surface: each entry binds a name to a
/// `WindowAction`. One name per operation: the `windows` plugin that
/// re-registered these under its own names is gone, and so is every alias.
pub const cmd_table = [_]struct { name: []const u8, action: WindowAction, summary: []const u8, meta: core.command.Presentation }{
    .{ .name = "window.split-below", .action = .split, .summary = "Split the focused window, opening a pane below.", .meta = .{ .label = "Split Editor Down", .menu = "View/Editor Layout", .group = "split", .order = 20, .icon = "split-down" } },
    .{ .name = "window.split-right", .action = .vsplit, .summary = "Split the focused window, opening a pane to the right.", .meta = .{ .label = "Split Editor Right", .menu = "View/Editor Layout", .group = "split", .order = 10, .icon = "split-right" } },
    .{ .name = "window.close", .action = .close, .summary = "Close the focused window, collapsing its split.", .meta = .{ .label = "Close Window", .menu = "View/Editor Layout", .group = "split", .order = 30, .icon = "close" } },
    .{ .name = "window.focus-left", .action = .focus_left, .summary = "Focus the window to the left.", .meta = .{ .label = "Focus Left Window", .menu = "View/Editor Layout", .group = "focus", .order = 10 } },
    .{ .name = "window.focus-right", .action = .focus_right, .summary = "Focus the window to the right.", .meta = .{ .label = "Focus Right Window", .menu = "View/Editor Layout", .group = "focus", .order = 20 } },
    .{ .name = "window.focus-up", .action = .focus_up, .summary = "Focus the window above.", .meta = .{ .label = "Focus Window Above", .menu = "View/Editor Layout", .group = "focus", .order = 30 } },
    .{ .name = "window.focus-down", .action = .focus_down, .summary = "Focus the window below.", .meta = .{ .label = "Focus Window Below", .menu = "View/Editor Layout", .group = "focus", .order = 40 } },
    .{ .name = "window.move-left", .action = .move_left, .summary = "Swap the focused window with its left neighbour.", .meta = .{ .label = "Move Window Left", .menu = "View/Editor Layout", .group = "move", .order = 10 } },
    .{ .name = "window.move-right", .action = .move_right, .summary = "Swap the focused window with its right neighbour.", .meta = .{ .label = "Move Window Right", .menu = "View/Editor Layout", .group = "move", .order = 20 } },
    .{ .name = "window.move-up", .action = .move_up, .summary = "Swap the focused window with the one above.", .meta = .{ .label = "Move Window Up", .menu = "View/Editor Layout", .group = "move", .order = 30 } },
    .{ .name = "window.move-down", .action = .move_down, .summary = "Swap the focused window with the one below.", .meta = .{ .label = "Move Window Down", .menu = "View/Editor Layout", .group = "move", .order = 40 } },
    .{ .name = "window.focus-next", .action = .focus_next, .summary = "Focus the next window.", .meta = .{ .label = "Focus Next Window", .menu = "View/Editor Layout", .group = "focus", .order = 50 } },
};

/// Count of window commands; `main()` sizes the stable `WindowActionCtx`
/// backing array from this so each command's `data` pointer stays valid.
pub const cmd_count = cmd_table.len;

/// Bind every window-layout command onto `commands`, each pointing at a slot
/// in the caller-owned `action_ctx` array (stable storage for the run). The
/// `win_ctx` the commands record intents on is likewise caller-owned.
pub fn registerCommands(
    gpa: std.mem.Allocator,
    commands: *core.command.Commands,
    win_ctx: *WindowCtx,
    action_ctx: *[cmd_count]WindowActionCtx,
) !void {
    inline for (cmd_table, 0..) |wc, i| {
        action_ctx[i] = .{ .win = win_ctx, .action = wc.action };
        _ = try commands.bind(gpa, wc.name, .{
            .name = wc.name,
            .summary = wc.summary,
            .args = &.{},
            .handler = windowActionHandler,
            .data = &action_ctx[i],
            .meta = wc.meta,
        });
    }
}

pub fn windowActionHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    _ = args;
    const a: *WindowActionCtx = @ptrCast(@alignCast(data.?));
    switch (a.action) {
        .split => a.win.split = .horizontal, // stacked rows (vim :split)
        .vsplit => a.win.split = .vertical, // side-by-side columns (vim :vsplit)
        .close => a.win.close = true,
        .focus_next => a.win.focus_next = true,
        .focus_left => a.win.focus_dir = .left,
        .focus_right => a.win.focus_dir = .right,
        .focus_up => a.win.focus_dir = .up,
        .focus_down => a.win.focus_dir = .down,
        .move_left => a.win.move_dir = .left,
        .move_right => a.win.move_dir = .right,
        .move_up => a.win.move_dir = .up,
        .move_down => a.win.move_dir = .down,
    }
    return ok_echo(ctx, "window");
}

/// Apply the window-layout intents recorded by commands (run in the frame
/// loop, outside the input hot section). Each op saves the focused pane's
/// scroll first, then mutates the tree; a focus/content change makes the
/// active buffer follow the focused pane (applyWindowFocus). Geometry uses
/// last render's frame. Returns whether the view was damaged. Always
/// reconciles the focused pane with the active buffer and prunes leaves
/// whose buffer died.
///
/// This is also where the workspace enforces the two viewport attributes the
/// pane tree cannot (`core/viewport.zig`): `persistent` decides which way the
/// focused-pane/active-entry mirror runs, and `focus_source` decides whether
/// a focus change moves the head's primary focus — the one input the primary
/// context (`core/context.zig`) reads focus from.
pub fn applyIntents(
    win_ctx: *WindowCtx,
    win_layout: *window_layout.Layout,
    view: *view_mod.View,
    buffers: *core.Buffers,
    gpa: std.mem.Allocator,
    head: *core.Head,
    keymap: *const core.Keymap,
    last_frame_rect: region.Rect,
    policy: *const core.placement.Policy,
) bool {
    var dirty = false;
    if (win_ctx.split) |axis| {
        win_ctx.split = null;
        const focused = window_layout.headFocus(win_layout, head);
        focused.pane().top_row = view.top_row; // carried into the surviving half
        const nf = win_layout.splitFocused(focused, axis) catch focused;
        window_layout.setHeadFocus(head, nf, win_layout);
        dirty = true;
    }
    if (win_ctx.close) {
        win_ctx.close = false;
        if (win_layout.count() > 1) {
            const focused = window_layout.headFocus(win_layout, head);
            const nf = win_layout.closeFocused(focused) catch focused;
            window_layout.setHeadFocus(head, nf, win_layout);
            applyWindowFocus(win_layout, view, buffers, gpa, head, keymap);
            dirty = true;
        }
    }
    if (win_ctx.focus_dir) |dir| {
        win_ctx.focus_dir = null;
        const focused = window_layout.headFocus(win_layout, head);
        focused.pane().top_row = view.top_row;
        if (win_layout.focusNeighbor(focused, last_frame_rect, dir)) |nb| {
            window_layout.setHeadFocus(head, nb, win_layout);
            applyWindowFocus(win_layout, view, buffers, gpa, head, keymap);
            dirty = true;
        }
    }
    if (win_ctx.move_dir) |dir| {
        win_ctx.move_dir = null;
        const focused = window_layout.headFocus(win_layout, head);
        focused.pane().top_row = view.top_row;
        // Swap contents with the neighbor; focus stays put but now shows
        // the neighbor's buffer, so the active buffer follows it.
        if (win_layout.swapNeighbor(focused, last_frame_rect, dir)) {
            applyWindowFocus(win_layout, view, buffers, gpa, head, keymap);
            dirty = true;
        }
    }
    if (win_ctx.focus_next) {
        win_ctx.focus_next = false;
        const focused = window_layout.headFocus(win_layout, head);
        focused.pane().top_row = view.top_row;
        if (win_layout.focusNext(focused)) |nx| {
            window_layout.setHeadFocus(head, nx, win_layout);
            applyWindowFocus(win_layout, view, buffers, gpa, head, keymap);
            dirty = true;
        }
    }
    if (applyPlacement(win_layout, buffers, gpa, head, keymap, policy)) dirty = true;
    // Reconcile the focused pane with the active buffer. WHICH WAY depends on
    // the viewport: an ordinary pane follows the active entry (buffer
    // switches via open/tabs/etc. land here), but a `persistent` one OWNS its
    // entry — an open that landed elsewhere must not drag the sidebar off its
    // root, so there the active entry follows the pane instead. Same
    // invariant ("the focused pane shows the active buffer"), stated once,
    // with the direction read off an attribute rather than guessed.
    {
        const fp = window_layout.headFocus(win_layout, head).pane();
        if (!fp.attrs.persistent)
            fp.buffer_id = buffers.active_id
        else if (buffers.active_id != fp.buffer_id)
            // Only when they actually disagree: `applyWindowFocus` also
            // restores the pane's saved scroll, which would fight the live
            // `view.top_row` if it ran on every quiet frame.
            applyWindowFocus(win_layout, view, buffers, gpa, head, keymap);
    }
    {
        // A pane whose buffer was closed falls back to the active one so no
        // leaf dangles.
        const PruneCtx = struct { active: core.Buffers.Id, bufs: *core.Buffers };
        win_layout.eachPane(PruneCtx{ .active = buffers.active_id, .bufs = buffers }, struct {
            fn visit(c: PruneCtx, p: *window_layout.Pane) void {
                if (c.bufs.get(p.buffer_id) == null) p.buffer_id = c.active;
            }
        }.visit);
    }
    recordPrimaryFocus(win_layout, head);
    return dirty;
}

/// Consume `head`'s pending open placement (§9.4): ask the policy where the
/// entry the open just made active belongs, and move it there.
///
/// The only case that does any work is a decision naming a pane OTHER than
/// the acting one — which is exactly the sidebar case, and exactly the jank
/// this kills ("the grep result opened inside my sidebar"). Everything else
/// is already where it should be, because `open` made it active and the
/// mirror above puts an active entry in the focused pane.
fn applyPlacement(
    win_layout: *window_layout.Layout,
    buffers: *core.Buffers,
    gpa: std.mem.Allocator,
    head: *core.Head,
    keymap: *const core.Keymap,
    policy: *const core.placement.Policy,
) bool {
    const request = head.placement orelse return false;
    head.placement = null;
    const focused = window_layout.headFocus(win_layout, head);
    const opened = buffers.active_id;
    const decision = policy.resolve(.{
        .hint = request.hint,
        .kind = request.kind,
        .source = focused.pane().attrs,
    });
    if (decision == .source) return false;
    if (decision == .none) {
        // Opened, but given no viewport: put the acting pane's own entry back
        // in front so the mirror below does not show it anyway. Putting it
        // back is not navigation: no jump.
        core.Buffers.quietly(head, core.Buffers.switchTo, .{ buffers, gpa, focused.pane().buffer_id, head, keymap }) catch {};
        return true;
    }
    const primary = win_layout.primaryPane() orelse return false;
    const target = if (decision == .split_primary)
        win_layout.splitFocused(primary, .vertical) catch primary
    else
        primary;
    if (target == focused) return false;
    target.pane().buffer_id = opened;
    target.pane().top_row = 0;
    // Focus does not move: activating from a companion leaves you in the
    // companion — that is its focus discipline. The active entry therefore
    // goes back to what the focused pane shows, which the persistent arm of
    // the mirror above does, the same way every focus move already does.
    return true;
}

/// Realize the viewports the manifest declares (`weft.viewport` /
/// `weft.present`, doc/configuration.md §5.2) into the live pane tree.
///
/// Run in the layout phase because that is where the tree is owned; driven
/// off the registry rather than off config apply because config evaluation is
/// sealed and must not touch a workspace. Each declaration is materialized
/// once — the registry remembers the pane — so this is a cheap scan on every
/// later frame, and a config reload re-presenting a new subject picks it up
/// without re-docking anything. A subject bound to a context key is presented
/// again when the frame boundary reports that key moved
/// (`Registry.follow`), which runs this again; a reveal likewise.
///
/// Only docked viewports are realized today: a tiled declaration has no
/// stated position to place it at, which is the `ui/layout` slot's business,
/// not this function's.
pub fn materializeViewports(
    ctx: *core.command.Context,
    win_layout: *window_layout.Layout,
    buffers: *core.Buffers,
    gpa: std.mem.Allocator,
    head: *core.Head,
    keymap: *const core.Keymap,
    registry: *core.viewport.Registry,
    view: *view_mod.View,
) bool {
    var dirty = false;
    for (registry.list.items, 0..) |*decl, at| {
        const edge = decl.attrs.dock orelse continue;
        if (!decl.shown) {
            // Hidden: undock it through the ordinary close, which already
            // knows how a dock collapses and where a head parked in it
            // recovers to. Its entry stays open, so showing it again
            // re-presents the same listing rather than a fresh one.
            if (decl.pane) |id| if (win_layout.paneById(id)) |node| {
                _ = win_layout.closeFocused(node) catch continue;
                dirty = true;
            };
            decl.pane = null;
            decl.presented = false;
            continue;
        }
        // A pending take, only while its entry is still open.
        const take: ?core.Buffers.Id = if (decl.take) |held| (if (core.designation.findText(buffers, held)) |b| b.id else null) else null;
        core.viewport.Registry.hold(gpa, &decl.take, null) catch {};
        // Docking again after a hide: show what it showed last. That is a
        // designation, so it is whichever entry opens it now — or, when that
        // entry has closed since, the designation opened again below; never
        // the stranger that took the closed entry's slot.
        var kept: ?core.Buffers.Id = null;
        var docked = false;
        if (decl.pane == null or win_layout.paneById(decl.pane.?) == null) {
            kept = if (decl.entry) |held| (if (core.designation.findText(buffers, held)) |b| b.id else null) else null;
            // Dock showing what it showed last (or is being handed), never a
            // second view of the active document when there is one.
            const first = take orelse kept orelse buffers.active_id;
            // Inside every viewport declared after this one: the one declared
            // last stays outermost (a window-wide bar), however late this one
            // is shown.
            var outer: [window_layout.max_panes]window_layout.PaneId = undefined;
            var nouter: usize = 0;
            for (registry.list.items[at + 1 ..]) |later| if (later.pane) |id| if (nouter < outer.len) {
                outer[nouter] = id;
                nouter += 1;
            };
            const panel = win_layout.dockWithin(edge, decl.extent, first, decl.attrs, outer[0..nouter]) catch continue;
            decl.pane = panel.leaf.id;
            // Something to show already: an entry kept across a hide stays
            // what it was, rather than being re-presented over.
            decl.presented = kept != null and take == null;
            docked = true;
            dirty = true;
        }
        const node = win_layout.paneById(decl.pane.?) orelse continue;
        if (take) |id| {
            takeInto(win_layout, view, buffers, gpa, head, keymap, node, id);
            hold(gpa, buffers, decl, id);
            decl.presented = true; // what was taken replaces what was declared
            dirty = true;
            continue;
        }
        if (docked and kept == null) if (decl.entry) |held| {
            const again = gpa.dupe(u8, held) catch continue;
            defer gpa.free(again);
            if (core.Buffers.quietly(head, reopenInto, .{ ctx, buffers, gpa, head, keymap, node, again })) {
                decl.presented = true;
                continue;
            }
            // Gone for good (a process that exited): forget it, and present
            // what the viewport declares instead.
            core.viewport.Registry.hold(gpa, &decl.entry, null) catch {};
            decl.presented = false;
        };
        // Shown again after a hide: a subject bound to a key that moved
        // while the viewport was away presents afresh; one that did not keeps
        // what it showed.
        if (docked and decl.presented and decl.subject.key) {
            var probe: [core.designation.max_len + 64]u8 = undefined;
            const now = subjectNow(ctx, decl, &probe) orelse "";
            if (decl.resolved) |was| if (!std.mem.eql(u8, was, now)) {
                decl.presented = false;
            };
        }
        if (!decl.presented and decl.hasPresentation()) {
            decl.presented = true;
            if (presentDeclared(ctx, win_layout, buffers, gpa, head, keymap, registry, decl, node)) dirty = true;
        }
        // A new reveal replaces one still waiting; a waiting one is asked
        // again once its view has republished (the provider read what it
        // needed off the frame path), never before.
        if (decl.reveal_due or revealAnswerDue(ctx, decl)) {
            decl.reveal_due = false;
            decl.reveal_waits = null;
            if (revealIn(ctx, buffers, head, decl, node)) dirty = true;
        }
        // What it holds follows what it shows: navigating inside a listing
        // moves the listing's designation, and that is what showing it again
        // must bring back.
        hold(gpa, buffers, decl, node.pane().buffer_id);
    }
    return dirty;
}

/// Room for a subject's designation with its projection parameter added.
const subject_cap = core.designation.max_len + 64;

/// What `decl`'s subject names right now, `as` included, into `out`: the
/// literal designation, or the current value of its key in the PRIMARY
/// context (`intent.primaryScopeOf` — the one context everything that
/// follows the editor reads). Null when the key has no value there, or the
/// value cannot carry the projection asked for.
fn subjectNow(ctx: *core.command.Context, decl: *const core.viewport.Declaration, out: []u8) ?[]const u8 {
    const value: []const u8 = if (!decl.subject.key) decl.subject.text else blk: {
        const scope = core.intent.primaryScopeOf(ctx) orelse return null;
        break :blk core.intent.factsIn(scope).get(decl.subject.text) orelse return null;
    };
    return withProjection(out, value, decl.as);
}

/// `value` with the projection `as` added as its `as` view parameter
/// (`designation.as_param`), which is where `open`'s routing reads it. A
/// bare path has no kind to project, so it carries no `as`.
fn withProjection(out: []u8, value: []const u8, as: []const u8) ?[]const u8 {
    if (as.len == 0) return std.fmt.bufPrint(out, "{s}", .{value}) catch null;
    const d = core.designation.durable.parse(value) orelse return null;
    if (d.param(core.designation.as_param) != null) return null;
    return std.fmt.bufPrint(out, "{s}{s}{s}={s}", .{ value, if (d.params.len == 0) "?" else "&", core.designation.as_param, as }) catch null;
}

/// Present what `decl` declares into `node`. A keyed subject whose key reads
/// the same as when it was last presented keeps what the pane shows — the
/// key changing is what re-presents, not the frame boundary having asked —
/// so a persistent viewport keeps whatever the user navigated to inside it.
/// A key with no value presents the explicit empty state, never the stale
/// subject. The entry the previous presentation MADE (it did not exist
/// before) is closed when nothing shows it any more, so following a key
/// does not leave a trail of listings behind as tabs — by the ordinary,
/// refusing close: an entry holding unsaved work (a draft rename in a
/// listing) is never discarded by following, and stays as a tab, no longer
/// the viewport's. True when the pane changed.
fn presentDeclared(
    ctx: *core.command.Context,
    win_layout: *window_layout.Layout,
    buffers: *core.Buffers,
    gpa: std.mem.Allocator,
    head: *core.Head,
    keymap: *const core.Keymap,
    registry: *core.viewport.Registry,
    decl: *core.viewport.Declaration,
    node: *window_layout.Node,
) bool {
    var buf: [subject_cap]u8 = undefined;
    const target = subjectNow(ctx, decl, &buf);
    const now = target orelse "";
    if (decl.subject.key) if (decl.resolved) |was| {
        if (std.mem.eql(u8, was, now) and buffers.get(node.pane().buffer_id) != null) return false;
    };
    core.viewport.Registry.hold(gpa, &decl.resolved, now) catch {};
    decl.reveal_due = decl.reveal.isSet();
    const before = if (buffers.get(node.pane().buffer_id)) |b| b.ref() else null;
    const born = buffers.next_generation;
    if (target) |t| {
        const owned = gpa.dupe(u8, t) catch return false;
        defer gpa.free(owned);
        presentBy(ctx, win_layout, buffers, gpa, head, keymap, decl.pane.?, "file.open", owned);
    } else presentEmpty(ctx, buffers, gpa, registry, decl, node);
    const shown = buffers.get(node.pane().buffer_id);
    // What the previous presentation made, and nothing shows any more.
    if (decl.made) |made| if (buffers.resolve(made)) |old| {
        // Through the shell's own close, borrowed for the one call, so the
        // entry's providers go with it.
        if (shown != old and old.id != buffers.active_id and !paneShows(win_layout, old.id))
            _ = buffers.withEntry(gpa, old.id, head, keymap, closeEntry, .{ctx}) catch {};
    };
    // The empty state is the viewport's own: it goes once something real is
    // shown, rather than lingering as a tab.
    const own = if (decl.empty) |e| if (shown) |b| b.generation == e.entry_generation else false else false;
    if (!own) retireEmpty(ctx, win_layout, buffers, gpa, head, keymap, registry, decl);
    decl.made = if (shown) |b| (if (b.generation >= born and !own) b.ref() else null) else null;
    const after = if (shown) |b| b.ref() else null;
    return !std.meta.eql(before, after);
}

/// Close `decl`'s empty-state entry and its view, if it has one nothing else
/// shows.
fn retireEmpty(
    ctx: *core.command.Context,
    win_layout: *window_layout.Layout,
    buffers: *core.Buffers,
    gpa: std.mem.Allocator,
    head: *core.Head,
    keymap: *const core.Keymap,
    registry: *core.viewport.Registry,
    decl: *core.viewport.Declaration,
) void {
    const empty = decl.empty orelse return;
    var it = buffers.iterator();
    const entry = while (it.next()) |b| {
        if (b.generation == empty.entry_generation) break b;
    } else null;
    if (entry) |b| {
        if (b.id == buffers.active_id or paneShows(win_layout, b.id)) return;
        _ = buffers.withEntry(gpa, b.id, head, keymap, closeEntry, .{ctx}) catch {};
    }
    if (ctx.semantic) |services| if (registry.owner) |owner| {
        _ = services.closeView(gpa, owner, empty.view);
    };
    decl.empty = null;
}

/// The shell's refusing close: a viewport retiring what it made never
/// discards work the user did in it (`buffer.close-unmodified` refuses a dirty file or
/// an unapplied draft, and the entry stays).
fn closeEntry(ctx: *core.command.Context) void {
    _ = core.command.run(ctx.commands, ctx, "buffer.close-unmodified", &.{}) catch {};
}

fn paneShows(win_layout: *window_layout.Layout, id: core.Buffers.Id) bool {
    const Probe = struct { id: core.Buffers.Id, found: bool = false };
    var probe: Probe = .{ .id = id };
    win_layout.eachPane(&probe, struct {
        fn visit(p: *Probe, pane: *window_layout.Pane) void {
            if (pane.buffer_id == p.id) p.found = true;
        }
    }.visit);
    return probe.found;
}

/// The explicit empty state: `decl`'s subject key has no value in the
/// primary context, so the viewport says so rather than showing whatever it
/// showed before. One entry per viewport, made on first need and reused: a
/// view (core's own) with one line naming the key.
fn presentEmpty(
    ctx: *core.command.Context,
    buffers: *core.Buffers,
    gpa: std.mem.Allocator,
    registry: *core.viewport.Registry,
    decl: *core.viewport.Declaration,
    node: *window_layout.Node,
) void {
    const services = ctx.semantic orelse return;
    if (decl.empty) |empty| {
        var it = buffers.iterator();
        while (it.next()) |b| if (b.generation == empty.entry_generation) {
            node.pane().buffer_id = b.id;
            node.pane().top_row = 0;
            return;
        };
        _ = services.closeView(gpa, registry.owner orelse return, empty.view);
        decl.empty = null;
    }
    const owner = registry.owner orelse (services.acquireOwner() catch return);
    registry.owner = owner;
    var line: [256]u8 = undefined;
    const label = std.fmt.bufPrint(&line, "Nothing to show: no {s} here", .{decl.subject.text}) catch "Nothing to show";
    const children = [_]semantic_model.scene.Node{.{ .id = @enumFromInt(2), .role = "muted", .content = .{ .label = label } }};
    const root: semantic_model.scene.Node = .{ .id = @enumFromInt(1), .role = "viewport.empty", .content = .{ .container = .{ .children = &children } } };
    const view_ref = services.publishView(gpa, owner, null, 1, root) catch return;
    const id = buffers.createView(gpa, decl.name, "viewport.empty") catch {
        _ = services.closeView(gpa, owner, view_ref);
        return;
    };
    const entry = buffers.get(id).?;
    entry.tool_view = view_ref;
    const instance = services.views.get(view_ref) orelse return;
    var storage: [4]semantic_model.scene.NodeId = undefined;
    if (instance.focusPath(root.id, &storage) catch null) |path| entry.scene_selection.set(gpa, path) catch {};
    decl.empty = .{ .entry_generation = entry.generation, .view = view_ref };
    node.pane().buffer_id = id;
    node.pane().top_row = 0;
}

/// Highlight `decl`'s reveal inside what `node` shows, without taking focus
/// (`Services.reveal`): the provider expands to it and names the node, and
/// that node becomes the VIEW's revealed highlight. Neither the head's nor
/// the entry's selection is handed over, so neither can move. A provider
/// that must read first answers later: the reveal then waits on the view's
/// next revision (`reveal_waits`). True when the highlight changed.
fn revealIn(
    ctx: *core.command.Context,
    buffers: *core.Buffers,
    head: *const core.Head,
    decl: *core.viewport.Declaration,
    node: *window_layout.Node,
) bool {
    const services = ctx.semantic orelse return false;
    const entry = buffers.get(node.pane().buffer_id) orelse return false;
    var buf: [subject_cap]u8 = undefined;
    const wanted: []const u8 = if (!decl.reveal.key) decl.reveal.text else blk: {
        const scope = core.intent.primaryScopeOf(ctx) orelse return false;
        const value = core.intent.factsIn(scope).get(decl.reveal.text) orelse return false;
        break :blk std.fmt.bufPrint(&buf, "{s}", .{value}) catch return false;
    };
    const shown = if (entry.id == buffers.active_id) head.scene_selection.view else entry.scene_selection.view;
    const view_ref = shown orelse entry.tool_view orelse return false;
    switch (services.reveal(view_ref, wanted)) {
        .revealed, .declined => {},
        .pending => decl.reveal_waits = .{
            .view = view_ref,
            .revision = (services.views.get(view_ref) orelse return true).descriptor.revision,
        },
    }
    return true;
}

/// Whether `decl`'s waiting reveal can be answered now: its view published
/// a revision past the one the provider accepted it at. A view that closed
/// meanwhile ends the wait unasked.
fn revealAnswerDue(ctx: *core.command.Context, decl: *core.viewport.Declaration) bool {
    const wait = decl.reveal_waits orelse return false;
    const services = ctx.semantic orelse return false;
    const instance = services.views.get(wait.view) orelse {
        decl.reveal_waits = null;
        return false;
    };
    return instance.descriptor.revision != wait.revision;
}

/// Open `designation` again and show it in `node` — a viewport's closed
/// entry coming back. Unlike `presentBy`, the pane changes only when the
/// designation really opened: a process that has exited is refused, and the
/// pane must not be handed whatever happened to be active instead. The head
/// goes back where it was either way.
fn reopenInto(
    ctx: *core.command.Context,
    buffers: *core.Buffers,
    gpa: std.mem.Allocator,
    head: *core.Head,
    keymap: *const core.Keymap,
    node: anytype,
    designation: []const u8,
) bool {
    const restore = buffers.active_id;
    const prev = buffers.prev_id;
    defer if (buffers.active_id != restore and buffers.get(restore) != null) {
        buffers.switchTo(gpa, restore, head, keymap) catch {};
        buffers.prev_id = prev;
    };
    _ = core.command.run(ctx.commands, ctx, "file.open", &.{.{ .string = designation }}) catch return false;
    const opened = core.designation.findText(buffers, designation) orelse return false;
    node.pane().buffer_id = opened.id;
    node.pane().top_row = 0;
    return true;
}

/// What a viewport remembers of the entry it shows: that entry's
/// designation, so a slot reused after the entry closes is never taken for
/// it, and a closed entry is opened again instead of lost. An entry with no
/// designation leaves nothing to remember.
fn hold(gpa: std.mem.Allocator, buffers: *core.Buffers, decl: *core.viewport.Declaration, id: core.Buffers.Id) void {
    var buf: [core.designation.max_len]u8 = undefined;
    const held = if (buffers.get(id)) |b| core.designation.of(b, &buf) else null;
    // Asked every frame for a shown viewport: unchanged is the common case,
    // and costs no allocation.
    if (held) |text| if (decl.entry) |old| if (std.mem.eql(u8, old, text)) return;
    core.viewport.Registry.hold(gpa, &decl.entry, held) catch {};
}

/// Realize a `viewport.take` (`core.viewport.Registry.takeEntry`): `node`
/// shows `entry`, and the head's focus moves there when the pane takes focus.
/// The pane the head leaves keeps its OWN entry — the command that made
/// `entry` active ran in it, but the focused-pane mirror has not run yet
/// this phase, so nothing was written over it.
fn takeInto(
    win_layout: *window_layout.Layout,
    view: *view_mod.View,
    buffers: *core.Buffers,
    gpa: std.mem.Allocator,
    head: *core.Head,
    keymap: *const core.Keymap,
    node: *window_layout.Node,
    entry: core.Buffers.Id,
) void {
    node.pane().buffer_id = entry;
    node.pane().top_row = 0;
    if (!node.pane().attrs.takes_focus) return;
    const focused = window_layout.headFocus(win_layout, head);
    if (node != focused) {
        focused.pane().top_row = view.top_row;
        window_layout.setHeadFocus(head, node, win_layout);
    }
    applyWindowFocus(win_layout, view, buffers, gpa, head, keymap);
}

/// "Present resource R in viewport V" (§7) — an ordinary operation, not a
/// special sidebar path. It opens `subject` through the very same `open`
/// every other locus uses (no new authority, no viewport-specific loader),
/// hands the resulting entry to `pane`, and puts the acting head back on the
/// entry it was already looking at.
///
/// This is the retarget half of following: a companion that hears the
/// primary context's `entry` move (`core/context.zig`) calls exactly this,
/// which is why following needs no binding language.
pub fn presentIn(
    ctx: *core.command.Context,
    win_layout: *window_layout.Layout,
    buffers: *core.Buffers,
    gpa: std.mem.Allocator,
    head: *core.Head,
    keymap: *const core.Keymap,
    pane: window_layout.PaneId,
    subject: []const u8,
) void {
    presentBy(ctx, win_layout, buffers, gpa, head, keymap, pane, "file.open", subject);
}

/// `presentIn` through any presenting command, not only `open`: whatever
/// entry `command` leaves active is what `pane` shows. It is how a plugin's
/// own entry, which has no path to open, reaches a declared viewport
/// (`weft.present(v, {command})`). `subject` is the command's one argument,
/// or none when empty.
pub fn presentBy(
    ctx: *core.command.Context,
    win_layout: *window_layout.Layout,
    buffers: *core.Buffers,
    gpa: std.mem.Allocator,
    head: *core.Head,
    keymap: *const core.Keymap,
    pane: window_layout.PaneId,
    command: []const u8,
    subject: []const u8,
) void {
    const node = win_layout.paneById(pane) orelse return;
    // The head goes and comes back: a presentation, not navigation, so
    // neither switch is a jump (nor is `buffer.back`'s entry disturbed).
    const here = window_layout.headFocus(win_layout, head) == node;
    core.Buffers.quietly(head, presentRoundTrip, .{ ctx, buffers, gpa, head, keymap, node, command, subject, here });
}

fn presentRoundTrip(
    ctx: *core.command.Context,
    buffers: *core.Buffers,
    gpa: std.mem.Allocator,
    head: *core.Head,
    keymap: *const core.Keymap,
    node: anytype,
    command: []const u8,
    subject: []const u8,
    /// The head is IN this pane: what it now shows is what the head is on,
    /// so the head does not go back.
    here: bool,
) void {
    const restore = buffers.active_id;
    const prev = buffers.prev_id;
    // A presentation is not an activation: an `open` run while a tool entry
    // is active asks placement for the editing pane (`buffers_cmds`), which
    // here would carry what the viewport presents off into the primary pane.
    const placement = head.placement;
    defer head.placement = placement;
    const arg = [_]core.command.Value{.{ .string = subject }};
    _ = core.command.run(ctx.commands, ctx, command, if (subject.len > 0) &arg else &.{}) catch return;
    node.pane().buffer_id = buffers.active_id;
    node.pane().top_row = 0;
    if (here or buffers.active_id == restore) return;
    buffers.switchTo(gpa, restore, head, keymap) catch return;
    buffers.prev_id = prev;
}

/// Record this head's PRIMARY focus (§7): the focused pane, when its viewport
/// is a `focus_source`. Cheap enough for every layout phase. This record is
/// the only thing the primary context reads focus from, so "what a toolbar
/// describes" and "what an outline follows" cannot disagree about which pane
/// is primary — and a companion taking focus moves neither.
fn recordPrimaryFocus(win_layout: *window_layout.Layout, head: *core.Head) void {
    const pane = window_layout.headFocus(win_layout, head).pane();
    if (pane.attrs.focus_source) {
        head.primary_focus = .{ .pane = pane.id, .entry = pane.buffer_id };
    } else if (head.primary_focus) |*p| {
        // Focus is on a companion, but the primary pane it left may since
        // show something else (an open from the sidebar lands there): follow
        // the pane, or forget it once the pane is gone.
        if (win_layout.paneById(p.pane)) |node| p.entry = node.pane().buffer_id else head.primary_focus = null;
    }
}

/// After a window op moved focus (or changed the focused pane's content),
/// make the active buffer follow `head`'s focused pane and restore that
/// pane's scroll — the invariant "focused pane == active buffer", per-head.
pub fn applyWindowFocus(win_layout: *window_layout.Layout, view: *view_mod.View, buffers: *core.Buffers, gpa: std.mem.Allocator, head: *core.Head, keymap: *const core.Keymap) void {
    const fp = window_layout.headFocus(win_layout, head).pane();
    if (buffers.get(fp.buffer_id) != null and buffers.active_id != fp.buffer_id)
        buffers.switchTo(gpa, fp.buffer_id, head, keymap) catch {};
    view.top_row = fp.top_row;
}
