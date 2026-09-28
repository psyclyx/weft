//! Pointer input as KEYS, and where the pointer is as FACTS.
//!
//! A pointer gesture reaches the keymap the way a keystroke does: the shell
//! (`app/pointer.zig`) names it as a keyspec and hands it to the one dispatch
//! path, so what a click does is a binding — rebindable per mode, layered by
//! tier, explained like any key — and never a branch in the shell.
//!
//! ## The keyspec grammar
//!
//!     [C-][M-][S-]<gesture>
//!
//!     mouse-N          button N went down (a single click)
//!     double-mouse-N   the second quick press of button N
//!     triple-mouse-N   the third
//!     drag-mouse-N     the pointer moved with button N held
//!     up-mouse-N       button N was released
//!     wheel-up / wheel-down / wheel-left / wheel-right   one wheel step
//!
//! `N` is 1 for the primary button, 2 middle, 3 secondary (Emacs numbering).
//! A press is exactly ONE spec: a double click dispatches `mouse-1` and then
//! `double-mouse-1`, never both for one press. A press/drag/release triple
//! composes with the chord model because each is an ordinary single key: an
//! unbound `drag-mouse-1` in insert mode is simply unhandled, and a click
//! mid-chord dead-ends the chord as any unbound key would. Modifiers come
//! first, in canonical `C-M-S-` order (`Keymap.normalizeKey`).
//!
//! ## The facts
//!
//! Where the gesture happened rides on the head (`Head.pointer`, a
//! `Gesture`): the pane under the pointer, the byte offset in that pane's
//! text, and the scene node under it. The shell fills it before dispatch;
//! commands read it from `ctx.head.pointer`, guests through `wl_pointer`.
//! `origin` is where the button went down, so a drag knows what it extends
//! from without the shell keeping a drag state machine.
//!
//! ## The commands
//!
//! The generic pointer commands below are the modeless floor, like the arrow
//! keys in `builtins.zig`: core owns what "place the caret at the click"
//! means. WHICH gesture runs which is config (`config/defaults.js`).
//! Focusing and scrolling a pane is layout, which core cannot see, so those
//! go through the `Panes` door the shell installs on the command context.

const std = @import("std");
const semantic_model = @import("weft_semantic");
const command = @import("command.zig");
const Context = command.Context;
const Value = command.Value;
const Buffers = @import("Buffers.zig");
const scene_edit = @import("scene_edit.zig");

const ok: Value = .nil;

/// Modifiers held for a gesture. Core's own spelling of the platform's
/// `Mods`, so core needs no platform import.
pub const Mods = packed struct(u4) {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    logo: bool = false,
};

/// A window-layout pane, as the generation-checked handle `Head.focused_pane`
/// already uses.
pub const PaneRef = struct { id: u32, gen: u32 };

pub const NodeRef = struct {
    view: semantic_model.view.Ref,
    node: semantic_model.scene.NodeId,
};

/// A pane's chrome under the point, as the view laid it out: a tab of the
/// tab strip (its body or its close glyph, naming the entry it shows), or a
/// segment of the status line (naming the command a click on it runs). Plain
/// facts — what a click on one does is the bound command's business.
pub const Chrome = struct {
    kind: Of,
    /// Which tab, or which status segment, in the order drawn.
    index: u16 = 0,
    part: Part = .body,
    /// The entry a tab shows.
    entry: ?Buffers.Id = null,
    /// The pane a status segment describes, when the status line it is on
    /// is PRESENTED by another pane (a bar showing the primary context's
    /// status): its command acts there, not in the pane it is drawn in.
    acts_in: ?PaneRef = null,
    /// A segment's command, `name [argument]`, copied (the segment itself
    /// lives in last frame's arena). Empty: not clickable.
    command_buf: [max_command]u8 = undefined,
    command_len: u8 = 0,

    pub const Of = enum { tab, status };
    pub const Part = enum { body, close };
    pub const max_command = 128;

    pub fn command(self: *const Chrome) []const u8 {
        return self.command_buf[0..self.command_len];
    }

    /// Record `text` as the command; one longer than `max_command` is
    /// dropped whole rather than cut into a different command.
    pub fn setCommand(self: *Chrome, text: []const u8) void {
        if (text.len > max_command) {
            self.command_len = 0;
            return;
        }
        @memcpy(self.command_buf[0..text.len], text);
        self.command_len = @intCast(text.len);
    }
};

