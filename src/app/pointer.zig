//! Pointer events → the keymap.
//!
//! The pointer half of `dispatch.dispatchKey`: one platform `PointerEvent`
//! becomes the facts of where it happened (`core.pointer.Hit`, written to the
//! head) and a keyspec (`mouse-1`, `S-drag-mouse-1`, `wheel-down`, …; the
//! grammar is `core/pointer.zig`'s) handed to the ONE dispatch path. What a
//! gesture does is whatever it is bound to — `config/defaults.js` binds the
//! everyday ones — so this file holds no click policy at all. It used to: a
//! left click placed the caret, a click outside the focused pane only
//! focused it, a click in a scene focused the row, and none of it was
//! rebindable.
//!
//! Also here: the `core.pointer.Panes` door, the layout operations the
//! generic pointer and caret commands need and core cannot see (focus a pane,
//! scroll a pane, move a caret by visual line), implemented over the frame
//! driver's layout and view.
//!
//! Hit-testing reads the geometry of the last BUILT frame, every pane's
//! (`View.pane_maps`), so a click lands where the user saw the thing it
//! points at, focused pane or not.

const std = @import("std");
const core = @import("weft_core");
const platform = @import("weft_platform");
const window_layout = @import("weft_gfx").window_layout;
const frame = @import("frame.zig");
const window_cmds = @import("window_cmds.zig");
const dispatch = @import("dispatch.zig");

const Pointer = core.pointer;

/// What the pointer rests on, as frame INPUT (doc/model.md §2.7,
/// doc/chrome.md §3.3): the target under it — a pane's chrome part or scene
/// node — and since when, for the tooltip delay. Hover is not a gesture: no
/// keyspec, no dispatch, no keymap lookup. A new TARGET marks the frame
/// dirty so the chrome style can light what is under the pointer; motion
/// within one target costs nothing at all.
pub const Hover = struct {
    target: Target = .{},
    /// The pointer, framebuffer pixels; null before it has moved.
    at: ?[2]f32 = null,
    since_ns: u64 = 0,
    /// The pointer has rested on `target` past `delay_ns`: tooltips show.
    ripe: bool = false,
    delay_ns: u64 = 600 * std.time.ns_per_ms,
    /// The tooltip's key hint, found when the pointer settled (`settle`), so
    /// the frame that shows the tooltip is handed it and asks nothing.
    hint: Hint = .{},

    /// The shortest key that runs a command where the person is, as a
    /// person reads it — owned, since it outlives the wake that found it.
    pub const Hint = struct {
        command_buf: [128]u8 = undefined,
        command_len: usize = 0,
        keys_buf: [64]u8 = undefined,
        keys_len: usize = 0,

        pub fn command(self: *const Hint) []const u8 {
            return self.command_buf[0..self.command_len];
        }

        pub fn keys(self: *const Hint) []const u8 {
            return self.keys_buf[0..self.keys_len];
        }

        /// The key that runs `name` in `ctx`'s person mode (`keys_for`,
        /// doc/chrome.md §1.3); none when nothing does, or `name` is too
        /// long to hold.
        pub fn find(ctx: *core.command.Context, name: []const u8) Hint {
            var hint: Hint = .{};
            if (name.len == 0 or name.len > hint.command_buf.len) return hint;
            @memcpy(hint.command_buf[0..name.len], name);
            hint.command_len = name.len;
            const found = core.keys_for.keysFor(ctx, ctx.gpa, name, core.keys_for.personMode(ctx)) catch return hint;
            defer core.keys_for.free(ctx.gpa, found);
            if (found.len == 0) return hint;
            var buf: [256]u8 = undefined;
            const shown = ctx.keymap.displayKey(&buf, found[0]);
            if (shown.len > hint.keys_buf.len) return hint;
            @memcpy(hint.keys_buf[0..shown.len], shown);
            hint.keys_len = shown.len;
            return hint;
        }
    };

    pub const Target = struct {
        pane: ?u32 = null,
        chrome: ?struct { kind: Pointer.Chrome.Of, index: u16, part: Pointer.Chrome.Part } = null,
        node: ?Pointer.NodeRef = null,

        pub fn of(hit: Pointer.Hit) Target {
            return .{
                .pane = if (hit.pane) |p| p.id else null,
                .chrome = if (hit.chrome) |c| .{ .kind = c.kind, .index = c.index, .part = c.part } else null,
                .node = hit.node,
            };
        }

        pub fn eql(a: Target, b: Target) bool {
            if (!std.meta.eql(a.pane, b.pane) or !std.meta.eql(a.chrome, b.chrome)) return false;
            if (a.node == null or b.node == null) return a.node == null and b.node == null;
            return a.node.?.node == b.node.?.node and a.node.?.view.eql(b.node.?.view);
        }

        /// Something a tooltip could be about.
        fn named(self: Target) bool {
            return self.chrome != null or self.node != null;
        }
    };

    /// The pointer is at `hit` now. True when that is a different target —
    /// the one change a frame has to show.
    pub fn move(self: *Hover, hit: Pointer.Hit, now_ns: u64) bool {
        self.at = .{ hit.x, hit.y };
        const target: Target = .of(hit);
        if (target.eql(self.target)) return false;
        self.target = target;
        self.since_ns = now_ns;
        self.ripe = false;
        self.hint = .{};
        return true;
    }

    /// When the tooltip for the current target is due; null when none is
    /// pending. The loop's timer source (`loop_sources.tooltipDue`).
    pub fn dueAt(self: *const Hover) ?u64 {
        if (self.ripe or !self.target.named()) return null;
        return self.since_ns + self.delay_ns;
    }

    /// Past the delay at `now_ns`: the tooltip shows. True on the one wake it
    /// ripens, which is the frame that has to draw it.
    pub fn ripen(self: *Hover, now_ns: u64) bool {
        const due = self.dueAt() orelse return false;
        if (now_ns < due) return false;
        self.ripe = true;
        return true;
    }

    /// The pointer has settled: find the key hint for `command`, what the
    /// element under it runs (`View.hoveredCommand`, the last frame's).
    pub fn settle(self: *Hover, ctx: *core.command.Context, command: []const u8) void {
        self.hint = .find(ctx, command);
    }
};

