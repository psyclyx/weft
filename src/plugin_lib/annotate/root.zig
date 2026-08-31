//! annotate — the guest half of `ui/pick-annotate`: the slot's schema, the
//! reader for a round's question, and the one-call answer.
//!
//! An annotator is a plugin that binds a slot core declares, decodes an `ask`
//! against a schema, and pushes a `tell`. Two plugins already do that
//! (`marginalia` for files/buffers/commands, `lsp` for completion kinds), and
//! a third-party one would too — so the schema, the variant tags, and the
//! answer-encoding live here once instead of being transcribed into each.
//!
//! **The schema is RESTATED, not imported from core.** A guest cannot reach
//! into `core/pick/annotate.zig`, and should not be able to: the wire shape is
//! the contract, and a library that could only exist by reaching across the
//! membrane would prove nothing about whether a real third-party annotator
//! could be written. If the two ever drift, the decode fails closed — a note
//! is simply not produced — because every `enterVariant`/`field` validates
//! against the tree it was handed.

const std = @import("std");
const weft = @import("weft");
const schema = weft.schema;

/// The slot an annotator binds. Core declares it; a guest never should
/// (`Container.declareSlot` keeps the first declaration anyway, so a second
/// one is a confusing no-op rather than an error).
pub const slot = "ui/pick-annotate";

const str_ty: schema.Schema = .str;
const u32_ty: schema.Schema = .{ .scalar = .u32 };

const row_fields = [_]schema.Schema.Field{
    .{ .name = "text", .ty = &str_ty },
    .{ .name = "key", .ty = &str_ty },
};
const row_ty: schema.Schema = .{ .@"struct" = &row_fields };
const rows_ty: schema.Schema = .{ .array = &row_ty };

const ask_fields = [_]schema.Schema.Field{
    .{ .name = "category", .ty = &str_ty },
    .{ .name = "from", .ty = &u32_ty },
    .{ .name = "rows", .ty = &rows_ty },
};
const ask_ty: schema.Schema = .{ .@"struct" = &ask_fields };

const notes_ty: schema.Schema = .{ .array = &str_ty };
const tell_fields = [_]schema.Schema.Field{
    .{ .name = "from", .ty = &u32_ty },
    .{ .name = "notes", .ty = &notes_ty },
};
const tell_ty: schema.Schema = .{ .@"struct" = &tell_fields };

const cases = [_]schema.Schema.Case{
    .{ .name = "ask", .ty = &ask_ty },
    .{ .name = "tell", .ty = &tell_ty },
};

pub const annotate_schema: schema.Schema = .{ .variant = &cases };

const tag_ask = 0;
const tag_tell = 1;

/// Bind this plugin as an annotator. `.all`, not a mode predicate: eligibility
/// is by CATEGORY, which rides the payload, and a pick's facts report mode
/// `"pick"` whatever kind of pick it is — so a mode predicate would either
/// match everything or nothing.
pub fn bind() void {
    weft.slotBind(slot, .all, .plugin, 0);
}

/// One round's question. `rows` walks the offered rows in order.
pub const Ask = struct {
    category: []const u8,
    from: u32,
    rows: schema.ArrayCursor,

    /// The next row's `(text, key)`, or null when the round is exhausted. The
    /// key is what an annotator resolves by — the text is display, and for a
    /// buffer row (`"3: foo.zig [ro] *"`) parsing it back into an identity is
    /// exactly the mistake the key exists to prevent.
    pub fn next(self: *Ask) ?Row {
        const row = (self.rows.next() catch return null) orelse return null;
        const rs = row.enterStruct() catch return null;
        const text_cur = (rs.field("text") catch return null) orelse return null;
        const key_cur = (rs.field("key") catch return null) orelse return null;
        return .{
            .text = text_cur.asStr() catch return null,
            .key = key_cur.asStr() catch return null,
        };
    }
};

pub const Row = struct { text: []const u8, key: []const u8 };

/// Read the round `session` is asking about. Null — never an error — for
/// anything that is not an `ask`: an empty payload, a `tell` (core asking the
/// wrong question, or a payload that is not what we think), a shape mismatch.
/// A provider that cannot read the question answers nothing, which is a
/// normal outcome for a raced slot.
pub fn ask(session: u32) ?Ask {
    const request = weft.payloadRead(session);
    if (request.len == 0) return null;
    const cur = schema.decodeCursor(&annotate_schema, request);
    const variant = cur.enterVariant() catch return null;
    if (variant.tag != tag_ask) return null;
    const s = variant.selected().enterStruct() catch return null;
    const category_cur = (s.field("category") catch return null) orelse return null;
    const from_cur = (s.field("from") catch return null) orelse return null;
    const rows_cur = (s.field("rows") catch return null) orelse return null;
    return .{
        .category = category_cur.asStr() catch return null,
        .from = from_cur.asU32() catch return null,
        .rows = rows_cur.enterArray() catch return null,
    };
}

/// Answer the round: `notes[i]` annotates the row at `from + i`. An empty
/// note means "nothing to say about this one" and costs the row nothing.
///
/// Not answering at all is also fine, and is the right move for a category
/// this plugin does not understand — a set of empty notes and no answer read
/// the same downstream, but declining is cheaper and says what it means.
pub fn tell(session: u32, from: u32, notes: []const []const u8) void {
    const values = weft.allocator.alloc(schema.Value, notes.len) catch return;
    defer weft.allocator.free(values);
    for (values, notes) |*v, n| v.* = .{ .str = n };
    const tell_values = [_]schema.Value{
        .{ .scalar = .{ .u32 = from } },
        .{ .array = values },
    };
    const payload: schema.Value = .{ .@"struct" = &tell_values };
    weft.payloadPush(session, 1, &annotate_schema, .{
        .variant = .{ .tag = tag_tell, .payload = &payload },
    });
}