/// What is under one point of the window, as of the last built frame.
pub const Hit = struct {
    /// Framebuffer pixels.
    x: f32 = 0,
    y: f32 = 0,
    /// The pane under the point; null outside every pane (the picker dock).
    pane: ?PaneRef = null,
    /// The entry that pane showed.
    entry: ?Buffers.Id = null,
    /// Whether that pane was the head's focused one when the event arrived.
    focused: bool = false,
    /// The byte offset under the point, in a pane showing text.
    offset: ?usize = null,
    /// The scene node under the point, in a pane showing a scene.
    node: ?NodeRef = null,
    /// The pane CHROME under the point — a tab, a status segment. When set,
    /// `offset` and `node` are null: the point is on the chrome, not on what
    /// the pane shows beneath it.
    chrome: ?Chrome = null,

    pub fn samePane(a: Hit, b: Hit) bool {
        const pa = a.pane orelse return false;
        const pb = b.pane orelse return false;
        return pa.id == pb.id and pa.gen == pb.gen;
    }
};

pub const Kind = enum { none, press, release, drag, wheel, hover };

/// One head's pointer facts: the gesture being dispatched and where it is.
pub const Gesture = struct {
    kind: Kind = .none,
    button: u8 = 0,
    clicks: u8 = 0,
    /// A single click that came after the double-click window of the
    /// previous press, but not long after (the platform's `slow_click_ms`):
    /// on the row it already focused, a list control's "rename".
    slow: bool = false,
    /// The scene node the previous press went down on, if any.
    prior: ?NodeRef = null,
    mods: Mods = .{},
    /// Where the pointer is now.
    hit: Hit = .{},
    /// Where the button of the gesture in progress went down.
    origin: Hit = .{},
    /// Whether a drag has already anchored its selection at `origin`.
    /// Cleared by every press; set by `pointer.drag-select`.
    selecting: bool = false,
};

/// Layout operations a pointer command needs and core cannot perform:
/// installed by the shell, which owns the pane tree and the view. Null in
/// embeddings without panes, where the pane commands do nothing.
pub const Panes = struct {
    context: *anyopaque,
    /// Focus `pane` for the dispatching head: its entry becomes active, its
    /// scroll the live one. False when the pane is gone, or declares that it
    /// takes no focus (the viewport's `takes_focus`).
    focus: *const fn (*anyopaque, *Context, PaneRef) bool,
    /// Scroll `pane` by `rows` (negative is up), keeping what the pane
    /// focuses — the caret, a scene's focused row — inside the new view.
    scroll: *const fn (*anyopaque, *Context, PaneRef, i32) void,
    /// Move the focused pane's caret one VISUAL line (`dir` < 0 is up),
    /// holding its goal column over the geometry the pane rendered. False
    /// when there is nothing to measure against, and `cursor.up`/`down`
    /// then move by logical line. One command, a door for what core cannot
    /// see — not a second registration shadowing the first.
    vertical: ?*const fn (*anyopaque, *Context, i32) bool = null,
};

// ── Keyspecs ────────────────────────────────────────────────────────

/// The gesture half of a pointer keyspec (no modifiers) into `buf`.
pub fn gestureName(buf: []u8, kind: Kind, button: u8, clicks: u8) []const u8 {
    return switch (kind) {
        .press => switch (clicks) {
            2 => std.fmt.bufPrint(buf, "double-mouse-{d}", .{button}),
            3 => std.fmt.bufPrint(buf, "triple-mouse-{d}", .{button}),
            else => std.fmt.bufPrint(buf, "mouse-{d}", .{button}),
        },
        .drag => std.fmt.bufPrint(buf, "drag-mouse-{d}", .{button}),
        .release => std.fmt.bufPrint(buf, "up-mouse-{d}", .{button}),
        .wheel, .hover, .none => return "",
    } catch "";
}

/// Hover has no keyspec: the keymap never sees it. The one place it is an
/// input is an active interaction that binds it by this name (a menu whose
/// highlight follows the pointer), handed it when the pointer comes to rest
/// on a new target (`app/pointer.zig`).
pub const hover_input = @import("weft_view_runtime").interaction.hover_input;

pub const WheelDir = enum { up, down, left, right };