/// Handle one pointer event whose position is already in framebuffer
/// pixels. Returns whether anything was dispatched (the input edge).
pub fn handle(driver: *frame.Driver, ctx: *core.command.Context, ev: platform.PointerEvent) !bool {
    const g = &ctx.head.pointer;
    const hit = hitAt(driver, ctx.head, @floatCast(ev.x), @floatCast(ev.y));
    // Hover is frame input, kept for every event kind: a press or a release
    // moves it too (a click is where the pointer is).
    const moved = driver.ctx.hover.move(hit, core.task.nowNs());
    if (moved) driver.ctx.view_dirty.* = true;
    const mods: Pointer.Mods = .{ .ctrl = ev.mods.ctrl, .alt = ev.mods.alt, .shift = ev.mods.shift, .logo = ev.mods.logo };
    var name_buf: [32]u8 = undefined;
    switch (ev.kind) {
        .press => {
            // Where the PREVIOUS press went down, before this one replaces it:
            // a slow second click means something only on the same node.
            const prior = g.origin.node;
            // What the gesture's first click did holds through its later
            // clicks, and only through them.
            const began_edit = ev.clicks > 1 and g.began_edit;
            g.* = .{
                .began_edit = began_edit,
                .kind = .press,
                .button = ev.button,
                .clicks = ev.clicks,
                .slow = ev.slow,
                .prior = prior,
                .mods = mods,
                .hit = hit,
                .origin = hit,
            };
            return dispatchGesture(ctx, mods, Pointer.gestureName(&name_buf, .press, ev.button, ev.clicks));
        },
        .release => {
            g.kind = .release;
            g.button = ev.button;
            g.mods = mods;
            g.hit = hit;
            return dispatchGesture(ctx, mods, Pointer.gestureName(&name_buf, .release, ev.button, 0));
        },
        .motion => {
            g.hit = hit;
            if (ev.held == 0) {
                // Hover: the facts move, nothing is dispatched — except to an
                // open interaction that asked to hear it (a menu's highlight
                // follows the pointer), once per new target.
                g.kind = .hover;
                return moved and hoverInteraction(ctx);
            }
            const button: u8 = @intCast(@ctz(ev.held) + 1);
            g.kind = .drag;
            g.button = button;
            g.mods = mods;
            return dispatchGesture(ctx, mods, Pointer.gestureName(&name_buf, .drag, button, 0));
        },
        .wheel => {
            g.kind = .wheel;
            g.mods = mods;
            g.hit = hit;
            var any = false;
            // One dispatch per step, so a binding is a per-notch action and
            // a fast flick is several of them.
            const axes = [_]struct { steps: i32, neg: Pointer.WheelDir, pos: Pointer.WheelDir }{
                .{ .steps = ev.dy, .neg = .up, .pos = .down },
                .{ .steps = ev.dx, .neg = .left, .pos = .right },
            };
            for (axes) |a| {
                const dir = if (a.steps < 0) a.neg else a.pos;
                for (0..@abs(a.steps)) |_| {
                    if (try dispatchGesture(ctx, mods, Pointer.wheelName(dir))) any = true;
                }
            }
            return any;
        },
    }
}

