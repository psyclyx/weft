//! Type-ahead over rows (doc/chrome.md §5.2): under `row` granularity a
//! printable key nothing bound jumps to the next row whose label starts with
//! what was typed. Core's, over ANY rows — a listing, the problems list, an
//! outline, the dashboard, and a text projection's rows (git status, grep
//! results) — and asks nothing of a producer but what it already said:
//!
//!   - a scene row's label is its primary field's text, else the text its
//!     focusable node shows;
//!   - a text projection's row is a focusable node, and its label is the
//!     row's subject (`projection.Node.label`).
//!
//! The list-control convention, exactly: keys typed within `window_ns` of
//! each other accumulate into one prefix, searched from the focused row on
//! (so `m` then `a` stays on `main.zig` once `m` found it); one key, or the
//! same key again and again, steps to the NEXT row it starts; the search
//! wraps; case is ignored.

const std = @import("std");
const semantic = @import("weft_semantic");
const view_runtime = @import("weft_view_runtime");
const command = @import("command.zig");
const projection = @import("projection.zig");
const Buffers = @import("Buffers.zig");
const Head = @import("Head.zig");
const Keymap = @import("Keymap.zig");
const Services = @import("semantic.zig").Services;
const scene_edit = @import("scene_edit.zig");
const task = @import("task.zig");

/// How long a pause ends a prefix — the common desktop value.
pub const window_ns: u64 = std.time.ns_per_s;

/// Which rows a prefix is being typed over: a scene's, or a text
/// projection's entry's.
pub const Over = union(enum) {
    view: semantic.view.Ref,
    entry: Buffers.Ref,

    fn eql(a: Over, b: Over) bool {
        return switch (a) {
            .view => |v| b == .view and v.eql(b.view),
            .entry => |e| b == .entry and std.meta.eql(e, b.entry),
        };
    }
};

/// One head's prefix in progress. `at_ns` is when its last key came.
pub const State = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,
    at_ns: u64 = 0,
    over: ?Over = null,

    pub fn prefix(self: *const State) []const u8 {
        return self.buf[0..self.len];
    }

    /// Take `bytes` into the prefix typed over `over`, starting a fresh one
    /// after a pause or on other rows.
    fn take(self: *State, over: Over, bytes: []const u8, now_ns: u64) void {
        const same = if (self.over) |o| o.eql(over) else false;
        if (!same or now_ns -| self.at_ns > window_ns) self.len = 0;
        self.at_ns = now_ns;
        self.over = over;
        const taken = @min(self.buf.len - self.len, bytes.len);
        @memcpy(self.buf[self.len..][0..taken], bytes[0..taken]);
        self.len += taken;
    }

    /// What to search for, and whether the search starts past the focused
    /// row: `a`, `a a`, `a a a` — one letter steps through the rows it starts.
    fn needle(self: *const State) struct { text: []const u8, step: bool } {
        const typed = self.prefix();
        const repeating = for (typed[1..]) |c| {
            if (c != typed[0]) break false;
        } else true;
        return if (repeating) .{ .text = typed[0..1], .step = true } else .{ .text = typed, .step = false };
    }
};

/// Whether ROWS take a printable key nothing bound — the one answer dispatch
/// (type-ahead, `feed`) and the frame (a focused row shown, not a caret)
/// both read, so they cannot disagree. Rows take a key only where nothing
/// else would: the head's mode focuses rows (`row` granularity), no text
/// commit claims the key there (`scene_edit.textCommit`: a picker's query,
/// a prompt's line, snipe's character, a begun edit), no picker or
/// interaction holds the keys, and rows are focused — a scene's, or a text
/// projection's with point on no editable span. Asked before any row moves,
/// never after: a key a line would have taken is the line's.
pub fn rowsTakeKeys(services: *const Services, km: *const Keymap, head: *const Head, entry: *Buffers.Buffer) bool {
    const mode = head.currentMode();
    if (services.granularityIn(mode) != .row) return false;
    if (head.pick.active or head.interactions.active() != null) return false;
    const scene = head.scene_selection.path() != null;
    if (scene_edit.textCommit(services, km, head, mode) != null) {
        // A focused scene holds none of its entry's text: the commit a
        // RESTING mode declares (the grammar's own typing — ide's `ide`,
        // where a scene hosted by a text entry rests) is that text's, and
        // yields to the rows. A mode ENTERED over them that commits — the
        // picker's query, a prompt's line, snipe's character — and a begun
        // edit claim the key.
        const yields = scene and head.scene_selection.edit == null and km.modeHasTag(mode, Keymap.tag_resting);
        if (!yields) return false;
    }
    if (scene) return head.scene_selection.edit == null;
    return entry.projection != null and !entry.fieldAtPoint();
}

