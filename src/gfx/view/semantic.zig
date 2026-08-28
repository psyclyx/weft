//! Bundled presenter for provider-authored semantic scenes.
//!
//! This is deliberately downstream of the semantic and view runtime: plugins
//! publish stable nodes, facts, actions, and generic editable fields; this
//! renderer chooses rows, colors, and popup geometry. A radically different
//! presenter can consume the same scene without changing files, vim, or core.

const std = @import("std");
const Allocator = std.mem.Allocator;
const semantic = @import("weft_semantic");

const region = @import("../region.zig");
const view = @import("../view.zig");
const data = @import("semantic_data.zig");
const popup = @import("popup.zig");

const View = view.View;
const Run = view.Run;
const Rect = view.Rect;

pub const max_rows = 4096;
pub const max_spans = 16384;
pub const max_depth = 128;
pub const max_visual_bytes = 1 << 16;

pub const Tone = enum { normal, muted, accent, positive, negative, warning, conflict };

pub const Span = struct {
    node: semantic.scene.NodeId,
    text: []const u8,
    column: u16,
    tone: Tone,
    focusable: bool,
};

pub const Row = struct {
    spans: []const Span,
    focused: bool,
};

pub const Hit = struct {
    view: semantic.view.Ref,
    node: semantic.scene.NodeId,
    rect: region.Rect,
};

/// Arena-owned projection used by both the renderer and layout tests. Field
/// providers are sampled once per call; the resulting rows retain semantic
/// node identity, and visible row indexes are never behavior.
pub fn rowsFor(arena: Allocator, document: data.Document) Allocator.Error![]const Row {
    var builder: Builder = .{ .arena = arena, .document = document };
    try builder.appendNode(document.root, 0, null);
    return builder.rows.toOwnedSlice(arena);
}

const Builder = struct {
    arena: Allocator,
    document: data.Document,
    rows: std.ArrayList(Row) = .empty,
    span_count: usize = 0,

    fn appendNode(self: *Builder, node: *const semantic.scene.Node, depth: usize, row: ?*std.ArrayList(Span)) Allocator.Error!void {
        if (depth > max_depth or self.rows.items.len >= max_rows) return;
        switch (node.content) {
            .container => |container| switch (container.axis) {
                .horizontal => {
                    var spans: std.ArrayList(Span) = .empty;
                    for (container.children) |*child| try self.appendNode(child, depth + 1, &spans);
                    if (spans.items.len != 0) try self.finishRow(&spans);
                },
                .vertical, .overlay => for (container.children) |*child|
                    try self.appendNode(child, depth + 1, null),
            },
            else => {
                if (self.span_count >= max_spans) return;
                if (row) |spans| {
                    try spans.append(self.arena, try self.spanFor(node, depth, spans.items));
                } else {
                    var spans: std.ArrayList(Span) = .empty;
                    try spans.append(self.arena, try self.spanFor(node, depth, spans.items));
                    try self.finishRow(&spans);
                }
                self.span_count += 1;
            },
        }
    }

    fn finishRow(self: *Builder, spans: *std.ArrayList(Span)) Allocator.Error!void {
        const owned = try spans.toOwnedSlice(self.arena);
        var focused = false;
        if (self.document.focused) |wanted| for (owned) |span| {
            if (span.node == wanted) {
                focused = true;
                break;
            }
        };
        try self.rows.append(self.arena, .{ .spans = owned, .focused = focused });
    }

    fn spanFor(self: *Builder, node: *const semantic.scene.Node, depth: usize, preceding: []const Span) Allocator.Error!Span {
        const text = switch (node.content) {
            .label => |label| try displayBytes(self.arena, label),
            .action => |action| blk: {
                const label = if (action.label.len != 0) action.label else action.action;
                const decorated = try std.fmt.allocPrint(self.arena, "[{s}]", .{label});
                break :blk try displayBytes(self.arena, decorated);
            },
            .field => |field| blk: {
                const provider = self.document.fields.get(field.ref) orelse
                    break :blk try displayBytes(self.arena, field.placeholder);
                var snapshot = provider.snapshot(self.arena) catch
                    break :blk try self.arena.dupe(u8, "<field unavailable>");
                defer snapshot.deinit();
                const bytes = if (snapshot.value.bytes.len == 0) field.placeholder else snapshot.value.bytes;
                break :blk try displayBytes(self.arena, bytes);
            },
            .container => unreachable,
        };
        const natural_column: usize = if (preceding.len == 0)
            depth * 2
        else blk: {
            const prior = preceding[preceding.len - 1];
            break :blk @as(usize, prior.column) + visualWidth(prior.text) + 2;
        };
        return .{
            .node = node.id,
            .text = text,
            .column = node.layout.column orelse @intCast(@min(natural_column, std.math.maxInt(u16))),
            .tone = toneFor(node),
            .focusable = node.focusable,
        };
    }
};