pub fn wheelName(dir: WheelDir) []const u8 {
    return switch (dir) {
        .up => "wheel-up",
        .down => "wheel-down",
        .left => "wheel-left",
        .right => "wheel-right",
    };
}

/// Whether a canonical keyspec names a pointer gesture (after any modifier
/// prefixes). Dot-repeat does not record these: a click replayed later
/// would land wherever the pointer happens to be.
pub fn isPointerSpec(spec: []const u8) bool {
    var base = spec;
    while (base.len >= 2 and base[1] == '-' and (base[0] == 'C' or base[0] == 'M' or base[0] == 'S')) base = base[2..];
    for ([_][]const u8{ "mouse-", "double-mouse-", "triple-mouse-", "drag-mouse-", "up-mouse-", "wheel-" }) |p| {
        if (std.mem.startsWith(u8, base, p)) return true;
    }
    return false;
}

// ── Commands ────────────────────────────────────────────────────────

/// Focus the pane under the pointer when it is not already the focused one.
/// Every acting command starts here, which is what makes a click in an
/// unfocused pane act THERE: click-through is a property of the bound
/// command, not of the shell.
///
/// Returns whether the click may act on the ACTIVE entry: the pointer is
/// over the focused pane now, or over no pane at all. False over a pane that
/// takes no focus — a strip of buttons — where only its action nodes act
/// (`activateInPlace`), and never on the entry that keeps the keys.
fn focusHitPane(ctx: *Context) bool {
    const g = &ctx.head.pointer;
    if (g.hit.pane == null) return true;
    if (g.hit.focused) return true;
    // No pane door (an embedding without panes): nothing to focus, as before.
    const panes = ctx.panes orelse return true;
    if (panes.focus(panes.context, ctx, g.hit.pane.?)) g.hit.focused = true;
    return g.hit.focused;
}

/// Whether the gesture being dispatched may ACT — run an action node, press
/// a tab or a status segment. Only its first click may: `double-mouse-1` and
/// `triple-mouse-1` are the same press continued (a double click on a word
/// selects it; on a button it must not press the button twice), so every
/// pointer route to an action asks this, in one place. Zero clicks is a
/// pointer command run with no gesture behind it, which acts.
fn actsThisClick(ctx: *const Context) bool {
    return ctx.head.pointer.clicks <= 1;
}

/// A click through a pane that took no focus: run the action node under the
/// pointer by reference, leaving the head's focus where it was.
fn activateInPlace(ctx: *Context) anyerror!Value {
    if (!actsThisClick(ctx)) return ok;
    const node = ctx.head.pointer.hit.node orelse return ok;
    const services = ctx.semantic orelse return ok;
    _ = services.invokeActionNode(&ctx.head.interactions, ctx.head, ctx.gpa, node.view, node.node) catch |err| switch (err) {
        error.ActionUnavailable, error.StaleView => return ok,
        else => return err,
    };
    return ok;
}

fn hitEditor(ctx: *Context) ?*@import("Editor.zig") {
    return (ctx.entry() orelse return null).textEditor();
}

/// Focus `node` in its view for this head.
fn focusNode(ctx: *Context, node: NodeRef) !void {
    const services = ctx.semantic orelse return;
    _ = services.focusView(ctx.head, ctx.gpa, node.view, node.node) catch |err| switch (err) {
        error.StaleView => return,
        else => return err,
    };
}

fn cPointerFocusPane(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    _ = focusHitPane(ctx);
    return ok;
}

/// Focus what is under the pointer without acting on it: the pane, then the
/// node there in a scene, or the caret in text — unless the point is inside
/// the selection, which a secondary click keeps (it is what a menu of
/// operations would act on). What a command that describes "the context
/// under the pointer" runs first, so the active context IS that context.
fn cPointerFocusPoint(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    if (!focusHitPane(ctx)) return ok;
    const hit = ctx.head.pointer.hit;
    if (hit.node) |node| {
        try focusNode(ctx, node);
        return ok;
    }
    const off = hit.offset orelse return ok;
    const ed = hitEditor(ctx) orelse return ok;
    if (ed.selectedRange()) |r| if (off >= r.start and off <= r.end) return ok;
    ed.clearSelection();
    ed.placeCursor(off);
    return ok;
}

