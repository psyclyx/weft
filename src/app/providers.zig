//! Per-buffer provider attachments. Syntax is a per-buffer instance hanging off
//! `Buffer.frontend`; its capability providers decline foreign documents, so
//! per-buffer registrations race correctly. Highlight layers key by (doc, name)
//! in the shared store. Also the config-supplied grammar registry these attach
//! from (`grammar-add`) and the pooled reconnect task. LSP is no longer here at
//! all — it's an async wasm plugin (`src/guest/lsp.zig`) that talks to servers
//! over the streaming membrane and provides every capability, completion
//! included, as a caps provider; server commands come from config, not a
//! registry. See [[lsp-plugin-migration]].

const std = @import("std");
const core = @import("../core/core.zig");
const collab = @import("collab.zig");

/// `grammar-add <exts> <grammar> <symbol> [query] [symbol-kinds]` — grammars
/// as data. `exts` and `symbol-kinds` are comma-separated; `grammar` is a name
/// resolved along the registry's search path, or an absolute package
/// directory. Every field of a `Registration` is reachable from here: there is
/// no richer way to describe a grammar that config cannot say.
pub fn grammarAddCommand(runtime: *core.syntax.Runtime) core.command.Command {
    return .{
        .name = "grammar-add",
        .summary = "Register a tree-sitter grammar for one or more extensions.",
        .args = &.{
            .{ .name = "exts", .type = .string },
            .{ .name = "grammar", .type = .string },
            .{ .name = "symbol", .type = .string },
            .{ .name = "query", .type = .string },
            .{ .name = "symbol-kinds", .type = .string },
        },
        .handler = grammarAddHandler,
        .data = runtime,
    };
}

/// The FEWEST arguments `grammar-add` will act on. This — not the declared
/// arity, which is larger because query and symbol-kinds are optional — is the
/// number that has to stay out of guest reach: it is what it takes to get to
/// `std.DynLib.open` on a caller-named directory. The gate below reads this,
/// so the two cannot drift apart.
pub const grammar_add_min_args = 3;

fn grammarAddHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const runtime: *core.syntax.Runtime = @ptrCast(@alignCast(data.?));
    if (args.len < grammar_add_min_args or args.len > 5) return error.ArityMismatch;
    for (args) |a| {
        if (a != .string) return error.TypeMismatch;
    }
    // An empty trailing string means "not given" — config writing '' for a
    // query it does not want to override should mean the default, not a read
    // of the empty path.
    const optional = struct {
        fn at(list: []const core.command.Value, i: usize) ?[]const u8 {
            if (i >= list.len) return null;
            const s = list[i].string;
            return if (s.len == 0) null else s;
        }
    };
    try runtime.add(ctx.gpa, .{
        .extensions = args[0].string,
        .grammar = args[1].string,
        .symbol = args[2].string,
        .query = optional.at(args, 3),
        .symbol_kinds = optional.at(args, 4),
    });
    return .nil;
}

pub fn reconnectTask(hostport: []const u8) anyerror!i32 {
    return core.session.tcpConnect(hostport);
}

// ── Per-buffer provider attachments ─────────────────────────────────
// Syntax is a per-buffer instance hanging off Buffer.frontend; its
// capability providers decline foreign documents, so per-buffer
// registrations race correctly. Highlight layers key by (doc, name) in
// the shared store.

pub const Attach = struct {
    syntax: ?*core.syntax.Syntax = null,
    seen_commits: usize = 0,
};

/// The `abi.SyntaxResolver` the catalog uses: reach a buffer's live grammar
/// through the shell-owned frontend slot (core cannot; the host can).
pub fn resolveSyntax(buf: *core.Buffers.Buffer) ?*core.syntax.Syntax {
    const at: *Attach = @ptrCast(@alignCast(buf.frontend orelse return null));
    return at.syntax;
}