/// Render a semantic tool view in the pane body. Text editing, modal state,
/// and filesystem meaning are absent here; fields and stable focus are the
/// only behavior-facing inputs.
pub fn drawDocument(v: *View, scratch: Allocator, hit_arena: Allocator, runs: *std.ArrayList(Run), rects: *std.ArrayList(Rect), document: data.Document, body: region.Rect) ![]const Hit {
    const rows = try rowsFor(scratch, document);
    var hits: std.ArrayList(Hit) = .empty;
    var content = body;
    if (document.title.len != 0 and body.h >= 2 * v.line_h) {
        const inset = v.cell_w;
        try popup.propLine(v, scratch, runs, document.title, body.x + inset, body.y + v.ascent, v.theme.accent);
        try rects.append(scratch, .{
            .x = body.x + inset,
            .y = body.y + v.line_h - 1,
            .w = @max(0, body.w - 2 * inset),
            .h = 1,
            .color = v.theme.status,
        });
        content = .{
            .x = body.x + inset,
            .y = body.y + v.line_h * 1.5,
            .w = @max(0, body.w - 2 * inset),
            .h = @max(0, body.h - v.line_h * 1.5),
        };
    }
    try drawRows(v, scratch, hit_arena, runs, rects, &hits, document.view, rows, content, false);
    return hits.toOwnedSlice(hit_arena);
}

/// Render the active head-local interaction above its underlying view. The
/// presentation string is an open hint consumed only by this presenter.
pub fn drawOverlay(v: *View, scratch: Allocator, hit_arena: Allocator, runs: *std.ArrayList(Run), rects: *std.ArrayList(Rect), overlay: data.Overlay, body: region.Rect) ![]const Hit {
    const rows = try rowsFor(scratch, overlay.document);
    if (rows.len == 0) return &.{};
    var widest: usize = 1;
    for (rows) |row| {
        for (row.spans) |span| {
            widest = @max(widest, @as(usize, span.column) + visualWidth(span.text));
        }
    }
    const visible_rows = @min(rows.len, @max(1, @as(usize, @intFromFloat(@max(0, body.h) / v.line_h)) -| 1));
    const pad_x = v.cell_w;
    const pad_y = v.line_h * 0.5;
    const box_w = @min(body.w, @as(f32, @floatFromInt(widest + 2)) * v.cell_w);
    const box_h = @min(body.h, @as(f32, @floatFromInt(visible_rows)) * v.line_h + 2 * pad_y);
    const x = std.math.clamp(body.x + (body.w - box_w) / 2, body.x, @max(body.x, body.x + body.w - box_w));
    const bottom = std.mem.eql(u8, overlay.presentation, "bottom") or
        std.mem.eql(u8, overlay.presentation, "which-key-like");
    const corner = std.mem.eql(u8, overlay.presentation, "corner");
    const raw_y = if (bottom)
        body.y + body.h - box_h
    else if (corner)
        body.y
    else
        body.y + (body.h - box_h) / 2;
    const y = std.math.clamp(raw_y, body.y, @max(body.y, body.y + body.h - box_h));
    try popup.outlinedBox(scratch, rects, x, y, box_w, box_h, v.theme.background, v.theme.accent);
    const inner: region.Rect = .{ .x = x + pad_x, .y = y + pad_y, .w = @max(0, box_w - 2 * pad_x), .h = @max(0, box_h - 2 * pad_y) };
    var hits: std.ArrayList(Hit) = .empty;
    try drawRows(v, scratch, hit_arena, runs, rects, &hits, overlay.document.view, rows[0..visible_rows], inner, true);
    return hits.toOwnedSlice(hit_arena);
}

fn drawRows(v: *View, scratch: Allocator, hit_arena: Allocator, runs: *std.ArrayList(Run), rects: *std.ArrayList(Rect), hits: *std.ArrayList(Hit), view_ref: semantic.view.Ref, rows: []const Row, body: region.Rect, clip_width: bool) !void {
    const count = @min(rows.len, @as(usize, @intFromFloat(@max(0, body.h) / v.line_h)));
    for (rows[0..count], 0..) |row, index| {
        const y = body.y + @as(f32, @floatFromInt(index)) * v.line_h;
        if (row.focused) try rects.append(scratch, .{ .x = body.x, .y = y, .w = body.w, .h = v.line_h, .color = v.theme.selection });
        for (row.spans) |span| {
            const x = body.x + @as(f32, @floatFromInt(span.column)) * v.cell_w;
            if (clip_width and x >= body.x + body.w) continue;
            try popup.propLine(v, scratch, runs, span.text, x, y + v.ascent, colorFor(v, span.tone));
            if (!span.focusable) continue;
            const available = @max(0, body.x + body.w - x);
            const width = @min(available, @max(v.cell_w, @as(f32, @floatFromInt(visualWidth(span.text))) * v.cell_w));
            try hits.append(hit_arena, .{ .view = view_ref, .node = span.node, .rect = .{ .x = x, .y = y, .w = width, .h = v.line_h } });
        }
    }
}