/// Add what is under the pointer to the selection, keeping what is already
/// there (C-click): a caret in text, the row in a scene — the same act on
/// either kind of extent. The new one is the primary; a row already marked
/// is not marked twice.
fn cPointerAddSelection(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    if (!focusHitPane(ctx)) return ok;
    const hit = ctx.head.pointer.hit;
    if (hit.node) |node| {
        const scene = &ctx.head.scene_selection;
        const same_view = if (scene.view) |v| v.eql(node.view) else false;
        const kept = if (same_view) scene.primaryRows() else null;
        try focusNode(ctx, node);
        const now = scene.head() orelse return ok;
        if (kept) |r| if (r.head != now or r.anchor != now) try scene.others.append(ctx.gpa, r);
        scene.anchor = null;
        // The row now focused is the primary; a mark it duplicates goes.
        var i: usize = 0;
        while (i < scene.others.items.len) {
            const r = scene.others.items[i];
            if (r.anchor == now and r.head == now) _ = scene.others.swapRemove(i) else i += 1;
        }
        return ok;
    }
    const off = hit.offset orelse return ok;
    const ed = hitEditor(ctx) orelse return ok;
    try ed.addSelection(ctx.gpa, .{ .anchor = off, .head = off });
    return ok;
}

/// A click: focus the pane under the pointer, then act at the point — put
/// the caret there in text, focus the node there in a scene, and activate
/// it when the node is an action. Over a pane that takes no focus only an
/// action node acts, and in place.
fn cPointerClick(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    if (ctx.head.pointer.hit.chrome) |chrome| return if (actsThisClick(ctx)) clickChrome(ctx, chrome) else ok;
    if (!focusHitPane(ctx)) return activateInPlace(ctx);
    const hit = ctx.head.pointer.hit;
    if (hit.node) |node| {
        // A list focused by ROWS reads the pointer as a list control does
        // (doc/chrome.md §5.2), whatever the grammar bound: a double click
        // activates the row the first click focused, and a slow second
        // click on the focused row edits its name.
        const rows = if (ctx.semantic) |services| services.granularityFor(ctx.head) == .row else false;
        if (rows and ctx.head.pointer.clicks >= 2) return if (ctx.head.pointer.clicks == 2) cPointerActivate(ctx, .{}) else ok;
        const again = rows and slowClickOnFocus(ctx, node);
        // A click is THE selection, as it is in text: marked rows go.
        ctx.head.scene_selection.collapse();
        try focusNode(ctx, node);
        if (isActionNode(ctx, node)) _ = try activateActionNode(ctx);
        if (again) _ = scene_edit.begin(ctx.semantic.?, ctx.head, ctx.gpa) catch |err| switch (err) {
            error.ActionRefused, error.ReadOnly => {},
            else => return err,
        };
        return ok;
    }
    const off = hit.offset orelse return ok;
    const ed = hitEditor(ctx) orelse return ok;
    ed.clearSelection();
    ed.placeCursor(off);
    return ok;
}

// ── Chrome ──────────────────────────────────────────────────────────

/// A click on the pane's chrome: a tab's body shows its entry, its close
/// glyph closes it, and a status segment runs the command it declared. The
/// pane is focused first, so a segment's command acts for the entry of the
/// status line it sits in — which, on a bar presenting another context's
/// status, is that context's pane.
fn clickChrome(ctx: *Context, chrome: Chrome) anyerror!Value {
    if (chrome.acts_in) |pane| {
        if (ctx.panes) |panes| _ = panes.focus(panes.context, ctx, pane);
    } else _ = focusHitPane(ctx);
    switch (chrome.kind) {
        .tab => {
            const entry = chrome.entry orelse return ok;
            if (chrome.part == .close) return closeEntry(ctx, entry);
            _ = try command.run(ctx.commands, ctx, "buffer.switch", &.{.{ .integer = entry }});
        },
        .status => try runLine(ctx, chrome.command()),
    }
    return ok;
}

/// Run `name [argument]` — a status segment's command: the name, then the
/// rest of the line as its one string argument when there is any.
fn runLine(ctx: *Context, line: []const u8) !void {
    const trimmed = std.mem.trim(u8, line, " ");
    if (trimmed.len == 0) return;
    const space = std.mem.indexOfScalar(u8, trimmed, ' ');
    const name = trimmed[0 .. space orelse trimmed.len];
    const rest = if (space) |at| std.mem.trim(u8, trimmed[at + 1 ..], " ") else "";
    _ = try command.run(ctx.commands, ctx, name, if (rest.len > 0) &.{.{ .string = rest }} else &.{});
}