pub const AttachDeps = struct {
    gpa: std.mem.Allocator,
    grammars: *core.syntax.Runtime,
    caps: *core.Caps,
    environ: std.process.Environ,
    /// Set once the connection exists: buffer close unbinds shares
    /// before the document dies.
    share: ?*collab.ShareCtx = null,
    /// Persistent shells per remote host (ssh spawner), created on
    /// first `open host:path` and reused for every buffer on that host.
    shells: std.StringHashMapUnmanaged(*core.ShellFs) = .empty,

    pub fn deinitShells(self: *AttachDeps) void {
        var it = self.shells.iterator();
        while (it.next()) |e| {
            e.value_ptr.*.deinit();
            self.gpa.destroy(e.value_ptr.*);
            self.gpa.free(e.key_ptr.*);
        }
        self.shells.deinit(self.gpa);
    }

    pub fn shellFor(self: *AttachDeps, host: []const u8) !*core.ShellFs {
        if (self.shells.get(host)) |fs| return fs;
        const fs = try self.gpa.create(core.ShellFs);
        errdefer self.gpa.destroy(fs);
        // BatchMode=yes: never block on an interactive password prompt (a
        // classic hang); ConnectTimeout bounds an unreachable host. The
        // spawn is still synchronous on the frame thread, but now it fails
        // fast instead of wedging the editor.
        fs.* = try core.ShellFs.spawn(self.gpa, &.{
            "ssh", "-o",               "BatchMode=yes",
            "-o",  "ConnectTimeout=8", host,
            "sh",
        }, self.environ);
        errdefer fs.deinit();
        try self.shells.put(self.gpa, try self.gpa.dupe(u8, host), fs);
        return fs;
    }
};

/// Idempotent: give a buffer its provider bundle (syntax by extension,
/// LSP when locally placed). Buffers without a path get an empty
/// bundle (tool/scratch); so does an entry with no text to parse.
pub fn attachProviders(deps: *AttachDeps, buf: *core.Buffers.Buffer) !void {
    if (buf.frontend != null) return;
    const gpa = deps.gpa;
    const at = try gpa.create(Attach);
    at.* = .{};
    buf.frontend = at;
    const editor = buf.textEditor() orelse return;
    const doc = &editor.doc;

    // The buffer's *language* is identified by its name/path hint —
    // independent of where the bytes live. A shared (remote) buffer holds
    // its content in our replica, so tree-sitter highlights it locally
    // even with no local file backing. (Local) LSP is different: the
    // server needs the file on this machine, so it attaches only to a
    // locally-backed buffer, below.
    const lang_path = editor.backingPath() orelse buf.name;

    if (deps.grammars.forPath(lang_path)) |spec| {
        // `createAsync`, not `create`: the initial full parse costs the
        // whole file (an incremental reparse after only costs the edit —
        // tree-sitter does that part for free), so it runs on the
        // buffer's own pool worker instead of blocking `open`. See
        // src/core/syntax.zig's module doc for how the tree lands.
        at.syntax = core.syntax.Syntax.createAsync(gpa, editor.pool, deps.grammars, spec, doc) catch |err| blk: {
            std.log.warn("syntax {s} unavailable: {t}", .{ spec.name, err });
            break :blk null;
        };
    }
    if (at.syntax) |syn| {
        try core.syntax.registerProviders(deps.caps, syn);
        _ = try deps.caps.registerFeed(doc, "edit/highlight", "highlight", .local, "treesitter");
    }
    // LSP (all capabilities, completion included) is the `lsp` wasm plugin now,
    // attaching via its own on_activate — nothing to wire per-buffer here.
}

pub fn detachProviders(deps: *AttachDeps, buf: *core.Buffers.Buffer) void {
    const at: *Attach = @ptrCast(@alignCast(buf.frontend orelse return));
    if (at.syntax) |s| s.destroy();
    if (buf.textEditor()) |ed| deps.caps.layers.dropDoc(deps.gpa, &ed.doc);
    deps.gpa.destroy(at);
    buf.frontend = null;
}