/// Hand the active interaction its `hover` input, when it binds one by name.
/// Not a keystroke: no macro, dot-repeat or key serial sees it — only the
/// interaction's own binding table (`Services.invokeInteractionInput`).
fn hoverInteraction(ctx: *core.command.Context) bool {
    const services = ctx.semantic orelse return false;
    const active = ctx.head.interactions.active() orelse return false;
    if (!active.binds(Pointer.hover_input)) return false;
    ctx.user_initiated = true;
    defer ctx.user_initiated = false;
    _ = services.invokeInteractionInput(&ctx.head.interactions, ctx.head, ctx.gpa, Pointer.hover_input) catch |err| {
        std.log.warn("interaction hover failed: {t}", .{err});
        return false;
    };
    return true;
}

fn dispatchGesture(ctx: *core.command.Context, mods: Pointer.Mods, name: []const u8) !bool {
    if (name.len == 0) return false;
    var spec_buf: [48]u8 = undefined;
    const spec = core.Keymap.keyspec(&spec_buf, mods.ctrl, mods.alt, mods.shift, name);
    try dispatch.dispatchSpec(ctx, spec, .none);
    return true;
}

/// What is under (x, y), from the last built frame.
pub fn hitAt(driver: *frame.Driver, head: *core.Head, x: f32, y: f32) Pointer.Hit {
    var hit: Pointer.Hit = .{ .x = x, .y = y };
    const map = driver.view.paneAtPoint(x, y) orelse return hit;
    const gen = driver.layout.paneGen(map.pane) orelse return hit;
    const node = driver.layout.resolvePane(map.pane, gen) orelse return hit;
    hit.pane = .{ .id = map.pane, .gen = gen };
    hit.entry = node.pane().buffer_id;
    hit.focused = node == window_layout.headFocus(driver.layout, head);
    // On the pane's floating overlay, the point is on that alone.
    if (map.float) |f| if (f.contains(x, y)) {
        if (map.hitAt(x, y)) |h| hit.node = .{ .view = h.view, .node = h.node };
        return hit;
    };
    // On the chrome (a tab, a status segment), the point is on THAT, not on
    // the text or scene the pane shows beneath the strip.
    if (map.chromeAt(x, y)) |c| {
        var chrome: Pointer.Chrome = .{
            .kind = switch (c.kind) {
                .tab => .tab,
                .status => .status,
            },
            .index = std.math.cast(u16, c.index) orelse std.math.maxInt(u16),
            .part = switch (c.part) {
                .body => .body,
                .close => .close,
            },
            .entry = c.entry,
            .acts_in = if (c.pane) |id| if (driver.layout.paneGen(id)) |g| .{ .id = id, .gen = g } else null else null,
        };
        chrome.setCommand(c.command);
        hit.chrome = chrome;
        return hit;
    }
    hit.offset = map.offsetAt(x, y);
    if (map.hitAt(x, y)) |h| hit.node = .{ .view = h.view, .node = h.node };
    return hit;
}