/// Close `entry` through the ordinary `buffer.close-unmodified` (which refuses a dirty
/// one), coming back to the entry that was active when it was another one —
/// a borrow (`Buffers.withEntry`), so the round trip records no jump.
fn closeEntry(ctx: *Context, entry: Buffers.Id) anyerror!Value {
    if (ctx.buffers.get(entry) == null) return ok;
    return try ctx.buffers.withEntry(ctx.gpa, entry, ctx.head, ctx.keymap, closeActive, .{ctx});
}

fn closeActive(ctx: *Context) anyerror!Value {
    return command.run(ctx.commands, ctx, "buffer.close-unmodified", &.{});
}

/// Close the tab under the pointer, wherever on the tab it is (a middle
/// click). Anywhere else it does nothing.
fn cPointerCloseTab(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    const chrome = ctx.head.pointer.hit.chrome orelse return ok;
    if (chrome.kind != .tab) return ok;
    _ = focusHitPane(ctx);
    return closeEntry(ctx, chrome.entry orelse return ok);
}

/// Motion with the button held: select from where the button went down to
/// the pointer. The mark is set on the first motion that actually leaves the
/// caret, so a click that jitters a pixel selects nothing.
fn cPointerDragSelect(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    const g = &ctx.head.pointer;
    if (!Hit.samePane(g.hit, g.origin)) return ok;
    const off = g.hit.offset orelse return ok;
    const anchor = g.origin.offset orelse return ok;
    const ed = hitEditor(ctx) orelse return ok;
    if (off == ed.cursorOffset()) return ok;
    if (!g.selecting) {
        try ed.selectRange(ctx.gpa, anchor, off);
        g.selecting = true;
        return ok;
    }
    ed.placeCursor(off);
    return ok;
}

/// Extend the selection from the caret to the pointer (a shift-click).
fn cPointerExtendSelection(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    if (!focusHitPane(ctx)) return ok;
    const off = ctx.head.pointer.hit.offset orelse return ok;
    const ed = hitEditor(ctx) orelse return ok;
    if (ed.selectedRange() == null) try ed.setMark(ctx.gpa);
    ed.placeCursor(off);
    ctx.head.pointer.selecting = true;
    return ok;
}

/// Focus the node under the pointer, then activate it: an action node runs
/// its action, anything else opens what it links to.
fn cPointerActivate(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    if (!focusHitPane(ctx)) return activateInPlace(ctx);
    const node = ctx.head.pointer.hit.node orelse return ok;
    // A double click whose first click was a slow one began an edit of this
    // row's name on the way: the gesture was an activation, so the edit ends
    // (nothing was typed into it, so nothing is applied).
    if (ctx.semantic) |services| _ = try scene_edit.commit(services, ctx.head, ctx.gpa);
    try focusNode(ctx, node);
    if (isActionNode(ctx, node)) return activateActionNode(ctx);
    // Opening a row's target is what a double click on a listing is FOR.
    _ = try command.run(ctx.commands, ctx, "target.open", &.{});
    return ok;
}

/// The pointer's route to the focused action node: it runs on a gesture's
/// first click only (`actsThisClick`).
fn activateActionNode(ctx: *Context) anyerror!Value {
    if (!actsThisClick(ctx)) return ok;
    return activateFocusedAction(ctx);
}

fn scrollHitPane(ctx: *Context, rows: i32) void {
    const pane = ctx.head.pointer.hit.pane orelse return;
    const panes = ctx.panes orelse return;
    panes.scroll(panes.context, ctx, pane, rows);
}

/// Lines per wheel step: the common desktop default.
pub const wheel_lines = 3;

fn cScrollWheelUp(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    scrollHitPane(ctx, -wheel_lines);
    return ok;
}

fn cScrollWheelDown(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    scrollHitPane(ctx, wheel_lines);
    return ok;
}

// ── Action nodes ────────────────────────────────────────────────────

