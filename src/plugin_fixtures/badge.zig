//! badge (D2 test fixture, doc/d2-schema-payloads.md §6's worked example —
//! non-install: exercised only by the wasm-membrane suite, never shipped).
//! A third-party "CI status" plugin that declares a NOVEL `ui/badge` slot
//! with a NOVEL result shape core has no type for, binds a provider, and
//! answers fires with schema-encoded payloads. Proves the whole D2 crossing
//! live: declare -> bind -> fire -> push -> decode, with a restamped
//! `range` field and a passthrough `anchor` field, no core recompile
//! anywhere in the loop — see `src/core/wasm_abi/tests.zig`'s "D2" test for
//! the host-side consumer half. Asked to (request bytes `act-…`), it also
//! acts from inside its answer — which it may: no fire happens while a frame
//! is drawn (doc/model.md §2.7), so what it does is just the next version.

const std = @import("std");
const weft = @import("weft");
const schema = weft.schema;

// The slot's schema (§6 step 1). Extended one field beyond the design doc's
// minimal `{text, count, where}` example with a `loc` field: an
// observation-path locator gives the restamp assertion something real to
// check, next to the effect-path `where` the host carries through.
const str_ty: schema.Schema = .str;
const u32_ty: schema.Schema = .{ .scalar = .u32 };
const fields = [_]schema.Schema.Field{
    .{ .name = "text", .ty = &str_ty },
    .{ .name = "count", .ty = &u32_ty },
    .{ .name = "where", .ty = &schema.anchor },
    .{ .name = "loc", .ty = &schema.range },
};
pub const badge_schema: schema.Schema = .{ .@"struct" = &fields };

fn describe() callconv(.c) void {}

fn init() callconv(.c) void {
    weft.slotDeclare("ui/badge", .query, .ordered_union, &badge_schema);
    weft.slotBind("ui/badge", .{ .all = &.{} }, .plugin, 0);

    // A second slot, bound with a predicate the old wire could not carry: a
    // DISJUNCTION over two axes' worth of leaves. Under the four-tag format a
    // binding was one leaf — `mode`, `ext`, `lang`, or `tool` — so a provider
    // that cared about "markdown or plain text" had to bind everything and
    // test inside itself, which put its interest on the wrong side of the
    // membrane. The host evaluates this one.
    weft.slotDeclare("ui/badge-docs", .query, .ordered_union, &badge_schema);
    weft.slotBind("ui/badge-docs", .{ .any = &.{
        .{ .ext = ".md" },
        .{ .ext = ".txt" },
    } }, .plugin, 0);
}

fn on_slot_fire(session: i32) callconv(.c) void {
    // A provider that ACTS from inside its answer, asked for with the request
    // bytes `act-…`. Answers are asked for between frames, so each of these
    // lands like any background entry's call would.
    const req = weft.payloadRead(@bitCast(session));
    if (std.mem.eql(u8, req, "act-edit")) weft.edit(.{ .start = 0, .end = 0 }, "ACTED");
    if (std.mem.eql(u8, req, "act-flash")) weft.flash(0, 1);
    if (std.mem.eql(u8, req, "act-run")) weft.run("edit.undo");
    const vals = [_]schema.Value{
        .{ .str = "3 failing" },
        .{ .scalar = .{ .u32 = 3 } },
        .{ .anchor = .{ .agent = "ci", .seq = 5, .side = 0 } },
        // A deliberately STALE claimed version — the host must never trust
        // it (§4): the e2e consumer asserts the DECODED version is the
        // fired session's, not this one.
        .{ .range = .{ .version = "stale-guest-claimed-version", .start = 10, .end = 14 } },
    };
    weft.payloadPush(@bitCast(session), 1, &badge_schema, .{ .@"struct" = &vals });
}

comptime {
    weft.exportCallback("describe", &describe);
    weft.exportCallback("init", &init);
    weft.exportCallback("on_slot_fire", &on_slot_fire);
}
