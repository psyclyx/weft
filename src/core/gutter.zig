//! The gutter's plugin exchange — the `ui/gutter-segment` slot: its name, its
//! schema, and the encode/decode either side of it needs.
//!
//! **What core knows about the gutter is in this file, and it is one string
//! and one shape.** An `ask` names a window of lines plus the line count (a
//! fixed-width column pads to it); a `tell` answers with one cell per line of
//! that window. Core does not know what a line number is, or which entries
//! deserve one. That is the same line `pick/annotate.zig` draws for pick
//! rows: core owns the exchange, a provider owns the answer.
//!
//! **An answer can be a formula over the frame's snapshot** (`rule`), for a
//! column whose cells depend on something that moves every frame. A caret
//! move is such a thing, and an answer asked between frames (doc/model.md
//! §2.7) is a frame late for it: cells computed against the caret the
//! provider was asked with would show the previous caret's numbering on the
//! frame the caret moved. So the caret is NOT in the question. A provider
//! that numbers relative to it says so declaratively — "the distance from the
//! caret line, `width` digits" — and the renderer evaluates that against the
//! snapshot it is drawing, so the column is right on the frame the caret
//! moves, and a caret move asks no provider anything. `Formula` is the whole
//! vocabulary, and deliberately small: a line's own number, or its distance
//! from the caret line.
//!
//! **One round per WINDOW, not per row.** A guest call per visible row would
//! be a membrane crossing per row per frame; a window costs one crossing for
//! the whole visible range (the host asks again only if the layout walks past
//! it — a fold, a scroll the build itself made). `window` is sized well past
//! a screen so the second ask is the exception.
//!
//! **One schema, both directions**, for the reason `pick/annotate.zig` gives:
//! `SlotHost.push` walks a result against the same declared schema it handed
//! the request, so the variant tag is what keeps an `ask` from passing as an
//! answer.

const std = @import("std");
const Allocator = std.mem.Allocator;

const schema_mod = @import("weft_schema");
const container_mod = @import("container.zig");

pub const Schema = schema_mod.Schema;

/// The slot the gutter fires at. Host-side providers (`gfx/view/ui_mesh.zig`)
/// bind it directly; a plugin binds it with `wl_slot_bind` and answers here.
pub const slot_name = "ui/gutter-segment";

/// How many lines one ask covers. Well past any screen, so a frame asks once.
pub const window = 256;

const str_ty: Schema = .str;
const u32_ty: Schema = .{ .scalar = .u32 };

const ask_fields = [_]Schema.Field{
    .{ .name = "first", .ty = &u32_ty },
    .{ .name = "count", .ty = &u32_ty },
    .{ .name = "lines", .ty = &u32_ty },
};
const ask_ty: Schema = .{ .@"struct" = &ask_fields };

/// One line's cell: its text (possibly empty — nothing to say about this
/// line) and a `surface.Role` wire value for its color.
const cell_fields = [_]Schema.Field{
    .{ .name = "text", .ty = &str_ty },
    .{ .name = "role", .ty = &u32_ty },
};
const cell_ty: Schema = .{ .@"struct" = &cell_fields };
const cells_ty: Schema = .{ .array = &cell_ty };
const tell_fields = [_]Schema.Field{
    .{ .name = "first", .ty = &u32_ty },
    .{ .name = "cells", .ty = &cells_ty },
};
const tell_ty: Schema = .{ .@"struct" = &tell_fields };
/// A column as a formula (`Rule`): which one, the digits it pads to, and the
/// `surface.Role` of every other line and of the caret line.
const rule_fields = [_]Schema.Field{
    .{ .name = "formula", .ty = &u32_ty },
    .{ .name = "width", .ty = &u32_ty },
    .{ .name = "role", .ty = &u32_ty },
    .{ .name = "caret_role", .ty = &u32_ty },
};
const rule_ty: Schema = .{ .@"struct" = &rule_fields };

const cases = [_]Schema.Case{
    .{ .name = "ask", .ty = &ask_ty },
    .{ .name = "tell", .ty = &tell_ty },
    .{ .name = "rule", .ty = &rule_ty },
};

pub const schema: Schema = .{ .variant = &cases };

const tag_ask = 0;
const tag_tell = 1;
const tag_rule = 2;

/// Declare the slot on `container`, WITH its schema. Idempotent (the first
/// declaration wins), so the System and the UI mesh may both call it.
pub fn declare(container: *container_mod.Container) Allocator.Error!void {
    try container.declareSlot(.{
        .name = slot_name,
        .shape = .query,
        // Several providers compose one gutter (numbers, then marks), in
        // priority order — never first-wins.
        .composition = .ordered_union,
        .schema = &schema,
    });
}

