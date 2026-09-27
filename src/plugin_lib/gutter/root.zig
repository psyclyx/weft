//! gutter — the guest half of `ui/gutter-segment`: the slot's schema, the
//! reader for a round's question, and the one-call answer.
//!
//! A gutter provider binds the slot core declares, reads an `ask` (a window
//! of lines, the line count), and pushes a `tell` with one cell per line — or
//! a `rule`, a formula the renderer evaluates against the frame it draws (a
//! line's number, or its distance from the caret line), for a column that
//! must follow the caret on the very frame it moves. The schema is RESTATED
//! from `core/gutter.zig`, not imported, for the reason `annotate` gives: the
//! wire shape is the contract, and a drift fails closed (the host decodes
//! nothing, the gutter shows nothing).

const std = @import("std");
const weft = @import("weft");
const schema = weft.schema;

/// The slot a gutter provider binds. Core declares it; a guest never should.
pub const slot = "ui/gutter-segment";

const str_ty: schema.Schema = .str;
const u32_ty: schema.Schema = .{ .scalar = .u32 };

const ask_fields = [_]schema.Schema.Field{
    .{ .name = "first", .ty = &u32_ty },
    .{ .name = "count", .ty = &u32_ty },
    .{ .name = "lines", .ty = &u32_ty },
};
const ask_ty: schema.Schema = .{ .@"struct" = &ask_fields };

const cell_fields = [_]schema.Schema.Field{
    .{ .name = "text", .ty = &str_ty },
    .{ .name = "role", .ty = &u32_ty },
};
const cell_ty: schema.Schema = .{ .@"struct" = &cell_fields };
const cells_ty: schema.Schema = .{ .array = &cell_ty };
const tell_fields = [_]schema.Schema.Field{
    .{ .name = "first", .ty = &u32_ty },
    .{ .name = "cells", .ty = &cells_ty },
};
const tell_ty: schema.Schema = .{ .@"struct" = &tell_fields };
const rule_fields = [_]schema.Schema.Field{
    .{ .name = "formula", .ty = &u32_ty },
    .{ .name = "width", .ty = &u32_ty },
    .{ .name = "role", .ty = &u32_ty },
    .{ .name = "caret_role", .ty = &u32_ty },
};
const rule_ty: schema.Schema = .{ .@"struct" = &rule_fields };

const cases = [_]schema.Schema.Case{
    .{ .name = "ask", .ty = &ask_ty },
    .{ .name = "tell", .ty = &tell_ty },
    .{ .name = "rule", .ty = &rule_ty },
};

pub const gutter_schema: schema.Schema = .{ .variant = &cases };

const tag_ask = 0;
const tag_tell = 1;
const tag_rule = 2;

/// A cell's color, as the host's `surface.Role` wire values.
pub const Role = enum(u32) { normal = 0, accent = 1, muted = 5, annotation = 6 };

/// Bind this plugin as a gutter provider where `when` holds — e.g.
/// `.{ .posture = "text" }` for text entries only. Eligibility is evaluated
/// by the host against the pane's entry, so a provider never answers for an
/// entry it did not ask for.
pub fn bind(when: weft.Predicate, priority: i32) void {
    weft.slotBind(slot, when, .plugin, priority);
}

/// One round's question: lines `[first, first + count)` of an entry `lines`
/// long. There is no caret in it; a column counted from the caret answers
/// with a `rule`.
pub const Ask = struct {
    first: u32,
    count: u32,
    lines: u32,
};

/// Read the round `session` asks about, or null for anything that is not an
/// `ask` — a provider that cannot read the question answers nothing.
pub fn ask(session: u32) ?Ask {
    const request = weft.payloadRead(session);
    if (request.len == 0) return null;
    const cur = schema.decodeCursor(&gutter_schema, request);
    const variant = cur.enterVariant() catch return null;
    if (variant.tag != tag_ask) return null;
    const s = variant.selected().enterStruct() catch return null;
    return .{
        .first = ((s.field("first") catch return null) orelse return null).asU32() catch return null,
        .count = ((s.field("count") catch return null) orelse return null).asU32() catch return null,
        .lines = ((s.field("lines") catch return null) orelse return null).asU32() catch return null,
    };
}

pub const Cell = struct { text: []const u8, role: Role = .normal };

/// What a `rule` computes per line, from the snapshot the host draws.
pub const Formula = enum(u32) {
    /// The line's own number, from 1.
    number = 0,
    /// The distance from the caret line; the caret line shows its own number.
    caret_distance = 1,
};

/// A column as a formula: every line shows `formula`'s number right-aligned
/// in `width` digits plus one blank column, `caret_role` on the caret line
/// and `role` elsewhere. Answered once, it stays right however the caret
/// moves, so the host asks again only when the entry's facts or length do.
pub const Rule = struct {
    formula: Formula,
    width: u32,
    role: Role = .annotation,
    caret_role: Role = .normal,
};

/// Answer the round with a formula instead of cells.
pub fn rule(session: u32, r: Rule) void {
    const values = [_]schema.Value{
        .{ .scalar = .{ .u32 = @intFromEnum(r.formula) } },
        .{ .scalar = .{ .u32 = r.width } },
        .{ .scalar = .{ .u32 = @intFromEnum(r.role) } },
        .{ .scalar = .{ .u32 = @intFromEnum(r.caret_role) } },
    };
    const payload: schema.Value = .{ .@"struct" = &values };
    weft.payloadPush(session, 1, &gutter_schema, .{
        .variant = .{ .tag = tag_rule, .payload = &payload },
    });
}

/// Answer the round: `cells[i]` is line `first + i`'s cell. An empty text
/// says nothing about that line.
pub fn tell(session: u32, first: u32, cells: []const Cell) void {
    const pairs = weft.allocator.alloc([2]schema.Value, cells.len) catch return;
    defer weft.allocator.free(pairs);
    const values = weft.allocator.alloc(schema.Value, cells.len) catch return;
    defer weft.allocator.free(values);
    for (cells, pairs, values) |c, *pair, *v| {
        pair.* = .{ .{ .str = c.text }, .{ .scalar = .{ .u32 = @intFromEnum(c.role) } } };
        v.* = .{ .@"struct" = pair };
    }
    const tell_values = [_]schema.Value{
        .{ .scalar = .{ .u32 = first } },
        .{ .array = values },
    };
    const payload: schema.Value = .{ .@"struct" = &tell_values };
    weft.payloadPush(session, 1, &gutter_schema, .{
        .variant = .{ .tag = tag_tell, .payload = &payload },
    });
}
