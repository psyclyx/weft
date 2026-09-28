//! The status line's plugin exchange — the `ui/statusline-seg` slot: its
//! name, its schema, and the encode/decode either side of it needs.
//!
//! The status line is composed of segments, each a provider's answer for one
//! pane (`gfx/view/ui_mesh.zig` holds the host-side providers: the mode chip,
//! the path, the position, the language). This file is what lets a PLUGIN be
//! one of those providers, the same way `gutter.zig` lets one be a gutter
//! column: it binds the slot with `wl_slot_bind`, is asked once per pane per
//! built frame, and answers with zero or more segments.
//!
//! **What core knows is one string and one shape.** An `ask` carries the two
//! facts a segment about the caret needs — the caret's byte offset in the
//! pane's entry, and whether that pane is the head's focused one (only the
//! focused pane's entry is the one a guest's document doors read). A `tell`
//! answers with segments: text and a compact form of it, a `surface.Role`
//! for its color, which end of the line it sits at, how much it matters when
//! the line is short (`priority`), the command a click on it runs ("" for
//! none), an icon name and a tooltip. Core does not know what a segment
//! says, or what its command does.
//!
//! **One schema, both directions**, for the reason `gutter.zig` gives: the
//! variant tag is what keeps an `ask` from passing as an answer.

const std = @import("std");
const Allocator = std.mem.Allocator;

const schema_mod = @import("weft_schema");
const container_mod = @import("container.zig");

pub const Schema = schema_mod.Schema;

/// The slot the status line fires at. Host-side providers bind it directly;
/// a plugin binds it with `wl_slot_bind` and answers here.
pub const slot_name = "ui/statusline-seg";

/// The most segments one provider's answer contributes; the rest are dropped.
pub const max_segments = 16;

/// A segment that says nothing of its importance sits in the middle of the
/// 0–100 scale core's own segments use (the mode chip 100, `Ln/Col` 85, the
/// language 35).
pub const default_priority: u32 = 50;

const str_ty: Schema = .str;
const u32_ty: Schema = .{ .scalar = .u32 };

const ask_fields = [_]Schema.Field{
    .{ .name = "caret", .ty = &u32_ty },
    .{ .name = "focused", .ty = &u32_ty },
};
const ask_ty: Schema = .{ .@"struct" = &ask_fields };

/// One segment: its text and compact form, a `surface.Role` wire value,
/// `right` (1 = the right-anchored cluster), its priority, the command a
/// click on it runs, an icon name and a tooltip.
const seg_fields = [_]Schema.Field{
    .{ .name = "text", .ty = &str_ty },
    .{ .name = "compact", .ty = &str_ty },
    .{ .name = "role", .ty = &u32_ty },
    .{ .name = "right", .ty = &u32_ty },
    .{ .name = "priority", .ty = &u32_ty },
    .{ .name = "command", .ty = &str_ty },
    .{ .name = "icon", .ty = &str_ty },
    .{ .name = "tooltip", .ty = &str_ty },
};
const seg_ty: Schema = .{ .@"struct" = &seg_fields };
const segs_ty: Schema = .{ .array = &seg_ty };
const tell_fields = [_]Schema.Field{
    .{ .name = "segments", .ty = &segs_ty },
};
const tell_ty: Schema = .{ .@"struct" = &tell_fields };

const cases = [_]Schema.Case{
    .{ .name = "ask", .ty = &ask_ty },
    .{ .name = "tell", .ty = &tell_ty },
};

pub const schema: Schema = .{ .variant = &cases };

const tag_ask = 0;
const tag_tell = 1;

/// Declare the slot on `container`, WITH its schema. Idempotent (the first
/// declaration wins), so the System and the UI mesh may both call it.
pub fn declare(container: *container_mod.Container) Allocator.Error!void {
    try container.declareSlot(.{
        .name = slot_name,
        .shape = .query,
        // Every eligible provider contributes, in priority order.
        .composition = .ordered_union,
        .schema = &schema,
    });
}

pub const Ask = struct {
    caret: u32,
    focused: bool,
};

/// Encode an `ask`. Caller owns the bytes.
pub fn encodeAsk(gpa: Allocator, ask: Ask) ![]u8 {
    const values = [_]schema_mod.Value{
        .{ .scalar = .{ .u32 = ask.caret } },
        .{ .scalar = .{ .u32 = @intFromBool(ask.focused) } },
    };
    const payload: schema_mod.Value = .{ .@"struct" = &values };
    return schema_mod.encode(gpa, &schema, .{ .variant = .{ .tag = tag_ask, .payload = &payload } });
}

pub const Segment = struct {
    text: []const u8,
    /// What shows when the line is short; "" for none.
    compact: []const u8 = "",
    role: u32 = 0,
    right: bool = false,
    priority: u32 = default_priority,
    command: []const u8 = "",
    icon: []const u8 = "",
    tooltip: []const u8 = "",
};