fn colorFor(v: *const View, tone: Tone) [4]f32 {
    return switch (tone) {
        .normal => v.theme.foreground,
        .muted => v.theme.status,
        .accent => v.theme.md_link,
        .positive => v.theme.syn_string,
        .negative => v.theme.diag_error,
        .warning => v.theme.diag_warn,
        .conflict => v.theme.syn_keyword,
    };
}

fn toneFor(node: *const semantic.scene.Node) Tone {
    var value = node.role;
    for (node.facts) |fact| if (std.mem.eql(u8, fact.name, "tone")) {
        value = fact.value;
        break;
    };
    if (std.mem.eql(u8, value, "muted")) return .muted;
    if (std.mem.eql(u8, value, "accent") or std.mem.eql(u8, value, "action")) return .accent;
    if (std.mem.eql(u8, value, "positive") or std.mem.eql(u8, value, "added")) return .positive;
    if (std.mem.eql(u8, value, "negative") or std.mem.eql(u8, value, "deleted")) return .negative;
    if (std.mem.eql(u8, value, "warning") or std.mem.eql(u8, value, "changed")) return .warning;
    if (std.mem.eql(u8, value, "conflict")) return .conflict;
    if (std.mem.eql(u8, node.role, "files.metadata") or
        std.mem.eql(u8, node.role, "files.mode") or
        std.mem.eql(u8, node.role, "files.original-name")) return .muted;
    if (std.mem.eql(u8, node.role, "files.name")) for (node.facts) |fact| {
        if (!std.mem.eql(u8, fact.name, "kind")) continue;
        if (std.mem.eql(u8, fact.value, "directory")) return .accent;
        if (std.mem.eql(u8, fact.value, "symlink")) return .warning;
    };
    return .normal;
}

fn visualWidth(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

/// Font shaping consumes UTF-8, while filesystem-backed fields may retain raw
/// names. Escape only bytes that cannot be displayed safely; semantic values
/// and effect plans retain the original bytes in their providers.
pub fn displayBytes(arena: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    const input = raw[0..@min(raw.len, max_visual_bytes)];
    var out: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < input.len) {
        const byte = input[index];
        if (byte >= 0x20 and byte < 0x7f) {
            try out.append(arena, byte);
            index += 1;
            continue;
        }
        if (byte >= 0x80) {
            const sequence_len = std.unicode.utf8ByteSequenceLength(byte) catch 0;
            if (sequence_len != 0 and index + sequence_len <= input.len and std.unicode.utf8ValidateSlice(input[index .. index + sequence_len])) {
                try out.appendSlice(arena, input[index .. index + sequence_len]);
                index += sequence_len;
                continue;
            }
        }
        switch (byte) {
            '\n' => try out.appendSlice(arena, "\\n"),
            '\r' => try out.appendSlice(arena, "\\r"),
            '\t' => try out.appendSlice(arena, "\\t"),
            else => {
                const escaped = try std.fmt.allocPrint(arena, "\\x{X:0>2}", .{byte});
                try out.appendSlice(arena, escaped);
            },
        }
        index += 1;
    }
    if (raw.len > input.len) try out.appendSlice(arena, "…");
    return out.toOwnedSlice(arena);
}

test "semantic rows preserve stable focus and field columns" {
    const view_runtime = @import("weft_view_runtime");
    const Memory = struct {
        pub fn snapshot(_: *@This(), gpa: Allocator) view_runtime.field.Error!view_runtime.field.OwnedSnapshot {
            var result = view_runtime.field.OwnedSnapshot.init(gpa);
            const alloc = result.allocator();
            result.value = .{ .revision = try alloc.dupe(u8, "1"), .bytes = try alloc.dupe(u8, "name"), .selection = .{ .anchor = 0, .caret = 0 } };
            return result;
        }
        pub fn edit(_: *@This(), _: []const u8, _: view_runtime.field.Edit) view_runtime.field.Error!void {}
    };
    var memory: Memory = .{};
    var fields = view_runtime.field.Registry.init(.here);
    defer fields.deinit(std.testing.allocator);
    const field_ref = try fields.insert(std.testing.allocator, @enumFromInt(1), .init(&memory));
    const children = [_]semantic.scene.Node{
        .{ .id = @enumFromInt(2), .layout = .{ .column = 0 }, .content = .{ .label = "0644" } },
        .{ .id = @enumFromInt(3), .layout = .{ .column = 8 }, .focusable = true, .content = .{ .field = .{ .ref = field_ref } } },
    };
    const root: semantic.scene.Node = .{ .id = @enumFromInt(1), .content = .{ .container = .{ .axis = .horizontal, .children = &children } } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rows = try rowsFor(arena.allocator(), .{ .view = .{ .authority = .here, .slot = 0, .generation = 1 }, .root = &root, .focused = @enumFromInt(3), .fields = &fields });
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expect(rows[0].focused);
    try std.testing.expectEqual(@as(u16, 8), rows[0].spans[1].column);
    try std.testing.expectEqualStrings("name", rows[0].spans[1].text);
}

test "semantic display escapes hostile raw bytes without changing identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a\\n\\xFFé", try displayBytes(arena.allocator(), "a\n\xffé"));
}