/// Whether this press is a slow second click on the row the head already
/// focuses, which the previous press went down on too — the list-control
/// gesture for editing a row's name. Not while that row is being edited:
/// a click inside an edit places its caret.
fn slowClickOnFocus(ctx: *Context, node: NodeRef) bool {
    const g = &ctx.head.pointer;
    if (!g.slow or g.clicks != 1) return false;
    const prior = g.prior orelse return false;
    if (!prior.view.eql(node.view) or prior.node != node.node) return false;
    const selection = &ctx.head.scene_selection;
    if (selection.began) return false;
    const view = selection.view orelse return false;
    return view.eql(node.view) and selection.head() == node.node;
}

fn isActionNode(ctx: *Context, node: NodeRef) bool {
    const services = ctx.semantic orelse return false;
    const instance = services.views.get(node.view) orelse return false;
    const n = instance.node(node.node) orelse return false;
    return n.content == .action;
}

/// Activate the focused scene node when it is an `action` node. The same
/// reference answers a click (`pointer.click`) and a key
/// (`std.target.activate`, derived for action nodes by `view_offers.zig`),
/// so the two cannot disagree.
pub fn activateFocusedAction(ctx: *Context) anyerror!Value {
    const services = ctx.semantic orelse return ok;
    _ = services.invokeFocusedActionNode(&ctx.head.interactions, ctx.head, ctx.gpa) catch |err| switch (err) {
        // The provider has no such action, or the view went away under the
        // click: nothing to run, which is not a failure.
        error.ActionUnavailable, error.StaleView => return ok,
        else => return err,
    };
    return ok;
}

fn cActivateFocusedAction(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    return activateFocusedAction(ctx);
}

pub const table = [_]command.Command{
    command.define("pointer.focus-pane", "Focus the pane under the pointer.", cPointerFocusPane).present(.{ .internal = true }),
    command.define("pointer.focus-point", "Focus the pane and the node or caret under the pointer, keeping a selection the point is inside.", cPointerFocusPoint).present(.{ .internal = true }),
    command.define("pointer.click", "Focus the pane under the pointer and act there, placing the caret, focusing a node or running an action.", cPointerClick).present(.{ .internal = true }),
    command.define("pointer.add-selection", "Add a caret in text, or the row in a scene, under the pointer to the selection.", cPointerAddSelection).present(.{ .internal = true }),
    command.define("pointer.drag-select", "Select from where the button went down to the pointer.", cPointerDragSelect).present(.{ .internal = true }),
    command.define("pointer.extend-selection", "Extend the selection from the caret to the pointer.", cPointerExtendSelection).present(.{ .internal = true }),
    command.define("pointer.activate", "Activate the node under the pointer, running its action or opening its target.", cPointerActivate).present(.{ .internal = true }),
    command.define("pointer.close-tab", "Close the tab under the pointer.", cPointerCloseTab).present(.{ .internal = true }),
    command.define("scroll.wheel-up", "Scroll the pane under the pointer up one wheel step.", cScrollWheelUp).present(.{ .internal = true }),
    command.define("scroll.wheel-down", "Scroll the pane under the pointer down one wheel step.", cScrollWheelDown).present(.{ .internal = true }),
    command.define("view.run-focused-action", "Run the action the focused action node names.", cActivateFocusedAction).present(.{ .internal = true }),
};

pub fn install(gpa: std.mem.Allocator, commands: *command.Commands) !void {
    for (table) |cmd| _ = try commands.bind(gpa, cmd.name, cmd);
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "pointer: gesture names follow the keyspec grammar" {
    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("mouse-1", gestureName(&buf, .press, 1, 1));
    try t.expectEqualStrings("double-mouse-1", gestureName(&buf, .press, 1, 2));
    try t.expectEqualStrings("triple-mouse-3", gestureName(&buf, .press, 3, 3));
    try t.expectEqualStrings("drag-mouse-1", gestureName(&buf, .drag, 1, 0));
    try t.expectEqualStrings("up-mouse-2", gestureName(&buf, .release, 2, 0));
    try t.expectEqualStrings("", gestureName(&buf, .hover, 0, 0));
    try t.expectEqualStrings("wheel-down", wheelName(.down));
}

test "pointer: pointer specs are recognised through modifiers, keys are not" {
    try t.expect(isPointerSpec("mouse-1"));
    try t.expect(isPointerSpec("C-S-double-mouse-1"));
    try t.expect(isPointerSpec("M-wheel-up"));
    try t.expect(!isPointerSpec("m"));
    try t.expect(!isPointerSpec("C-minus"));
    try t.expect(!isPointerSpec("space"));
}
