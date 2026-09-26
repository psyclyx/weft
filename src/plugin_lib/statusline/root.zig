//! statusline — the guest half of `ui/statusline-seg`: the slot's schema, the
//! reader for a round's question, and the one-call answer.
//!
//! A status-line provider binds the slot core declares, reads an `ask` (the
//! caret's byte offset in the pane's entry, and whether that pane is the
//! focused one), and pushes a `tell` with zero or more segments — each with
//! a color role, a side, and the command a click on it runs. The schema is
//! RESTATED from `core/status_segment.zig`, not imported, for the reason
//! `gutter` gives: the wire shape is the contract, and a drift fails closed.

const std = @import("std");
const weft = @import("weft");
const schema = weft.schema;

/// The slot a status-line provider binds. Core declares it.
pub const slot = "ui/statusline-seg";

const str_ty: schema.Schema = .str;
const u32_ty: schema.Schema = .{ .scalar = .u32 };

const ask_fields = [_]schema.Schema.Field{
    .{ .name = "caret", .ty = &u32_ty },
    .{ .name = "focused", .ty = &u32_ty },
};
const ask_ty: schema.Schema = .{ .@"struct" = &ask_fields };

const seg_fields = [_]schema.Schema.Field{
    .{ .name = "text", .ty = &str_ty },
    .{ .name = "role", .ty = &u32_ty },
    .{ .name = "right", .ty = &u32_ty },
    .{ .name = "command", .ty = &str_ty },
};
const seg_ty: schema.Schema = .{ .@"struct" = &seg_fields };
const segs_ty: schema.Schema = .{ .array = &seg_ty };
const tell_fields = [_]schema.Schema.Field{
    .{ .name = "segments", .ty = &segs_ty },
};
const tell_ty: schema.Schema = .{ .@"struct" = &tell_fields };

const cases = [_]schema.Schema.Case{
    .{ .name = "ask", .ty = &ask_ty },
    .{ .name = "tell", .ty = &tell_ty },
};

pub const statusline_schema: schema.Schema = .{ .variant = &cases };

const tag_ask = 0;
const tag_tell = 1;

/// A segment's color, as the host's `surface.Role` wire values.
pub const Role = enum(u32) { normal = 0, accent = 1, muted = 5, annotation = 6 };

/// Bind this plugin as a status-line provider where `when` holds, at
/// `priority` within `tier`. The default segments (mode, position, path) sit
/// at the `core` tier, priorities 100 down to 10; a provider that means to sit
/// AMONG them binds `core` too, since a higher tier always comes first.
pub fn bind(when: weft.Predicate, tier: weft.SlotTier, priority: i32) void {
    weft.slotBind(slot, when, tier, priority);
}

pub const Ask = struct {
    caret: u32,
    focused: bool,
};

/// Read the round `session` asks about, or null for anything that is not an
/// `ask`.
pub fn ask(session: u32) ?Ask {
    const request = weft.payloadRead(session);
    if (request.len == 0) return null;
    const cur = schema.decodeCursor(&statusline_schema, request);
    const variant = cur.enterVariant() catch return null;
    if (variant.tag != tag_ask) return null;
    const s = variant.selected().enterStruct() catch return null;
    return .{
        .caret = ((s.field("caret") catch return null) orelse return null).asU32() catch return null,
        .focused = (((s.field("focused") catch return null) orelse return null).asU32() catch return null) != 0,
    };
}

pub const Segment = struct {
    text: []const u8,
    role: Role = .normal,
    right: bool = false,
    /// `name [argument]`, run when the segment is clicked; "" for none.
    command: []const u8 = "",
};

/// Answer the round with `segments` (possibly none).
pub fn tell(session: u32, segments: []const Segment) void {
    const fields = weft.allocator.alloc([4]schema.Value, segments.len) catch return;
    defer weft.allocator.free(fields);
    const values = weft.allocator.alloc(schema.Value, segments.len) catch return;
    defer weft.allocator.free(values);
    for (segments, fields, values) |sg, *f, *v| {
        f.* = .{
            .{ .str = sg.text },
            .{ .scalar = .{ .u32 = @intFromEnum(sg.role) } },
            .{ .scalar = .{ .u32 = @intFromBool(sg.right) } },
            .{ .str = sg.command },
        };
        v.* = .{ .@"struct" = f };
    }
    const tell_values = [_]schema.Value{.{ .array = values }};
    const payload: schema.Value = .{ .@"struct" = &tell_values };
    weft.payloadPush(session, 1, &statusline_schema, .{
        .variant = .{ .tag = tag_tell, .payload = &payload },
    });
}