/// The provider cluster, owned as one unit: the config-extended grammar registry
/// (`grammars`) plus the per-buffer attach bundle (`attach_deps`). It mirrors how
/// `RenderState`/`Session` own their clusters — `main()` holds one `providers`
/// object instead of loose provider locals.
///
/// Two-phase, because the pieces are born at different times: the registry exists
/// BEFORE the session (its capability consumers bind `grammar-add` onto it),
/// while `attach_deps` borrows the session's caps, so it is built AFTER.
///
/// CRITICAL TEARDOWN ORDER — the whole reason this is a distinct cluster:
/// `attach_deps.deinitShells()` must run AFTER the buffers die (in-flight save
/// workers still use shell backings at shutdown) AND after the task pool joins
/// (a pool worker may still hold a shell). `main()` guarantees this by
/// registering `Providers.deinit` FIRST (so it runs LAST) — after both
/// `Session.deinit` and `pool.deinit`. Grammars/LSP are independent data, freed
/// here too (their syntax instances were already destroyed by `detachProviders`,
/// which `main()` runs before this).
pub const Providers = struct {
    grammars: core.syntax.Runtime,
    attach_deps: AttachDeps,
    /// `attach_deps` is filled in phase two; until then `deinit` must not touch
    /// it (an early error between the two phases would otherwise free garbage).
    attached: bool,

    /// Phase one: the config-extended registries, built before the session.
    pub fn initRegistries(self: *Providers, gpa: std.mem.Allocator) !void {
        self.grammars = try core.syntax.Runtime.initBuiltins(gpa);
        errdefer self.grammars.deinit(gpa);
        self.attached = false;
    }

    /// Phase two: the per-buffer attach bundle, built once the session's caps are
    /// known. It borrows into `self` (grammars), so it must run IN PLACE (self
    /// already at its final address). `share` is wired by `main()` once the collab
    /// state exists.
    pub fn initAttach(
        self: *Providers,
        gpa: std.mem.Allocator,
        caps: *core.Caps,
        environ: std.process.Environ,
    ) void {
        self.attach_deps = .{
            .gpa = gpa,
            .grammars = &self.grammars,
            .caps = caps,
            .environ = environ,
        };
        self.attached = true;
    }

    /// Free in the order `main()`'s defers used to run: grammars, then the
    /// persistent remote shells LAST (they outlive buffers + pool).
    pub fn deinit(self: *Providers, gpa: std.mem.Allocator) void {
        self.grammars.deinit(gpa);
        if (self.attached) self.attach_deps.deinitShells();
    }
};

// ── `grammar-add` is held shut by ARITY. Keep it that way. ───────────
//
// `grammar-add` hands a caller-supplied directory to `std.DynLib.open`
// (`core/syntax.zig`'s `loadGrammar`) — arbitrary NATIVE code into this
// process — and it is an ordinary bound command with no permission gate.
// For its one real caller that is fine and deliberate: config JS is a
// trusted tier that can already load arbitrary wasm through `weft.plugin`,
// so refusing it a `.so` would be theatre (doc/place.md §4).
//
// For a WASM GUEST it would not be fine, and today a guest cannot reach it
// — but only by accident. The membrane's command runners top out at TWO
// arguments (`wl_run_str2`); `grammar-add` declares three, so every guest
// call dies on `error.ArityMismatch` before `loadGrammar` is reached. That
// is a sandbox escape held shut by a coincidence of signatures.
//
// The census below turns the coincidence into a property, and the test
// under it fails the moment either side moves: a runner gaining the arity
// to pass three arguments, or `grammar-add` shrinking to a shape a runner
// can already call. Whichever fires, the answer is the same — put a real
// gate on the door BEFORE it becomes reachable, not after.

const contract_data = @import("../core/membrane/contract_data.zig");

/// The census: every wasm-membrane import that could plausibly run a
/// command (see `mustBeCensused`), and the number of arguments it hands
/// `command.run` under a GUEST-SUPPLIED NAME. `0` covers both "runs a
/// command with no arguments" and "never calls `command.run` at all" —
/// either way it can pass none, which is all this gate asks.
///
/// Derived by grepping `command.run(` across `src/core/wasm_host/`:
/// `commands.zig`'s four and `edit.zig`'s two are the whole set.
///
/// `wl_intent_invoke` is deliberately absent: it resolves a dotted
/// INTENTION name through the catalog and calls a registered endpoint, so
/// it can neither name a bare command nor forward guest arguments to one.
const guest_command_runners = [_]struct { name: []const u8, args: usize }{
    // The runners.
    .{ .name = "wl_run", .args = 0 },
    .{ .name = "wl_run_int", .args = 1 },
    .{ .name = "wl_run_str", .args = 1 },
    .{ .name = "wl_run_str2", .args = 2 },
    .{ .name = "wl_run_range", .args = 0 },
    .{ .name = "wl_run_range_arg", .args = 1 },
    // In the `.commands` group, but they only intern a name or read the
    // registry — no `command.run` at all.
    .{ .name = "wl_register", .args = 0 },
    .{ .name = "wl_command_count", .args = 0 },
    .{ .name = "wl_command_name", .args = 0 },
    .{ .name = "wl_command_summary", .args = 0 },
};

