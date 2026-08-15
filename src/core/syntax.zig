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

/// Class vocabulary comes from the edit/highlight capability schema;
/// capture names map by their first dotted segment
/// ("punctuation.bracket" → .punctuation).
pub const Class = @import("capability.zig").HighlightClass;

pub const LanguageSpec = struct {
    name: []const u8,
    extensions: []const []const u8,
    parser_dir: []const u8,
    symbol: [:0]const u8,
    highlights: []const u8,
    /// Node kinds that define document symbols (name = first identifier
    /// child). Data, not code — a grammar registration supplies its own.
    symbol_kinds: []const []const u8 = &.{},
};

/// Built-in grammar registrations (pinned store paths via build
/// options). Runtime additions go through `Runtime.add` — a config/data
/// change, not code.
pub const languages = [_]LanguageSpec{
    .{
        .name = "zig",
        .extensions = &.{".zig"},
        .parser_dir = build_options.ts_zig,
        .symbol = "tree_sitter_zig",
        .highlights = @embedFile("ts_zig_highlights"),
        .symbol_kinds = &.{ "function_declaration", "variable_declaration", "struct_declaration" },
    },
    .{
        .name = "fennel",
        .extensions = &.{".fnl"},
        .parser_dir = build_options.ts_fennel,
        .symbol = "tree_sitter_fennel",
        .highlights = @embedFile("ts_fennel_highlights"),
    },
    .{
        .name = "lua",
        .extensions = &.{".lua"},
        .parser_dir = build_options.ts_lua,
        .symbol = "tree_sitter_lua",
        .highlights = @embedFile("ts_lua_highlights"),
        .symbol_kinds = &.{ "function_declaration", "function_definition" },
    },
    .{
        .name = "nix",
        .extensions = &.{".nix"},
        .parser_dir = build_options.ts_nix,
        .symbol = "tree_sitter_nix",
        .highlights = @embedFile("ts_nix_highlights"),
    },
};

