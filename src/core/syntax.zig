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
//!
//! Initial parse, off the open path: an incremental reparse (`sync`)
//! costs roughly the edit size, not the file size — tree-sitter does
//! that part for free. The FIRST parse of a freshly opened file has no
//! old tree to reuse, so its cost is the whole file, full stop.
//! `createAsync` (the interactive `open` path, `src/app/providers.zig`)
//! hands that one-time cost to a `task.Pool` worker instead of running
//! it inline: `self.tree` stays null (the buffer paints unhighlighted —
//! `paint`'s `tree orelse` fallback) until the worker's tree lands and
//! `sync` adopts it. Edits landing during that window are NOT lost: the
//! mirror is snapshotted at spawn time but `sync` refuses to drain it
//! while `pending_initial` is outstanding (every `editCb` before the
//! tree lands would be a no-op anyway — there's nothing to edit yet), so
//! they queue up as ordinary un-drained commits; the moment the worker's
//! tree lands, `sync` drains all of them at once — each becomes a
//! `ts_tree_edit` against the just-landed tree — and does ONE
//! incremental reparse to bring it current. Same semantics an edit gets
//! any other day, just batched. `create` (tests/tools that want a tree
//! back immediately) keeps the old, fully synchronous shape.
//!
//! The background job (`InitialParseJob`) owns EVERYTHING it touches —
//! its own re-opened grammar handle, its own `TSParser`, its own rope
//! snapshot, its own TSInput read buffer — none of it borrowed from the
//! `Syntax` it was spawned for. That is what lets `destroy` walk away
//! from a still-running job with no wait: there is nothing of `Syntax`'s
//! left for the worker to touch, so closing a buffer never has to wait
//! on the pool actually scheduling the parse — which matters because
//! production runs ONE shared pool where persistent readers (shells,
//! REPLs, the agent door, net collab — `proc_stream`/`repl_session`/
//! `net_session`/`proc`) can occupy every worker for their session's
//! whole lifetime; a join here would starve exactly like that class of
//! bug. `InitialParseJob.state` is the single-owner handoff for the
//! `*TSTree` it eventually produces: a plain CAS between "the worker
//! finished, here's the tree" and "`Syntax.destroy` got there first,
//! self-clean" — whichever side loses touches `result` not at all, so
//! there is no window where both a live pointer AND nobody who deletes
//! it exist at once.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const stemma = @import("stemma");
const build_options = @import("build_options");
const Document = @import("Document.zig");
const Mirror = @import("mirror.zig");
const task = @import("task.zig");

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
    .{
        .name = "javascript",
        .extensions = &.{ ".js", ".jsx", ".mjs", ".cjs" },
        .parser_dir = build_options.ts_javascript,
        .symbol = "tree_sitter_javascript",
        .highlights = @embedFile("ts_javascript_highlights"),
        .symbol_kinds = &.{ "function_declaration", "class_declaration", "lexical_declaration" },
    },
    .{
        .name = "html",
        .extensions = &.{ ".html", ".htm" },
        .parser_dir = build_options.ts_html,
        .symbol = "tree_sitter_html",
        .highlights = @embedFile("ts_html_highlights"),
    },
};

/// Everything about a language whose cost depends on the GRAMMAR rather
/// than on the buffer: the opened `.so`, the language, the compiled
/// highlight query and the tables derived from it. All of it is immutable
/// once built, so every buffer of a language shares one instance.
///
/// This exists because compiling the highlight query is not cheap and is
/// not proportional to anything per-buffer: `ts_query_new` on zig's 3.3KB
/// highlights costs ~18ms in ReleaseFast, which was previously paid on
/// EVERY buffer open — an order of magnitude more than opening the file,
/// reading it and building its CRDT put together. Compiling once per
/// grammar is the whole point of the type; a `Syntax` cannot compile its
/// own, so "accidentally recompile per buffer" is no longer expressible.
pub const Compiled = struct {
    lib: std.DynLib,
    lang: *const c.TSLanguage,
    query: *c.TSQuery,
    /// capture id → class; pattern id → enabled.
    classes: []Class,
    enabled: []bool,
    /// Owned copies of the inputs that determined everything above, held
    /// so the cache can recognise a spec by what it SAYS rather than by
    /// where it lives — `Runtime.specs` is an ArrayList, so a spec's
    /// address is not stable across `add`, and a config grammar may
    /// replace a built-in under the same name.
    key_parser_dir: []u8,
    key_symbol: []u8,
    key_highlights: []u8,

    fn matches(self: *const Compiled, spec: *const LanguageSpec) bool {
        return std.mem.eql(u8, self.key_parser_dir, spec.parser_dir) and
            std.mem.eql(u8, self.key_symbol, spec.symbol) and
            std.mem.eql(u8, self.key_highlights, spec.highlights);
    }

    fn destroy(self: *Compiled, gpa: Allocator) void {
        c.ts_query_delete(self.query);
        gpa.free(self.classes);
        gpa.free(self.enabled);
        gpa.free(self.key_parser_dir);
        gpa.free(self.key_symbol);
        gpa.free(self.key_highlights);
        self.lib.close();
        gpa.destroy(self);
    }
};