/// Entries the census must account for, so a new runner cannot slip past
/// it unnoticed. Two independent nets, because a runner could plausibly be
/// added under either convention: everything in the `.commands` group
/// (whose whole purpose is running commands), and everything anywhere in
/// the contract whose name says "run". A door that is neither — a runner
/// in some other group under some other name — would still escape this,
/// which is why the census above records how it was derived.
fn mustBeCensused(entry: contract_data.Entry) bool {
    return entry.group == .commands or std.mem.indexOf(u8, entry.name, "run") != null;
}

const t = std.testing;

test "providers: no guest command runner can reach grammar-add's arity (it DynLib.opens a caller-named directory)" {
    const gpa = t.allocator;

    // 1. The census is COMPLETE: every import that could plausibly be a
    //    runner is accounted for. A new `wl_run_str3` lands here first.
    for (contract_data.imports) |entry| {
        if (!mustBeCensused(entry)) continue;
        var listed = false;
        for (guest_command_runners) |r| {
            if (std.mem.eql(u8, r.name, entry.name)) listed = true;
        }
        if (!listed) {
            std.debug.print(
                "\nsrc/app/providers.zig: '{s}' is a new membrane import that may run a command.\n" ++
                    "Add it to `guest_command_runners` with the number of arguments it\n" ++
                    "passes to `command.run` (0 if it never calls it) — and if that number\n" ++
                    "reaches 3, `grammar-add` just became reachable from a wasm guest, which\n" ++
                    "means `std.DynLib.open` on a guest-named directory did too.\n" ++
                    "Gate the door before landing the runner, not after.\n",
                .{entry.name},
            );
            return error.UncensusedCommandRunner;
        }
    }

    // 2. The census is CURRENT: nothing in it has been renamed away, which
    //    would leave a stale row silently guarding nothing.
    for (guest_command_runners) |r| {
        var found = false;
        for (contract_data.imports) |entry| {
            if (std.mem.eql(u8, entry.name, r.name)) found = true;
        }
        if (!found) {
            std.debug.print("\nsrc/app/providers.zig: `guest_command_runners` names '{s}', which is no longer a membrane import.\n", .{r.name});
            return error.StaleCommandRunnerCensus;
        }
    }

    // 3. The property itself: `grammar-add` takes more arguments than any
    //    guest can pass, so a guest call cannot survive `command.run`'s
    //    arity check to reach `std.DynLib.open`.
    var max_guest_args: usize = 0;
    for (guest_command_runners) |r| max_guest_args = @max(max_guest_args, r.args);

    var runtime: core.syntax.Runtime = .empty;
    defer runtime.deinit(gpa);
    const grammar_add = grammarAddCommand(&runtime);
    // Deliberately the MINIMUM the handler acts on, not `grammar_add.args.len`.
    // Those were the same number until query and symbol-kinds became optional;
    // comparing the declared count now would overstate the barrier and let a
    // three-argument guest runner through while still reporting green.
    if (grammar_add_min_args <= max_guest_args) {
        std.debug.print(
            "\nsrc/app/providers.zig: a wasm guest can now pass {d} argument(s) to a command\n" ++
                "by name, and `grammar-add` acts on {d} — so a guest can reach\n" ++
                "`std.DynLib.open` on a directory it chose. The arity coincidence that held\n" ++
                "this shut is gone; `grammar-add` needs a real permission gate now.\n",
            .{ max_guest_args, grammar_add_min_args },
        );
        return error.GrammarAddIsGuestReachable;
    }
    // Today's numbers, pinned so the margin itself is visible when either side
    // moves: two arguments reachable, three required to do anything.
    try t.expectEqual(@as(usize, 2), max_guest_args);
    try t.expectEqual(@as(usize, 3), grammar_add_min_args);
    try t.expectEqual(@as(usize, 5), grammar_add.args.len);

    // And the handler agrees with the declaration — the arity check that
    // does the actual refusing reads `args.len`, not the `.args` table.
    var ctx: core.command.Context = undefined; // never reached: arity fails first
    try t.expectError(error.ArityMismatch, grammar_add.handler(
        &ctx,
        grammar_add.data,
        &.{ .{ .string = ".fixture" }, .{ .string = "/tmp/anywhere" } },
    ));
}