/// The question: lines `[first, first + count)`, and how many lines the
/// entry has (a fixed-width column pads to that). No caret: see `Rule`.
pub const Ask = struct {
    first: u32,
    count: u32,
    lines: u32,
};

/// What a `rule` computes for a line, from the frame's snapshot.
pub const Formula = enum(u32) {
    /// The line's own number, from 1.
    number = 0,
    /// The line's distance from the caret line; the caret line shows its
    /// own number (a bare 0 there would say nothing).
    caret_distance = 1,
    _,
};

/// A column answered as a formula: every line's cell is `formula`'s number,
/// right-aligned in `width` digits and followed by one blank column, colored
/// `caret_role` on the caret line and `role` elsewhere.
pub const Rule = struct {
    formula: Formula,
    width: u32,
    role: u32,
    caret_role: u32,

    /// The number `line` (0-based) shows with the caret on `caret_line`.
    pub fn number(self: Rule, line: usize, caret_line: usize) usize {
        return switch (self.formula) {
            .caret_distance => if (line == caret_line) line + 1 else if (line > caret_line) line - caret_line else caret_line - line,
            else => line + 1,
        };
    }

    /// Whether this build evaluates the rule's formula; an unknown one is a
    /// provider that said nothing.
    pub fn known(self: Rule) bool {
        return switch (self.formula) {
            .number, .caret_distance => true,
            _ => false,
        };
    }
};

/// Encode an `ask`. Caller owns the bytes.
pub fn encodeAsk(gpa: Allocator, ask: Ask) ![]u8 {
    const values = [_]schema_mod.Value{
        .{ .scalar = .{ .u32 = ask.first } },
        .{ .scalar = .{ .u32 = ask.count } },
        .{ .scalar = .{ .u32 = ask.lines } },
    };
    const payload: schema_mod.Value = .{ .@"struct" = &values };
    return schema_mod.encode(gpa, &schema, .{ .variant = .{ .tag = tag_ask, .payload = &payload } });
}

/// One provider's answer: the line its first cell is about, and a cursor
/// over the cells. Borrowed from the payload bytes.
pub const Tell = struct {
    first: u32,
    cells: schema_mod.ArrayCursor,

    /// The next cell's `(text, role)`, or null when the answer is exhausted
    /// or malformed past this point.
    pub fn next(self: *Tell) ?Cell {
        const c = (self.cells.next() catch return null) orelse return null;
        const s = c.enterStruct() catch return null;
        const text_cur = (s.field("text") catch return null) orelse return null;
        const role_cur = (s.field("role") catch return null) orelse return null;
        return .{
            .text = text_cur.asStr() catch return null,
            .role = role_cur.asU32() catch return null,
        };
    }
};

pub const Cell = struct { text: []const u8, role: u32 };

/// Encode a `tell` — what a provider answers; the guest library restates
/// this, and a host-side provider or a test calls it directly. Caller owns
/// the bytes.
pub fn encodeTell(gpa: Allocator, first: u32, cells: []const Cell) ![]u8 {
    const fields = try gpa.alloc(schema_mod.Value, cells.len * 2);
    defer gpa.free(fields);
    const values = try gpa.alloc(schema_mod.Value, cells.len);
    defer gpa.free(values);
    for (cells, 0..) |c, i| {
        fields[i * 2] = .{ .str = c.text };
        fields[i * 2 + 1] = .{ .scalar = .{ .u32 = c.role } };
        values[i] = .{ .@"struct" = fields[i * 2 .. i * 2 + 2] };
    }
    const tell_values = [_]schema_mod.Value{ .{ .scalar = .{ .u32 = first } }, .{ .array = values } };
    const payload: schema_mod.Value = .{ .@"struct" = &tell_values };
    return schema_mod.encode(gpa, &schema, .{ .variant = .{ .tag = tag_tell, .payload = &payload } });
}

/// Encode a `rule`. Caller owns the bytes.
pub fn encodeRule(gpa: Allocator, rule: Rule) ![]u8 {
    const values = [_]schema_mod.Value{
        .{ .scalar = .{ .u32 = @intFromEnum(rule.formula) } },
        .{ .scalar = .{ .u32 = rule.width } },
        .{ .scalar = .{ .u32 = rule.role } },
        .{ .scalar = .{ .u32 = rule.caret_role } },
    };
    const payload: schema_mod.Value = .{ .@"struct" = &values };
    return schema_mod.encode(gpa, &schema, .{ .variant = .{ .tag = tag_rule, .payload = &payload } });
}