/// The runtime grammar registry: seeded with the built-ins, extended by
/// config through the `grammar-add` command (extension, package dir,
/// symbol — the highlight query is read from the package). Also the owner
/// of every `Compiled` grammar (see `compiledFor`) — the registry of
/// languages is the natural home for the artifacts of those languages,
/// and it gives them a lifetime that outlives any one buffer.
pub const Runtime = struct {
    const Owned = struct {
        spec: LanguageSpec,
        owned: bool,
    };

    specs: std.ArrayList(Owned) = .empty,
    /// Compiled grammars, built on first use and kept for the registry's
    /// life. A handful of entries at most, so a linear scan beats the
    /// ceremony of a keyed map.
    compiled: std.ArrayList(*Compiled) = .empty,
    /// `compiledFor` can be reached from more than one buffer attaching at
    /// once; the list and the compile itself are what this guards.
    compiled_mu: task.Mutex = .{},

    pub const empty: Runtime = .{};

    pub fn initBuiltins(gpa: Allocator) !Runtime {
        var self: Runtime = .empty;
        errdefer self.deinit(gpa);
        for (&languages) |*spec| {
            try self.specs.append(gpa, .{ .spec = spec.*, .owned = false });
        }
        return self;
    }

    /// The compiled form of `spec`, built once and shared thereafter.
    /// The result belongs to this `Runtime` and stays valid until it is
    /// deinit'd — callers borrow, never free.
    pub fn compiledFor(self: *Runtime, gpa: Allocator, spec: *const LanguageSpec) Error!*const Compiled {
        self.compiled_mu.lock();
        defer self.compiled_mu.unlock();
        for (self.compiled.items) |ce| if (ce.matches(spec)) return ce;

        const g = try loadGrammar(spec);
        var lib = g.lib;
        errdefer lib.close();
        // The parser `loadGrammar` hands back is per-USE state, not part of
        // the shared artifact — each `Syntax` makes its own from `lang`.
        c.ts_parser_delete(g.parser);

        var err_offset: u32 = 0;
        var err_type: c.TSQueryError = c.TSQueryErrorNone;
        const query = c.ts_query_new(
            g.lang,
            spec.highlights.ptr,
            @intCast(spec.highlights.len),
            &err_offset,
            &err_type,
        ) orelse {
            std.log.err("syntax {s}: query error {d} at byte {d}", .{ spec.name, err_type, err_offset });
            return error.QueryLoad;
        };
        errdefer c.ts_query_delete(query);

        const classes, const enabled = try deriveQueryTables(gpa, query);
        errdefer gpa.free(classes);
        errdefer gpa.free(enabled);

        const key_parser_dir = try gpa.dupe(u8, spec.parser_dir);
        errdefer gpa.free(key_parser_dir);
        const key_symbol = try gpa.dupe(u8, spec.symbol);
        errdefer gpa.free(key_symbol);
        const key_highlights = try gpa.dupe(u8, spec.highlights);
        errdefer gpa.free(key_highlights);

        const entry = try gpa.create(Compiled);
        errdefer gpa.destroy(entry);
        entry.* = .{
            .lib = lib,
            .lang = g.lang,
            .query = query,
            .classes = classes,
            .enabled = enabled,
            .key_parser_dir = key_parser_dir,
            .key_symbol = key_symbol,
            .key_highlights = key_highlights,
        };
        try self.compiled.append(gpa, entry);
        return entry;
    }

    /// How many grammars are compiled so far. For tests and diagnostics —
    /// nothing about behaviour depends on it.
    pub fn compiledCount(self: *Runtime) usize {
        self.compiled_mu.lock();
        defer self.compiled_mu.unlock();
        return self.compiled.items.len;
    }

    const WarmJob = struct { rt: *Runtime, gpa: Allocator };

    fn warmWorker(job: *WarmJob) void {
        defer job.gpa.destroy(job);
        // Best effort by construction: a grammar that cannot be compiled is
        // not this job's problem to report — the open that actually needs it
        // will try again and log there, exactly as if no warm had run.
        for (&languages) |*spec| _ = job.rt.compiledFor(job.gpa, spec) catch {};
    }

    /// Compile the BUILT-IN grammars on `pool`, so the first file of a
    /// language does not pay for it on the frame thread. tree-sitter offers
    /// no way to persist a compiled query (there is no serialization entry
    /// point in its API at all), so precomputing within the session is the
    /// only caching available — see `Compiled`.
    ///
    /// Built-ins only, and deliberately: their `LanguageSpec`s are static
    /// comptime data, so the worker cannot race `Runtime.add` reallocating
    /// `specs` out from under it. Config grammars still compile on first use.
    ///
    /// The caller must join `pool` before `deinit`ing this `Runtime` — the
    /// worker touches it. `main.zig` gets that from defer order (the pool is
    /// created after the registry, so it tears down first).
    pub fn warmBuiltins(self: *Runtime, gpa: Allocator, pool: *task.Pool) void {
        const job = gpa.create(WarmJob) catch return;
        job.* = .{ .rt = self, .gpa = gpa };
        var handle = pool.spawn(warmWorker, .{job}) catch {
            gpa.destroy(job);
            return;
        };
        // Nothing to poll it for: the results land in `compiled`, not in the
        // handle, and a warm that never runs is merely a slower first open.
        handle.detach();
    }

    pub fn deinit(self: *Runtime, gpa: Allocator) void {
        for (self.compiled.items) |ce| ce.destroy(gpa);
        self.compiled.deinit(gpa);
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

/// Test/embedding escape hatch for the compile-time catalog. Application code
/// must resolve through `Runtime.forPath`, so config-added grammars participate.
pub fn builtinForPath(path: []const u8) ?*const LanguageSpec {
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

/// dlopen `spec`'s grammar `.so` and hand back a parser already bound to
/// its language. Shared by `Syntax.createUnparsed` (whose parser serves
/// the QUERY compile below it, and every later incremental `sync`) and
/// `InitialParseJob.create` (whose parser is a wholly separate,
/// worker-owned instance — see module doc). `dlopen` on an
/// already-mapped `.so` is a fast refcount bump, not a second disk read,
/// so calling this twice per buffer is not the cost this file exists to
/// avoid.
fn loadGrammar(spec: *const LanguageSpec) Error!struct { lib: std.DynLib, parser: *c.TSParser, lang: *const c.TSLanguage } {
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

    return .{ .lib = lib, .parser = parser, .lang = lang };
}

/// A background initial-parse job (`Syntax.createAsync`), fully
/// independent of the `Syntax` it was spawned for — see module doc for
/// why. `state`/`result` are the single-owner CAS handoff for the tree:
/// 0 = undecided, 1 = the worker claimed it (finished, `result` is
/// final — `Syntax.sync` will adopt it), 2 = `Syntax.destroy` claimed it
/// first (the buffer closed before the parse landed — the worker
/// self-cleans instead of publishing). Whichever side LOSES the CAS
/// touches `result` not at all.
const InitialParseJob = struct {
    gpa: Allocator,
    lib: std.DynLib,
    parser: *c.TSParser,
    rope: stemma.Rope,
    read_buf: [4096]u8 = undefined,
    read_rope: ?*const stemma.Rope = null,
    state: std.atomic.Value(u8) = .init(0),
    result: ?*c.TSTree = null,

    const claimed_by_worker: u8 = 1;
    const claimed_by_syntax: u8 = 2;

    /// `rope` is a snapshot the caller hands off (this job becomes its
    /// sole owner — freed in `runAndRelease`/`abandonUnstarted`, whichever
    /// runs).
    fn create(gpa: Allocator, spec: *const LanguageSpec, rope: stemma.Rope) Error!*InitialParseJob {
        const g = try loadGrammar(spec);
        errdefer {
            c.ts_parser_delete(g.parser);
            var lib = g.lib;
            lib.close();
        }
        const job = try gpa.create(InitialParseJob);
        job.* = .{ .gpa = gpa, .lib = g.lib, .parser = g.parser, .rope = rope };
        return job;
    }

    /// Never spawned (grammar reload raced/OOM in `Syntax.createAsync`,
    /// or the pool itself failed to accept the task) — release every
    /// resource this job holds and free the job itself. There is no tree
    /// to worry about; the parse never ran.
    fn abandonUnstarted(self: *InitialParseJob) void {
        const gpa = self.gpa;
        c.ts_parser_delete(self.parser);
        self.lib.close();
        self.rope.deinit(gpa);
        gpa.destroy(self);
    }

    fn readCb(payload: ?*anyopaque, byte_index: u32, _: c.TSPoint, bytes_read: [*c]u32) callconv(.c) [*c]const u8 {
        const self: *InitialParseJob = @ptrCast(@alignCast(payload.?));
        const rope = self.read_rope.?;
        const len = rope.byteLen();
        if (byte_index >= len) {
            bytes_read.* = 0;
            return null;
        }
        var n = @min(self.read_buf.len, len - byte_index);
        // Hole-aware, same as `Syntax.readCb` — a partial checkout reads
        // as EOF at the first unrealized byte.
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

    /// Runs the (whole-file, no old tree — this job is single-use) parse
    /// and immediately releases every OTHER resource it holds — parser,
    /// grammar handle, rope snapshot — regardless of what happens to the
    /// tree afterward (published or self-deleted by the caller). Only
    /// the returned tree, if any, outlives this call.
    fn runAndRelease(self: *InitialParseJob) ?*c.TSTree {
        self.read_rope = &self.rope;
        const input: c.TSInput = .{
            .payload = self,
            .read = readCb,
            .encoding = c.TSInputEncodingUTF8,
            .decode = null,
        };
        const tree = c.ts_parser_parse(self.parser, null, input);
        self.read_rope = null;
        c.ts_parser_delete(self.parser);
        self.lib.close();
        self.rope.deinit(self.gpa);
        return tree;
    }
};

/// Pool-worker body for `Syntax.createAsync`'s initial parse. Runs the
/// parse, then races `Syntax.destroy` for ownership of the result via
/// `job.state`'s CAS (see `InitialParseJob`'s doc): lose, and this
/// deletes its own tree and frees the job — `Syntax` is already gone and
/// nothing else will ever look at `job` again; win, and `job` (tree
/// included) is left for `Syntax.sync` to adopt and free.
fn initialParseWorker(job: *InitialParseJob) void {
    const tree = job.runAndRelease();
    job.result = tree;
    const lost = job.state.cmpxchgStrong(0, InitialParseJob.claimed_by_worker, .release, .acquire) != null;
    if (lost) {
        if (tree) |t_| c.ts_tree_delete(t_);
        const gpa = job.gpa;
        gpa.destroy(job);
    }
}

/// capture id → class, and pattern id → enabled, read off a compiled
/// query. Both depend only on the query, so they are built once with it
/// and shared by every buffer of the language (see `Compiled`).
fn deriveQueryTables(gpa: Allocator, query: *c.TSQuery) Allocator.Error!struct { []Class, []bool } {
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
    return .{ classes, enabled };
}

pub const Syntax = struct {
    gpa: Allocator,
    /// The shared per-grammar artifacts — borrowed from the `Runtime` that
    /// owns them, never freed here.
    compiled: *const Compiled,
    parser: *c.TSParser,
    qcursor: *c.TSQueryCursor,
    tree: ?*c.TSTree = null,
    mirror: Mirror = .empty,
    spec: LanguageSpec,
    /// The document this instance mirrors (providers decline others;
    /// per-buffer instances race under the capability model).
    doc: *const Document,
    /// TSInput chunk buffer (parse-time only).
    read_buf: [4096]u8 = undefined,
    read_rope: ?*const stemma.Rope = null,
    /// The initial full parse, in flight on a pool worker (`createAsync`
    /// only) — a fully independent `InitialParseJob` (see module doc and
    /// its own doc comment for the ownership split and the CAS handoff).
    /// While set: `self.tree` is null. Never set by `create`.
    pending_initial: ?*InitialParseJob = null,

    /// Shared setup for both constructors below: makes this buffer's own
    /// parse-time state (parser, query cursor) over the already-`Compiled`
    /// grammar, and positions the mirror at the document's current commit.
    /// Does NOT parse, and does NOT compile — see `Compiled` for why that
    /// distinction is the difference between a 18ms open and a free one.
    fn createUnparsed(gpa: Allocator, compiled: *const Compiled, spec: *const LanguageSpec, doc: *const Document) Error!*Syntax {
        const self = try gpa.create(Syntax);
        errdefer gpa.destroy(self);

        const parser = c.ts_parser_new() orelse return error.OutOfMemory;
        errdefer c.ts_parser_delete(parser);
        if (!c.ts_parser_set_language(parser, compiled.lang)) return error.GrammarLoad;
        const qcursor = c.ts_query_cursor_new() orelse return error.OutOfMemory;
        errdefer c.ts_query_cursor_delete(qcursor);

        self.* = .{
            .gpa = gpa,
            .compiled = compiled,
            .parser = parser,
            .qcursor = qcursor,
            .spec = spec.*,
            .doc = doc,
        };

        // Adopt the current text (parsing it is each caller's job).
        self.mirror.rope = doc.text().snapshot();
        self.mirror.cursor = doc.commitCount();
        return self;
    }

    /// Loads the grammar and does the initial full parse of `doc`'s
    /// current text INLINE — for tests/tools that want a ready tree back.
    /// The interactive open path uses `createAsync` instead (see module
    /// doc): a full parse costs the whole file, and that must not run on
    /// the path that makes a buffer usable.
    pub fn create(gpa: Allocator, rt: *Runtime, spec: *const LanguageSpec, doc: *const Document) Error!*Syntax {
        const self = try createUnparsed(gpa, try rt.compiledFor(gpa, spec), spec, doc);
        self.tree = self.parse(doc.text(), null);
        return self;
    }

    /// Same setup as `create`, but the initial full parse runs on `pool`
    /// instead of inline, on a job that owns everything it touches (see
    /// `InitialParseJob`'s doc): this call returns with the buffer's
    /// mirror positioned and `self.tree` still null — the buffer is
    /// immediately usable and paints unhighlighted until the worker's
    /// tree lands (see module doc for how `sync` adopts it and folds in
    /// edits that landed meanwhile).
    pub fn createAsync(gpa: Allocator, pool: *task.Pool, rt: *Runtime, spec: *const LanguageSpec, doc: *const Document) Error!*Syntax {
        const self = try createUnparsed(gpa, try rt.compiledFor(gpa, spec), spec, doc);
        // A second, independent snapshot for the job: `self.mirror.rope`
        // stays put (untouched — `sync` won't drain it until the tree
        // lands), but the job needs its own refcounted handle since it
        // outlives this call and runs concurrently with whatever this
        // buffer does next.
        const worker_rope = self.mirror.rope.snapshot();
        const job = InitialParseJob.create(gpa, spec, worker_rope) catch {
            var wr = worker_rope;
            wr.deinit(gpa);
            // Degraded fallback (not a second supported mode — just the
            // one case, grammar reload/allocation failing for the
            // background job specifically, where parsing inline THIS
            // ONCE beats a buffer that never highlights at all).
            self.tree = self.parse(doc.text(), null);
            return self;
        };
        var handle = pool.spawn(initialParseWorker, .{job}) catch {
            job.abandonUnstarted();
            // Same degraded-fallback reasoning as above (OOM spawning).
            self.tree = self.parse(doc.text(), null);
            return self;
        };
        // Fire-and-forget: `task.Handle` only owns the pool's bookkeeping
        // for this task now (the worker's `void` return carries nothing —
        // the tree crosses through `job.result`, below), so there is
        // nothing to poll it FOR; detaching immediately means its
        // container reclaims itself whenever the worker finishes, with no
        // one required to ever look at it again.
        handle.detach();
        self.pending_initial = job;
        return self;
    }

    /// See module doc + `InitialParseJob`'s doc for the ownership split
    /// and the CAS handoff `state`/`result` implement; `destroy` is the
    /// other side of it.
    pub fn destroy(self: *Syntax) void {
        const gpa = self.gpa;
        if (self.pending_initial) |job| {
            // No join, no spin, no deadline: the job owns its own
            // parser/grammar-handle/rope — nothing of ours for a
            // still-running (or not-yet-STARTED — a saturated pool can
            // leave this queued behind persistent readers for a session's
            // whole lifetime) worker to touch, so there is nothing to
            // wait for here. We race the worker for `state` purely to
            // decide who deletes the tree, never to synchronize teardown.
            const lost = job.state.cmpxchgStrong(0, InitialParseJob.claimed_by_syntax, .release, .acquire) != null;
            if (lost) {
                // The worker already finished (and already claimed) before
                // we got here — its tree is ours to free now; nothing else
                // ever will.
                if (job.result) |t_| c.ts_tree_delete(t_);
                job.gpa.destroy(job);
            }
            // Else: the worker will see `state == claimed_by_syntax`
            // (whenever the pool gets around to running it) and clean up
            // after itself — see `initialParseWorker`.
            self.pending_initial = null;
        }
        if (self.tree) |t_| c.ts_tree_delete(t_);
        c.ts_query_cursor_delete(self.qcursor);
        c.ts_parser_delete(self.parser);
        self.mirror.deinit(gpa);
        // `self.compiled` belongs to the `Runtime`, which outlives every
        // buffer — nothing of it is freed here.
        gpa.destroy(self);
    }

    /// Fold new commits into the tree and reparse incrementally.
    /// Returns true when anything changed.
    ///
    /// While `createAsync`'s initial parse is still in flight (see module
    /// doc), this refuses to drain the mirror — every `editCb` before the
    /// tree lands is a no-op anyway (no tree to edit yet), which would
    /// otherwise advance `mirror.cursor` past commits and lose their
    /// `ts_tree_edit` deltas for good. Once the job's tree lands, draining
    /// resumes and folds in everything that queued up meanwhile as one
    /// incremental reparse — same shape as an ordinary edit.
    pub fn sync(self: *Syntax, gpa: Allocator, doc: *const Document) !bool {
        var changed = false;
        if (self.pending_initial) |job| {
            const st = job.state.load(.acquire);
            if (st == 0) return false; // still parsing
            // `sync`/`destroy` are never both reachable for a live
            // `Syntax` (the latter frees it) — the only claimant `sync`
            // can ever observe here is the worker's own.
            assert(st == InitialParseJob.claimed_by_worker);
            self.tree = job.result;
            self.pending_initial = null;
            job.gpa.destroy(job);
            changed = true;
        }
        const drained = try self.mirror.drain(gpa, doc, self, editCb);
        if (drained == 0) return changed;
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

    // ── Tree queries (plan 02 P7) ───────────────────────────────
    // Structural navigation the tree already holds, exposed for
    // textobjects/folding/imenu/structural edits. The tree stays
    // host-side (lifetime + one-impl safety, footgun rule b); only
    // MATERIALIZED node descriptors and query captures cross — nothing
    // holds a live `TSNode` across a reparse, so there is no dangling
    // handle. Offsets are read against the CURRENT tree (the caller reads
    // synchronously between edits); the durable version-stamped handle is
    // the wasm ABI's job, deferred with the sandbox.

    /// A materialized node: its grammar kind and byte span at the current
    /// tree. `kind` borrows from the grammar (valid while this Syntax
    /// lives); the span is plain data.
    pub const Node = struct {
        kind: []const u8,
        start: usize,
        end: usize,
        named: bool,
    };

    /// A query capture: the capture name and the matched byte span. `name`
    /// is gpa-owned (the temporary query it came from is already gone).
    pub const Capture = struct {
        name: []u8,
        start: usize,
        end: usize,
    };

    fn nodeInfo(node: c.TSNode) Node {
        return .{
            .kind = std.mem.span(c.ts_node_type(node)),
            .start = c.ts_node_start_byte(node),
            .end = c.ts_node_end_byte(node),
            .named = c.ts_node_is_named(node),
        };
    }

    /// The smallest NAMED node covering `off`, or null (offset out of the
    /// tree, or no tree). The node-at-point primitive.
    pub fn nodeAt(self: *Syntax, off: usize) ?Node {
        const tree = self.tree orelse return null;
        const root = c.ts_tree_root_node(tree);
        const n = c.ts_node_named_descendant_for_byte_range(root, @intCast(off), @intCast(off));
        if (c.ts_node_is_null(n)) return null;
        return nodeInfo(n);
    }

    /// Named ancestors of the node at `off`, OUTERMOST-first (root → the
    /// node). The parent/enclosing-scope primitive without a live handle.
    /// Caller frees the slice.
    pub fn ancestorsAt(self: *Syntax, gpa: Allocator, off: usize) ![]Node {
        var chain: std.ArrayList(Node) = .empty;
        defer chain.deinit(gpa);
        if (self.tree) |tree| {
            const root = c.ts_tree_root_node(tree);
            var n = c.ts_node_named_descendant_for_byte_range(root, @intCast(off), @intCast(off));
            while (!c.ts_node_is_null(n)) {
                try chain.append(gpa, nodeInfo(n));
                n = c.ts_node_parent(n);
            }
            std.mem.reverse(Node, chain.items); // leaf→root becomes root→leaf
        }
        return chain.toOwnedSlice(gpa);
    }

    /// The named children of the smallest node at `off` (its immediate
    /// structural constituents — siblings of one another). Caller frees.
    pub fn childrenAt(self: *Syntax, gpa: Allocator, off: usize) ![]Node {
        var out: std.ArrayList(Node) = .empty;
        defer out.deinit(gpa);
        if (self.tree) |tree| {
            const root = c.ts_tree_root_node(tree);
            const parent = c.ts_node_named_descendant_for_byte_range(root, @intCast(off), @intCast(off));
            if (!c.ts_node_is_null(parent)) {
                const count = c.ts_node_named_child_count(parent);
                for (0..count) |i| try out.append(gpa, nodeInfo(c.ts_node_named_child(parent, @intCast(i))));
            }
        }
        return out.toOwnedSlice(gpa);
    }

    /// Run an arbitrary tree-sitter query (`.scm`) over `range` and return
    /// its captures, materialized so the tree never crosses the boundary.
    /// The one primitive folding/textobjects/imenu are all expressible in.
    /// Caller frees the slice and every `.name`.
    pub fn queryCaptures(self: *Syntax, gpa: Allocator, scm: []const u8, range: stemma.Range) Error![]Capture {
        var out: std.ArrayList(Capture) = .empty;
        errdefer {
            for (out.items) |cap| gpa.free(cap.name);
            out.deinit(gpa);
        }
        const tree = self.tree orelse return out.toOwnedSlice(gpa);
        const lang = c.ts_parser_language(self.parser);
        var err_offset: u32 = 0;
        var err_type: c.TSQueryError = c.TSQueryErrorNone;
        const q = c.ts_query_new(lang, scm.ptr, @intCast(scm.len), &err_offset, &err_type) orelse
            return error.QueryLoad;
        defer c.ts_query_delete(q);
        const cursor = c.ts_query_cursor_new() orelse return error.OutOfMemory;
        defer c.ts_query_cursor_delete(cursor);
        _ = c.ts_query_cursor_set_byte_range(cursor, @intCast(range.start), @intCast(range.end));
        c.ts_query_cursor_exec(cursor, q, c.ts_tree_root_node(tree));
        var match: c.TSQueryMatch = undefined;
        while (c.ts_query_cursor_next_match(cursor, &match)) {
            for (match.captures[0..match.capture_count]) |cap| {
                var nlen: u32 = 0;
                const name = c.ts_query_capture_name_for_id(q, cap.index, &nlen);
                try out.append(gpa, .{
                    .name = try gpa.dupe(u8, name[0..nlen]),
                    .start = c.ts_node_start_byte(cap.node),
                    .end = c.ts_node_end_byte(cap.node),
                });
            }
        }
        return out.toOwnedSlice(gpa);
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
        c.ts_query_cursor_exec(self.qcursor, self.compiled.query, root);
        var match: c.TSQueryMatch = undefined;
        while (c.ts_query_cursor_next_match(self.qcursor, &match)) {
            if (!self.compiled.enabled[match.pattern_index]) continue;
            for (match.captures[0..match.capture_count]) |cap| {
                const class = self.compiled.classes[cap.index];
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
    if (req.doc != self.doc) {
        // Another buffer's instance will answer (per-buffer race).
        caps.decline(req.session);
        return;
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