// ── The Panes door ──────────────────────────────────────────────────

pub fn panesDoor(driver: *frame.Driver) Pointer.Panes {
    return .{ .context = driver, .focus = focusPane, .scroll = scrollPane, .vertical = verticalMove };
}

/// `cursor.up`/`cursor.down` in a text pane: one visual line, goal column
/// held, over the view the frame last built.
fn verticalMove(raw: *anyopaque, ctx: *core.command.Context, dir: i32) bool {
    const ed = ctx.textEditor() catch return false;
    dispatch.visualVertical(ed, driverOf(raw).view, dir) catch return false;
    return true;
}

fn driverOf(raw: *anyopaque) *frame.Driver {
    return @ptrCast(@alignCast(raw));
}

/// Focus `pane` now, synchronously, so the command that asked can act in it
/// within the same dispatch. The same steps the window commands' deferred
/// focus takes: save the live scroll into the pane being left, move the
/// head's focus, and let the active entry follow.
fn focusPane(raw: *anyopaque, ctx: *core.command.Context, pane: Pointer.PaneRef) bool {
    const driver = driverOf(raw);
    const node = driver.layout.resolvePane(pane.id, pane.gen) orelse return false;
    const focused = window_layout.headFocus(driver.layout, ctx.head);
    if (node == focused) return true;
    // A strip of buttons acts through; the keys stay where they were.
    if (!node.pane().attrs.takes_focus) return false;
    focused.pane().top_row = driver.view.top_row;
    window_layout.setHeadFocus(ctx.head, node, driver.layout);
    window_cmds.applyWindowFocus(driver.layout, driver.view, ctx.buffers, ctx.gpa, ctx.head, ctx.keymap);
    driver.ctx.view_dirty.* = true;
    return true;
}

/// Scroll `pane` by `rows`. The view keeps what the pane focuses on screen
/// every frame, so scrolling away from the caret moves the caret with it
/// (into the first or last visible row), and in a scene moves the focused
/// row. An unfocused scene has no focus of this head's to move, so it does
/// not scroll.
fn scrollPane(raw: *anyopaque, ctx: *core.command.Context, pane: Pointer.PaneRef, rows: i32) void {
    const driver = driverOf(raw);
    const node = driver.layout.resolvePane(pane.id, pane.gen) orelse return;
    const is_focused = node == window_layout.headFocus(driver.layout, ctx.head);
    const p = node.pane();
    const buffer = ctx.buffers.get(p.buffer_id) orelse return;
    driver.ctx.view_dirty.* = true;
    const ed = buffer.textEditor() orelse {
        if (!is_focused) return;
        const services = ctx.semantic orelse return;
        for (0..@abs(rows)) |_| {
            _ = services.moveHeadFocus(ctx.head, ctx.gpa, if (rows < 0) .previous else .next) catch return;
        }
        return;
    };
    const top: *usize = if (is_focused) &driver.view.top_row else &p.top_row;
    const rope = ed.text();
    const last = rope.lineCount() -| 1;
    top.* = if (rows < 0) top.* -| @abs(rows) else @min(top.* + @abs(rows), last);
    const visible = paneRows(driver, pane.id);
    const cur = rope.offsetToPoint(ed.cursorOffset()).row;
    if (cur < top.*) {
        ed.placeCursor(rope.lineRange(top.*).start);
    } else if (cur >= top.* + visible) {
        ed.placeCursor(rope.lineRange(@min(top.* + visible - 1, last)).start);
    }
}

/// How many text rows `pane` showed last frame; the focused pane's body
/// height before its first frame.
fn paneRows(driver: *frame.Driver, pane: u32) usize {
    for (driver.view.pane_maps[0..driver.view.pane_map_count]) |m| {
        if (m.pane == pane and m.lines.lines.len > 0) return m.lines.lines.len;
    }
    return driver.view.bodyRows();
}