/// The runtime grammar registry: seeded with the built-ins, extended by
/// config through the `grammar-add` command (extension, package dir,
/// symbol — the highlight query is read from the package).
pub const Runtime = struct {
    const Owned = struct {
        spec: LanguageSpec,
        owned: bool,
    };

    specs: std.ArrayList(Owned) = .empty,

    pub const empty: Runtime = .{};

    pub fn initBuiltins(gpa: Allocator) !Runtime {
        var self: Runtime = .empty;
        errdefer self.deinit(gpa);
        for (&languages) |*spec| {
            try self.specs.append(gpa, .{ .spec = spec.*, .owned = false });
        }
        return self;
    }

    pub fn deinit(self: *Runtime, gpa: Allocator) void {
        for (self.specs.items) |*o| {
            if (o.owned) {
                gpa.free(@constCast(o.spec.name));
                gpa.free(@constCast(o.spec.extensions[0]));
                gpa.free(@constCast(o.spec.extensions));
                gpa.free(@constCast(o.spec.parser_dir));
                gpa.free(@constCast(o.spec.symbol[0 .. o.spec.symbol.len + 1]));
                gpa.free(@constCast(o.spec.highlights));
            }
        }
        self.specs.deinit(gpa);
        self.* = .{};
    }

    /// Register a grammar from a package directory laid out like the
    /// nixpkgs tree-sitter grammars (`parser` + `queries/highlights.scm`).
    pub fn add(self: *Runtime, gpa: Allocator, ext: []const u8, dir: []const u8, symbol: []const u8) !void {
        const file = @import("file.zig");
        var qpath_buf: [512]u8 = undefined;
        const qpath = try std.fmt.bufPrint(&qpath_buf, "{s}/queries/highlights.scm", .{dir});
        const highlights = try file.readAlloc(gpa, qpath);
        errdefer gpa.free(highlights);
        const name = try gpa.dupe(u8, std.mem.trimStart(u8, ext, "."));
        errdefer gpa.free(name);
        const ext_owned = try gpa.dupe(u8, ext);
        errdefer gpa.free(ext_owned);
        const exts = try gpa.alloc([]const u8, 1);
        errdefer gpa.free(exts);
        exts[0] = ext_owned;
        const dir_owned = try gpa.dupe(u8, dir);
        errdefer gpa.free(dir_owned);
        const sym = try gpa.dupeZ(u8, symbol);
        errdefer gpa.free(sym[0 .. sym.len + 1]);
        try self.specs.append(gpa, .{ .owned = true, .spec = .{
            .name = name,
            .extensions = exts,
            .parser_dir = dir_owned,
            .symbol = sym,
            .highlights = highlights,
        } });
    }

    pub fn forPath(self: *const Runtime, path: []const u8) ?*const LanguageSpec {
        // Later registrations shadow earlier (config over builtin).
        var i = self.specs.items.len;
        while (i > 0) {
            i -= 1;
            const spec = &self.specs.items[i].spec;
            for (spec.extensions) |ext| {
                if (std.mem.endsWith(u8, path, ext)) return spec;
            }
        }
        return null;
    }
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
    spec: LanguageSpec,
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
            .spec = spec.*,
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
        var n = @min(self.read_buf.len, len - byte_index);
        // Hole-aware: a partially materialized document (remote partial
        // checkout) reads as EOF at the first unrealized byte — the
        // parse degrades to the materialized prefix; it never forces a
        // fetch and never crashes. Halving finds a realized prefix.
        while (n > 0 and !rope.isRealized(.{ .start = byte_index, .end = byte_index + n })) {
            n /= 2;
        }
        if (n == 0) {
            bytes_read.* = 0;
            return null;
        }
        var sr = rope.streamReader(.{ .start = byte_index, .end = byte_index + n }, &.{});
        sr.interface.readSliceAll(self.read_buf[0..n]) catch unreachable;
        bytes_read.* = @intCast(n);
        return &self.read_buf;
    }

    /// Parse an arbitrary rope with this grammar (holey-document
    /// robustness testing; the live path goes through `sync`).
    pub fn reparseRope(self: *Syntax, rope: *const stemma.Rope) void {
        const new_tree = self.parse(rope, null);
        if (self.tree) |old| c.ts_tree_delete(old);
        self.tree = new_tree;
    }

    /// Publish paint over `range` into a highlight feed layer, stamped
    /// with the document's head version.
    pub fn publishHighlight(
        self: *Syntax,
        gpa: Allocator,
        doc: *const Document,
        layer: *@import("layers.zig").Layer,
        range: stemma.Range,
    ) !void {
        const classes = try self.paint(gpa, range);
        defer gpa.free(classes);
        const token = try doc.version(gpa);
        defer gpa.free(token);
        try layer.publishBulk(gpa, token, range.start, @ptrCast(classes));
    }

    // ── Instant-tier providers ──────────────────────────────────

    pub const Sym = struct { name: []u8, start: usize, end: usize };

    /// Walk the tree for `symbol_kinds` nodes (depth ≤ 3); names are
    /// gpa-owned by the caller.
    pub fn collectSymbols(self: *Syntax, gpa: Allocator, doc: *const Document, out: *std.ArrayList(Sym)) !void {
        const tree = self.tree orelse return;
        try self.walkSymbols(gpa, doc, c.ts_tree_root_node(tree), 0, out);
    }

    fn walkSymbols(self: *Syntax, gpa: Allocator, doc: *const Document, node: c.TSNode, depth: u8, out: *std.ArrayList(Sym)) !void {
        if (depth > 3) return;
        const count = c.ts_node_named_child_count(node);
        for (0..count) |i| {
            const child = c.ts_node_named_child(node, @intCast(i));
            const kind = std.mem.span(c.ts_node_type(child));
            var is_symbol = false;
            for (self.spec.symbol_kinds) |k| {
                if (std.mem.eql(u8, kind, k)) {
                    is_symbol = true;
                    break;
                }
            }
            if (is_symbol) {
                if (identifierOf(child)) |id_node| {
                    const s = c.ts_node_start_byte(id_node);
                    const e = c.ts_node_end_byte(id_node);
                    if (e > s and e - s <= 256 and e <= doc.text().byteLen()) {
                        const name = try gpa.alloc(u8, e - s);
                        errdefer gpa.free(name);
                        var sr = doc.text().streamReader(.{ .start = s, .end = e }, &.{});
                        sr.interface.readSliceAll(name) catch unreachable;
                        try out.append(gpa, .{
                            .name = name,
                            .start = c.ts_node_start_byte(child),
                            .end = c.ts_node_end_byte(child),
                        });
                    }
                }
            }
            try self.walkSymbols(gpa, doc, child, depth + 1, out);
        }
    }

    fn identifierOf(node: c.TSNode) ?c.TSNode {
        const count = c.ts_node_named_child_count(node);
        for (0..count) |i| {
            const child = c.ts_node_named_child(node, @intCast(i));
            const kind = std.mem.span(c.ts_node_type(child));
            if (std.mem.indexOf(u8, kind, "identifier") != null or std.mem.eql(u8, kind, "name")) {
                return child;
            }
        }
        return null;
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

// ── Capability wiring ───────────────────────────────────────────────

const capability = @import("capability.zig");

/// Register the instant tier: same-file definition + document symbols,
/// scoped to this grammar's extensions. This is the cheap tier that
/// races the LSP providers.
pub fn registerProviders(caps: *capability.Caps, self: *Syntax) !void {
    var id_buf: [64]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "treesitter/{s}", .{self.spec.name});
    for ([_][]const u8{ "edit/definition", "edit/symbols-document" }) |cap| {
        try caps.register(.{
            .capability = cap,
            .id = id,
            .latency = .instant,
            .priority = 1,
            .extensions = self.spec.extensions,
            .data = self,
            .handler = tsProvider,
        });
    }
}