/// Take `bytes`, a printable commit no binding claimed, as type-ahead. True
/// when rows took it (`rowsTakeKeys`), whether or not a row matched; false
/// where they do not, and the key is someone else's.
pub fn feed(ctx: *command.Context, bytes: []const u8) !bool {
    return feedAt(ctx, bytes, task.nowNs());
}

pub fn feedAt(ctx: *command.Context, bytes: []const u8, now_ns: u64) !bool {
    const services = ctx.semantic orelse return false;
    const entry = ctx.entry() orelse return false;
    if (!rowsTakeKeys(services, ctx.keymap, ctx.head, entry)) return false;
    const selection = &ctx.head.scene_selection;
    if (selection.path()) |path| {
        const instance = services.views.get(path.view) orelse return false;
        return feedScene(ctx, services, instance, path, bytes, now_ns);
    }
    const view = entry.projection orelse return false;
    const ed = entry.textEditor() orelse return false;
    const state = &ctx.head.type_ahead;
    state.take(.{ .entry = entry.ref() }, bytes, now_ns);
    return feedText(ctx.gpa, view, ed, state.needle());
}

fn feedScene(
    ctx: *command.Context,
    services: anytype,
    instance: *const view_runtime.view.Instance,
    path: semantic.focus.Path,
    bytes: []const u8,
    now_ns: u64,
) !bool {
    const state = &ctx.head.type_ahead;
    state.take(.{ .view = path.view }, bytes, now_ns);
    const order = instance.focus_order;
    if (order.len == 0) return true;
    const want = state.needle();
    const here = std.mem.indexOfScalar(semantic.scene.NodeId, order, path.leaf() orelse order[0]) orelse 0;
    const start = if (want.step) here + 1 else here;
    for (0..order.len) |step| {
        const at = (start + step) % order.len;
        if (!try startsWith(ctx.gpa, services, instance, order[at], want.text)) continue;
        _ = try services.focusView(ctx.head, ctx.gpa, path.view, order[at]);
        return true;
    }
    return true;
}

/// A text projection's rows are its focusable nodes a person can see (none
/// under a collapsed ancestor), in document order; point moves to where it
/// rests on the matching one.
fn feedText(gpa: std.mem.Allocator, view: *const projection.View, ed: anytype, want: anytype) !bool {
    var rows: std.ArrayList(*const projection.Node) = .empty;
    defer rows.deinit(gpa);
    for (view.nodes.items) |*n| {
        if (n.focusable and !hidden(view, n)) try rows.append(gpa, n);
    }
    if (rows.items.len == 0) return true;
    const at = ed.cursorOffset();
    var here: usize = 0;
    for (rows.items, 0..) |n, i| {
        if (n.start <= at) here = i;
    }
    const start = if (want.step) here + 1 else here;
    for (0..rows.items.len) |step| {
        const row = rows.items[(start + step) % rows.items.len];
        if (!std.ascii.startsWithIgnoreCase(row.label(), want.text)) continue;
        ed.moveTo(row.restingOffset(null));
        ed.clearGoal();
        return true;
    }
    return true;
}

/// Whether a collapsed ancestor hides `node`.
fn hidden(view: *const projection.View, node: *const projection.Node) bool {
    var parent = node.parent;
    while (parent) |i| {
        if (i >= view.nodes.items.len) return false;
        const p = &view.nodes.items[i];
        if (view.isCollapsed(p.key)) return true;
        parent = p.parent;
    }
    return false;
}

fn startsWith(
    gpa: std.mem.Allocator,
    services: anytype,
    instance: *const view_runtime.view.Instance,
    node: semantic.scene.NodeId,
    needle: []const u8,
) !bool {
    var storage: [1026]semantic.scene.NodeId = undefined;
    const path = (try instance.focusPath(node, &storage)) orelse return false;
    if (instance.primaryField(path)) |primary| {
        const provider = services.fields.get(primary.ref) orelse return false;
        var snapshot = provider.snapshot(gpa) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return false,
        };
        defer snapshot.deinit();
        return std.ascii.startsWithIgnoreCase(snapshot.value.bytes, needle);
    }
    const shown = instance.node(node) orelse return false;
    const label = switch (shown.content) {
        .label => |text| text,
        .action => |action| if (action.label.len != 0) action.label else action.action,
        .field, .container => return false,
    };
    return std.ascii.startsWithIgnoreCase(std.mem.trimStart(u8, label, " "), needle);
}
