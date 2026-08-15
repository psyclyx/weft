//! Syntax — incremental tree-sitter parsing + highlighting, driven by
//! the commit log. The grammar is a pinned shared object opened at
//! runtime (`build_options` carries the store paths); the highlight
//! query is embedded at build time.
//!
//! Change flow: a `Mirror` drains commits; each patch becomes a
//! `ts_tree_edit` (old coordinates from the pre-patch shadow, new-end
//! point derived from the inserted bytes), then one incremental
//! reparse reads the *current* rope through a chunked TSInput. The
//! view asks `paint` for a class-per-byte buffer over the visible
//! range — capture names map to a small class enum; how classes look
//! is the view's business.
//!
//! Query predicates (`#lua-match?` etc.) are not evaluated: patterns
//! carrying any predicate are disabled at load. That keeps keywords,
//! literals, comments, types-by-node — the load-bearing highlights —
//! and drops only heuristic identifier classification.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const stemma = @import("stemma");
const build_options = @import("build_options");
const Document = @import("Document.zig");
const Mirror = @import("mirror.zig");

pub const c = @cImport({
    @cInclude("tree_sitter/api.h");
});

/// Semantic classes the view can color. Capture names map by their
/// first dotted segment ("punctuation.bracket" → .punctuation).
pub const Class = enum(u8) {
    none,
    keyword,
    string,
    comment,
    number,
    type,
    function,
    variable,
    constant,
    operator,
    punctuation,
    attribute,
    label,
};

pub const LanguageSpec = struct {
    name: []const u8,
    extensions: []const []const u8,
    parser_dir: []const u8,
    symbol: [:0]const u8,
    highlights: []const u8,
};

pub const languages = [_]LanguageSpec{
    .{
        .name = "zig",
        .extensions = &.{".zig"},
        .parser_dir = build_options.ts_zig,
        .symbol = "tree_sitter_zig",
        .highlights = @embedFile("ts_zig_highlights"),
    },
    .{
        .name = "fennel",
        .extensions = &.{".fnl"},
        .parser_dir = build_options.ts_fennel,
        .symbol = "tree_sitter_fennel",
        .highlights = @embedFile("ts_fennel_highlights"),
    },
};

pub fn forPath(path: []const u8) ?*const LanguageSpec {
    for (&languages) |*spec| {
        for (spec.extensions) |ext| {
            if (std.mem.endsWith(u8, path, ext)) return spec;
        }
    }
    return null;
}

fn classOf(name: []const u8) Class {
    const head = name[0 .. std.mem.indexOfScalar(u8, name, '.') orelse name.len];
    const map = std.StaticStringMap(Class).initComptime(.{
        .{ "keyword", .keyword },
        .{ "string", .string },
        .{ "character", .string },
        .{ "comment", .comment },
        .{ "number", .number },
        .{ "float", .number },
        .{ "boolean", .constant },
        .{ "type", .type },
        .{ "function", .function },
        .{ "method", .function },
        .{ "constructor", .function },
        .{ "variable", .variable },
        .{ "field", .variable },
        .{ "property", .variable },
        .{ "constant", .constant },
        .{ "operator", .operator },
        .{ "punctuation", .punctuation },
        .{ "attribute", .attribute },
        .{ "tag", .attribute },
        .{ "label", .label },
        .{ "symbol", .label },
    });
    return map.get(head) orelse .none;
}

pub const Error = error{ OutOfMemory, GrammarLoad, QueryLoad };

