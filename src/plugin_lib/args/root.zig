//! args — what an argument can be: the `arg/<kind>` slots, both halves.
//!
//! A command says what each argument TAKES (`ArgSpec.takes`): a kind —
//! `file`, `command`, `buffer` — or the values themselves, `read|edit`.
//! Whoever asks a person for the argument offers those values; a closed list
//! it reads off the declaration, and a kind it ASKS for, on the slot
//! `arg/<kind>`, of every plugin that answers that kind here.
//!
//! **A slot per kind, not one slot carrying a kind.** The kinds a plugin
//! answers are then interest the host can see and route — a fire of
//! `arg/file` reaches the plugins that bound it, and a kind nobody answers is
//! the ordinary "nobody offers", not a round of declines. The plugin that
//! answers a kind declares its slot (`offer`); `Container.declareSlot` keeps
//! the first of identical declarations, so two answering one kind agree by
//! construction — the schema is this file's.
//!
//! **An answer may be late, and may come in parts.** A provider that has the
//! values answers inside the fire; one that must find them (a walk of the
//! place's files) answers as it finds them. The asker hears each part as it
//! lands (`weft.listen`).

const std = @import("std");
const weft = @import("weft");
const schema = weft.schema;

/// The prefix of every argument slot: `arg/file`, `arg/command`, ….
pub const prefix = "arg/";

const str_ty: schema.Schema = .str;

const row_fields = [_]schema.Schema.Field{
    .{ .name = "text", .ty = &str_ty },
    .{ .name = "doc", .ty = &str_ty },
};
const row_ty: schema.Schema = .{ .@"struct" = &row_fields };
const rows_ty: schema.Schema = .{ .array = &row_ty };

const ask_fields = [_]schema.Schema.Field{
    .{ .name = "command", .ty = &str_ty },
    .{ .name = "param", .ty = &str_ty },
};
const ask_ty: schema.Schema = .{ .@"struct" = &ask_fields };

const tell_fields = [_]schema.Schema.Field{
    .{ .name = "rows", .ty = &rows_ty },
};
const tell_ty: schema.Schema = .{ .@"struct" = &tell_fields };

const cases = [_]schema.Schema.Case{
    .{ .name = "ask", .ty = &ask_ty },
    .{ .name = "tell", .ty = &tell_ty },
};

pub const args_schema: schema.Schema = .{ .variant = &cases };

const tag_ask = 0;
const tag_tell = 1;

/// One value an argument can take, and a note beside it.
pub const Row = struct { text: []const u8, doc: []const u8 = "" };

/// `arg/<kind>`, into `buf`. Null when it does not fit.
pub fn slotOf(buf: []u8, kind: []const u8) ?[]const u8 {
    if (prefix.len + kind.len > buf.len) return null;
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..][0..kind.len], kind);
    return buf[0 .. prefix.len + kind.len];
}

/// The values a closed `takes` lists (`read|edit`), or null when it names a
/// kind instead.
pub fn values(takes: []const u8) ?std.mem.SplitIterator(u8, .scalar) {
    if (std.mem.indexOfScalar(u8, takes, '|') == null) return null;
    return std.mem.splitScalar(u8, takes, '|');
}

// ── Answering ────────────────────────────────────────────────────────

/// Answer kind `kind` here: declare its slot and bind this plugin to it.
/// Call from `init`; the plugin's `on_slot_fire` then hears each question
/// (`question`).
pub fn offer(comptime kind: []const u8) void {
    const name = prefix ++ kind;
    weft.slotDeclare(name, .query, .ordered_union, &args_schema);
    weft.slotBind(name, .{ .all = &.{} }, .plugin, 0);
}

/// One question: a value for `command`'s argument `param`, of `kind`.
pub const Question = struct {
    kind: []const u8,
    command: []const u8,
    param: []const u8,
};

/// What `session` asks, when it is an argument question — null for any other
/// slot this plugin answers, so one `on_slot_fire` can route both.
pub fn question(session: u32) ?Question {
    const slot = weft.slotName(session) orelse return null;
    if (!std.mem.startsWith(u8, slot, prefix)) return null;
    const request = weft.payloadRead(session);
    if (request.len == 0) return null;
    const cur = schema.decodeCursor(&args_schema, request);
    const variant = cur.enterVariant() catch return null;
    if (variant.tag != tag_ask) return null;
    const s = variant.selected().enterStruct() catch return null;
    const command_cur = (s.field("command") catch return null) orelse return null;
    const param_cur = (s.field("param") catch return null) orelse return null;
    return .{
        .kind = slot[prefix.len..],
        .command = command_cur.asStr() catch return null,
        .param = param_cur.asStr() catch return null,
    };
}

/// Answer `session` with `rows` — all of them, or the next part of them: a
/// provider still finding values answers again as it finds more.
pub fn answer(session: u32, rows: []const Row) void {
    const gpa = weft.allocator;
    const row_values = gpa.alloc([2]schema.Value, rows.len) catch return;
    defer gpa.free(row_values);
    const items = gpa.alloc(schema.Value, rows.len) catch return;
    defer gpa.free(items);
    for (rows, row_values, items) |r, *fields, *item| {
        fields.* = .{ .{ .str = r.text }, .{ .str = r.doc } };
        item.* = .{ .@"struct" = fields };
    }
    const tell_values = [_]schema.Value{.{ .array = items }};
    const payload: schema.Value = .{ .@"struct" = &tell_values };
    weft.payloadPush(session, 1, &args_schema, .{ .variant = .{ .tag = tag_tell, .payload = &payload } });
}

// ── Asking ───────────────────────────────────────────────────────────

/// Ask every plugin answering `kind` here for values of `command`'s
/// argument `param`. Null when none does.
pub fn ask(kind: []const u8, command: []const u8, param: []const u8) ?weft.Fire {
    var buf: [128]u8 = undefined;
    const slot = slotOf(&buf, kind) orelse return null;
    const fields = [_]schema.Value{ .{ .str = command }, .{ .str = param } };
    const request: schema.Value = .{ .@"struct" = &fields };
    return weft.Fire.openWith(slot, &args_schema, .{ .variant = .{ .tag = tag_ask, .payload = &request } });
}

/// The rows of one answer, in order.
pub const Rows = struct {
    cursor: schema.ArrayCursor,

    pub fn next(self: *Rows) ?Row {
        const row = (self.cursor.next() catch return null) orelse return null;
        const rs = row.enterStruct() catch return null;
        const text_cur = (rs.field("text") catch return null) orelse return null;
        const doc_cur = (rs.field("doc") catch return null) orelse return null;
        return .{
            .text = text_cur.asStr() catch return null,
            .doc = doc_cur.asStr() catch return null,
        };
    }
};

/// Read one answer's payload. Null for anything that is not a `tell`.
pub fn rowsOf(payload: []const u8) ?Rows {
    const cur = schema.decodeCursor(&args_schema, payload);
    const variant = cur.enterVariant() catch return null;
    if (variant.tag != tag_tell) return null;
    const s = variant.selected().enterStruct() catch return null;
    const rows_cur = (s.field("rows") catch return null) orelse return null;
    return .{ .cursor = rows_cur.enterArray() catch return null };
}
