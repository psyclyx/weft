//! The pick's annotation round — the `ui/pick-annotate` slot: its name, its
//! schema, and the encode/decode either side of it needs.
//!
//! **What core knows about annotation is entirely in this file, and it is one
//! string and one shape.** Core knows there is a slot called
//! `ui/pick-annotate`, that an `ask` carries a category and some rows and a
//! `tell` carries some notes, and that a note is display text beside a row.
//! It does not know what any category means, what a note should say, who may
//! write one, or that "file" and "buffer" are things. That is the same line
//! `edit/completion` already draws: core owns the exchange, a provider owns
//! the answer.
//!
//! **Why a slot instead of new pick doors.** `SlotHost` (`core/slot.zig`)
//! already is this mechanism: runtime-declared providers, eligibility by
//! predicate, a raced session, the restamp walk, teardown by owner prefix. A
//! bespoke `wl_pick_annotate_*` session would have been the `wl_caps_*` shape
//! that doc/d2-schema-payloads.md §5.3 has already named for demolition.
//! Building the new thing in the shape being retired is a regression with a
//! tidy diff. See doc/marginalia.md §3.1 for the two rejected alternatives.
//!
//! **One schema, both directions.** `SlotHost.push` walks a RESULT payload
//! against the same `SlotDecl.schema` it handed the request, so the schema
//! has to describe both halves. That is what `variant` is for: `ask` is what
//! core encodes, `tell` is what a provider answers. Neither side can send the
//! other's shape by accident, because the tag is part of the wire.

const std = @import("std");
const Allocator = std.mem.Allocator;

const schema_mod = @import("weft_schema");
const container_mod = @import("../container.zig");

pub const Schema = schema_mod.Schema;

/// The slot every pick annotation round fires at.
pub const slot_name = "ui/pick-annotate";

/// How many rows one round offers. A file pick streams thousands of
/// candidates; marshalling all of them every frame would be `O(n)` per frame
/// for the life of the pick. A round takes the next `batch` and the following
/// frame resumes where it stopped, so a long list annotates progressively —
/// which is also what it should look like.
pub const batch = 256;

// ── The schema tree ──────────────────────────────────────────────────
//
// Written out as static consts because `Schema` is a tree of pointers and
// `SlotDecl.schema` BORROWS it — the declarer keeps it alive for the slot's
// lifetime, and a `const` at file scope is the longest lifetime there is.

const str_ty: Schema = .str;
const u32_ty: Schema = .{ .scalar = .u32 };

/// One row offered for annotation: what the user sees, and a key an
/// annotator can resolve when the label is not one (`types.Entry.key`).
const row_fields = [_]Schema.Field{
    .{ .name = "text", .ty = &str_ty },
    .{ .name = "key", .ty = &str_ty },
};
const row_ty: Schema = .{ .@"struct" = &row_fields };
const rows_ty: Schema = .{ .array = &row_ty };

const ask_fields = [_]Schema.Field{
    .{ .name = "category", .ty = &str_ty },
    .{ .name = "from", .ty = &u32_ty },
    .{ .name = "rows", .ty = &rows_ty },
};
const ask_ty: Schema = .{ .@"struct" = &ask_fields };

const notes_ty: Schema = .{ .array = &str_ty };
const tell_fields = [_]Schema.Field{
    .{ .name = "from", .ty = &u32_ty },
    .{ .name = "notes", .ty = &notes_ty },
};
const tell_ty: Schema = .{ .@"struct" = &tell_fields };

const cases = [_]Schema.Case{
    .{ .name = "ask", .ty = &ask_ty },
    .{ .name = "tell", .ty = &tell_ty },
};

pub const schema: Schema = .{ .variant = &cases };

const tag_ask = 0;
const tag_tell = 1;

/// Declare the slot on `container`. Idempotent (`Container.declareSlot` keeps
/// the first declaration), so an embedder calling it twice is harmless.
///
/// Core declares this, rather than leaving it to whichever plugin wants to
/// annotate, for one reason: core has to DECODE the answers, and it can only
/// do that against a shape it knows. A plugin-declared schema would leave
/// core holding bytes it cannot read.
pub fn declare(container: *container_mod.Container) Allocator.Error!void {
    try container.declareSlot(.{
        .name = slot_name,
        .shape = .query,
        // Every eligible annotator contributes; priority orders them. Not
        // `first_wins` — two annotators saying different things about one row
        // is composition working, not a collision.
        .composition = .ordered_union,
        .schema = &schema,
    });
}

pub const Row = struct { text: []const u8, key: []const u8 };