pub const Syntax = struct {
    gpa: Allocator,
    lib: std.DynLib,
    parser: *c.TSParser,
    query: *c.TSQuery,
    qcursor: *c.TSQueryCursor,
    tree: ?*c.TSTree = null,
    mirror: Mirror = .empty,
    /// capture id → class; pattern id → enabled.
    classes: []Class,
    enabled: []bool,
    /// TSInput chunk buffer (parse-time only).
    read_buf: [4096]u8 = undefined,
    read_rope: ?*const stemma.Rope = null,

    /// Loads the grammar, does the initial full parse of `doc`'s
    /// current text, and positions the mirror at the current commit.
    pub fn create(gpa: Allocator, spec: *const LanguageSpec, doc: *const Document) Error!*Syntax {
        const self = try gpa.create(Syntax);
        errdefer gpa.destroy(self);

        var path_buf: [512]u8 = undefined;
        const lib_path = std.fmt.bufPrint(&path_buf, "{s}/parser", .{spec.parser_dir}) catch return error.GrammarLoad;
        var lib = std.DynLib.open(lib_path) catch return error.GrammarLoad;
        errdefer lib.close();
        const LangFn = *const fn () callconv(.c) ?*const c.TSLanguage;
        const lang_fn = lib.lookup(LangFn, spec.symbol) orelse return error.GrammarLoad;
        const lang = lang_fn() orelse return error.GrammarLoad;

        const parser = c.ts_parser_new() orelse return error.OutOfMemory;
        errdefer c.ts_parser_delete(parser);
        if (!c.ts_parser_set_language(parser, lang)) return error.GrammarLoad;

        var err_offset: u32 = 0;
        var err_type: c.TSQueryError = c.TSQueryErrorNone;
        const query = c.ts_query_new(
            lang,
            spec.highlights.ptr,
            @intCast(spec.highlights.len),
            &err_offset,
            &err_type,
        ) orelse {
            std.log.err("syntax {s}: query error {d} at byte {d}", .{ spec.name, err_type, err_offset });
            return error.QueryLoad;
        };
        errdefer c.ts_query_delete(query);
        const qcursor = c.ts_query_cursor_new() orelse return error.OutOfMemory;
        errdefer c.ts_query_cursor_delete(qcursor);

        const capture_count = c.ts_query_capture_count(query);
        const classes = try gpa.alloc(Class, capture_count);
        errdefer gpa.free(classes);
        for (0..capture_count) |i| {
            var len: u32 = 0;
            const name = c.ts_query_capture_name_for_id(query, @intCast(i), &len);
            classes[i] = classOf(name[0..len]);
        }
        const pattern_count = c.ts_query_pattern_count(query);
        const enabled = try gpa.alloc(bool, pattern_count);
        errdefer gpa.free(enabled);
        for (0..pattern_count) |i| {
            var n: u32 = 0;
            const steps = c.ts_query_predicates_for_pattern(query, @intCast(i), &n);
            // Directives (`#set!`) are settings, not filters — patterns
            // carrying only those stay enabled; real predicates
            // (`#lua-match?`, `#eq?`, …) disable their pattern.
            enabled[i] = ok: {
                if (n == 0) break :ok true; // steps may be null
                var at_group_head = true;
                for (steps[0..n]) |step| {
                    if (step.type == c.TSQueryPredicateStepTypeDone) {
                        at_group_head = true;
                        continue;
                    }
                    if (at_group_head) {
                        at_group_head = false;
                        if (step.type != c.TSQueryPredicateStepTypeString) break :ok false;
                        var len: u32 = 0;
                        const name = c.ts_query_string_value_for_id(query, step.value_id, &len);
                        if (!std.mem.eql(u8, name[0..len], "set!")) break :ok false;
                    }
                }
                break :ok true;
            };
        }

        self.* = .{
            .gpa = gpa,
            .lib = lib,
            .parser = parser,
            .query = query,
            .qcursor = qcursor,
            .classes = classes,
            .enabled = enabled,
        };

        // Adopt the current text and parse it whole.
        self.mirror.rope = doc.text().snapshot();
        self.mirror.cursor = doc.commitCount();
        self.tree = self.parse(doc.text(), null);
        return self;
    }

    pub fn destroy(self: *Syntax) void {
        const gpa = self.gpa;
        if (self.tree) |t_| c.ts_tree_delete(t_);
        c.ts_query_cursor_delete(self.qcursor);
        c.ts_query_delete(self.query);
        c.ts_parser_delete(self.parser);
        self.mirror.deinit(gpa);
        gpa.free(self.classes);
        gpa.free(self.enabled);
        self.lib.close();
        gpa.destroy(self);
    }

    /// Fold new commits into the tree and reparse incrementally.
    /// Returns true when anything changed.
    pub fn sync(self: *Syntax, gpa: Allocator, doc: *const Document) !bool {
        const drained = try self.mirror.drain(gpa, doc, self, editCb);
        if (drained == 0) return false;
        const new_tree = self.parse(doc.text(), self.tree);
        if (self.tree) |old| c.ts_tree_delete(old);
        self.tree = new_tree;
        return true;
    }

    fn editCb(self: *Syntax, shadow: *const stemma.Rope, p: Document.Patch, inserted: []const u8) anyerror!void {
        const tree = self.tree orelse return;
        const start = shadow.offsetToPoint(p.offset);
        const old_end = shadow.offsetToPoint(p.offset + p.removed);
        const new_end: stemma.Point = blk: {
            const nl = std.mem.count(u8, inserted, "\n");
            if (nl == 0) break :blk .{ .row = start.row, .col = start.col + inserted.len };
            const last = std.mem.lastIndexOfScalar(u8, inserted, '\n').?;
            break :blk .{ .row = start.row + nl, .col = inserted.len - last - 1 };
        };
        var edit: c.TSInputEdit = .{
            .start_byte = @intCast(p.offset),
            .old_end_byte = @intCast(p.offset + p.removed),
            .new_end_byte = @intCast(p.offset + inserted.len),
            .start_point = .{ .row = @intCast(start.row), .column = @intCast(start.col) },
            .old_end_point = .{ .row = @intCast(old_end.row), .column = @intCast(old_end.col) },
            .new_end_point = .{ .row = @intCast(new_end.row), .column = @intCast(new_end.col) },
        };
        c.ts_tree_edit(tree, &edit);
    }

    fn parse(self: *Syntax, rope: *const stemma.Rope, old_tree: ?*c.TSTree) ?*c.TSTree {
        self.read_rope = rope;
        defer self.read_rope = null;
        const input: c.TSInput = .{
            .payload = self,
            .read = readCb,
            .encoding = c.TSInputEncodingUTF8,
            .decode = null,
        };
        return c.ts_parser_parse(self.parser, old_tree, input);
    }

    fn readCb(payload: ?*anyopaque, byte_index: u32, _: c.TSPoint, bytes_read: [*c]u32) callconv(.c) [*c]const u8 {
        const self: *Syntax = @ptrCast(@alignCast(payload.?));
        const rope = self.read_rope.?;
        const len = rope.byteLen();
        if (byte_index >= len) {
            bytes_read.* = 0;
            return null;
        }
        const n = @min(self.read_buf.len, len - byte_index);
        var sr = rope.streamReader(.{ .start = byte_index, .end = byte_index + n }, &.{});
        sr.interface.readSliceAll(self.read_buf[0..n]) catch unreachable;
        bytes_read.* = @intCast(n);
        return &self.read_buf;
    }

    /// Class-per-byte over `range` (caller frees). Captures paint in
    /// match order, later matches overwriting — the conventional
    /// highlight precedence.
    pub fn paint(self: *Syntax, gpa: Allocator, range: stemma.Range) ![]Class {
        const out = try gpa.alloc(Class, range.len());
        @memset(out, .none);
        const tree = self.tree orelse return out;
        const root = c.ts_tree_root_node(tree);
        _ = c.ts_query_cursor_set_byte_range(self.qcursor, @intCast(range.start), @intCast(range.end));
        c.ts_query_cursor_exec(self.qcursor, self.query, root);
        var match: c.TSQueryMatch = undefined;
        while (c.ts_query_cursor_next_match(self.qcursor, &match)) {
            if (!self.enabled[match.pattern_index]) continue;
            for (match.captures[0..match.capture_count]) |cap| {
                const class = self.classes[cap.index];
                if (class == .none) continue;
                const s = c.ts_node_start_byte(cap.node);
                const e = c.ts_node_end_byte(cap.node);
                const cs = @max(@as(usize, @intCast(s)), range.start);
                const ce = @min(@as(usize, @intCast(e)), range.end);
                if (cs >= ce) continue;
                @memset(out[cs - range.start .. ce - range.start], class);
            }
        }
        return out;
    }
};

test {
    std.testing.refAllDecls(@This());
}
