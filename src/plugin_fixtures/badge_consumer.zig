//! badge-consumer (test fixture — not installed): the CONSUMER half of D2's
//! worked example, and the proof that a plugin ecosystem is possible rather
//! than just a plugin catalog.
//!
//! `badge.zig` declares a NOVEL `ui/badge` slot core has no type for and
//! answers fires on it. This guest — a SEPARATE wasm module, in a separate
//! linear memory, sharing no code with it — ASKS the question and decodes
//! the answer:
//!
//!     weft.Fire.open("ui/badge", &.{})  ->  result(0)  ->  schema decode
//!
//! Nothing in core knows what a badge is. Nothing here knows who answers.
//! The two agree on a SCHEMA, the host resolves WHO by context, and the
//! payload crosses two membranes as bytes the host restamps but never
//! interprets. Before `wl_slot_fire` this could only have been spelled as
//! `weft.runStr("badge-please", ...)` with the answer flattened to a string
//! — untyped on both sides, and unresolvable by context.
//!
//! It deliberately re-declares the schema rather than importing badge's:
//! that is what a THIRD party would have to do (it has no build edge to
//! badge, and must not), so the test proves agreement-by-schema, not
//! agreement-by-shared-source.

const weft = @import("weft");
const schema = weft.schema;

const str_ty: schema.Schema = .str;
const u32_ty: schema.Schema = .{ .scalar = .u32 };
const fields = [_]schema.Schema.Field{
    .{ .name = "text", .ty = &str_ty },
    .{ .name = "count", .ty = &u32_ty },
    .{ .name = "where", .ty = &schema.anchor },
    .{ .name = "loc", .ty = &schema.range },
};
const badge_schema: schema.Schema = .{ .@"struct" = &fields };

var id_read: u32 = 0;

/// `"<provider>|<text>|<count>|<restamped version>"` — everything the
/// consumer learned, flattened for the host-side assertion. Held here rather
/// than echoed so the test reads a value instead of scraping an echo line.
var answer: [256]u8 = undefined;

export fn describe() void {
    weft.declareCommand("badge-read");
}

export fn init() void {
    id_read = weft.register("badge-read");
}

export fn on_command(id: u32) void {
    _ = id;
    const fire = weft.Fire.open("ui/badge", &.{}) orelse {
        weft.setResultStr("no-provider");
        return;
    };
    defer fire.deinit();
    if (fire.count() == 0) {
        weft.setResultStr("no-answer");
        return;
    }
    // Provider name FIRST: `result` and `provider` use separate scratch
    // buffers precisely so both can be held at once, but copying the short
    // one out immediately is the habit worth showing.
    const who = fire.provider(0) orelse "?";
    var who_buf: [64]u8 = undefined;
    const n_who = @min(who.len, who_buf.len);
    @memcpy(who_buf[0..n_who], who[0..n_who]);

    const payload = fire.result(0) orelse {
        weft.setResultStr("no-payload");
        return;
    };
    const decoded = decode(payload) catch {
        weft.setResultStr("undecodable");
        return;
    };

    var w: usize = 0;
    for ([_][]const u8{ who_buf[0..n_who], "|", decoded.text, "|" }) |part| {
        const n = @min(part.len, answer.len - w);
        @memcpy(answer[w .. w + n], part[0..n]);
        w += n;
    }
    if (w < answer.len) {
        answer[w] = '0' + @as(u8, @intCast(decoded.count % 10));
        w += 1;
    }
    for ([_][]const u8{ "|", decoded.version }) |part| {
        const n = @min(part.len, answer.len - w);
        @memcpy(answer[w .. w + n], part[0..n]);
        w += n;
    }
    weft.setResultStr(answer[0..w]);
}

const Badge = struct { text: []const u8, count: u32, version: []const u8 };

/// Read one answer against the schema both sides agreed on. A missing field
/// is `error.SchemaMismatch` like any other decode failure: the point of a
/// schema is that "the shape was not what we agreed" is one answer, not a
/// per-field ladder at the call site.
fn decode(payload: []const u8) !Badge {
    const cur = try schema.decodeCursor(&badge_schema, payload).enterStruct();
    const text = try (try cur.field("text") orelse return error.SchemaMismatch).asStr();
    const count = try (try cur.field("count") orelse return error.SchemaMismatch).asU32();
    const loc = try (try cur.field("loc") orelse return error.SchemaMismatch).asRange();
    return .{ .text = text, .count = count, .version = loc.version };
}
