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
    mods: Mods = .{},
    /// Where the pointer is now.
    hit: Hit = .{},
    /// Where the button of the gesture in progress went down.
    origin: Hit = .{},
    /// Whether a drag has already anchored its selection at `origin`.
    /// Cleared by every press; set by `pointer-drag-select`.
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

/// A click through a pane that took no focus: run the action node under the
/// pointer by reference, leaving the head's focus where it was.
fn activateInPlace(ctx: *Context) anyerror!Value {
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

/// A click: focus the pane under the pointer, then act at the point — put
/// the caret there in text, focus the node there in a scene, and activate
/// it when the node is an action. Over a pane that takes no focus only an
/// action node acts, and in place.
fn cPointerClick(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    if (!focusHitPane(ctx)) return activateInPlace(ctx);
    const hit = ctx.head.pointer.hit;
    if (hit.node) |node| {
        try focusNode(ctx, node);
        if (isActionNode(ctx, node)) _ = try activateFocusedAction(ctx);
        return ok;
    }
    const off = hit.offset orelse return ok;
    const ed = hitEditor(ctx) orelse return ok;
    ed.clearSelection();
    ed.placeCursor(off);
    return ok;
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
        ed.placeCursor(anchor);
        try ed.setMark(ctx.gpa);
        g.selecting = true;
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
    try focusNode(ctx, node);
    if (isActionNode(ctx, node)) return activateFocusedAction(ctx);
    _ = try command.run(ctx.commands, ctx, "target-open-focused", &.{});
    return ok;
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

fn isActionNode(ctx: *Context, node: NodeRef) bool {
    const services = ctx.semantic orelse return false;
    const instance = services.views.get(node.view) orelse return false;
    const n = instance.node(node.node) orelse return false;
    return n.content == .action;
}

/// Activate the focused scene node when it is an `action` node. The same
/// reference answers a click (`pointer-click`) and a key
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
    command.define("pointer-focus-pane", "Focus the pane under the pointer.", cPointerFocusPane),
    command.define("pointer-focus-point", "Focus the pane and the node or caret under the pointer, keeping a selection the point is inside.", cPointerFocusPoint),
    command.define("pointer-click", "Focus the pane under the pointer and act at the point: place the caret, focus a node, run an action node.", cPointerClick),
    command.define("pointer-drag-select", "Select from where the button went down to the pointer.", cPointerDragSelect),
    command.define("pointer-extend-selection", "Extend the selection from the caret to the pointer.", cPointerExtendSelection),
    command.define("pointer-activate", "Activate the node under the pointer (run its action, or open its target).", cPointerActivate),
    command.define("scroll-wheel-up", "Scroll the pane under the pointer up one wheel step.", cScrollWheelUp),
    command.define("scroll-wheel-down", "Scroll the pane under the pointer down one wheel step.", cScrollWheelDown),
    command.define("activate-focused-action", "Run the action the focused action node names.", cActivateFocusedAction),
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
