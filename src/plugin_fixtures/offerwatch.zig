//! Test fixture ONLY (not installed — see build.zig's `guests` table): a
//! toolbar-shaped consumer of the action-system doors (doc/configs.md §3.5),
//! with no toolbar in it — just the three things a toolbar does, each a
//! command a test can drive and read:
//!
//!   - `on_offers_changed`: counts deliveries. A toolbar would re-read its
//!     offers and redraw here; the count is what proves the event fires once
//!     per relevant change and never on a quiet frame.
//!   - `ow-fired`: that count, as the command's integer result.
//!   - `ow-list <where>`: `wl_offers_list` for context `where` (0 active, 1
//!     primary), one `intention|provider|availability|reason|label|group|order`
//!     line per offer, as the command's string result.
//!   - `ow-invoke <where> <intention>`: `wl_intent_invoke_at` — "invoked",
//!     "unknown", or the refusal text.
//!   - `ow-provide`: provides `plugin.offerwatch.probe` and labels it through
//!     `wl_provide_affordance`, so the presentation override is observable.
//!
//! No permissions: reading offers and invoking one through the effect door
//! grant nothing the invoked verb does not already check.

const std = @import("std");
const weft = @import("weft");

var fired: i32 = 0;
var out: [1 << 15]u8 = undefined;

fn onOffersChanged() callconv(.c) void {
    fired += 1;
}

fn firedCount() void {
    weft.setResultInt(fired);
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
    weft.provide("plugin.offerwatch.probe", .{ .all = &.{} }, "ow-probe", 0);
    weft.setResultInt(@intCast(weft.provideAffordance("plugin.offerwatch.probe", .{
        .label = "Probe",
        .group = "watch",
        .order = 5,
    })));
}

const cmds = [_]weft.CommandEntry{
    .{ .name = "ow-fired", .call = firedCount },
    .{ .name = "ow-list", .call = list },
    .{ .name = "ow-invoke", .call = invoke },
    .{ .name = "ow-probe", .call = probe },
    .{ .name = "ow-provide", .call = provideProbe },
};

comptime {
    weft.plugin(&cmds, .{}).exportAll();
    weft.exportCallback("on_offers_changed", &onOffersChanged);
}
