//! Window-layout commands. Core commands only RECORD intent on a
//! `WindowCtx`; the frame loop applies them (split/close/focus/move by
//! pane geometry) and keeps the focused pane == the active buffer.

const std = @import("std");
const core = @import("weft_core");
const view_mod = @import("weft_gfx").view;
const region = @import("weft_gfx").region;
const window_layout = @import("weft_gfx").window_layout;
const ok_echo = @import("handler.zig").ok_echo;

/// Window-layout intents; applied in the frame loop (which owns the pane
/// tree + scroll/build state). Commands only record intent — the loop
/// mutates the layout and keeps the focused pane == the active buffer.
pub const WindowCtx = struct {
    split: ?region.Axis = null, // request a split of the focused pane
    close: bool = false,
    focus_dir: ?window_layout.Dir = null,
    move_dir: ?window_layout.Dir = null,
    focus_next: bool = false, // cycle focus (legacy `focus-other`)
    click_focus: bool = false, // focus the pane at (click_x, click_y)
    click_x: f32 = 0,
    click_y: f32 = 0,
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
/// `WindowAction`. The legacy names (split/vsplit/unsplit/focus-other) alias
/// onto the same intents so the prebuilt `windows` .wasm plugin and older
/// configs keep working. Registration order is last-wins; keep it stable.
pub const cmd_table = [_]struct { name: []const u8, action: WindowAction, summary: []const u8 }{
    .{ .name = "window-split", .action = .split, .summary = "Split the focused window horizontally (a pane below)." },
    .{ .name = "window-vsplit", .action = .vsplit, .summary = "Split the focused window vertically (a pane beside)." },
    .{ .name = "window-close", .action = .close, .summary = "Close the focused window, collapsing its split." },
    .{ .name = "window-focus-left", .action = .focus_left, .summary = "Focus the window to the left." },
    .{ .name = "window-focus-right", .action = .focus_right, .summary = "Focus the window to the right." },
    .{ .name = "window-focus-up", .action = .focus_up, .summary = "Focus the window above." },
    .{ .name = "window-focus-down", .action = .focus_down, .summary = "Focus the window below." },
    .{ .name = "window-move-left", .action = .move_left, .summary = "Swap the focused window with its left neighbor." },
    .{ .name = "window-move-right", .action = .move_right, .summary = "Swap the focused window with its right neighbor." },
    .{ .name = "window-move-up", .action = .move_up, .summary = "Swap the focused window with the one above." },
    .{ .name = "window-move-down", .action = .move_down, .summary = "Swap the focused window with the one below." },
    .{ .name = "split", .action = .split, .summary = "Split the focused window horizontally." },
    .{ .name = "vsplit", .action = .vsplit, .summary = "Split the focused window vertically." },
    .{ .name = "unsplit", .action = .close, .summary = "Close the focused window." },
    .{ .name = "focus-other", .action = .focus_next, .summary = "Focus the next window." },
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
/// a focus change is published on `focus`.
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
    focus: *core.focus_feed.Feed,
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
    if (win_ctx.click_focus) {
        win_ctx.click_focus = false;
        const focused = window_layout.headFocus(win_layout, head);
        focused.pane().top_row = view.top_row;
        if (win_layout.focusAt(last_frame_rect, win_ctx.click_x, win_ctx.click_y)) |hit| {
            if (hit != focused) {
                window_layout.setHeadFocus(head, hit, win_layout);
                applyWindowFocus(win_layout, view, buffers, gpa, head, keymap);
                dirty = true;
            }
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
    publishFocus(win_layout, head, focus);
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
        // in front so the mirror below does not show it anyway.
        buffers.switchTo(gpa, focused.pane().buffer_id, head, keymap) catch {};
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
/// without re-docking anything.
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
) bool {
    var dirty = false;
    for (registry.list.items) |*decl| {
        const edge = decl.attrs.dock orelse continue;
        if (decl.pane == null or win_layout.paneById(decl.pane.?) == null) {
            const panel = win_layout.dock(edge, decl.extent, buffers.active_id, decl.attrs) catch continue;
            decl.pane = panel.leaf.id;
            decl.presented = false;
            dirty = true;
        }
        if (decl.presented or decl.subject.len == 0) continue;
        decl.presented = true;
        presentIn(ctx, win_layout, buffers, gpa, head, keymap, decl.pane.?, decl.subject);
        dirty = true;
    }
    return dirty;
}

/// "Present resource R in viewport V" (§7) — an ordinary operation, not a
/// special sidebar path. It opens `subject` through the very same `open`
/// every other locus uses (no new authority, no viewport-specific loader),
/// hands the resulting entry to `pane`, and puts the acting head back on the
/// entry it was already looking at.
///
/// This is the retarget half of the follow-focus pair
/// (`core/focus_feed.zig`'s `Companion` is the other): a companion that
/// follows the focus feed calls exactly this, which is why following needs no
/// binding language.
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
    const node = win_layout.paneById(pane) orelse return;
    const restore = buffers.active_id;
    _ = core.command.run(ctx.commands, ctx, "open", &.{.{ .string = subject }}) catch return;
    node.pane().buffer_id = buffers.active_id;
    node.pane().top_row = 0;
    if (buffers.active_id != restore)
        buffers.switchTo(gpa, restore, head, keymap) catch {};
}

/// Publish this head's focused viewport on the primary-focus feed (§7). The
/// feed is idempotent, so calling it every layout phase costs one comparison
/// on a quiet frame; every event carries the source viewport's attributes, so
/// a companion consumer can tell primary focus from companion focus without
/// the workspace deciding for it.
fn publishFocus(win_layout: *window_layout.Layout, head: *core.Head, focus: *core.focus_feed.Feed) void {
    const pane = window_layout.headFocus(win_layout, head).pane();
    focus.publish(.{ .viewport = pane.id, .entry = pane.buffer_id, .attrs = pane.attrs });
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
