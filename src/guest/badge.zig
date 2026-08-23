//! badge (D2 test fixture, doc/d2-schema-payloads.md §6's worked example —
//! non-install: exercised only by the wasm-membrane suite, never shipped).
//! A third-party "CI status" plugin that declares a NOVEL `ui/badge` slot
//! with a NOVEL result shape core has no type for, binds a provider, and
//! answers fires with schema-encoded payloads. Proves the whole D2 crossing
//! live: declare -> bind -> fire -> push -> decode, with a restamped
//! `range` field and a passthrough `anchor` field, no core recompile
//! anywhere in the loop — see `src/core/wasm_abi/tests.zig`'s "D2" test for
//! the host-side consumer half.

const weft = @import("weft.zig");
const schema = weft.schema;

// The slot's schema (§6 step 1). Extended one field beyond the design doc's
// minimal `{text, count, where}` example with a `loc: range` field — see
// this repo's D2 slice report: a `range`-marked field gives the restamp
// assertion (§4's "on_range live on the new path") something real to check,
// not just a passthrough `anchor`.
const str_ty: schema.Schema = .str;
const u32_ty: schema.Schema = .{ .scalar = .u32 };
const anchor_ty: schema.Schema = .anchor;
const range_ty: schema.Schema = .range;
const fields = [_]schema.Schema.Field{
    .{ .name = "text", .ty = &str_ty },
    .{ .name = "count", .ty = &u32_ty },
    .{ .name = "where", .ty = &anchor_ty },
    .{ .name = "loc", .ty = &range_ty },
};
pub const badge_schema: schema.Schema = .{ .@"struct" = &fields };

export fn describe() void {}

export fn init() void {
    weft.slotDeclare("ui/badge", .query, .ordered_union, &badge_schema);
    weft.slotBind("ui/badge", .all, .plugin, 0);
}

export fn on_slot_fire(session: i32) void {
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