/// Decode a `rule`, or null for anything that is not one (a `tell`, an
/// unknown formula, a malformed answer).
pub fn decodeRule(bytes: []const u8) ?Rule {
    const cur = schema_mod.decodeCursor(&schema, bytes);
    const variant = cur.enterVariant() catch return null;
    if (variant.tag != tag_rule) return null;
    const s = variant.selected().enterStruct() catch return null;
    const rule: Rule = .{
        .formula = @enumFromInt(ruleField(s, "formula") orelse return null),
        .width = ruleField(s, "width") orelse return null,
        .role = ruleField(s, "role") orelse return null,
        .caret_role = ruleField(s, "caret_role") orelse return null,
    };
    return if (rule.known()) rule else null;
}

fn ruleField(s: anytype, name: []const u8) ?u32 {
    const c = (s.field(name) catch return null) orelse return null;
    return c.asU32() catch null;
}

/// Decode a `tell`, or null for anything that is not one. A malformed answer
/// is a provider that said nothing — normal for a raced slot.
pub fn decodeTell(bytes: []const u8) ?Tell {
    const cur = schema_mod.decodeCursor(&schema, bytes);
    const variant = cur.enterVariant() catch return null;
    if (variant.tag != tag_tell) return null;
    const s = variant.selected().enterStruct() catch return null;
    const first_cur = (s.field("first") catch return null) orelse return null;
    const cells_cur = (s.field("cells") catch return null) orelse return null;
    return .{
        .first = first_cur.asU32() catch return null,
        .cells = cells_cur.enterArray() catch return null,
    };
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "gutter: ask/tell round-trip through the one shared schema" {
    const gpa = t.allocator;
    const asked = try encodeAsk(gpa, .{ .first = 10, .count = 3, .lines = 120 });
    defer gpa.free(asked);
    const cur = schema_mod.decodeCursor(&schema, asked);
    const variant = try cur.enterVariant();
    try t.expectEqualStrings("ask", variant.caseName());
    const s = try variant.selected().enterStruct();
    try t.expectEqual(@as(u32, 120), try (try s.field("lines")).?.asU32());

    const cell_vals = [_]schema_mod.Value{ .{ .str = "  1 " }, .{ .scalar = .{ .u32 = 6 } } };
    const cells = [_]schema_mod.Value{ .{ .@"struct" = &cell_vals }, .{ .@"struct" = &cell_vals } };
    const tell_vals = [_]schema_mod.Value{ .{ .scalar = .{ .u32 = 10 } }, .{ .array = &cells } };
    const tell: schema_mod.Value = .{ .@"struct" = &tell_vals };
    const answered = try schema_mod.encode(gpa, &schema, .{ .variant = .{ .tag = tag_tell, .payload = &tell } });
    defer gpa.free(answered);
    var decoded = decodeTell(answered).?;
    try t.expectEqual(@as(u32, 10), decoded.first);
    const c0 = decoded.next().?;
    try t.expectEqualStrings("  1 ", c0.text);
    try t.expectEqual(@as(u32, 6), c0.role);
    _ = decoded.next().?;
    try t.expect(decoded.next() == null);

    // An ask is well-formed and still not an answer.
    try t.expect(decodeTell(asked) == null);
    try t.expect(decodeTell(&.{}) == null);
    try t.expect(decodeRule(asked) == null);
    try t.expect(decodeRule(answered) == null);
}

test "gutter: a rule round-trips, and numbers lines from the caret the frame draws" {
    const gpa = t.allocator;
    const bytes = try encodeRule(gpa, .{ .formula = .caret_distance, .width = 2, .role = 6, .caret_role = 0 });
    defer gpa.free(bytes);
    const rule = decodeRule(bytes).?;
    try t.expectEqual(Formula.caret_distance, rule.formula);
    try t.expectEqual(@as(u32, 2), rule.width);
    try t.expect(decodeTell(bytes) == null);
    // The caret line shows its own number; every other line its distance.
    try t.expectEqual(@as(usize, 3), rule.number(2, 2));
    try t.expectEqual(@as(usize, 2), rule.number(0, 2));
    try t.expectEqual(@as(usize, 8), rule.number(10, 2));
    // The same answer a caret later: no new answer needed.
    try t.expectEqual(@as(usize, 1), rule.number(2, 3));
    const absolute: Rule = .{ .formula = .number, .width = 3, .role = 6, .caret_role = 0 };
    try t.expectEqual(@as(usize, 11), absolute.number(10, 2));
    // A formula this build does not know is a provider that said nothing.
    const unknown = try encodeRule(gpa, .{ .formula = @enumFromInt(9), .width = 1, .role = 0, .caret_role = 0 });
    defer gpa.free(unknown);
    try t.expect(decodeRule(unknown) == null);
}