/// Encode the `ask` half. Caller owns the bytes.
pub fn encodeAsk(gpa: Allocator, category: []const u8, from: usize, rows: []const Row) !?[]u8 {
    const from_u32 = std.math.cast(u32, from) orelse return null;
    const row_values = try gpa.alloc(schema_mod.Value, rows.len);
    defer gpa.free(row_values);
    // One flat backing array for the per-row field pairs, so the whole
    // encode is two allocations regardless of row count.
    const fields = try gpa.alloc(schema_mod.Value, rows.len * 2);
    defer gpa.free(fields);
    for (rows, 0..) |r, i| {
        fields[i * 2] = .{ .str = r.text };
        fields[i * 2 + 1] = .{ .str = if (r.key.len > 0) r.key else r.text };
        row_values[i] = .{ .@"struct" = fields[i * 2 .. i * 2 + 2] };
    }
    const ask_values = [_]schema_mod.Value{
        .{ .str = category },
        .{ .scalar = .{ .u32 = from_u32 } },
        .{ .array = row_values },
    };
    const ask: schema_mod.Value = .{ .@"struct" = &ask_values };
    return try schema_mod.encode(gpa, &schema, .{ .variant = .{ .tag = tag_ask, .payload = &ask } });
}

/// What a provider answered: the row index its first note is about, and the
/// notes. Borrowed from `bytes` — copy before the payload is freed.
pub const Tell = struct {
    from: u32,
    notes: schema_mod.ArrayCursor,
};

/// Decode a `tell`. `null` — never an error — for anything that is not one:
/// a provider that answered with an `ask`, a truncated payload, a shape that
/// does not match. A malformed answer is a provider that said nothing, which
/// is a normal outcome for a raced slot and not core's problem to report.
pub fn decodeTell(bytes: []const u8) ?Tell {
    const cur = schema_mod.decodeCursor(&schema, bytes);
    const variant = cur.enterVariant() catch return null;
    if (variant.tag != tag_tell) return null;
    const s = variant.selected().enterStruct() catch return null;
    const from_cur = (s.field("from") catch return null) orelse return null;
    const notes_cur = (s.field("notes") catch return null) orelse return null;
    return .{
        .from = from_cur.asU32() catch return null,
        .notes = notes_cur.enterArray() catch return null,
    };
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "ask/tell round-trip through the one shared schema" {
    const gpa = t.allocator;
    const rows = [_]Row{
        .{ .text = "3: main.zig *", .key = "src/main.zig" },
        .{ .text = "plain", .key = "" }, // empty key means "the text IS the key"
    };
    const asked = (try encodeAsk(gpa, "buffer", 7, &rows)).?;
    defer gpa.free(asked);

    // A provider decodes the ask against the same schema it answers with.
    const cur = schema_mod.decodeCursor(&schema, asked);
    const variant = try cur.enterVariant();
    try t.expectEqualStrings("ask", variant.caseName());
    const s = try variant.selected().enterStruct();
    try t.expectEqualStrings("buffer", try (try s.field("category")).?.asStr());
    try t.expectEqual(@as(u32, 7), try (try s.field("from")).?.asU32());
    var arr = try (try s.field("rows")).?.enterArray();
    try t.expectEqual(@as(usize, 2), arr.len());
    const r0 = try (try arr.next()).?.enterStruct();
    try t.expectEqualStrings("3: main.zig *", try (try r0.field("text")).?.asStr());
    try t.expectEqualStrings("src/main.zig", try (try r0.field("key")).?.asStr());
    // The degenerate case is filled in at encode, so a provider never has to
    // know the convention: an empty key arrives AS the text.
    const r1 = try (try arr.next()).?.enterStruct();
    try t.expectEqualStrings("plain", try (try r1.field("key")).?.asStr());

    // …and the answer comes back through the same schema, tagged the other way.
    const notes = [_]schema_mod.Value{ .{ .str = "zig  1.2K" }, .{ .str = "" } };
    const tell_values = [_]schema_mod.Value{ .{ .scalar = .{ .u32 = 7 } }, .{ .array = &notes } };
    const tell: schema_mod.Value = .{ .@"struct" = &tell_values };
    const answered = try schema_mod.encode(gpa, &schema, .{ .variant = .{ .tag = tag_tell, .payload = &tell } });
    defer gpa.free(answered);

    var decoded = decodeTell(answered).?;
    try t.expectEqual(@as(u32, 7), decoded.from);
    try t.expectEqual(@as(usize, 2), decoded.notes.len());
    try t.expectEqualStrings("zig  1.2K", try (try decoded.notes.next()).?.asStr());
}

test "a provider that answers with the wrong half, or with rubbish, said nothing" {
    const gpa = t.allocator;
    // An `ask` is a well-formed payload of this schema and still not an
    // answer — the tag is what makes the two undelegatable.
    const asked = (try encodeAsk(gpa, "file", 0, &.{})).?;
    defer gpa.free(asked);
    try t.expect(decodeTell(asked) == null);

    try t.expect(decodeTell(&.{}) == null);
    try t.expect(decodeTell(&[_]u8{ 0xff, 0xff, 0xff }) == null);
}