/// One provider's answer: a cursor over its segments, borrowed from the
/// payload bytes.
pub const Tell = struct {
    segments: schema_mod.ArrayCursor,

    /// The next segment, or null when the answer is exhausted or malformed
    /// past this point.
    pub fn next(self: *Tell) ?Segment {
        const c = (self.segments.next() catch return null) orelse return null;
        const s = c.enterStruct() catch return null;
        return .{
            .text = str(s, "text") orelse return null,
            .compact = str(s, "compact") orelse return null,
            .role = int(s, "role") orelse return null,
            .right = (int(s, "right") orelse return null) != 0,
            .priority = int(s, "priority") orelse return null,
            .command = str(s, "command") orelse return null,
            .icon = str(s, "icon") orelse return null,
            .tooltip = str(s, "tooltip") orelse return null,
        };
    }

    fn str(s: schema_mod.StructCursor, name: []const u8) ?[]const u8 {
        const cur = (s.field(name) catch return null) orelse return null;
        return cur.asStr() catch null;
    }

    fn int(s: schema_mod.StructCursor, name: []const u8) ?u32 {
        const cur = (s.field(name) catch return null) orelse return null;
        return cur.asU32() catch null;
    }
};

/// Encode a `tell` — what a provider answers; the guest library restates
/// this, and a host-side provider or a test calls it directly. Caller owns
/// the bytes.
pub fn encodeTell(gpa: Allocator, segments: []const Segment) ![]u8 {
    const n = seg_fields.len;
    const fields = try gpa.alloc(schema_mod.Value, segments.len * n);
    defer gpa.free(fields);
    const values = try gpa.alloc(schema_mod.Value, segments.len);
    defer gpa.free(values);
    for (segments, 0..) |sg, i| {
        const f = fields[i * n ..][0..n];
        f.* = .{
            .{ .str = sg.text },
            .{ .str = sg.compact },
            .{ .scalar = .{ .u32 = sg.role } },
            .{ .scalar = .{ .u32 = @intFromBool(sg.right) } },
            .{ .scalar = .{ .u32 = sg.priority } },
            .{ .str = sg.command },
            .{ .str = sg.icon },
            .{ .str = sg.tooltip },
        };
        values[i] = .{ .@"struct" = f };
    }
    const tell_values = [_]schema_mod.Value{.{ .array = values }};
    const payload: schema_mod.Value = .{ .@"struct" = &tell_values };
    return schema_mod.encode(gpa, &schema, .{ .variant = .{ .tag = tag_tell, .payload = &payload } });
}

/// Decode a `tell`, or null for anything that is not one. A malformed answer
/// is a provider that said nothing.
pub fn decodeTell(bytes: []const u8) ?Tell {
    const cur = schema_mod.decodeCursor(&schema, bytes);
    const variant = cur.enterVariant() catch return null;
    if (variant.tag != tag_tell) return null;
    const s = variant.selected().enterStruct() catch return null;
    const segs_cur = (s.field("segments") catch return null) orelse return null;
    return .{ .segments = segs_cur.enterArray() catch return null };
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "status_segment: ask/tell round-trip through the one shared schema" {
    const gpa = t.allocator;
    const asked = try encodeAsk(gpa, .{ .caret = 42, .focused = true });
    defer gpa.free(asked);
    const cur = schema_mod.decodeCursor(&schema, asked);
    const variant = try cur.enterVariant();
    try t.expectEqualStrings("ask", variant.caseName());
    const s = try variant.selected().enterStruct();
    try t.expectEqual(@as(u32, 42), try (try s.field("caret")).?.asU32());
    try t.expectEqual(@as(u32, 1), try (try s.field("focused")).?.asU32());

    const answered = try encodeTell(gpa, &.{
        .{ .text = "a.zig", .role = 5 },
        .{ .text = "main", .compact = "m", .right = true, .priority = 80, .command = "jump 12", .icon = "git-branch", .tooltip = "Branch" },
    });
    defer gpa.free(answered);
    var decoded = decodeTell(answered).?;
    const first = decoded.next().?;
    try t.expectEqualStrings("a.zig", first.text);
    try t.expectEqualStrings("", first.compact);
    try t.expectEqual(@as(u32, 5), first.role);
    try t.expect(!first.right);
    try t.expectEqual(default_priority, first.priority);
    try t.expectEqualStrings("", first.command);
    const second = decoded.next().?;
    try t.expect(second.right);
    try t.expectEqualStrings("m", second.compact);
    try t.expectEqual(@as(u32, 80), second.priority);
    try t.expectEqualStrings("jump 12", second.command);
    try t.expectEqualStrings("git-branch", second.icon);
    try t.expectEqualStrings("Branch", second.tooltip);
    try t.expect(decoded.next() == null);

    // An ask is well-formed and still not an answer.
    try t.expect(decodeTell(asked) == null);
    try t.expect(decodeTell(&.{}) == null);
}
