//! Test fixture ONLY (not installed — see build.zig's `guests` table): a
//! toolbar-shaped consumer of the action-system doors (doc/configs.md §3.5),
//! with no toolbar in it — just the three things a toolbar does, each a
//! command a test can drive and read:
//!
//!   - `on_context_changed`: counts deliveries and keeps the moved keys. A
//!     toolbar would re-read its offers and redraw here; the count is what
//!     proves the event fires once per change and never on a quiet frame.
//!   - `ow.fired`: that count, as the command's integer result.
//!   - `ow.keys`: the last delivery's moved keys, comma-joined.
//!   - `ow.context-set <key> <value> <scope>` / `ow.context-get <key>`:
//!     `wl_context_set` ("ok", "held", "refused") and `wl_context_get` (the
//!     value, or "<unset>").
//!   - `ow.list <where>`: `wl_offers_list` for context `where` (0 active, 1
//!     primary), one `intention|provider|availability|reason|label|group|order`
//!     line per offer, as the command's string result.
//!   - `ow.invoke <where> <intention>`: `wl_intent_invoke_at` — "invoked",
//!     "unknown", or the refusal text.
//!   - `ow.provide`: provides `plugin.offerwatch.probe` and labels it through
//!     `wl_provide_affordance`, so the presentation override is observable.
//!
//! No permissions: reading offers and invoking one through the effect door
//! grant nothing the invoked verb does not already check.

const std = @import("std");
const weft = @import("weft");

var fired: i32 = 0;
var out: [1 << 15]u8 = undefined;
var keys_buf: [1024]u8 = undefined;
var keys_len: usize = 0;

fn onContextChanged() callconv(.c) void {
    fired += 1;
    var w: std.Io.Writer = .fixed(&keys_buf);
    var keys = weft.contextChanged();
    var first = true;
    while (keys.next()) |k| {
        if (!first) w.writeAll(",") catch break;
        w.writeAll(k) catch break;
        first = false;
    }
    keys_len = w.buffered().len;
}

fn firedCount() void {
    weft.setResultInt(fired);
}

fn lastKeys() void {
    weft.setResultStr(keys_buf[0..keys_len]);
}

var arg_bufs: [3][1024]u8 = undefined;

/// Copy argument `i` out of the SDK's scratch, which the next read reuses.
fn arg(i: usize) []const u8 {
    const raw = weft.argStr(i) orelse "";
    const n = @min(raw.len, arg_bufs[i].len);
    @memcpy(arg_bufs[i][0..n], raw[0..n]);
    return arg_bufs[i][0..n];
}

fn contextSet() void {
    const key = arg(0);
    const value = arg(1);
    const scope = std.meta.stringToEnum(weft.ContextScope, arg(2)) orelse return weft.setResultStr("refused");
    weft.contextSet(key, value, scope) catch |err| return weft.setResultStr(switch (err) {
        error.Held => "held",
        error.Refused => "refused",
    });
    weft.setResultStr("ok");
}

fn contextGet() void {
    weft.setResultStr(weft.contextGet(arg(0)) orelse "<unset>");
}

/// `contextSetAt(key, value, place)`: the same publication at a place named
/// by its designation.
fn contextSetAt() void {
    const key = arg(0);
    const value = arg(1);
    const place = arg(2);
    weft.contextSetAt(key, value, place) catch |err| return weft.setResultStr(switch (err) {
        error.Held => "held",
        error.Refused => "refused",
    });
    weft.setResultStr("ok");
}

/// The designation doors, answered as a test reads them.
fn designation() void {
    weft.setResultStr(weft.designation() orelse "<none>");
}
fn designate() void {
    weft.setResultStr(if (weft.designate(arg(0))) "ok" else "refused");
}
/// An entry this plugin makes (and focuses), by name.
fn create() void {
    weft.focusOrCreateBuffer(arg(0));
}
fn claim() void {
    const kind = arg(0);
    weft.setResultStr(if (weft.designationOpener(kind, arg(1))) "ok" else "refused");
}

fn whereArg(i: usize) weft.OfferContext {
    return if (weft.argInt(i) == 1) .primary else .active;
}

fn list() void {
    var offers = weft.offersIn(whereArg(0));
    var w: std.Io.Writer = .fixed(&out);
    while (offers.next()) |o| {
        w.print("{s}|{s}|{t}|{s}|{s}|{s}|", .{ o.intention, o.provider, o.availability, o.reason, o.label, o.group }) catch break;
        if (o.order) |n| w.print("{d}", .{n}) catch break;
        w.writeAll("\n") catch break;
    }
    weft.setResultStr(w.buffered());
}

var name_buf: [256]u8 = undefined;

fn invoke() void {
    const where = whereArg(0);
    const raw = weft.argStr(1) orelse return;
    const n = @min(raw.len, name_buf.len);
    @memcpy(name_buf[0..n], raw[0..n]);
    weft.setResultStr(switch (weft.invokeIntentionIn(where, name_buf[0..n])) {
        .invoked => "invoked",
        .unknown => "unknown",
        .refused => |why| why,
    });
}

fn probe() void {}

fn provideProbe() void {
    weft.provide("plugin.offerwatch.probe", .{ .all = &.{} }, "ow.probe", 0);
    weft.setResultInt(@intCast(weft.provideAffordance("plugin.offerwatch.probe", .{
        .label = "Probe",
        .group = "watch",
        .order = 5,
    })));
}

const cmds = [_]weft.CommandEntry{
    .{ .name = "ow.fired", .arity = .one, .call = firedCount, .summary = "Exercise the ow.fired fixture command.", .internal = true },
    .{ .name = "ow.keys", .arity = .one, .call = lastKeys, .summary = "Exercise the ow.keys fixture command.", .internal = true },
    .{ .name = "ow.context-set", .arity = .one, .call = contextSet, .summary = "Exercise the ow.context-set fixture command.", .internal = true },
    .{ .name = "ow.context-get", .arity = .one, .call = contextGet, .summary = "Exercise the ow.context-get fixture command.", .internal = true },
    .{ .name = "ow.context-set-at", .arity = .one, .call = contextSetAt, .summary = "Exercise the ow.context-set-at fixture command.", .internal = true },
    .{ .name = "ow.designation", .arity = .one, .call = designation, .summary = "Exercise the ow.designation fixture command.", .internal = true },
    .{ .name = "ow.designate", .arity = .one, .call = designate, .summary = "Exercise the ow.designate fixture command.", .internal = true },
    .{ .name = "ow.create", .arity = .one, .call = create, .summary = "Exercise the ow.create fixture command.", .internal = true },
    .{ .name = "ow.claim", .arity = .one, .call = claim, .summary = "Exercise the ow.claim fixture command.", .internal = true },
    .{ .name = "ow.list", .arity = .one, .call = list, .summary = "Exercise the ow.list fixture command.", .internal = true },
    .{ .name = "ow.invoke", .arity = .one, .call = invoke, .summary = "Exercise the ow.invoke fixture command.", .internal = true },
    .{ .name = "ow.probe", .arity = .one, .call = probe, .summary = "Exercise the ow.probe fixture command.", .internal = true },
    .{ .name = "ow.provide", .arity = .one, .call = provideProbe, .summary = "Exercise the ow.provide fixture command.", .internal = true },
};

comptime {
    weft.plugin(&cmds, .{}).exportAll();
    weft.exportCallback("on_context_changed", &onContextChanged);
}
