//! Type-ahead over a scene's rows (doc/chrome.md §5.2): under `row`
//! granularity a printable key nothing bound jumps to the next row whose
//! label starts with what was typed. Core's, over ANY rows — a listing, the
//! problems list, an outline, the dashboard — and asks nothing of the
//! projection but its scene: a row's label is its primary field's text, else
//! the text its focusable node shows.
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
const task = @import("task.zig");

/// How long a pause ends a prefix — the common desktop value.
pub const window_ns: u64 = std.time.ns_per_s;

/// One head's prefix in progress. `at_ns` is when its last key came.
pub const State = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,
    at_ns: u64 = 0,
    view: ?semantic.view.Ref = null,

    pub fn prefix(self: *const State) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Take `bytes`, a printable commit no binding claimed, as type-ahead. True
/// when a row-focused scene consumed it (whether or not a row matched);
/// false where type-ahead does not apply — a `text` granularity grammar, an
/// edit in progress, no scene focused.
pub fn feed(ctx: *command.Context, bytes: []const u8) !bool {
    return feedAt(ctx, bytes, task.nowNs());
}

pub fn feedAt(ctx: *command.Context, bytes: []const u8, now_ns: u64) !bool {
    const services = ctx.semantic orelse return false;
    if (services.granularity != .row) return false;
    const selection = &ctx.head.scene_selection;
    if (selection.field != null) return false;
    const path = selection.path() orelse return false;
    const instance = services.views.get(path.view) orelse return false;
    const state = &ctx.head.type_ahead;
    const same_view = if (state.view) |v| v.eql(path.view) else false;
    if (!same_view or now_ns -| state.at_ns > window_ns) state.len = 0;
    state.at_ns = now_ns;
    state.view = path.view;
    const room = state.buf.len - state.len;
    const taken = @min(room, bytes.len);
    @memcpy(state.buf[state.len..][0..taken], bytes[0..taken]);
    state.len += taken;

    const order = instance.focus_order;
    if (order.len == 0) return true;
    const typed = state.prefix();
    // `a`, `a a`, `a a a`: one letter steps through the rows it starts.
    const repeating = for (typed[1..]) |c| {
        if (c != typed[0]) break false;
    } else true;
    const needle = if (repeating) typed[0..1] else typed;
    const here = std.mem.indexOfScalar(semantic.scene.NodeId, order, path.leaf() orelse order[0]) orelse 0;
    const start = if (repeating) here + 1 else here;
    for (0..order.len) |step| {
        const at = (start + step) % order.len;
        if (!try startsWith(ctx.gpa, services, instance, order[at], needle)) continue;
        _ = try services.focusView(ctx.head, ctx.gpa, path.view, order[at]);
        return true;
    }
    return true;
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