fn tsProvider(data: ?*anyopaque, caps: *capability.Caps, req: *const capability.Request) anyerror!void {
    const self: *Syntax = @ptrCast(@alignCast(data.?));
    const gpa = self.gpa;
    switch (req.kind) {
        .symbols, .definition => {},
        else => {
            caps.decline(req.session);
            return;
        },
    }
    var syms: std.ArrayList(Syntax.Sym) = .empty;
    defer {
        for (syms.items) |s| gpa.free(s.name);
        syms.deinit(gpa);
    }
    try self.collectSymbols(gpa, req.doc, &syms);

    if (req.kind == .symbols) {
        const out = try gpa.alloc(capability.Symbol, syms.items.len);
        defer gpa.free(out);
        for (syms.items, 0..) |s, i| {
            out[i] = .{
                .name = s.name,
                .kind = 0,
                .range = @import("position.zig").StampedRange.at(req.version, s.start, s.end),
            };
        }
        try caps.push(req.session, .{ .id = "treesitter", .priority = 1 }, .{ .symbols = out });
        return;
    }

    // Definition: the identifier under the cursor, matched against
    // collected symbol names.
    const word = try wordAt(gpa, req.doc, req.offset);
    defer gpa.free(word);
    var locs: std.ArrayList(capability.Location) = .empty;
    defer locs.deinit(gpa);
    if (word.len > 0) {
        for (syms.items) |s| {
            if (std.mem.eql(u8, s.name, word)) {
                try locs.append(gpa, .{
                    .range = @import("position.zig").StampedRange.at(req.version, s.start, s.end),
                });
                break;
            }
        }
    }
    try caps.push(req.session, .{ .id = "treesitter", .priority = 1 }, .{ .locations = locs.items });
}

/// The word (ASCII-classed, non-ASCII counts in) containing `offset`.
fn wordAt(gpa: Allocator, doc: *const Document, offset: usize) ![]u8 {
    const rope = doc.text();
    const len = rope.byteLen();
    const start = offset -| 64;
    const end = @min(len, offset + 64);
    if (start >= end) return gpa.alloc(u8, 0);
    const buf = try gpa.alloc(u8, end - start);
    defer gpa.free(buf);
    var sr = rope.streamReader(.{ .start = start, .end = end }, &.{});
    sr.interface.readSliceAll(buf) catch unreachable;
    const rel = offset - start;
    var a = rel;
    while (a > 0 and isWord(buf[a - 1])) a -= 1;
    var b = rel;
    while (b < buf.len and isWord(buf[b])) b += 1;
    return gpa.dupe(u8, buf[a..b]);
}

fn isWord(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch >= 0x80;
}
