//! quickjs — user config as JavaScript, run in `quickjs.wasm` (QuickJS-ng
//! compiled to a wasm32-wasi reactor; see build.zig `addQuickjs`). This is
//! plan 06B: the sample config, reborn from Fennel as `config.js`, evaluated
//! inside the sandbox and driving weft ONLY through the `weft.*` host imports
//! the shim (src/quickjs/weft_qjs.c) installs as a JS global. The same
//! membrane discipline as a `.wasm` plugin — strings cross through the guest's
//! linear memory, no host pointer leaks — one layer down, under the JS engine.
//!
//! The config plane is deliberately small: `weft.bind`/`run`/`echo`/`log`.
//! It is declaration, not a general JS host (no quickjs-libc, no fs/net from
//! JS) — powers a config wants come through weft's own gated ABI, not Node's.

const std = @import("std");
const Allocator = std.mem.Allocator;
const wasm = @import("wasm.zig");
const command = @import("command.zig");
const task = @import("task.zig");
const proc_stream = @import("proc_stream.zig");
const Buffers = @import("Buffers.zig");
const pick_mod = @import("pick.zig");
const status_feed = @import("status_feed.zig");
const manifest_mod = @import("manifest.zig");
const viewport_mod = @import("viewport.zig");
const TranscriptDoc = @import("transcript.zig");
const GraphDoc = @import("graph.zig");
const subbuffer = @import("subbuffer.zig");
const semantic_model = @import("weft_semantic");
const view_runtime = @import("weft_view_runtime");
const grants_mod = @import("grants.zig");
/// The membrane's ONE perm vocabulary and check — shared with the wasm plane
/// verbatim (`Perm`, `hasPerm`), never reimplemented here.
const perm_gate = @import("wasm_host/plugin.zig");
/// The fs semantic bodies, shared with the wasm plane so `.fs_root`
/// confinement has ONE implementation (`cFileRead`).
const fs_gate = @import("wasm_host/fs.zig");
/// The plugin-plane PROC bodies, shared with the wasm plane for the same
/// reason one layer over: a JS plugin runs inside `quickjs.wasm`, so it must
/// not be able to reach a proc door shaped differently from the one every
/// other guest gets (doc/place.md §4.1a).
const proc_doors = @import("wasm_host/proc.zig");
const Perm = perm_gate.Perm;
const perm_count = perm_gate.WasmPlugin.perm_count;

/// The embedded engine+shim (built from quickjs-ng + weft_qjs.c by build.zig).
pub const quickjs_wasm: []const u8 = @embedFile("quickjs_wasm");

pub const EvalError = error{ConfigException} || wasm.Error;

/// How `weft.plugin(name)` reaches the host's plugin loader. Defined in
/// `manifest.zig` (so that module stays quickjs-independent while still
/// being the thing `Manifest.apply` calls); re-exported here so existing
/// call sites (`config_load.zig`, tests) keep spelling it `quickjs.PluginLoader`.
pub const PluginLoader = manifest_mod.PluginLoader;

/// Host state behind the `weft.*` config imports: the editor the config
/// wires and the plugin loader / config-data store. Two modes, picked by
/// `manifest`:
///
///   - CONFIG-EVAL mode (`manifest` set, by `evalToManifest`): every
///     `weft.*` call STAGES a declaration onto the `Manifest` instead of
///     touching the editor — sealed evaluation (doc/configuration.md §5).
///     Applying the result is a separate step (`Manifest.apply`/
///     `.reconcile`), never done here.
///   - LIVE mode (`manifest` null — a resident `JsPlugin`, see below): a
///     persistent plugin isn't a one-shot declarative eval — its `weft.*`
///     calls may run at any point in its lifetime (an `on_command`
///     handler firing years into a session), so staging doesn't apply;
///     each handler mutates the editor immediately, exactly as this module
///     did before `manifest.zig` existed.
const Bridge = struct {
    ctx: *command.Context,
    loader: ?PluginLoader,
    config: ?*kv.Store,
    /// Directory the loaded config lives in — `weft.use(name)` resolves
    /// `<dir>/<name>.js` against it (config-data includes). Null = no includes
    /// (the plugin plane, or an unnamed config): `weft.use` degrades to a no-op.
    config_dir: ?[]const u8 = null,
    /// The resident wasm engine — `weft.use` needs it to spin up a NESTED,
    /// independent `evalToManifest` for the imported file (its own fresh
    /// quickjs runtime, exactly like the top-level eval; see `cUse`).
    engine: *wasm.Engine,
    /// Set only in CONFIG-EVAL mode — see the mode doc above.
    manifest: ?*manifest_mod.Manifest = null,
    /// HEAD ADDRESSING (mirrors `WasmPlugin.active_ctx`, wasm_host/commands.zig's
    /// classification doc): the dispatching head's ctx for the duration of a
    /// LIVE `JsPlugin` guest call (`weft_on_command`/`weft_on_pick`), set/
    /// restored by `JsPlugin.onCommand`/`jsPickAccept`. Null in every other
    /// case — CONFIG-EVAL mode (`evalToManifest`/`evalConfig`, always staging
    /// into `manifest`, never touching `ctx.head`) never sets it, and a
    /// resident plugin's BACKGROUND entry (`tick`'s `weft_on_output`) leaves it
    /// alone too, so both correctly fall back to `ctx` via `activeCtx()`.
    active_ctx: ?*command.Context = null,
    /// Mirrors `WasmPlugin.in_dispatch` (task #19 item 4 — same escape hatch,
    /// closed the same way, one layer down under the JS engine): true only
    /// for the duration of a LIVE `JsPlugin` DISPATCHING call
    /// (`weft_on_command`/`weft_on_pick`), set/restored by the same sites as
    /// `active_ctx` above. CONFIG-EVAL mode never sets it (every `weft.*`
    /// call there stages onto `manifest` instead of touching `ctx.head`, so
    /// gating would be a no-op anyway); a resident plugin's BACKGROUND entry
    /// (`tick`'s `weft_on_output`) leaves it false, so `requireDispatch`
    /// (below) traps a head-touching `weft.*` call reached from there.
    in_dispatch: bool = false,
    /// Mirrors `WasmPlugin.loading` (task #19 item 4, corrected mid-build —
    /// see that field's doc for why: a modal guest's `init()` legitimately
    /// sets its STARTING mode, discovered by the wasm plane's test suite,
    /// not by inspection). True for the duration of `JsPlugin.load`'s
    /// `weft_plugin_init` call (the JS body's top-level run, registering
    /// commands — the closest analogue to `describe()`+`init()`). Same
    /// safety argument: `active_ctx` is still the fresh load-time `ctx`
    /// during this call, so nothing else could be mid-interaction yet.
    loading: bool = false,

    /// Optional-with-fallback where WasmPlugin's twin is non-optional
    /// (init'd to the load ctx): the null here MEANS something — config-eval
    /// mode never sets it, so `orelse ctx` doubles as the "not a live
    /// dispatch" marker. Same concept, two representations, both deliberate.
    pub fn activeCtx(self: *Bridge) *command.Context {
        return self.active_ctx orelse self.ctx;
    }

    /// task #19 item 4 (mirrors `wasm_host/plugin.zig`'s `requireDispatch`
    /// exactly, one layer down under the JS engine): every LIVE `weft.*`
    /// handler that MUTATES head state (`weft.echo`, `weft.pick` — see
    /// `contract_data.zig`'s `.head_gated` doc for the exact boundary this
    /// mirrors) calls this before touching `activeCtx().head`. In dispatch
    /// (`in_dispatch`, set by `JsPlugin.onCommand`/`jsPickAccept`) or loading
    /// (`loading`, set by `JsPlugin.load`) → true, the site proceeds.
    /// Outside both (a resident plugin's BACKGROUND `weft_on_output`, fired
    /// by `tick`, reaching for the head directly) → traps the call, same
    /// discipline as the wasm plane's twin. Config-eval mode never reaches
    /// here — every `weft.*` call there returns early onto `manifest`
    /// before touching `ctx.head` at all.
    fn requireDispatch(self: *Bridge, caller: *wasm.Caller, comptime verb: []const u8) bool {
        if (self.in_dispatch or self.loading) return true;
        caller.trap("a JS plugin called {s} from a background entry (weft_on_output) — head state requires a dispatching entry (weft_on_command/weft_on_pick) or the load handshake", .{verb});
        return false;
    }
};

const kv = @import("kv.zig");

const qjs_contract = @import("membrane/qjs_contract.zig");

/// Look up `name`'s handler in a comptime `{name, handler}` list — a
/// missing entry is a compile error naming exactly which qjs_* import
/// wasn't wired, not a runtime binding gap.
fn findHandler(comptime handlers: anytype, comptime name: []const u8) wasm.Linker.HostFn {
    inline for (handlers) |h| {
        if (comptime std.mem.eql(u8, h.name, name)) return h.handler;
    }
    @compileError("core/quickjs.zig: no handler bound for qjs_* import '" ++ name ++ "'");
}

/// Bind every `qjs_contract.imports` entry in `group` onto `linker`, each
/// against its handler in `handlers` — the qjs analogue of contract.zig's
/// `zip()`, but side-effecting (`defineFn` calls) instead of building a
/// table, since quickjs.zig binds straight onto a `wasm.Linker`. Checked
/// both ways: every matching table entry must find a handler (`findHandler`
/// above), and `handlers.len` must equal the group's entry count (an extra,
/// unlisted handler — e.g. a stale rename — is otherwise invisible).
fn defineGroup(linker: *wasm.Linker, comptime group: qjs_contract.Group, comptime handlers: anytype, data: ?*anyopaque) !void {
    comptime {
        @setEvalBranchQuota(10_000);
        var count: usize = 0;
        for (qjs_contract.imports) |entry| {
            if (entry.group == group) count += 1;
        }
        if (handlers.len != count) @compileError(std.fmt.comptimePrint(
            "core/quickjs.zig: {d} handlers bound for group .{s} but qjs_contract.imports has {d} entries in it",
            .{ handlers.len, @tagName(group), count },
        ));
    }
    inline for (qjs_contract.imports) |entry| {
        if (entry.group != group) continue;
        const hfn = comptime findHandler(handlers, entry.name);
        try linker.defineFn("weft", entry.name, entry.params.len, entry.results.len, hfn, data);
    }
}

/// Satisfy every `.plugin`-group import with a generic stub — the config
/// linker never calls them (quickjs.wasm imports them all as one shared
/// binary; the JS globals that would call them aren't installed on the
/// config path), so the stub choice (reject vs no-op) only has to match the
/// import's result arity, derived straight from the table.
fn defineStubs(linker: *wasm.Linker, data: ?*anyopaque) !void {
    inline for (qjs_contract.imports) |entry| {
        if (entry.group != .plugin) continue;
        const hfn: wasm.Linker.HostFn = if (entry.results.len == 0) cStubVoid else cStubI32;
        try linker.defineFn("weft", entry.name, entry.params.len, entry.results.len, hfn, data);
    }
}

/// The `.config`-group handlers (real always — see `qjs_contract.Group`'s doc).
const config_handlers = .{
    .{ .name = "qjs_bind_key", .handler = cBindKey },
    .{ .name = "qjs_run", .handler = cRun },
    .{ .name = "qjs_echo", .handler = cEcho },
    .{ .name = "qjs_log", .handler = cLog },
    .{ .name = "qjs_plugin", .handler = cPlugin },
    .{ .name = "qjs_use", .handler = cUse },
    .{ .name = "qjs_set", .handler = cSet },
    .{ .name = "qjs_menu", .handler = cMenu },
    .{ .name = "qjs_action", .handler = cAction },
    .{ .name = "qjs_semantic_action", .handler = cSemanticAction },
    .{ .name = "qjs_provide", .handler = cProvide },
    .{ .name = "qjs_status_segment", .handler = cStatusSegment },
    .{ .name = "qjs_grant", .handler = cGrant },
    .{ .name = "qjs_viewport", .handler = cViewport },
    .{ .name = "qjs_present", .handler = cPresent },
};

/// The `.plugin`-group handlers a RESIDENT JS plugin's linker binds (real —
/// `defineStubs` above covers the config linker's stand-ins). Public so the
/// §4.1a gate (`e2e/demolition_test.zig`) can read the handler this plane
/// ACTUALLY binds for a door, not a const that merely exists beside it.
pub const plugin_handlers = .{
    .{ .name = "qjs_register", .handler = cRegister },
    .{ .name = "qjs_proc_spawn", .handler = cProcSpawn },
    .{ .name = "qjs_proc_send", .handler = cProcSend },
    .{ .name = "qjs_proc_read", .handler = cProcRead },
    .{ .name = "qjs_proc_close", .handler = cProcClose },
    .{ .name = "qjs_buffer_append", .handler = cBufferAppend },
    .{ .name = "qjs_buffer_fold", .handler = cBufferFold },
    .{ .name = "qjs_buffer_len", .handler = cBufferLen },
    .{ .name = "qjs_transcript_entry", .handler = cTranscriptEntry },
    .{ .name = "qjs_transcript_append", .handler = cTranscriptAppend },
    .{ .name = "qjs_config", .handler = cConfig },
    .{ .name = "qjs_breakpoints", .handler = cBreakpoints },
    .{ .name = "qjs_file_read", .handler = cFileRead },
    .{ .name = "qjs_file_write", .handler = cAgentWrite },
    .{ .name = "qjs_line_text", .handler = cLineText },
    .{ .name = "qjs_active_buffer", .handler = cActiveBuffer },
    .{ .name = "qjs_pick", .handler = cPick },
    .{ .name = "qjs_status", .handler = cStatus },
};

/// The shared `weft.*` membrane, bound over a `Bridge` — used by both the
/// config eval plane and a JS plugin (they drive the editor identically; a
/// plugin additionally registers commands via `qjs_register`).
fn defineConfigFns(linker: *wasm.Linker, bridge: *Bridge) !void {
    try defineGroup(linker, .config, config_handlers, bridge);
}

/// Plugin-plane import stubs for the config linker (never called there): an
/// i32-returning one that rejects, and a void no-op.
fn cStubI32(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = data;
    _ = caller;
    _ = args;
    results[0] = -1;
}
fn cStubVoid(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = data;
    _ = caller;
    _ = args;
    _ = results;
}

/// Evaluate `src` into a fresh `Manifest`, WITHOUT applying it: instantiate
/// `quickjs.wasm` under WASI with the `weft.*` config surface bound in
/// CONFIG-EVAL (staging) mode, run its reactor init, marshal the source into
/// the guest, and eval it — every `weft.*` call the source makes appends one
/// declaration to the returned manifest (doc/configuration.md §5: "nothing
/// mutates the editor during eval"). A JS exception surfaces as
/// `error.ConfigException` (the shim logs its message) and the partial
/// manifest is destroyed — never a partial, silent half-applied config.
/// Each call is a fresh JS runtime. `tier`/`owner` stamp the returned
/// manifest (`.config`/`"config"` for the root; `cUse` calls this again,
/// nested, for a `weft.use(name)` import at `.imported`/`"import:<name>"`).
pub fn evalToManifest(engine: *wasm.Engine, ctx: *command.Context, loader: ?PluginLoader, config: ?*kv.Store, config_dir: ?[]const u8, src: []const u8, tier: manifest_mod.Tier, owner: []const u8) EvalError!*manifest_mod.Manifest {
    const m = try manifest_mod.Manifest.create(ctx.gpa, owner, tier);
    errdefer m.destroy();

    var bridge: Bridge = .{ .ctx = ctx, .loader = loader, .config = config, .config_dir = config_dir, .engine = engine, .manifest = m };

    var module = try engine.compileCached(quickjs_wasm);
    defer module.deinit();
    var linker = try wasm.Linker.init(engine);
    defer linker.deinit();
    try linker.defineWasi();
    try defineConfigFns(&linker, &bridge);
    // The config plane uses none of the plugin-plane imports, but quickjs.wasm
    // imports them all (one shared binary) — satisfy each with a stub so it
    // instantiates. They are never called on the config path (the JS globals
    // that would call them aren't installed for config).
    try defineStubs(&linker, &bridge);

    var instance = try linker.instantiateWasi(&module);
    defer instance.deinit();
    // Reactor: run the WASI init once before any export call.
    instance.callVoid("_initialize", &.{}) catch |e| {
        if (e != error.MissingExport) return e;
    };

    // Marshal the source into the guest (null-terminated — QuickJS' parser
    // reads a C string), eval, free.
    const size: i32 = @intCast(src.len + 1);
    const ptr = try instance.callI32("malloc", &.{size});
    if (ptr == 0) return error.OutOfMemory;
    defer instance.callVoid("free", &.{ptr}) catch {};
    const at: usize = @intCast(ptr);
    try instance.writeGuest(at, src);
    try instance.writeGuest(at + src.len, &.{0});

    const rc = try instance.callI32("weft_eval", &.{ ptr, @intCast(src.len) });
    if (rc != 0) return error.ConfigException;

    return m;
}

/// Evaluate `src` as the user config AND apply it — `evalToManifest` plus
/// the hash-log + fresh `apply` pass (doc/configuration.md §5's "the approved
/// artifact is the manifest value plus its hash"). This is the convenience
/// entry point for a FIRST load; a config-reload wired against a previous
/// manifest should call `evalToManifest` + `Manifest.reconcile` directly
/// (see `config_load.ConfigSession`) so an unchanged reload is a verified
/// no-op instead of a blind re-apply.
pub fn evalConfig(engine: *wasm.Engine, ctx: *command.Context, loader: ?PluginLoader, config: ?*kv.Store, config_dir: ?[]const u8, src: []const u8) EvalError!void {
    const m = try evalToManifest(engine, ctx, loader, config, config_dir, src, .config, "config");
    defer m.destroy();
    std.log.info("config: manifest hash = 0x{x}", .{m.hash()});
    var actx: manifest_mod.Manifest.ApplyCtx = .{ .ctx = ctx, .loader = loader, .config = config };
    try m.apply(ctx.gpa, &actx);
}

// ── The plugin plane: a PERSISTENT quickjs.wasm instance as a weft plugin ──

/// A JS plugin — a resident `quickjs.wasm` instance driving weft through the
/// same `weft.*` membrane the config uses, plus command registration and
/// `on_command` dispatch (the describe/init/on_command lifecycle a `.wasm`
/// plugin has, one layer up under the JS engine). One instance per plugin, so
/// its runtime + globals are private; the host resolves its commands to
/// `weft_on_command(id)` calls back into the same instance. The membrane's
/// `Bridge` reuses the config bridge (loader/config unused here).
pub const JsPlugin = struct {
    gpa: Allocator,
    ctx: *command.Context,
    pool: *task.Pool,
    /// This plugin's name (its config namespace — what `weft.set(name, …)` and
    /// `weft.config(key)` key on).
    name: []u8,
    /// Read-only config data the config plane staged for this plugin, read via
    /// `weft.config(key)`. Null in tests.
    config_store: ?*kv.Store,
    /// The child environment agent subprocesses inherit (so they resolve PATH).
    environ: std.process.Environ,
    /// This plugin's authority, in `wasm_host/plugin.zig`'s `hasPerm` duck
    /// type (same three field names, so the JS plane runs literally the same
    /// check the wasm plane does — see that file's `hasPerm` doc for the
    /// contract). A `.js` plugin has NO `describe()` handshake, so `perms`
    /// is never populated from the guest: config's `weft.grant` is the only
    /// door, adopted from the table at load (`adoptGrantHandles`). No table
    /// wired (headless fixtures) → `perms`, which is all-false unless a test
    /// pokes it — fail closed either way.
    perms: [perm_count]bool = @splat(false),
    grant_table: ?*grants_mod.HandleTable = null,
    grant_handles: [perm_count]grants_mod.CapHandle = @splat(.none),
    bridge: Bridge,
    module: wasm.Module,
    linker: wasm.Linker,
    instance: wasm.Instance,
    /// Owned command trampolines (one per `weft.command`), kept for teardown;
    /// each carries the id the host dispatches by and owns its command name.
    cmds: std.ArrayList(*Cmd) = .empty,
    /// Proc streams this plugin spawned, indexed by the handle the JS holds.
    /// A closed slot is left null so handles stay stable (never reused).
    streams: std.ArrayList(?*proc_stream.ProcStream) = .empty,
    /// Handles whose child's exit has already been announced — an exit is an
    /// EDGE, reported exactly once, never a level the plugin re-reads every
    /// frame. Grown by `tick`, not by the spawn door: spawning is
    /// `wasm_host/proc.zig`'s shared body now (doc/place.md §4.1a), and a side
    /// table only one plane keeps is exactly the kind of thing that makes one
    /// plane's door different from the other's. A short list means "not yet
    /// reported", which is the correct answer for a handle `tick` has not
    /// reached.
    exits_reported: std.ArrayList(bool) = .empty,
    /// This plugin's live transcripts, one per projected buffer name (W6
    /// check-in producer seam, doc/contextual-workspace-architecture.md §12)
    /// — minted on the first `weft.transcriptEntry` naming that buffer. The
    /// buffer name IS the conversation's identity: two ACP agents in flight
    /// stream into `*agent*` and `*agent:2*`, each with its OWN model, its
    /// own claims and its own open entry, so neither can land a chunk in the
    /// other's transcript (§18's isolation gate).
    conversations: std.ArrayList(*Conversation) = .empty,

    const Cmd = struct { plugin: *JsPlugin, id: i32, name: []u8 };

    /// One live transcript conversation, keyed by the buffer it projects
    /// into. Heap-owned: `live_sub` and the model must survive the list
    /// growing, and a conversation outlives any single membrane call.
    pub const Conversation = struct {
        /// The projected buffer's name — this conversation's identity.
        buffer: []u8,
        /// The MODEL (replication's source of truth).
        transcript: TranscriptDoc,
        /// This conversation's subbuffer claims (mirrors `fill`'s `subs`).
        subs: subbuffer.SubBuffers = .empty,
        /// The currently-streaming entry's TEXT object —
        /// `weft.transcriptAppend` inserts at its end. `null` until the
        /// first entry; a chunk with nothing open is a silent no-op, not a
        /// trap — an adapter racing its first chunk ahead of the entry-open
        /// call is that plugin's protocol-timing bug to fix.
        live_text: ?GraphDoc.ObjId = null,
        /// Bytes already written into `live_text` — where the next streamed
        /// chunk's `editText` insert lands (append-only).
        live_len: usize = 0,
        /// The PROJECTED BUFFER's claim for the same live entry, cached
        /// right after `cTranscriptEntry`'s `fill` so `cTranscriptAppend`
        /// can grow it INCREMENTALLY — see that handler's doc comment.
        live_sub: ?*subbuffer.SubBuffer = null,

        fn deinit(self: *Conversation, gpa: Allocator) void {
            self.subs.deinit(gpa);
            self.transcript.deinit(gpa);
            gpa.free(self.buffer);
            gpa.destroy(self);
        }
    };

    // ── The plugin-plane proc door's duck type (doc/place.md §4.1a) ──
    //
    // `wasm_host/proc.zig`'s four bodies ARE this plane's proc doors; these
    // are the four names they reach a plugin's proc state by, declared here
    // under exactly the names `WasmPlugin` declares them, so neither type has
    // to be spelled into the other. Same contract as `hasPerm`'s duck type a
    // few fields up — one implementation, two transports.

    /// The DISPATCHING entry's context, where a spawned child's place and
    /// environment are read from. The bridge's optional-with-fallback is the
    /// JS plane's spelling of `WasmPlugin.active_ctx`.
    pub fn activeCtx(self: *JsPlugin) *command.Context {
        return self.bridge.activeCtx();
    }

    /// A JS plugin always has a pool (`load` takes one) — the optional is the
    /// wasm plane's, whose bare test fixtures may have none.
    pub fn procPool(self: *JsPlugin) ?*task.Pool {
        return self.pool;
    }

    pub fn procStreams(self: *JsPlugin) *std.ArrayList(?*proc_stream.ProcStream) {
        return &self.streams;
    }

    /// The environment a spawned child inherits absent a place overlay. Held
    /// in a field here rather than read from `wasm_host`'s global, but it is
    /// the same value: `config_load.zig` passes `wasm_host.hostEnviron()`.
    pub fn baseEnviron(self: *JsPlugin) std.process.Environ {
        return self.environ;
    }

    /// The conversation projecting into `name`, or null if none was opened.
    pub fn conversation(self: *JsPlugin, name: []const u8) ?*Conversation {
        for (self.conversations.items) |c| {
            if (std.mem.eql(u8, c.buffer, name)) return c;
        }
        return null;
    }

    /// The conversation projecting into `name`, minted on first use. Its
    /// CRDT identity is the buffer name, so two conversations of the same
    /// plugin are distinct replicas, not one doc with two views.
    fn openConversation(self: *JsPlugin, gpa: Allocator, name: []const u8) !*Conversation {
        if (self.conversation(name)) |c| return c;
        const conv = try gpa.create(Conversation);
        errdefer gpa.destroy(conv);
        conv.* = .{ .buffer = try gpa.dupe(u8, name), .transcript = undefined };
        errdefer gpa.free(conv.buffer);
        conv.transcript = try TranscriptDoc.create(gpa, name);
        errdefer conv.transcript.deinit(gpa);
        try self.conversations.append(gpa, conv);
        return conv;
    }

    /// Instantiate `quickjs.wasm`, wire the membrane + registrar, and run the
    /// plugin body (`src`), which registers its commands. Heap-owned so the
    /// membrane's `&self.bridge` and the trampolines' `plugin` pointers stay
    /// valid (the instance is resident for the plugin's life). `pool`/`environ`
    /// back the proc-stream membrane (agent subprocesses). Authority comes
    /// from `ctx.grant_table` — whatever `weft.grant` already minted for
    /// `name`, adopted BEFORE the body runs, so the plugin's very first
    /// statement is already gated.
    pub fn load(gpa: Allocator, engine: *wasm.Engine, ctx: *command.Context, pool: *task.Pool, environ: std.process.Environ, name: []const u8, config_store: ?*kv.Store, src: []const u8) !*JsPlugin {
        const self = try gpa.create(JsPlugin);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .ctx = ctx,
            .pool = pool,
            .name = try gpa.dupe(u8, name),
            .config_store = config_store,
            .environ = environ,
            .grant_table = ctx.grant_table,
            // LIVE mode (`manifest` left null) — see Bridge's doc: a resident
            // JS plugin's `weft.*` calls mutate the editor immediately, not
            // staged.
            .bridge = .{ .ctx = ctx, .loader = null, .config = null, .engine = engine },
            .module = try engine.compileCached(quickjs_wasm),
            .linker = undefined,
            .instance = undefined,
        };
        errdefer {
            gpa.free(self.name);
            self.module.deinit();
        }
        if (self.grant_table) |table| perm_gate.adoptGrantHandles(table, self.name, &self.grant_handles);
        self.linker = try wasm.Linker.init(engine);
        errdefer self.linker.deinit();
        try self.linker.defineWasi();
        try defineConfigFns(&self.linker, &self.bridge);
        try defineGroup(&self.linker, .plugin, plugin_handlers, self);

        self.instance = try self.linker.instantiateWasi(&self.module);
        errdefer self.instance.deinit();
        self.instance.callVoid("_initialize", &.{}) catch |e| {
            if (e != error.MissingExport) return e;
        };

        const size: i32 = @intCast(src.len + 1);
        const ptr = try self.instance.callI32("malloc", &.{size});
        if (ptr == 0) return error.OutOfMemory;
        defer self.instance.callVoid("free", &.{ptr}) catch {};
        const at: usize = @intCast(ptr);
        try self.instance.writeGuest(at, src);
        try self.instance.writeGuest(at + src.len, &.{0});
        // `Bridge.loading` (task #19 item 4): legitimate for the top-level JS
        // body to touch head state while it runs (see that field's doc) — no
        // `defer` needed to reset it: every error path below returns before
        // reaching the plain `false` set, and `self`/`self.bridge` are only
        // read again on the surviving success path.
        self.bridge.loading = true;
        const rc = try self.instance.callI32("weft_plugin_init", &.{ ptr, @intCast(src.len) });
        self.bridge.loading = false;
        if (rc != 0) return error.ConfigException;
        return self;
    }

    /// Dispatch command `id` into the JS handler registered for it. DISPATCHING
    /// (mirrors `wasm_host/commands.zig`'s `wpCmdTrampoline`): `ctx` is the
    /// head `command.run` was actually invoked with — route `bridge.active_ctx`
    /// through it for the call's duration (save/restore, not a bare set — kept
    /// nesting-safe on the same discipline as the wasm plane; a JS command
    /// handler CAN still open a pick, whose accept re-enters through
    /// `jsPickAccept`, so a bare set would be wrong). `bridge.in_dispatch`
    /// (task #19 item 4) rides along the SAME save/restore, unconditionally
    /// true for this call's duration — including when a BACKGROUND entry
    /// (`weft_on_output`) reached here via a nested `weft.run` (now
    /// dispatching for real, `cRun`'s doc): that promotion is the sanctioned
    /// door, not a bug — see `Bridge.requireDispatch`'s doc.
    pub fn onCommand(self: *JsPlugin, ctx: *command.Context, id: i32) void {
        const saved_ctx = self.bridge.active_ctx;
        const saved_dispatch = self.bridge.in_dispatch;
        self.bridge.active_ctx = ctx;
        self.bridge.in_dispatch = true;
        defer {
            self.bridge.active_ctx = saved_ctx;
            self.bridge.in_dispatch = saved_dispatch;
        }
        self.instance.callVoid("weft_on_command", &.{id}) catch {};
    }

    /// Frame boundary: fire the JS output handler for every stream with new
    /// bytes waiting, so the plugin drains + parses this frame. Top-level (never
    /// nested in another guest call) — the wasm-store re-entrancy rule. Returns
    /// whether anything was dispatched (the view may need a rebuild).
    pub fn tick(self: *JsPlugin) bool {
        var fired = false;
        var h: usize = 0;
        while (h < self.streams.items.len) : (h += 1) {
            if (self.streams.items[h]) |s| {
                if (s.pending() > 0) {
                    self.instance.callVoid("weft_on_output", &.{@intCast(h)}) catch {};
                    fired = true;
                }
            }
            // Re-read the slot: the handler above may have closed this very
            // stream (`weft.procClose`), which frees it and nulls the slot.
            const s = self.streams.items[h] orelse continue;
            // The child's exit, AFTER its last bytes: a peer that dies mid
            // conversation is news the plugin must act on (answer what it left
            // pending, free the slot), not a silence it has to poll for. Once
            // per stream, so an exit is an edge and not a level.
            if (!s.ended() or s.pending() > 0) continue;
            // Grown HERE, not at spawn: the spawn door is `wasm_host/proc.zig`'s
            // shared body now (doc/place.md §4.1a), and a per-plane side table
            // it would have to know about is exactly the kind of thing that
            // makes one plane's door different from the other's. An
            // unallocatable slot just defers the edge to the next tick.
            while (self.exits_reported.items.len <= h) {
                self.exits_reported.append(self.gpa, false) catch break;
            }
            if (h >= self.exits_reported.items.len or self.exits_reported.items[h]) continue;
            self.exits_reported.items[h] = true;
            self.instance.callVoid("weft_on_exit", &.{@intCast(h)}) catch {};
            fired = true;
        }
        return fired;
    }

    /// The JS plane's ONE deny path — `wasm_host/plugin.zig`'s `requirePerm`
    /// twin, over the SAME `hasPerm`. Granted → true, the effect proceeds.
    /// Denied → a host log naming the plugin, the capability and the
    /// `weft.grant` line that would fix it, and false: the caller answers
    /// `qjs_contract.denied`, which `weft_qjs.c` throws as a JS exception at
    /// the `weft.*` call site. Denial is never success-shaped and never
    /// silent. Not a trap (the wasm plane's answer): this instance is
    /// RESIDENT — trapping a routine, fail-closed denial would tear down a
    /// live QuickJS runtime the next command still needs.
    fn requirePerm(self: *JsPlugin, comptime perm: Perm) bool {
        if (perm_gate.hasPerm(self, perm)) return true;
        self.denyPerm(perm);
        return false;
    }

    /// `requirePerm`'s log half, callable on its own from a site whose
    /// possession check already ran inside a shared semantic body (see
    /// `cFileRead`, which delegates the disk half to `wasm_host/fs.zig`).
    fn denyPerm(self: *JsPlugin, comptime perm: Perm) void {
        std.log.warn("js plugin '{s}': denied capability '{s}' — declare it in your config with weft.grant(\"{s}\", \"{s}\")", .{ self.name, perm.label(), self.name, perm.label() });
    }

    /// The other denial: the capability IS possessed, but its limit doesn't
    /// reach `path`. Names both, like the wasm plane's `trapOutOfLimit`, so a
    /// narrowed grant is diagnosable — including the `.place` case, where the
    /// confinement is the dispatching place and the fix is a config grant
    /// rather than a root string nobody ever wrote (doc/place.md §4.1).
    fn denyOutOfLimit(self: *JsPlugin, comptime perm: Perm, path: []const u8) void {
        if (perm_gate.limitFor(self, perm) == .place) {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const dir = perm_gate.placeRootFor(self, &buf);
            if (dir.len == 0) {
                std.log.warn("js plugin '{s}': '{s}' — this place has no local directory, so path '{s}' is outside it", .{ self.name, perm.label(), path });
            } else {
                std.log.warn("js plugin '{s}': '{s}' path '{s}' is outside this dispatch's place '{s}' — widen it with weft.grant(\"{s}\", \"{s}\", {{ root: \"/\" }})", .{ self.name, perm.label(), path, dir, self.name, perm.label() });
            }
            return;
        }
        const root: []const u8 = switch (perm_gate.limitFor(self, perm)) {
            .fs_root => |r| r,
            .none, .place, .doc_region, .graph_subtree => "?",
        };
        std.log.warn("js plugin '{s}': '{s}' path '{s}' is outside the granted root '{s}'", .{ self.name, perm.label(), path, root });
    }

    /// The third: `path` is the editor's own machinery, which no grant
    /// reaches (doc/place.md §4.1). The wasm plane's `trapMachinery`, in the
    /// register this plane denies in — a log plus `qjs_contract.denied`, not
    /// a trap, for the reason `requirePerm` gives above.
    fn denyMachinery(self: *JsPlugin, comptime perm: Perm, path: []const u8) void {
        const what = if (@import("machinery.zig").locationOf(path)) |loc| loc.label() else "the editor's own state";
        std.log.warn("js plugin '{s}': '{s}' — {s} is editor machinery, no grant reaches it (path '{s}')", .{ self.name, perm.label(), what, path });
    }

    /// Report whichever of the three `fs_gate.pathAllowed` returned. One
    /// dispatch, so neither `cFileRead` nor `cAgentWrite` can report a
    /// machinery refusal as an out-of-root one — and adding a fourth reason
    /// to `PermError` is a compile error here rather than a silent
    /// mis-labelling.
    fn denyPath(self: *JsPlugin, comptime perm: Perm, path: []const u8, e: fs_gate.PermError) void {
        switch (e) {
            error.PermissionDenied => self.denyPerm(perm),
            error.OutOfLimit => self.denyOutOfLimit(perm, path),
            error.Machinery => self.denyMachinery(perm, path),
        }
    }

    pub fn deinit(self: *JsPlugin) void {
        const gpa = self.gpa;
        gpa.free(self.name);
        for (self.streams.items) |maybe| if (maybe) |s| s.deinit();
        self.streams.deinit(gpa);
        self.exits_reported.deinit(gpa);
        for (self.conversations.items) |c| c.deinit(gpa);
        self.conversations.deinit(gpa);
        for (self.cmds.items) |c| {
            gpa.free(c.name);
            gpa.destroy(c);
        }
        self.cmds.deinit(gpa);
        self.instance.deinit();
        self.linker.deinit();
        self.module.deinit();
        gpa.destroy(self);
    }
};

// ── The proc-stream membrane (plugin plane): spawn/send/read/close a duplex
// child, handles indexing the plugin's `streams`.
//
// There is no JS proc door any more — only the wasm one, reached from JS
// (doc/place.md §4.1a). `wasm_host/proc.zig` holds the four bodies; `jsDoor`
// below is the whole of what this plane adds: the `*JsPlugin` cast and a
// denial that LOGS and answers `qjs_contract.denied` instead of trapping,
// because this instance is RESIDENT and a trap would tear down a live QuickJS
// runtime the next command still needs. A divergence like the `cwd` argument
// this door once carried and `wl_proc_spawn` never had is now unrepresentable:
// there is no second body to grow one in.
//
// Every door that reaches the child is `proc`-gated: spawn is where the
// authority is MINTED into a handle, send/read where the JS plane keeps
// exercising it — so a revoked `proc` grant stops an already-running agent on
// its next call, not merely its next spawn. That last part is the ONE
// remaining asymmetry with the wasm plane, recorded as data (not as a
// difference in behaviour anyone has to read two bodies to find) in
// `proc_doors.doors`'s `wl_gate`/`qjs_gate` — see its doc for the exact
// two-file edit that closes it. `procClose` is ungated on both planes: it only
// RELEASES authority.

/// Bind one shared `wasm_host/proc.zig` body onto the resident JS membrane.
/// `gate`'s possession check runs first when the door has one; denial is a
/// host log plus `qjs_contract.denied` in the result (thrown as a JS exception
/// by `weft_qjs.c`), never a success-shaped answer and never silence.
pub fn jsDoor(comptime body: anytype, comptime gate: ?Perm) wasm.Linker.HostFn {
    return struct {
        fn f(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
            const self: *JsPlugin = @ptrCast(@alignCast(data.?));
            if (gate) |perm| {
                if (!perm_gate.hasPerm(self, perm)) {
                    self.denyPerm(perm);
                    if (results.len > 0) results[0] = qjs_contract.denied;
                    return;
                }
            }
            body(self, caller, args, results);
        }
    }.f;
}

const cProcSpawn = jsDoor(proc_doors.spawnBody, .proc);
const cProcSend = jsDoor(proc_doors.sendBody, .proc);
const cProcRead = jsDoor(proc_doors.readBody, .proc);
const cProcClose = jsDoor(proc_doors.closeBody, null);

/// The CRDT peer JS-plugin transcript/tool-buffer output authors as.
const transcript_peer = "agent-ui";

/// Append `text` to the end of the buffer named `name` (created if absent),
/// authored as a fixed tool peer — the streamed-transcript path, targeting a
/// buffer by name so it need not be focused (mirrors repl_session.drain).
fn appendNamed(ctx: *command.Context, gpa: Allocator, name: []const u8, text: []const u8, class: u8) void {
    const bufs = ctx.buffers;
    const b = bufs.get(bufs.ensureNamed(gpa, name) catch return) orelse return;
    const ed = b.textEditor() orelse return;
    const doc = &ed.doc;
    const start = ed.text().byteLen();
    command.renderInto(gpa, doc, .plugin, transcript_peer, &.{.{ .range = .{ .start = start, .end = start }, .bytes = text }}) catch return;
    if (class != 0) paintStyle(ctx, gpa, doc, start, start + text.len, class);
}

/// Paint `[start, end)` with StyleClass `class` on `doc`'s styles feed, growing
/// the class-per-byte bulk to the buffer's new length and PRESERVING prior
/// classes (so a streamed transcript keeps each chunk's color). The styles
/// layer is claimed once (find, else claim) and republished with the extended
/// array — the whole-buffer bulk the view paints from.
fn paintStyle(ctx: *command.Context, gpa: Allocator, doc: *@import("Document.zig"), start: usize, end: usize, class: u8) void {
    const total = end; // the append put the new end here
    const layer = ctx.caps.layers.find(doc, "styles") orelse
        (ctx.caps.layers.claim(gpa, doc, "styles", .local, transcript_peer) catch return);
    const classes = gpa.alloc(u8, total) catch return;
    defer gpa.free(classes);
    @memset(classes, 0);
    if (layer.bulk) |b0| {
        const keep = @min(b0.classes.len, total);
        @memcpy(classes[0..keep], b0.classes[0..keep]);
    }
    const s = @min(start, total);
    @memset(classes[s..total], class);
    const version = doc.version(gpa) catch return;
    defer gpa.free(version);
    layer.publishBulk(gpa, version, 0, classes) catch {};
}

/// Find the buffer named `name` (created if absent), or null on failure.
fn namedBuffer(ctx: *command.Context, gpa: Allocator, name: []const u8) ?*Buffers.Buffer {
    var it = ctx.buffers.iterator();
    while (it.next()) |b| if (std.mem.eql(u8, b.name, name)) return b;
    const id = ctx.buffers.create(gpa, name) catch return null;
    return ctx.buffers.get(id);
}

/// Collapse `[start, end)` of a named buffer (an invisible+foldable span on its
/// fold layer) — folding a tool-call's verbose content under its header, even
/// when the transcript isn't focused. Accumulates (claims on first use).
fn foldNamed(ctx: *command.Context, gpa: Allocator, name: []const u8, start: usize, end: usize) void {
    if (end <= start) return;
    const b = namedBuffer(ctx, gpa, name) orelse return;
    const doc = &(b.textEditor() orelse return).doc;
    const layer = ctx.caps.layers.find(doc, "folds") orelse
        (ctx.caps.layers.claim(gpa, doc, "folds", .local, transcript_peer) catch return);
    layer.appendSpan(gpa, .{ .start = start, .end = end, .kind = 0, .message = "", .face = .{ .invisible = true, .foldable = true } }) catch {};
}

fn cBufferFold(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const self: *JsPlugin = @ptrCast(@alignCast(data.?));
    const gpa = self.gpa;
    const name = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(name);
    foldNamed(self.bridge.activeCtx(), gpa, name, @intCast(@as(u32, @bitCast(args[2]))), @intCast(@as(u32, @bitCast(args[3]))));
}

/// weft.bufferLen(name) → a named buffer's byte length (for fold offsets).
fn cBufferLen(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const self: *JsPlugin = @ptrCast(@alignCast(data.?));
    const name = caller.readMemory(self.gpa, @intCast(args[0]), @intCast(args[1])) catch {
        results[0] = 0;
        return;
    };
    defer self.gpa.free(name);
    const b = namedBuffer(self.bridge.activeCtx(), self.gpa, name) orelse {
        results[0] = 0;
        return;
    };
    results[0] = @intCast((b.textEditor() orelse return).text().byteLen());
}

fn cBufferAppend(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const self: *JsPlugin = @ptrCast(@alignCast(data.?));
    const gpa = self.gpa;
    const name = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(name);
    const text = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer gpa.free(text);
    appendNamed(self.bridge.activeCtx(), gpa, name, text, @truncate(@as(u32, @bitCast(args[4]))));
}

/// weft.transcriptEntry(name, role, text): begin a new entry in this
/// plugin's conversation for `name` (minted on first use —
/// `JsPlugin.conversations`), then FULLY re-fill `name`'s projection buffer
/// from the model. Full `fill` (not the incremental path `cTranscriptAppend`
/// below uses) is the honest choice HERE: a new entry is a structural
/// change to the model (a new row, new decoration prefix, a whole new
/// subbuffer claim to mint) — there is no "just grow the last claim" shape
/// for it, unlike a chunk streamed onto a row that already exists. This is
/// the LOCAL half of live-projection freshness (a local append is
/// synchronous, so re-filling right here is the honest trigger; the REMOTE
/// half is `TranscriptDoc.refillOnChange`, driven by a collab quad's own
/// changed signal — see that function's doc comment). This is the seam
/// REPLACING a raw `weft.bufferAppend` for actual conversation content
/// (doc/agents.md's ACP client is the first caller, config/plugins/acp.js):
/// `role` is now real model data an entry carries, not a decoration prefix
/// a plugin painted onto a plain buffer by hand.
fn cTranscriptEntry(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const self: *JsPlugin = @ptrCast(@alignCast(data.?));
    const gpa = self.gpa;
    const name = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(name);
    const role = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer gpa.free(role);
    const text = caller.readMemory(gpa, @intCast(args[4]), @intCast(args[5])) catch return;
    defer gpa.free(text);
    transcriptEntry(self, gpa, name, role, text) catch return;
}

fn transcriptEntry(self: *JsPlugin, gpa: Allocator, name: []const u8, role: []const u8, text: []const u8) !void {
    const conv = try self.openConversation(gpa, name);
    const tr = &conv.transcript;
    const obj = try tr.append(gpa, role, @bitCast(task.nowNs()), text);
    conv.live_text = tr.graph.ref(obj).mapGet("text").?.objId().?;
    conv.live_len = text.len;
    // Cleared BEFORE the buffer lookup/fill below, not after: if either
    // fails partway (buffer creation, `fill`'s allocation), an early
    // `return`/error must never leave a STALE claim pointing at the
    // PREVIOUS entry's row cached under `live_text` now naming
    // the NEW one — `cTranscriptAppend`'s `sub.?.doc != doc` guard only
    // catches a buffer/name mismatch, not this. `null` here always means
    // "fall back to a full fill", which is always correct.
    conv.live_sub = null;
    const b = namedBuffer(self.bridge.activeCtx(), gpa, name) orelse return;
    const ed = b.textEditor() orelse return;
    try b.setTool(gpa, TranscriptDoc.projection_author);
    try TranscriptDoc.fill(gpa, tr, &ed.doc, &conv.subs);
    // Cache the fresh row's claim for `cTranscriptAppend`'s incremental
    // path — see `transcript.lastRowClaim`'s doc comment for why this is
    // safe to grab right here (nothing else claims on `ed.doc`
    // between the `fill` above and this line).
    conv.live_sub = TranscriptDoc.lastRowClaim(&conv.subs, &ed.doc);
}

/// weft.transcriptAppend(name, text): stream `text` onto the currently-open
/// entry's body — a real text-CRDT insert into the MODEL
/// (`TranscriptDoc.editText`, the append-mostly shape transcript.zig's own
/// docs anticipate) PLUS an INCREMENTAL update of the PROJECTED BUFFER,
/// deliberately NOT a full `fill` (REQUIRED per review: streaming is the
/// primary workload here, and a full re-fill is O(chunks × (transcript_
/// bytes + n_rows)) — every entry re-read, the whole buffer text rebuilt,
/// every row's claim dropped and re-minted — for a chunk that only ever
/// touches ONE row's tail). The buffer-side update instead: (1) a
/// zero-width point-insert at the conversation's `live_sub`'s CURRENT end —
/// the exact shape `appendNamed` already uses for a plain buffer, so it's
/// the SAME `command.renderInto` call, just aimed at one claim's tail
/// instead of the whole document — then (2) `SubBuffer.extendEnd` to widen
/// that ONE claim to cover the new bytes (an append landing exactly at a
/// claim's inward-biased end does NOT auto-extend it — see `extendEnd`'s
/// doc comment for why that's a real gap this closes, not a workaround).
/// Cost: O(chunk_len), independent of transcript size or row count.
///
/// A chunk for a buffer no `weft.transcriptEntry` ever opened is a no-op:
/// `name` selects the CONVERSATION, so a stray append can never leak into
/// another agent's transcript.
///
/// Falls back to a full `fill` (loud in effect, not in a log — see below)
/// in exactly two cases, both meaning the cached claim can't be trusted:
/// no claim was ever cached (`live_sub == null`, e.g. the entry's own
/// `fill` failed partway), or the cached claim's OWN buffer no
/// longer matches `name`'s buffer right now (the same cross-buffer case,
/// caught defensively even if the cache was stale for another reason). A
/// full `fill` is always a CORRECT answer for either case — the fallback
/// never drops a chunk, it just pays the price the fast path exists to
/// avoid.
fn cTranscriptAppend(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const self: *JsPlugin = @ptrCast(@alignCast(data.?));
    const gpa = self.gpa;
    const name = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(name);
    const text = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer gpa.free(text);
    transcriptAppend(self, gpa, name, text) catch return;
}

fn transcriptAppend(self: *JsPlugin, gpa: Allocator, name: []const u8, text: []const u8) !void {
    if (text.len == 0) return;
    const conv = self.conversation(name) orelse return;
    const tr = &conv.transcript;
    const text_obj = conv.live_text orelse return;
    // The model insert always happens — replication's source of truth,
    // independent of whatever the buffer-side fast/slow path below does.
    try tr.editText(gpa, text_obj, conv.live_len, text);
    conv.live_len += text.len;

    const b = namedBuffer(self.bridge.activeCtx(), gpa, name) orelse return;
    const doc = &(b.textEditor() orelse return).doc;
    const sub = conv.live_sub;
    if (sub == null or sub.?.doc != doc) {
        // Slow path: no trustworthy cached claim (see this fn's doc
        // comment for the two cases) — a full re-fill is always correct.
        try TranscriptDoc.fill(gpa, tr, doc, &conv.subs);
        conv.live_sub = TranscriptDoc.lastRowClaim(&conv.subs, doc);
        return;
    }
    // Fast path: grow the buffer and the one claim that names this row,
    // nothing else touched.
    const at = sub.?.resolve().end;
    try command.renderInto(gpa, doc, .plugin, TranscriptDoc.projection_author, &.{
        .{ .range = .{ .start = at, .end = at }, .bytes = text },
    });
    try sub.?.extendEnd(gpa, at + text.len);
}

/// weft.config(key) -> string: this plugin's config value for `key` (what the
/// config plane staged via `weft.set(<plugin>, key, value)`), or "". The stored
/// blob is framed (uvarint count, then uvarint(len)++bytes per record); a
/// single value is its first record.
fn cConfig(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const self: *JsPlugin = @ptrCast(@alignCast(data.?));
    const store = self.config_store orelse {
        results[0] = 0;
        return;
    };
    const key = caller.readMemory(self.gpa, @intCast(args[0]), @intCast(args[1])) catch {
        results[0] = 0;
        return;
    };
    defer self.gpa.free(key);
    const blob = store.get(self.name, key) orelse {
        results[0] = 0;
        return;
    };
    const value = firstFramedRecord(blob) orelse {
        results[0] = 0;
        return;
    };
    results[0] = @intCast(caller.writeMemory(@intCast(args[2]), @intCast(args[3]), value) catch 0);
}

/// weft.breakpoints(path) → the file's breakpoint lines as a "l1,l2,…" CSV, or
/// "" if the file holds none (or isn't open). The DAP client reads this to send
/// setBreakpoints, so the session stops where you marked.
///
/// DERIVED AT SEND TIME: the marks are anchors on that file's document, so the
/// lines are computed HERE, from the current head — an edit above a breakpoint
/// cannot leave the adapter re-arming on the line it used to be on.
fn cBreakpoints(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    results[0] = 0;
    const self: *JsPlugin = @ptrCast(@alignCast(data.?));
    const path = caller.readMemory(self.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer self.gpa.free(path);
    const ctx = self.bridge.activeCtx();
    const id = ctx.buffers.findByPath(path) orelse return;
    const buffer = ctx.buffers.get(id) orelse return;
    const doc = &(buffer.textEditor() orelse return).doc;
    var buf: [1024]u8 = undefined;
    const csv = @import("breakpoints.zig").lineCsv(&ctx.caps.layers, doc, &buf);
    results[0] = @intCast(caller.writeMemory(@intCast(args[2]), @intCast(args[3]), csv) catch 0);
}

/// weft.fileRead(path) → the file's content for the agent's fs/read: the LIVE
/// buffer text if the file is open (uncommitted edits included — the honest
/// current state, not stale disk), else the disk file. Capped at the guest's
/// receive buffer for now.
///
/// ONE `fs_read` grant, two sources, the same confinement on both: the DISK
/// half is `wasm_host/fs.zig`'s semantic body verbatim (the machinery
/// carve-out, possession, `.fs_root` root-relativity, and the rooted open
/// that stops a symlink escape), so the JS plane never re-derives fs policy;
/// the BUFFER half has no descriptor to root against, so it takes that file's
/// descriptor-free gate (`pathAllowed` — the same carve-out and the same
/// lexical layer) — otherwise merely OPENING a file would launder it past a
/// narrowed grant, or past the carve-out.
fn cFileRead(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const self: *JsPlugin = @ptrCast(@alignCast(data.?));
    const gpa = self.gpa;
    const path = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch {
        results[0] = 0;
        return;
    };
    defer gpa.free(path);

    const ctx = self.bridge.activeCtx();
    if (ctx.buffers.findByPath(path)) |id| open: {
        if (!self.requirePerm(.fs_read)) {
            results[0] = qjs_contract.denied;
            return;
        }
        fs_gate.pathAllowed(self, .fs_read, path) catch |e| {
            self.denyPath(.fs_read, path, e);
            results[0] = qjs_contract.denied;
            return;
        };
        const b = ctx.buffers.get(id) orelse break :open;
        const text = (b.textEditor() orelse break :open).text().toOwnedSlice(gpa) catch break :open;
        defer gpa.free(text);
        results[0] = @intCast(caller.writeMemory(@intCast(args[2]), @intCast(args[3]), text) catch 0);
        return;
    }

    const bytes = fs_gate.fsRead(gpa, self, path) catch |e| {
        self.denyPath(.fs_read, path, e);
        results[0] = qjs_contract.denied;
        return;
    } orelse {
        results[0] = 0;
        return;
    };
    defer gpa.free(bytes);
    results[0] = @intCast(caller.writeMemory(@intCast(args[2]), @intCast(args[3]), bytes) catch 0);
}

/// A JS plugin's open pick — dispatches a structured outcome back into the
/// instance via `weft_on_pick`. Freed by `jsPickCleanup`.
const JsBoundPick = struct {
    plugin: *JsPlugin,
    /// The opaque continuation identity the caller minted (owned copy,
    /// delivered back with the outcome): WHICH request this pick answers.
    /// A plugin with two agents in flight keys its pending tool calls by
    /// conversation + call id, so an answer can only ever resolve its own.
    token: []u8,
};

fn allocPickBuffer(plugin: *JsPlugin, cap: usize) !i32 {
    if (cap == 0) return 0;
    const guest_cap = std.math.cast(i32, cap) orelse return error.PickPayloadTooLarge;
    const ptr = try plugin.instance.callI32("malloc", &.{guest_cap});
    return if (ptr == 0) error.OutOfMemory else ptr;
}

/// weft.pick(prompt, options, token): open a pick over the newline-joined
/// options, bound to this JS plugin; the structured outcome returns via
/// `weft_on_pick` carrying `token` (the async approve/deny round-trip — an
/// agent's permission request, answered by continuation identity rather
/// than by "whatever was pending").
fn cPick(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const self: *JsPlugin = @ptrCast(@alignCast(data.?));
    // HEAD-GATED (task #19 item 4): opens a pick on the dispatching head —
    // only ever bound on a resident JsPlugin's linker (the `.plugin` group),
    // so always LIVE mode; no manifest branch to short-circuit through.
    if (!self.bridge.requireDispatch(caller, "weft.pick")) return;
    const gpa = self.gpa;
    const prompt = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(prompt);
    const opts = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer gpa.free(opts);
    const token = caller.readMemory(gpa, @intCast(args[4]), @intCast(args[5])) catch return;
    var entries: std.ArrayList(pick_mod.Entry) = .empty;
    defer entries.deinit(gpa);
    var it = std.mem.splitScalar(u8, opts, '\n');
    while (it.next()) |o| entries.append(gpa, .{ .text = o, .doc = "" }) catch {};
    const bp = gpa.create(JsBoundPick) catch {
        gpa.free(token);
        return;
    };
    bp.* = .{ .plugin = self, .token = token };
    // pick.open copies the entry text/doc, so `opts` may free after this.
    const ctx = self.bridge.activeCtx();
    ctx.head.pick.open(ctx, prompt, entries.items, .{
        .handler = jsPickAccept,
        .cleanup = jsPickCleanup,
        .data = bp,
    }) catch jsPickCleanup(bp, gpa);
}

/// DISPATCHING (mirrors `wasm_host/pick.zig`'s `wpPickAccept`): `ctx` is the
/// head whose pick session produced the outcome. Route `bridge.active_ctx`
/// through it too for the `weft_on_pick` call, so anything the JS handler does
/// in response (echo, bind, another pick) sees the SAME head, not the plugin's
/// load-time one. If exact guest allocation/copy fails after core has closed,
/// the allocation-free cancelled case is still delivered exactly once.
fn jsPickAccept(ctx: *command.Context, data: ?*anyopaque, outcome: pick_mod.Outcome) anyerror!void {
    const bp: *JsBoundPick = @ptrCast(@alignCast(data.?));
    var kind: i32 = 2; // cancelled
    var idx: i32 = -1;
    var text: []const u8 = &.{};
    var query: []const u8 = &.{};
    var match_start: i32 = -1;
    var match_span: i32 = -1;
    switch (outcome) {
        .cancelled => {},
        .candidate => |candidate| {
            const guest_index = std.math.cast(i32, candidate.index);
            const guest_match_start = std.math.cast(i32, candidate.match.start);
            const guest_match_span = std.math.cast(i32, candidate.match.span);
            if (guest_index != null and guest_match_start != null and guest_match_span != null) {
                kind = 0;
                idx = guest_index.?;
                text = candidate.text;
                query = candidate.query;
                match_start = guest_match_start.?;
                match_span = guest_match_span.?;
            }
        },
        .input => |input| {
            kind = 1;
            text = input;
        },
    }

    var text_ptr: i32 = 0;
    defer if (text_ptr != 0) bp.plugin.instance.callVoid("free", &.{text_ptr}) catch {};
    var query_ptr: i32 = 0;
    defer if (query_ptr != 0) bp.plugin.instance.callVoid("free", &.{query_ptr}) catch {};
    // The token rides the SAME copy: an outcome that reaches the guest
    // without it could only be routed by guessing, which is the failure
    // this seam exists to make impossible.
    var token_ptr: i32 = 0;
    defer if (token_ptr != 0) bp.plugin.instance.callVoid("free", &.{token_ptr}) catch {};

    var copied = false;
    copy: {
        text_ptr = allocPickBuffer(bp.plugin, text.len) catch break :copy;
        query_ptr = allocPickBuffer(bp.plugin, query.len) catch break :copy;
        token_ptr = allocPickBuffer(bp.plugin, bp.token.len) catch break :copy;
        if (text.len > 0) bp.plugin.instance.writeGuest(@intCast(text_ptr), text) catch break :copy;
        if (query.len > 0) bp.plugin.instance.writeGuest(@intCast(query_ptr), query) catch break :copy;
        if (bp.token.len > 0) bp.plugin.instance.writeGuest(@intCast(token_ptr), bp.token) catch break :copy;
        copied = true;
    }
    if (!copied) {
        kind = 2;
        idx = -1;
        text = &.{};
        query = &.{};
        match_start = -1;
        match_span = -1;
    }

    const saved_ctx = bp.plugin.bridge.active_ctx;
    const saved_dispatch = bp.plugin.bridge.in_dispatch;
    bp.plugin.bridge.active_ctx = ctx;
    bp.plugin.bridge.in_dispatch = true; // DISPATCHING (task #19 item 4) — see onCommand's doc
    defer {
        bp.plugin.bridge.active_ctx = saved_ctx;
        bp.plugin.bridge.in_dispatch = saved_dispatch;
    }
    bp.plugin.instance.callVoid("weft_on_pick", &.{
        kind,
        idx,
        text_ptr,
        std.math.cast(i32, text.len) orelse 0,
        query_ptr,
        std.math.cast(i32, query.len) orelse 0,
        match_start,
        match_span,
        token_ptr,
        if (copied) std.math.cast(i32, bp.token.len) orelse 0 else 0,
    }) catch {};
}

fn jsPickCleanup(data: ?*anyopaque, gpa: Allocator) void {
    const bp: *JsBoundPick = @ptrCast(@alignCast(data.?));
    gpa.free(bp.token);
    gpa.destroy(bp);
}

/// weft.status(text): set the generic plugin status chip (empty clears it).
fn cStatus(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const self: *JsPlugin = @ptrCast(@alignCast(data.?));
    const text = caller.readMemory(self.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer self.gpa.free(text);
    status_feed.set(text);
}

/// weft.lineText() → the active buffer's current line (at the cursor), for a
/// prompt line. Written into the guest's receive buffer.
fn cLineText(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const self: *JsPlugin = @ptrCast(@alignCast(data.?));
    const ed = self.bridge.activeCtx().buffers.active().textEditor() orelse {
        results[0] = 0;
        return;
    };
    const rope = ed.text();
    const row = rope.offsetToPoint(@min(ed.cursorOffset(), rope.byteLen())).row;
    const line = rope.lineRange(row);
    const gpa = self.gpa;
    const buf = gpa.alloc(u8, line.end - line.start) catch {
        results[0] = 0;
        return;
    };
    defer gpa.free(buf);
    var sr = rope.streamReader(.{ .start = line.start, .end = line.end }, &.{});
    sr.interface.readSliceAll(buf) catch {
        results[0] = 0;
        return;
    };
    results[0] = @intCast(caller.writeMemory(@intCast(args[0]), @intCast(args[1]), buf) catch 0);
}

/// weft.activeBuffer() → the focused buffer's display name. An instanced JS
/// tool (two DAP sessions, each owning `*debug*` / `*debug:2*`) routes a
/// command by it: the session whose buffer you are looking at is the one the
/// command drives. The wasm plane's `weft.activeBufferName` in the same words.
fn cActiveBuffer(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const self: *JsPlugin = @ptrCast(@alignCast(data.?));
    const name = self.bridge.activeCtx().buffers.active().name;
    results[0] = @intCast(caller.writeMemory(@intCast(args[0]), @intCast(args[1]), name) catch 0);
}

/// The CRDT peer an agent's file writes author as (a single agent identity for
/// now; per-conversation naming is a refinement).
const agent_peer = "agent";

/// weft.fileWrite(path, content) → the agent's fs/write_text_file: replace the
/// buffer for `path` with `content`, authored as the agent peer — a gated,
/// attributed, selectively-undoable edit (the harness payoff), not a raw disk
/// write. Opens (binds) the path if it isn't already a buffer; the user saves.
/// A whole-file write, so the buffer's whole content is replaced.
///
/// `cFileRead`'s WRITE twin, gated identically: possession first
/// (`fs_write`), then `pathAllowed` — the carve-out plus the lexical layer,
/// because like `cFileRead`'s buffer half this door has no descriptor to root
/// against (it never touches the filesystem; the user's later save does).
/// Without both, `weft.grant("acp", "fs_write", {root: …})` confined NOTHING here:
/// an agent could bind and fill a buffer at any absolute path outside its
/// granted root. The `command.renderInto` call below is NOT that gate —
/// its `gradeMin(doc.my_grant, .edit)` is a COLLAB authority check, and
/// `Document.my_grant` defaults to `.own`, so it passes trivially for
/// every local buffer.
fn cAgentWrite(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const self: *JsPlugin = @ptrCast(@alignCast(data.?));
    const gpa = self.gpa;
    results[0] = 0;
    const path = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(path);
    const content = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer gpa.free(content);
    const agent = caller.readMemory(gpa, @intCast(args[4]), @intCast(args[5])) catch return;
    defer gpa.free(agent);
    if (!self.requirePerm(.fs_write)) {
        results[0] = qjs_contract.denied;
        return;
    }
    fs_gate.pathAllowed(self, .fs_write, path) catch |e| {
        self.denyPath(.fs_write, path, e);
        results[0] = qjs_contract.denied;
        return;
    };
    const peer = if (agent.len > 0) agent else agent_peer;
    const bufs = self.bridge.activeCtx().buffers;
    const id = bufs.findByPath(path) orelse blk: {
        const new_id = bufs.create(gpa, std.fs.path.basename(path)) catch return;
        const nb = bufs.get(new_id) orelse return;
        (nb.textEditor() orelse return).adoptPath(gpa, path) catch return; // bind the path (save creates it)
        break :blk new_id;
    };
    const b = bufs.get(id) orelse return;
    const ed = b.textEditor() orelse return;
    const doc = &ed.doc;
    const end = ed.text().byteLen();
    command.renderInto(gpa, doc, .agent, peer, &.{.{ .range = .{ .start = 0, .end = end }, .bytes = content }}) catch return;
}

/// The framed blob the shim encodes — one decoder, shared with the guest ABI
/// membrane (see `framed.zig`).
const FramedRecords = @import("framed.zig").Records;

/// The first record of a framed blob — a single-valued `weft.set`'s value.
const firstFramedRecord = @import("framed.zig").first;

/// The command handler a `weft.command` registers under: dispatch back into the
/// owning JS plugin by id. `ctx` is the dispatching head's — forwarded to
/// `onCommand` (THE FIX: previously discarded, so a guest-JS-backed command
/// always ran against the plugin's load-time ctx regardless of which head
/// dispatched it).
fn jsCmdTramp(ctx: *command.Context, data: ?*anyopaque, args: []const command.Value) anyerror!command.Value {
    _ = args;
    const c: *JsPlugin.Cmd = @ptrCast(@alignCast(data.?));
    c.plugin.onCommand(ctx, c.id);
    return .nil;
}

/// qjs_register(name) for the plugin plane: bind a command whose handler
/// dispatches to the JS plugin, and return its id (the array index the JS side
/// keys its handler by, and the host passes to weft_on_command).
///
/// WHY THIS ONE DOES NOT COLLAPSE onto `wl_register` (doc/place.md §4.1a),
/// stated so the next reader doesn't have to rediscover it: the two doors
/// share a name and a shape, but almost nothing of a body. `hRegister` mints a
/// `WasmCmd` into `WasmPlugin.commands` bound to `wpCmdTrampoline`; this mints
/// a `JsPlugin.Cmd` into `JsPlugin.cmds` bound to `jsCmdTramp` — two id
/// registries whose entries are the identity the host dispatches by, so there
/// is no shared state for one body to operate on, and the ~6 lines that would
/// be common (read a name, append, bind, answer the index) are smaller than
/// the seam it would take to share them.
///
/// The REAL divergence here is not the body, and it is not fixable by sharing
/// one: `hRegister` cross-checks `p.declaresCommand(cname)` — an undeclared
/// command FAILS THE LOAD — and this door cannot, because a `.js` plugin has
/// no `describe()` handshake to populate a declaration from. A JS plugin can
/// therefore register any command name; a `.wasm` plugin only the ones it
/// declared. Closing that means giving the JS plane a manifest of its own, not
/// giving it this function.
fn cRegister(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const self: *JsPlugin = @ptrCast(@alignCast(data.?));
    const gpa = self.gpa;
    const name = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch {
        results[0] = -1;
        return;
    };
    // `name` is owned by the Cmd (the command registry borrows the field).
    const id: i32 = @intCast(self.cmds.items.len);
    const c = gpa.create(JsPlugin.Cmd) catch {
        gpa.free(name);
        results[0] = -1;
        return;
    };
    c.* = .{ .plugin = self, .id = id, .name = name };
    self.cmds.append(gpa, c) catch {
        gpa.free(name);
        gpa.destroy(c);
        results[0] = -1;
        return;
    };
    _ = self.bridge.activeCtx().commands.bind(gpa, name, .{
        .name = c.name,
        .summary = "js",
        .args = &.{},
        .handler = jsCmdTramp,
        .data = c,
    }) catch {
        results[0] = -1;
        return;
    };
    results[0] = id;
}

// ── The `weft.*` config imports: read the guest's strings, drive the ctx.
// Each mirrors one config-surface import of the wasm plane; failures degrade
// quietly (a bad bind is dropped) — the JS side already validated
// arity/types. ──

fn readStr(br: *Bridge, caller: *wasm.Caller, ptr: i32, len: i32) ?[]u8 {
    return caller.readMemory(br.activeCtx().gpa, @intCast(ptr), @intCast(len)) catch null;
}

/// `weft.bind(scope, key, intention | [intentions])`: the third argument
/// arrives as a framed list (the shim frames the string form as one entry),
/// so both authored shapes reach the manifest as one representation.
fn cBindKey(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const br: *Bridge = @ptrCast(@alignCast(data.?));
    const gpa = br.activeCtx().gpa;
    const mode = readStr(br, caller, args[0], args[1]) orelse return;
    defer gpa.free(mode);
    const key = readStr(br, caller, args[2], args[3]) orelse return;
    defer gpa.free(key);
    const blob = readStr(br, caller, args[4], args[5]) orelse return;
    defer gpa.free(blob);
    var cmds: [manifest_mod.maxBindCommands][]const u8 = undefined;
    var n: usize = 0;
    var it = FramedRecords.init(blob) orelse return;
    // The shim already throws on a degenerate list; these drop a blob that
    // reached here anyway rather than bind a truncated one.
    while (it.next()) |rec| : (n += 1) {
        if (n == cmds.len) return;
        cmds[n] = rec;
    }
    if (n == 0) return;
    if (br.manifest) |m| {
        m.addBind(mode, key, cmds[0..n]) catch {};
        return;
    }
    // LIVE mode (a resident JS plugin): user config shadows plugins and core
    // defaults (highest tier). Fallback lists bind their FIRST entry, as
    // `applyDecls` does — no resolution is faked here either.
    br.activeCtx().keymap.bind(gpa, mode, key, cmds[0], @import("Keymap.zig").prio_config, "config") catch {};
}

/// `weft.use(name)` backing: evaluate `<config_dir>/<name>.js` into ITS OWN
/// manifest — a NESTED, independent `evalToManifest` call (its own fresh
/// quickjs runtime, exactly like the top-level config's own eval), attached
/// as an import at `.imported` tier (doc/configuration.md §7: "imported
/// manifests land one tier below the importer"). A no-op (no result to
/// report — `weft.use` has always been fire-and-forget from JS) when: this
/// isn't config-eval mode (a resident JS plugin's `weft.use` — no config_dir
/// is ever wired for one, matching the old `cReadConfig`'s degrade), the
/// file can't be read, or the nested eval throws — each logged, none fatal
/// to the OUTER eval (a broken include shouldn't brick the whole config).
fn cUse(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const br: *Bridge = @ptrCast(@alignCast(data.?));
    const gpa = br.activeCtx().gpa;
    const m = br.manifest orelse return;
    const dir = br.config_dir orelse return;
    const name = readStr(br, caller, args[0], args[1]) orelse return;
    defer gpa.free(name);
    // Nested weft.use (an imported file itself calling weft.use) flat-tiers
    // — the sub-sub-manifest still lands at plain `.imported`, one rung, not
    // a deeper one (manifest.zig's module doc: "a deliberate simplification
    // — nothing in the shipped config nests weft.use more than one level").
    // LOUD about it (nit c), not a silent behavior a config author has to
    // discover by reading this file's comments.
    if (m.tier == .imported) {
        const msg = std.fmt.allocPrint(gpa, "config: weft.use(\"{s}\") nested inside an imported config — flattens to the same 'imported' tier, not a deeper one", .{name}) catch "";
        defer if (msg.len > 0) gpa.free(msg);
        std.log.warn("{s}", .{msg});
        br.activeCtx().head.echo.clearRetainingCapacity();
        br.activeCtx().head.echo.appendSlice(gpa, msg) catch {};
    }
    const path = std.fmt.allocPrint(gpa, "{s}/{s}.js", .{ dir, name }) catch return;
    defer gpa.free(path);
    const src = @import("file.zig").readAlloc(gpa, path) catch |e| {
        std.log.warn("config: weft.use(\"{s}\") failed to read {s}: {t}", .{ name, path, e });
        return;
    };
    defer gpa.free(src);
    const owner = std.fmt.allocPrint(gpa, "import:{s}", .{name}) catch return;
    defer gpa.free(owner);
    const sub = evalToManifest(br.engine, br.activeCtx(), br.loader, br.config, dir, src, .imported, owner) catch |e| {
        std.log.warn("config: weft.use(\"{s}\") failed: {t}", .{ name, e });
        return;
    };
    m.addImport(sub) catch sub.destroy();
}

const maxRunArgs = 8;
const maxRunArgBytes = 1024;
const maxRunArgTotal = 4096;

fn cRun(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const br: *Bridge = @ptrCast(@alignCast(data.?));
    const gpa = br.activeCtx().gpa;
    const cmd = readStr(br, caller, args[0], args[1]) orelse return;
    defer gpa.free(cmd);
    if (args[3] < 0) return;
    const count: usize = @intCast(args[3]);
    if (count > maxRunArgs) return;
    var values: [maxRunArgs]command.Value = undefined;
    var decoded: usize = 0;
    defer for (values[0..decoded]) |value| gpa.free(value.string);
    var total: usize = 0;
    if (count > 0) {
        if (args[2] < 0) return;
        const record_bytes = std.math.mul(usize, count, 8) catch return;
        const records = caller.readMemory(gpa, @intCast(args[2]), record_bytes) catch return;
        defer gpa.free(records);
        for (0..count) |i| {
            const off = i * 8;
            var ptr_bytes: [4]u8 = undefined;
            var len_bytes: [4]u8 = undefined;
            @memcpy(&ptr_bytes, records[off .. off + 4]);
            @memcpy(&len_bytes, records[off + 4 .. off + 8]);
            const ptr = std.mem.readInt(i32, &ptr_bytes, .little);
            const len = std.mem.readInt(i32, &len_bytes, .little);
            if (ptr < 0 or len < 0 or len > maxRunArgBytes) return;
            total = std.math.add(usize, total, @intCast(len)) catch return;
            if (total > maxRunArgTotal) return;
            const value = readStr(br, caller, ptr, len) orelse return;
            values[decoded] = .{ .string = value };
            decoded += 1;
        }
    }
    if (br.manifest) |m| {
        m.addRun(cmd, values[0..decoded]) catch {};
        return;
    }
    // LIVE mode (task #19 item 4): NOW dispatches for real — a resident JS
    // plugin's `weft.run(name)` runs `name` through the SAME shared command
    // registry `wl_run` does, via `command.run`. Previously a no-op (the
    // config-eval tail's replay list never applied here); this is what makes
    // a background `weft_on_output` handler's ONE sanctioned door to head
    // state work at all (`Bridge.requireDispatch`'s doc): a message landing
    // async can't call `weft.echo`/`weft.pick` directly, but it CAN defer
    // through a self-registered command, which re-enters `JsPlugin.onCommand`
    // (a DISPATCHING entry — `in_dispatch` promotes to true for its nested
    // duration, mirroring `wpCmdTrampoline`'s reentrancy story exactly). If
    // `cmd` resolves to a command bound by ANOTHER plugin (wasm or JS), this
    // runs THAT one too — same "by name, system-wide" semantics `wl_run`
    // already has, not scoped to the calling plugin.
    _ = command.run(br.activeCtx().commands, br.activeCtx(), cmd, values[0..decoded]) catch {};
}

/// weft.set(plugin, key, blob) — stage config data for a plugin (read at its
/// init via wl_config_get). The blob is already framed by the shim.
fn cSet(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const br: *Bridge = @ptrCast(@alignCast(data.?));
    const gpa = br.activeCtx().gpa;
    const owner = readStr(br, caller, args[0], args[1]) orelse return;
    defer gpa.free(owner);
    const key = readStr(br, caller, args[2], args[3]) orelse return;
    defer gpa.free(key);
    const blob = readStr(br, caller, args[4], args[5]) orelse return;
    defer gpa.free(blob);
    if (br.manifest) |m| {
        m.addValue(owner, key, blob) catch {};
        return;
    }
    const store = br.config orelse return;
    store.put(gpa, owner, key, blob) catch {};
}

/// weft.menu(name) — declare `name` as a prefix-menu keymap mode: a which-key
/// submenu. It swallows text (a modal menu, not typing) and Escape/C-g leave it
/// via `menu-escape`. A leader key bound to `name` enters it (the dispatch
/// treats a bound command that names a menu mode as "enter that submenu").
fn cMenu(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const br: *Bridge = @ptrCast(@alignCast(data.?));
    const gpa = br.activeCtx().gpa;
    const name = readStr(br, caller, args[0], args[1]) orelse return;
    defer gpa.free(name);
    if (br.manifest) |m| {
        m.addMenu(name) catch {};
        return;
    }
    const km = br.activeCtx().keymap;
    const Keymap = @import("Keymap.zig");
    km.markMenuMode(gpa, name) catch {};
    km.bind(gpa, name, "Escape", "menu-escape", Keymap.prio_config, "config") catch {};
    km.bind(gpa, name, "C-g", "menu-escape", Keymap.prio_config, "config") catch {};
    km.bind(gpa, name, "F1", "which-key-now", Keymap.prio_config, "config") catch {}; // force the hint now
}

/// weft.action(name) — declare a `pick` action (an abstract intent) and bind
/// its same-named trampoline command, so a config `weft.bind(mode, key, name)`
/// dispatches it. Idempotent.
fn cAction(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const br: *Bridge = @ptrCast(@alignCast(data.?));
    const gpa = br.activeCtx().gpa;
    const name = readStr(br, caller, args[0], args[1]) orelse return;
    defer gpa.free(name);
    if (br.manifest) |m| {
        m.addAction(name) catch {};
        return;
    }
    command.registerAction(gpa, br.activeCtx().commands, br.activeCtx().actions, name, .pick) catch {};
}

/// weft.semanticAction(name) — declare a focused structured-view action
/// command. Names are open protocol strings; unlike `weft.action`, they do
/// not enter context/provider resolution.
fn cSemanticAction(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const br: *Bridge = @ptrCast(@alignCast(data.?));
    const gpa = br.activeCtx().gpa;
    const name = readStr(br, caller, args[0], args[1]) orelse return;
    defer gpa.free(name);
    if (br.manifest) |m| {
        m.addSemanticAction(name) catch {};
        return;
    }
    if (br.activeCtx().semantic) |services|
        @import("builtins.zig").registerSemanticAction(gpa, br.activeCtx().commands, services, name) catch {};
}

/// weft.provide(action, mode, lang, cmd, prio) — register a provider. Empty
/// mode/lang strings mean "don't care" (an unconstrained provider). Auto-
/// declares the action if `weft.action` hasn't run yet (load order is free),
/// but does NOT bind a trampoline command — a provider alone isn't a key
/// target; declare (or another config's declare) owns the command bind.
fn cProvide(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const br: *Bridge = @ptrCast(@alignCast(data.?));
    const gpa = br.activeCtx().gpa;
    const action = readStr(br, caller, args[0], args[1]) orelse return;
    defer gpa.free(action);
    const mode = readStr(br, caller, args[2], args[3]) orelse return;
    defer gpa.free(mode);
    const lang = readStr(br, caller, args[4], args[5]) orelse return;
    defer gpa.free(lang);
    const cmd = readStr(br, caller, args[6], args[7]) orelse return;
    defer gpa.free(cmd);
    const priority = args[8];
    if (br.manifest) |m| {
        m.addProvide(action, mode, lang, cmd, priority) catch {};
        return;
    }
    br.activeCtx().actions.provide(.{
        .action = action,
        .when = .{
            .mode = if (mode.len > 0) mode else null,
            .lang = if (lang.len > 0) lang else null,
        },
        .command = cmd,
        .priority = priority,
        .owner = "config",
    }) catch |e| if (e == error.RaceRejectsProvider) echoProvideRefused(br, action);
}

/// weft.statusSegment(text, role, priority) — stage a static `ui/statusline-
/// seg` segment onto the manifest (doc/contextual-workspace-architecture.md
/// §11, the mesh-reachability verb). CONFIG-ONLY: unlike
/// `weft.provide`/`weft.action` this has no LIVE (resident-JS-plugin,
/// `br.manifest == null`) behavior — the direct-bind path would need this
/// (core-layer) module to know the gfx-layer `ui_mesh.zig` provider shape,
/// exactly the dependency `manifest.StatusSegBinder`'s doc explains core
/// can't take; a resident plugin reaching `ui/*` live is a later step
/// (D2/W0b), not this one.
fn cStatusSegment(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const br: *Bridge = @ptrCast(@alignCast(data.?));
    const gpa = br.activeCtx().gpa;
    const text = readStr(br, caller, args[0], args[1]) orelse return;
    defer gpa.free(text);
    const role = readStr(br, caller, args[2], args[3]) orelse return;
    defer gpa.free(role);
    const priority = args[4];
    if (br.manifest) |m| {
        m.addStatusSegment(text, role, priority) catch {};
        return;
    }
    std.log.warn("weft.statusSegment: config-plane only (not available to a resident plugin yet)", .{});
}

/// weft.grant(plugin, capability, opts) — stage a `GrantDecl` onto the
/// manifest (doc/contextual-workspace-architecture.md §13.5, the deferred
/// verb `grants.zig`'s module doc named). `root` is already the flattened
/// `opts.root` string by the time it reaches here (the C shim, `js_grant`,
/// pulls it out of the JS object — this handler stays as string-only as every
/// other `.config` import). CONFIG-EVAL mode only — same precedent as
/// `cStatusSegment` above: authority delegation is a declarative,
/// sealed-eval-time act (§2.3), not something a resident plugin's live code
/// should be able to conjure for ANOTHER principal at any point in its
/// lifetime.
fn cGrant(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const br: *Bridge = @ptrCast(@alignCast(data.?));
    const gpa = br.activeCtx().gpa;
    const plugin = readStr(br, caller, args[0], args[1]) orelse return;
    defer gpa.free(plugin);
    const capability = readStr(br, caller, args[2], args[3]) orelse return;
    defer gpa.free(capability);
    const root = readStr(br, caller, args[4], args[5]) orelse return;
    defer gpa.free(root);
    if (br.manifest) |m| {
        m.addGrant(plugin, capability, root) catch {};
        return;
    }
    std.log.warn("weft.grant: config-plane only (not available to a resident plugin yet)", .{});
}

/// The attribute bits `weft_qjs.c`'s `WEFT_VP_*` sets. The two lists must
/// agree; there is no third place they are spelled.
const vp_cycles: i32 = 1 << 0;
const vp_persistent: i32 = 1 << 1;
const vp_focus_source: i32 = 1 << 2;

/// `weft.viewport(name, opts)` — stage a viewport's attributes
/// (doc/configuration.md §5.2). The edge arrives as a name and is PARSED
/// here: the attribute set is closed, so a misspelled edge is a config
/// mistake to report at the boundary, not an undocked viewport to puzzle
/// over later.
fn cViewport(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const br: *Bridge = @ptrCast(@alignCast(data.?));
    const gpa = br.activeCtx().gpa;
    const name = readStr(br, caller, args[0], args[1]) orelse return;
    defer gpa.free(name);
    const edge_name = readStr(br, caller, args[2], args[3]) orelse return;
    defer gpa.free(edge_name);
    const edge = viewport_mod.parseEdge(edge_name);
    if (edge == null and edge_name.len > 0) {
        std.log.warn("weft.viewport(\"{s}\"): unknown edge '{s}' — expected left/right/top/bottom; declared undocked", .{ name, edge_name });
    }
    const flags = args[4];
    const attrs: viewport_mod.Attrs = .{
        .cycles = flags & vp_cycles != 0,
        .persistent = flags & vp_persistent != 0,
        .dock = edge,
        .focus_source = flags & vp_focus_source != 0,
    };
    const extent: f32 = @as(f32, @floatFromInt(args[5])) / 1000.0;
    if (br.manifest) |m| {
        m.addViewport(name, attrs, extent) catch {};
        return;
    }
    std.log.warn("weft.viewport: config-plane only (a viewport is manifest composition, not a runtime poke)", .{});
}

/// `weft.present(viewport, {subject})` — stage what a declared viewport
/// shows (§7).
fn cPresent(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const br: *Bridge = @ptrCast(@alignCast(data.?));
    const gpa = br.activeCtx().gpa;
    const name = readStr(br, caller, args[0], args[1]) orelse return;
    defer gpa.free(name);
    const subject = readStr(br, caller, args[2], args[3]) orelse return;
    defer gpa.free(subject);
    if (br.manifest) |m| {
        m.addPresent(name, subject) catch {};
        return;
    }
    std.log.warn("weft.present: config-plane only (a viewport is manifest composition, not a runtime poke)", .{});
}

/// Surface a rejected `provide` to the plugin author through the echo line —
/// the normal user-facing channel — so the mistake (a pick provider on a race
/// action) is reported where they'll see it, not on a global stderr. LIVE
/// mode only — `manifest.zig`'s `applyDecls` has its own copy for the
/// config-eval path (this module stays free of a dependency the other
/// direction).
fn echoProvideRefused(br: *Bridge, action: []const u8) void {
    const ctx = br.activeCtx();
    const gpa = ctx.gpa;
    const msg = std.fmt.allocPrint(gpa, "provide: '{s}' is a race action — register a capability provider instead", .{action}) catch return;
    defer gpa.free(msg);
    // head.echo only from a dispatching path or load — a BACKGROUND entry's
    // error lands in the log instead (the gated class; see #19 item 4).
    if (br.in_dispatch or br.loading) {
        ctx.head.echo.clearRetainingCapacity();
        ctx.head.echo.appendSlice(gpa, msg) catch {};
    } else {
        std.log.warn("js plugin: {s}", .{msg});
    }
}

fn cEcho(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const br: *Bridge = @ptrCast(@alignCast(data.?));
    const msg = readStr(br, caller, args[0], args[1]) orelse return;
    // alloc + free both via activeCtx().gpa: safe because gpa is the one
    // process allocator and active_ctx cannot change inside a synchronous
    // host import — stated because the free would be wrong if either stopped
    // holding.
    defer br.activeCtx().gpa.free(msg);
    if (br.manifest) |m| {
        m.addEcho(msg) catch {};
        return;
    }
    // HEAD-GATED (task #19 item 4): reached only in LIVE mode (config-eval
    // already returned above) — a resident plugin's BACKGROUND
    // `weft_on_output` must not write the head's echo line directly.
    if (!br.requireDispatch(caller, "weft.echo")) return;
    br.activeCtx().head.echo.clearRetainingCapacity();
    br.activeCtx().head.echo.appendSlice(br.activeCtx().gpa, msg) catch {};
}

fn cLog(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const br: *Bridge = @ptrCast(@alignCast(data.?));
    const msg = readStr(br, caller, args[0], args[1]) orelse return;
    defer br.activeCtx().gpa.free(msg);
    if (br.manifest) |m| {
        m.addLog(msg) catch {};
        return;
    }
    std.log.info("config: {s}", .{msg});
}

fn cPlugin(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const br: *Bridge = @ptrCast(@alignCast(data.?));
    const name = readStr(br, caller, args[0], args[1]) orelse return;
    if (br.manifest) |m| {
        defer br.activeCtx().gpa.free(name);
        m.addPlugin(name) catch {};
        return;
    }
    if (br.loader == null) {
        br.activeCtx().gpa.free(name);
        return; // no loader wired → weft.plugin is a no-op (LIVE mode)
    }
    // LIVE mode with a loader wired never actually happens today (a resident
    // JS plugin's bridge always has `loader = null` — see `JsPlugin.load`),
    // but preserved for shape: load immediately (no deferred-replay list to
    // stage into anymore — see manifest.zig's `apply` for why config-eval
    // mode no longer needs one).
    defer br.activeCtx().gpa.free(name);
    br.loader.?.load(br.loader.?.ctx, name);
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

const Env = struct {
    pool: *@import("task.zig").Pool,
    buffers: @import("Buffers.zig"),
    commands: command.Commands,
    keymap: @import("Keymap.zig"),
    head: @import("Head.zig"),
    /// The ONE shared Container `caps`/`actions` bind into (task #19).
    container: @import("container.zig").Container,
    caps: @import("capability.zig").Caps,
    actions: @import("action.zig"),
    semantic: @import("semantic.zig").Services,
    quit: bool,
    /// A real grant table, as `System.create` wires one — so a JS plugin
    /// loaded here adopts its authority exactly the way production does
    /// (`grant` below stands in for the config plane's `weft.grant`).
    grants: grants_mod.HandleTable,
    ctx: command.Context,

    fn init(gpa: Allocator, self: *Env) !void {
        self.pool = try task.Pool.init(gpa, .{ .threads = 1 });
        self.buffers = try @import("Buffers.zig").init(gpa, self.pool, "user");
        self.commands = .empty;
        self.keymap = .empty;
        self.head = .empty;
        self.container = @import("container.zig").Container.init(gpa);
        self.caps = @import("capability.zig").Caps.init(gpa, task.nowNs, &self.container);
        self.actions = @import("action.zig").init(gpa, &self.container);
        self.semantic = @import("semantic.zig").Services.init(.here);
        self.quit = false;
        self.grants = grants_mod.HandleTable.init(gpa);
        self.ctx = .{
            .gpa = gpa,
            .buffers = &self.buffers,
            .commands = &self.commands,
            .keymap = &self.keymap,
            .actions = &self.actions,
            .semantic = &self.semantic,
            .caps = &self.caps,
            .quit = &self.quit,
            .head = &self.head,
            .grant_table = &self.grants,
        };
    }

    /// Mint what `weft.grant(plugin, capability)` would mint — call BEFORE
    /// `JsPlugin.load`, which is when a plugin adopts its rows. `plugin`
    /// and `capability` are borrowed by the table (string literals here).
    fn grant(self: *Env, plugin: []const u8, capability: []const u8) !void {
        _ = try self.grants.grant(.{ .capability = capability }, plugin, null);
    }

    fn deinit(self: *Env, gpa: Allocator) void {
        self.grants.deinit();
        self.actions.deinit();
        self.semantic.deinit(gpa);
        self.caps.deinit();
        self.container.deinit();
        self.head.deinit(gpa);
        self.keymap.deinit(gpa);
        self.commands.deinit(gpa);
        self.buffers.deinit(gpa);
        self.pool.deinit();
    }
};

fn bindRunArgsFixture(gpa: Allocator, env: *Env) !void {
    const H = struct {
        fn invoke(ctx: *command.Context, data: ?*anyopaque, args: []const command.Value) anyerror!command.Value {
            _ = data;
            if (args.len != 3) return error.FixtureArity;
            if (args[0] != .string or args[1] != .string or args[2] != .string) return error.FixtureType;
            if (!std.mem.eql(u8, args[0].string, ".foo") or
                !std.mem.eql(u8, args[1].string, "/tmp/grammar") or
                !std.mem.eql(u8, args[2].string, "tree_sitter_fixture")) return error.FixtureValue;
            ctx.head.echo.clearRetainingCapacity();
            try ctx.head.echo.appendSlice(ctx.gpa, "run-args-ok");
            return .nil;
        }
    };
    _ = try env.commands.bind(gpa, "fixture-run-args", .{
        .name = "fixture-run-args",
        .summary = "argument-bearing config fixture",
        .args = &.{
            .{ .name = "ext", .type = .string },
            .{ .name = "dir", .type = .string },
            .{ .name = "symbol", .type = .string },
        },
        .handler = H.invoke,
        .data = null,
    });
}

test "quickjs: config.js drives the weft ABI — binds a key and echoes" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    const cfg =
        \\weft.bind("normal", "j", "cursor-down");
        \\weft.bind("normal", "k", "cursor-up");
        \\weft.echo("config loaded (" + (1 + 1) + " keys)");
    ;
    try evalConfig(&engine, &env.ctx, null, null, null, cfg);

    // The JS ran real logic (string concat + arithmetic) and reached the host:
    try env.head.setModeRaw(gpa, "normal");
    try t.expectEqualStrings("cursor-down", env.keymap.lookup(env.head.currentMode(), "j").?);
    try t.expectEqualStrings("cursor-up", env.keymap.lookup(env.head.currentMode(), "k").?);
    try t.expectEqualStrings("config loaded (2 keys)", env.head.echo.items);
}

test "quickjs: weft.use includes a shared bindings module from the config dir" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    // A shared defaults file the config pulls in with `weft.use`. It binds a
    // pick key (which now lives in config data, not core).
    const dir = ".zig-cache/tmp/weft-use-test";
    const defaults_path = dir ++ "/shared.js";
    try @import("file.zig").writeBytesMakingDirs(gpa, dir, defaults_path,
        \\weft.bind("pick", "Down", "pick-next");
        \\weft.bind("pick", "Return", "pick-accept");
    );
    defer @import("file.zig").deleteFile(gpa, defaults_path);

    // The config includes it, then OVERRIDES one bind (last-wins) to prove the
    // including config wins over the shared defaults.
    const cfg =
        \\weft.use("shared");
        \\weft.bind("pick", "Down", "pick-prev");
    ;
    try evalConfig(&engine, &env.ctx, null, null, dir, cfg);

    try env.head.setModeRaw(gpa, "pick");
    try t.expectEqualStrings("pick-accept", env.keymap.lookup(env.head.currentMode(), "Return").?); // from the include
    try t.expectEqualStrings("pick-prev", env.keymap.lookup(env.head.currentMode(), "Down").?); // config override won
}

test "quickjs: config.js can run a registered command through weft.run" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    // A host command the config invokes: appends a mark to the echo line.
    const H = struct {
        fn mark(ctx: *command.Context, data: ?*anyopaque, args: []const command.Value) anyerror!command.Value {
            _ = data;
            _ = args;
            try ctx.head.echo.appendSlice(ctx.gpa, "ran!");
            return .nil;
        }
    };
    _ = try env.commands.bind(gpa, "mark", .{ .name = "mark", .summary = "", .args = &.{}, .handler = H.mark, .data = null });

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    try evalConfig(&engine, &env.ctx, null, null, null, "weft.run(\"mark\");");
    try t.expectEqualStrings("ran!", env.head.echo.items);
}

test "quickjs: config weft.run carries bounded string args through the generic command door" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    try bindRunArgsFixture(gpa, &env);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    try evalConfig(&engine, &env.ctx, null, null, null, "weft.run('fixture-run-args', '.foo', '/tmp/grammar', 'tree_sitter_fixture');");
    try t.expectEqualStrings("run-args-ok", env.head.echo.items);
}

test "quickjs: manifest run declarations retain args until apply" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    try bindRunArgsFixture(gpa, &env);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    const m = try evalToManifest(&engine, &env.ctx, null, null, null, "weft.run('fixture-run-args', '.foo', '/tmp/grammar', 'tree_sitter_fixture');", .config, "config");
    defer m.destroy();
    try t.expectEqual(@as(usize, 1), m.runs.items.len);
    try t.expectEqualStrings("/tmp/grammar", m.runs.items[0].args[1].value);
    var actx: manifest_mod.Manifest.ApplyCtx = .{ .ctx = &env.ctx, .loader = null, .config = null };
    try m.apply(gpa, &actx);
    try t.expectEqualStrings("run-args-ok", env.head.echo.items);
}

test "quickjs: argument-bearing weft.run rejects invalid shape before staging" {
    const gpa = t.allocator;
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const cases = [_][]const u8{
        "weft.run('fixture', 1);",
        "weft.run('fixture', '1','2','3','4','5','6','7','8','9');",
        "weft.run('fixture', new Array(1025).fill('x').join(''));",
    };
    for (cases) |source| {
        var env: Env = undefined;
        try Env.init(gpa, &env);
        defer env.deinit(gpa);
        try t.expectError(error.ConfigException, evalToManifest(&engine, &env.ctx, null, null, null, source, .config, "config"));
    }
}

test "quickjs: weft.action + weft.provide wire the pick dispatch layer" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    // Declare an abstract intent, provide language-specific and default
    // implementations, and bind a key to the intent — the synthetic bind.
    const cfg =
        \\weft.action("eval");
        \\weft.provide("eval", { lang: "zig" }, "zig-eval");
        \\weft.provide("eval", { lang: "py" }, "python-repl");
        \\weft.provide("eval", {}, "eval-line", -10);
        \\weft.bind("normal", "space", "eval");
    ;
    try evalConfig(&engine, &env.ctx, null, null, null, cfg);

    // The action registered its trampoline command (a key can bind to it), and
    // the key resolves to the action name through the normal keymap door.
    try t.expect(env.commands.resolve("eval") != null);
    try t.expect(env.ctx.actions.isAction("eval"));
    try env.head.setModeRaw(gpa, "normal");
    try t.expectEqualStrings("eval", env.keymap.lookup(env.head.currentMode(), "space").?);

    // The `when` predicates crossed the JS→host membrane intact: eval resolves
    // per language, and the unconstrained default covers everything else.
    try t.expectEqualStrings("zig-eval", env.ctx.actions.resolve("eval", .{ .mode = "normal", .lang = "zig" }).?);
    try t.expectEqualStrings("python-repl", env.ctx.actions.resolve("eval", .{ .mode = "normal", .lang = "py" }).?);
    try t.expectEqualStrings("eval-line", env.ctx.actions.resolve("eval", .{ .mode = "normal", .lang = "md" }).?);
}

test "quickjs: semanticAction binds and invokes an open plugin view action" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    try evalConfig(&engine, &env.ctx, null, null, null, "weft.semanticAction('fixture.plugin-action'); weft.bind('normal', 'm', 'fixture.plugin-action');");
    try t.expect(env.commands.resolve("fixture.plugin-action") != null);
    try env.head.setModeRaw(gpa, "normal");
    try t.expectEqualStrings("fixture.plugin-action", env.keymap.lookup("normal", "m").?);

    const ActionProvider = struct {
        calls: usize = 0,

        pub fn invoke(self: *@This(), request: semantic_model.action.Request) view_runtime.action.ProviderError!semantic_model.action.Outcome {
            if (!std.mem.eql(u8, request.action, "fixture.plugin-action")) return .declined;
            self.calls += 1;
            return .handled;
        }
    };
    const owner = try env.semantic.acquireOwner();
    const actions = [_]semantic_model.scene.Action{.{ .id = "fixture.plugin-action" }};
    const view = try env.semantic.publishView(gpa, owner, null, 1, .{
        .id = @enumFromInt(1),
        .focusable = true,
        .actions = &actions,
        .content = .{ .label = "fixture" },
    });
    var provider: ActionProvider = .{};
    try env.semantic.registerActionProvider(gpa, owner, .init(&provider));
    _ = try env.semantic.focusView(&env.head, gpa, view, null);

    _ = try command.run(&env.commands, &env.ctx, "fixture.plugin-action", &.{});
    try t.expectEqual(@as(usize, 1), provider.calls);
}

test "quickjs: a JS plugin registers a command dispatched back into JS" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    // The plugin plane: a PERSISTENT quickjs instance that registers a command
    // and receives its dispatch back — the JS-plugin reactor, proving the
    // describe/init/on_command lifecycle works one layer up under the engine.
    const src =
        \\weft.command("greet", () => weft.echo("hi from js"));
    ;
    var plugin = try JsPlugin.load(gpa, &engine, &env.ctx, env.pool, .empty, "test", null, src);
    defer plugin.deinit();

    try t.expect(env.commands.resolve("greet") != null);
    _ = try command.run(&env.commands, &env.ctx, "greet", &.{});
    try t.expectEqualStrings("hi from js", env.head.echo.items);
}

test "quickjs: weft.pick delivers structured acceptance and cancellation" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    try pick_mod.install(gpa, &env.commands, &env.keymap);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    // Empty options are intentional: the accepted index must remain the
    // caller's original line ordinal (beta is index 2, not normalized index 1).
    const src =
        \\weft.onPick((o) => {
        \\  if (o.kind === "candidate")
        \\    weft.echo(o.kind + "|" + o.index + "|" + o.text + "|" + o.query + "|" + o.match.start + "|" + o.match.span);
        \\  else weft.echo(o.kind);
        \\});
        \\weft.command("open-pick", () => weft.pick("choose", "alpha\n\nbeta"));
    ;
    var plugin = try JsPlugin.load(gpa, &engine, &env.ctx, env.pool, .empty, "test", null, src);
    defer plugin.deinit();

    _ = try command.run(&env.commands, &env.ctx, "open-pick", &.{});
    try t.expect(env.head.pick.active);
    _ = try command.run(&env.commands, &env.ctx, "pick-input", &.{.{ .string = "beta" }});
    _ = try command.run(&env.commands, &env.ctx, "pick-accept", &.{});
    try t.expectEqualStrings("candidate|2|beta|beta|0|4", env.head.echo.items);

    // The live query is not bounded by the original option payload. Preserve
    // it exactly without sizing guest memory from that unrelated input.
    const long_query = "                    beta";
    _ = try command.run(&env.commands, &env.ctx, "open-pick", &.{});
    _ = try command.run(&env.commands, &env.ctx, "pick-input", &.{.{ .string = long_query }});
    _ = try command.run(&env.commands, &env.ctx, "pick-accept", &.{});
    try t.expectEqualStrings("candidate|2|beta|                    beta|0|4", env.head.echo.items);

    _ = try command.run(&env.commands, &env.ctx, "open-pick", &.{});
    try t.expect(env.head.pick.active);
    _ = try command.run(&env.commands, &env.ctx, "pick-cancel", &.{});
    try t.expectEqualStrings("cancelled", env.head.echo.items);
}

test "quickjs: a JS plugin drives a duplex subprocess and reads its output" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    // The plugin spawns a child (sh builtins, hermetic .empty env), sends it a
    // line, and its onOutput handler reads the echoed reply — the whole
    // agent-transport shape (spawn + stdin + streamed stdout) in JS.
    // `weft.onOutput` is BACKGROUND (`weft_on_output`, fired by `tick`);
    // `weft.echo` is head-gated (task #19 item 4), so the reply defers
    // through a self-registered command — a nested `weft.run` from a
    // background entry IS a dispatching entry for its duration (same door
    // `config/plugins/acp.js`'s real onOutput→weft.pick path uses).
    const src =
        \\let reply = "";
        \\weft.onOutput((h) => { reply = weft.procRead(h); weft.run("deliver"); });
        \\weft.command("deliver", () => { weft.echo("got:" + reply); });
        \\weft.command("go", () => {
        \\  let h = weft.procSpawn("read x; printf '%s\n' \"$x\"");
        \\  weft.procSend(h, "ping\n");
        \\});
    ;
    try env.grant("test", "proc");
    var plugin = try JsPlugin.load(gpa, &engine, &env.ctx, env.pool, .empty, "test", null, src);
    defer plugin.deinit();

    _ = try command.run(&env.commands, &env.ctx, "go", &.{});
    // Pump the frame-boundary output dispatch until the reply arrives.
    const deadline = task.nowNs() + 2 * std.time.ns_per_s;
    while (std.mem.indexOf(u8, env.head.echo.items, "ping") == null and task.nowNs() < deadline) {
        _ = plugin.tick();
        std.Thread.yield() catch {};
    }
    try t.expect(std.mem.indexOf(u8, env.head.echo.items, "ping") != null);
}

// SCOPE NOTE (added alongside the incremental-append/decoration-path
// rework below, so a future reader doesn't have to reconstruct this from
// git blame): this test predates `weft.transcriptEntry`/`transcriptAppend`
// and was written against the OLD raw `weft.bufferAppend` path — it never
// names the transcript seam and never asserts role tagging or model state,
// only a plain substring in the rendered buffer. It still exercises the
// REAL `config/plugins/acp.js` end to end (a real mock-agent subprocess,
// the real JSON-RPC parse, the real `weft.transcriptEntry` call
// `acp.js`'s `trAppend` now makes), so it is NOT vacuous — but it is
// coincidental coverage of the new seam, not a test written FOR it. The
// test below is: a direct handler-level test, driving `weft.
// transcriptEntry`/`transcriptAppend` through the real JS runtime, that
// asserts what this one does not (role tagging, streamed-body accumulation,
// the model AND the projected buffer, and that the FAST incremental path —
// not a full-`fill` fallback — is what actually ran).
test "quickjs: the ACP plugin drives a mock agent's message into the transcript" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    // A fire-and-forget mock ACP agent (sh builtins only — printf): emits the
    // initialize + session/new results, a session/update carrying an agent
    // message, and the prompt result. This is the client-side round-trip the
    // plugin parses: JSON-RPC in, agent_message_chunk → transcript.
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const mock_path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/mock.sh", .{tmp.sub_path});
    defer gpa.free(mock_path);
    const mock =
        \\printf '{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1,"agentCapabilities":{}}}\n'
        \\printf '{"jsonrpc":"2.0","id":1,"result":{"sessionId":"s1"}}\n'
        \\printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hello from agent"}}}}\n'
        \\printf '{"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}\n'
    ;
    try @import("file.zig").writeBytes(gpa, mock_path, mock);

    // The real ACP client plugin (read from the repo) + a start line pointing
    // at the mock. `/bin/sh <path>` needs no PATH (hermetic .empty env).
    const acp = try @import("file.zig").readAlloc(gpa, "config/plugins/acp.js");
    defer gpa.free(acp);
    const src = try std.fmt.allocPrint(gpa, "{s}\nstartAgent(\"/bin/sh {s}\", \"hi\");\n", .{ acp, mock_path });
    defer gpa.free(src);

    try env.grant("test", "proc"); // what config/config.js's weft.grant("acp", "proc") mints
    var plugin = try JsPlugin.load(gpa, &engine, &env.ctx, env.pool, .empty, "test", null, src);
    defer plugin.deinit();

    // Pump the frame-boundary output dispatch until the agent's message lands
    // in the transcript buffer.
    const deadline = task.nowNs() + 3 * std.time.ns_per_s;
    var found = false;
    while (!found and task.nowNs() < deadline) {
        _ = plugin.tick();
        var it = env.buffers.iterator();
        while (it.next()) |b| {
            if (!std.mem.eql(u8, b.name, "*agent*")) continue;
            const txt = try b.textEditor().?.text().toOwnedSlice(gpa);
            defer gpa.free(txt);
            if (std.mem.indexOf(u8, txt, "hello from agent") != null) found = true;
        }
        std.Thread.yield() catch {};
    }
    try t.expect(found);
}

test "quickjs: transcriptEntry/transcriptAppend — role tagging, streamed-body accumulation, model+buffer agreement, and the INCREMENTAL (not full-refill) fast path" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    // Four commands, one per step, so the Zig side can peek host state
    // BETWEEN individual `weft.transcriptEntry`/`transcriptAppend` calls —
    // a single top-level `weft_plugin_init` eval (like the mock-agent test
    // above uses) runs its whole body in one uninterruptible JS_Eval, which
    // can't be inspected mid-script.
    const src =
        \\weft.command("open", () => weft.transcriptEntry("*t*", "user", "hi"));
        \\weft.command("chunk", () => weft.transcriptAppend("*t*", "!"));
        \\weft.command("open2", () => weft.transcriptEntry("*t*", "agent", "yo"));
    ;
    var plugin = try JsPlugin.load(gpa, &engine, &env.ctx, env.pool, .empty, "test", null, src);
    defer plugin.deinit();

    const bufText = struct {
        fn get(e: *Env, gpa2: Allocator) ![]u8 {
            var it = e.buffers.iterator();
            while (it.next()) |b| {
                if (std.mem.eql(u8, b.name, "*t*")) return b.textEditor().?.text().toOwnedSlice(gpa2);
            }
            return error.NoBuffer;
        }
    }.get;

    // "open": the model gets its first (role, text) entry; the FULL `fill`
    // path runs (a structural change — new row), which mints entry 0's
    // subbuffer claim — cached as `live_sub`.
    _ = try command.run(&env.commands, &env.ctx, "open", &.{});
    try t.expectEqual(@as(usize, 1), plugin.conversation("*t*").?.transcript.count());
    try t.expectEqualStrings("user", plugin.conversation("*t*").?.transcript.at(0).role());
    {
        const b0 = try plugin.conversation("*t*").?.transcript.at(0).text(gpa);
        defer gpa.free(b0);
        try t.expectEqualStrings("hi", b0);
    }
    {
        const got = try bufText(&env, gpa);
        defer gpa.free(got);
        try t.expectEqualStrings("user: hi", got);
    }
    try t.expectEqual(@as(usize, 1), plugin.conversation("*t*").?.subs.list.items.len);
    const sub_a = plugin.conversation("*t*").?.live_sub.?;

    // "chunk" ×2: streamed onto the SAME row. The claim object's IDENTITY
    // (not just its resolved range) stays the SAME pointer across both —
    // the precise signature of the INCREMENTAL path (`SubBuffer.extendEnd`
    // mutates the existing claim in place); a full-`fill` fallback would
    // `dropDoc` + re-`claim`, minting a BRAND NEW object each time, which
    // this asserts did NOT happen.
    _ = try command.run(&env.commands, &env.ctx, "chunk", &.{});
    const sub_b = plugin.conversation("*t*").?.live_sub.?;
    try t.expectEqual(@as(usize, 1), plugin.conversation("*t*").?.subs.list.items.len); // no new/leaked claim
    try t.expect(sub_a == sub_b);

    _ = try command.run(&env.commands, &env.ctx, "chunk", &.{});
    const sub_c = plugin.conversation("*t*").?.live_sub.?;
    try t.expectEqual(@as(usize, 1), plugin.conversation("*t*").?.subs.list.items.len);
    try t.expect(sub_b == sub_c);

    // The MODEL accumulated both chunks (replication's source of truth)...
    {
        const b0 = try plugin.conversation("*t*").?.transcript.at(0).text(gpa);
        defer gpa.free(b0);
        try t.expectEqualStrings("hi!!", b0);
    }
    // ...and the PROJECTED BUFFER agrees, byte for byte, with what a full
    // `fill` of this same model would have produced — the incremental path
    // is a performance shortcut, never a divergent rendering.
    {
        const got = try bufText(&env, gpa);
        defer gpa.free(got);
        try t.expectEqualStrings("user: hi!!", got);

        const DocumentMod = @import("Document.zig");
        var doc_check = try DocumentMod.init(gpa, "check");
        defer doc_check.deinit(gpa);
        var subs_check: subbuffer.SubBuffers = .empty;
        defer subs_check.deinit(gpa);
        try TranscriptDoc.fill(gpa, &plugin.conversation("*t*").?.transcript, &doc_check, &subs_check);
        const full = try doc_check.text().toOwnedSlice(gpa);
        defer gpa.free(full);
        try t.expectEqualStrings(full, got);
    }

    // "open2": a NEW row — role tagging carries through per entry, not just
    // per plugin — and its claim is a genuinely DIFFERENT object (the full
    // `fill` this triggers re-mints every row's claim, entry 0's included).
    _ = try command.run(&env.commands, &env.ctx, "open2", &.{});
    try t.expectEqual(@as(usize, 2), plugin.conversation("*t*").?.transcript.count());
    try t.expectEqualStrings("agent", plugin.conversation("*t*").?.transcript.at(1).role());
    const sub_d = plugin.conversation("*t*").?.live_sub.?;
    try t.expect(sub_d != sub_c);
    try t.expectEqual(@as(usize, 2), plugin.conversation("*t*").?.subs.list.items.len);
    {
        const got = try bufText(&env, gpa);
        defer gpa.free(got);
        try t.expectEqualStrings("user: hi!!\nagent: yo", got);
    }
}

test "quickjs: a JS plugin reads a file through weft.fileRead" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const fpath = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/read.txt", .{tmp.sub_path});
    defer gpa.free(fpath);
    try @import("file.zig").writeBytes(gpa, fpath, "file contents here");

    // fs/read is answered from disk (no open buffer here) — the harness reading
    // a file for the agent.
    const src = try std.fmt.allocPrint(gpa, "weft.command(\"r\", () => weft.echo(weft.fileRead(\"{s}\")));", .{fpath});
    defer gpa.free(src);
    try env.grant("test", "fs_read");
    var plugin = try JsPlugin.load(gpa, &engine, &env.ctx, env.pool, .empty, "test", null, src);
    defer plugin.deinit();

    _ = try command.run(&env.commands, &env.ctx, "r", &.{});
    try t.expectEqualStrings("file contents here", env.head.echo.items);
}

// ── The JS plane's grant gate (`guest/deny.zig`'s twin, one layer up under
// the JS engine): a resident `.js` plugin declares nothing about itself, so a
// config `weft.grant` is the ONLY thing that can give it an effect. The
// fixture is the plugin source itself — each command wraps its effect in
// try/catch and echoes which arm ran, so the test can tell a THROWN denial
// apart from a value the plugin could have silently ignored. ──

/// A plugin that reports, through the echo line, whether its effect ran or
/// was denied. `weft.echo` is head-gated, so both arms defer nothing — they
/// run inside the dispatching command that called them.
const grant_gate_js =
    \\weft.command("spawn", () => {
    \\  try { weft.procSpawn("true"); weft.echo("spawned"); }
    \\  catch (e) { weft.echo("threw: " + e.message); }
    \\});
    \\weft.command("read", () => {
    \\  try { weft.echo("read:" + weft.fileRead("/etc/hostname")); }
    \\  catch (e) { weft.echo("threw: " + e.message); }
    \\});
;

test "quickjs: a JS plugin with NO declared grants gets NO effect capability — the call throws" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    // Nothing granted: fail closed on every effect door, and loudly.
    var plugin = try JsPlugin.load(gpa, &engine, &env.ctx, env.pool, .empty, "ungranted", null, grant_gate_js);
    defer plugin.deinit();

    _ = try command.run(&env.commands, &env.ctx, "spawn", &.{});
    try t.expect(std.mem.startsWith(u8, env.head.echo.items, "threw: "));
    try t.expect(std.mem.indexOf(u8, env.head.echo.items, "permission denied") != null);
    // Denial is not a spawn that merely failed — no child was ever started.
    try t.expectEqual(@as(usize, 0), plugin.streams.items.len);

    _ = try command.run(&env.commands, &env.ctx, "read", &.{});
    try t.expect(std.mem.startsWith(u8, env.head.echo.items, "threw: "));
}

test "quickjs: a granted JS plugin spawns — and revoking `proc` stops it on the very next call" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    try env.grant("gated", "proc");
    var plugin = try JsPlugin.load(gpa, &engine, &env.ctx, env.pool, .empty, "gated", null, grant_gate_js);
    defer plugin.deinit();

    _ = try command.run(&env.commands, &env.ctx, "spawn", &.{});
    try t.expectEqualStrings("spawned", env.head.echo.items);
    // `fs_read` was never granted — one capability is not the others.
    _ = try command.run(&env.commands, &env.ctx, "read", &.{});
    try t.expect(std.mem.startsWith(u8, env.head.echo.items, "threw: "));

    // Possession, not a cached boolean: the plugin re-checks the SAME row.
    try t.expectEqual(@as(usize, 1), env.grants.revoke("gated", "proc"));
    _ = try command.run(&env.commands, &env.ctx, "spawn", &.{});
    try t.expect(std.mem.startsWith(u8, env.head.echo.items, "threw: "));
}

test "quickjs: an fs_read grant narrowed to a root confines a JS plugin (guest/fs_limit.zig's twin)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const file = @import("file.zig");
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/root", .{tmp.sub_path});
    defer gpa.free(root);
    const inside = try std.fmt.allocPrint(gpa, "{s}/ok.txt", .{root});
    defer gpa.free(inside);
    const outside = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/secret.txt", .{tmp.sub_path});
    defer gpa.free(outside);
    const traversal = try std.fmt.allocPrint(gpa, "{s}/../secret.txt", .{root});
    defer gpa.free(traversal);
    try file.writeBytesMakingDirs(gpa, root, inside, "in root");
    try file.writeBytes(gpa, outside, "out of root");

    const src = try std.fmt.allocPrint(gpa,
        \\function reader(name, path) {{
        \\  weft.command(name, () => {{
        \\    try {{ weft.echo("read:" + weft.fileRead(path)); }}
        \\    catch (e) {{ weft.echo("threw"); }}
        \\  }});
        \\}}
        \\reader("in", "{s}");
        \\reader("out", "{s}");
        \\reader("up", "{s}");
    , .{ inside, outside, traversal });
    defer gpa.free(src);

    _ = try env.grants.grant(.{ .capability = "fs_read", .limit = .{ .fs_root = root } }, "confined", null);
    var plugin = try JsPlugin.load(gpa, &engine, &env.ctx, env.pool, .empty, "confined", null, src);
    defer plugin.deinit();

    _ = try command.run(&env.commands, &env.ctx, "in", &.{});
    try t.expectEqualStrings("read:in root", env.head.echo.items);
    // Possessed, but out of the granted root — a denial, not an empty read.
    _ = try command.run(&env.commands, &env.ctx, "out", &.{});
    try t.expectEqualStrings("threw", env.head.echo.items);
    _ = try command.run(&env.commands, &env.ctx, "up", &.{});
    try t.expectEqualStrings("threw", env.head.echo.items);
}

// ── doc/place.md §4.1a: a JS plugin is not a different KIND of plugin ─────
// The wasm-plane gate for this lives in `wasm_abi/tests.zig`. Its twin here
// is the point: both planes go through `wasm_host/fs.zig`'s ONE gate, so the
// carve-out cannot hold on one surface and not the other — which is exactly
// how `cAgentWrite` came to have no perm check at all while `wl_fs_write`
// had two.

test "quickjs: no grant, however broad, reaches the editor's own machinery (guest gate's JS twin)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    const machinery = @import("machinery.zig");
    const cache = wasm.Engine.cacheDir(gpa).?;
    defer gpa.free(cache);
    const cached = try std.fmt.allocPrint(gpa, "{s}/deadbeef.cwasm", .{cache});
    defer gpa.free(cached);
    const kv_dir = @import("kv_file.zig").stateDir(gpa).?;
    defer gpa.free(kv_dir);
    const kv_blob = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ kv_dir, @import("kv_file.zig").store_file });
    defer gpa.free(kv_blob);
    var ibuf: [512]u8 = undefined;
    const id_path = @import("identity.zig").configPath(&ibuf, machinery.Posix{});
    var kbuf: [512]u8 = undefined;
    const peers_path = @import("known_peers.zig").configPath(&kbuf, machinery.Posix{});

    // Ordinary content the unconfined grant DOES reach, so the refusals below
    // are about the carve-out and not about a broken door.
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(dir);
    const content = try std.fmt.allocPrint(gpa, "{s}/user-content.txt", .{dir});
    defer gpa.free(content);
    try @import("file.zig").writeBytesMakingDirs(gpa, dir, content, "ordinary");

    const src = try std.fmt.allocPrint(gpa,
        \\function reader(name, path) {{
        \\  weft.command(name, () => {{
        \\    try {{ weft.echo("read:" + weft.fileRead(path)); }}
        \\    catch (e) {{ weft.echo("threw"); }}
        \\  }});
        \\}}
        \\reader("content", "{s}");
        \\reader("cache", "{s}");
        \\reader("kv", "{s}");
        \\reader("identity", "{s}");
        \\reader("peers", "{s}");
    , .{ content, cached, kv_blob, id_path orelse content, peers_path orelse content });
    defer gpa.free(src);

    // The BROADEST grant the config plane can spell: no root, no scope.
    try env.grant("broad", "fs_read");
    var plugin = try JsPlugin.load(gpa, &engine, &env.ctx, env.pool, .empty, "broad", null, src);
    defer plugin.deinit();

    _ = try command.run(&env.commands, &env.ctx, "content", &.{});
    try t.expectEqualStrings("read:ordinary", env.head.echo.items);

    _ = try command.run(&env.commands, &env.ctx, "cache", &.{});
    try t.expectEqualStrings("threw", env.head.echo.items);
    _ = try command.run(&env.commands, &env.ctx, "kv", &.{});
    try t.expectEqualStrings("threw", env.head.echo.items);
    if (id_path != null) {
        _ = try command.run(&env.commands, &env.ctx, "identity", &.{});
        try t.expectEqualStrings("threw", env.head.echo.items);
    }
    if (peers_path != null) {
        _ = try command.run(&env.commands, &env.ctx, "peers", &.{});
        try t.expectEqualStrings("threw", env.head.echo.items);
    }
}

test "quickjs: an OPEN buffer doesn't launder the machinery carve-out either" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    // `cFileRead`'s LIVE-BUFFER half — the branch with no descriptor to root
    // against, and the one that used to be gated only by the limit. Opening
    // a machinery file (which the HOST may legitimately do) must not make it
    // readable by a plugin holding an unconfined grant.
    const cache = wasm.Engine.cacheDir(gpa).?;
    defer gpa.free(cache);
    const cached = try std.fmt.allocPrint(gpa, "{s}/opened.cwasm", .{cache});
    defer gpa.free(cached);
    try @import("file.zig").writeBytesMakingDirs(gpa, cache, cached, "compiled image bytes");
    defer @import("file.zig").deleteFile(gpa, cached);

    const bid = try env.buffers.create(gpa, "opened.cwasm");
    try env.buffers.get(bid).?.textEditor().?.openFile(gpa, cached);

    const src = try std.fmt.allocPrint(gpa,
        \\weft.command("go", () => {{
        \\  try {{ weft.echo("read:" + weft.fileRead("{s}")); }}
        \\  catch (e) {{ weft.echo("threw"); }}
        \\}});
    , .{cached});
    defer gpa.free(src);

    try env.grant("broad", "fs_read");
    var plugin = try JsPlugin.load(gpa, &engine, &env.ctx, env.pool, .empty, "broad", null, src);
    defer plugin.deinit();

    _ = try command.run(&env.commands, &env.ctx, "go", &.{});
    try t.expectEqualStrings("threw", env.head.echo.items);
}

test "quickjs: an agent's fileWrite cannot bind a buffer onto the editor's machinery" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    // `cAgentWrite` never touches the filesystem — it binds a buffer the USER
    // later saves. That is still a write to machinery, one save away, so the
    // same carve-out has to hold here: refused, and NO buffer bound.
    const kv_dir = @import("kv_file.zig").stateDir(gpa).?;
    defer gpa.free(kv_dir);
    const blob = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ kv_dir, @import("kv_file.zig").store_file });
    defer gpa.free(blob);

    const src = try std.fmt.allocPrint(gpa,
        \\weft.command("w", () => {{
        \\  try {{ weft.fileWrite("{s}", "clobbered", "a1"); weft.echo("wrote"); }}
        \\  catch (e) {{ weft.echo("threw"); }}
        \\}});
    , .{blob});
    defer gpa.free(src);

    try env.grant("broad", "fs_write");
    var plugin = try JsPlugin.load(gpa, &engine, &env.ctx, env.pool, .empty, "broad", null, src);
    defer plugin.deinit();

    _ = try command.run(&env.commands, &env.ctx, "w", &.{});
    try t.expectEqualStrings("threw", env.head.echo.items);
    try t.expect(env.buffers.findByPath(blob) == null);
}

test "quickjs: an OPEN buffer doesn't launder a narrowed fs_read grant" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    // The live-buffer branch of `cFileRead` — the one with no descriptor to
    // root against. Opening a file must not make it readable past the limit.
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(dir);
    const outside = try std.fmt.allocPrint(gpa, "{s}/secret.txt", .{dir});
    defer gpa.free(outside);
    try @import("file.zig").writeBytesMakingDirs(gpa, dir, outside, "top secret");

    const id = try env.buffers.create(gpa, "secret.txt");
    try env.buffers.get(id).?.textEditor().?.openFile(gpa, outside);

    const src = try std.fmt.allocPrint(gpa,
        \\weft.command("go", () => {{
        \\  try {{ weft.echo("read:" + weft.fileRead("{s}")); }}
        \\  catch (e) {{ weft.echo("threw"); }}
        \\}});
    , .{outside});
    defer gpa.free(src);

    const root = try std.fmt.allocPrint(gpa, "{s}/notes", .{dir});
    defer gpa.free(root);
    _ = try env.grants.grant(.{ .capability = "fs_read", .limit = .{ .fs_root = root } }, "confined", null);
    var plugin = try JsPlugin.load(gpa, &engine, &env.ctx, env.pool, .empty, "confined", null, src);
    defer plugin.deinit();

    _ = try command.run(&env.commands, &env.ctx, "go", &.{});
    try t.expectEqualStrings("threw", env.head.echo.items);
}

test "quickjs: a JS plugin writes a file as an attributed agent peer edit" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    // fs/write to a path that isn't open → weft binds a buffer to it and applies
    // the content as the agent peer (gated + attributed), not a raw disk write.
    const src =
        \\weft.command("w", () => weft.fileWrite("/tmp/weft-agent-out.zig", "const x = 1;"));
    ;
    // `fs_write`, declared: this door is possession-gated like every other
    // effect door (it was not always — see the confinement test below), so
    // the fixture has to hold the capability it exercises.
    try env.grant("test", "fs_write");
    var plugin = try JsPlugin.load(gpa, &engine, &env.ctx, env.pool, .empty, "test", null, src);
    defer plugin.deinit();
    _ = try command.run(&env.commands, &env.ctx, "w", &.{});

    const id = env.buffers.findByPath("/tmp/weft-agent-out.zig") orelse return error.NoAgentBuffer;
    const b = env.buffers.get(id).?;
    const txt = try b.textEditor().?.text().toOwnedSlice(gpa);
    defer gpa.free(txt);
    try t.expectEqualStrings("const x = 1;", txt);
    // Authored by a non-user peer — the agent, not the user's undo history.
    const doc = &b.textEditor().?.doc;
    try t.expect(doc.commitAt(doc.commitCount() - 1).author != .user);
}

test "quickjs: an agent's fileWrite outside a narrowed fs_write root is refused — and binds no buffer" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    // `cFileRead`'s confinement, on the WRITE door. `command.renderInto`'s
    // grade gate is not this check: it caps `.agent` at `gradeMin(doc.my_grant,
    // .edit)`, and `Document.my_grant` defaults to `.own`, so it passes for
    // every local buffer. Only `fs_write`'s own limit says where an agent may
    // write.
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(dir);
    const root = try std.fmt.allocPrint(gpa, "{s}/allowed", .{dir});
    defer gpa.free(root);
    const inside = try std.fmt.allocPrint(gpa, "{s}/note.txt", .{root});
    defer gpa.free(inside);
    const outside = try std.fmt.allocPrint(gpa, "{s}/secret.txt", .{dir});
    defer gpa.free(outside);
    try @import("file.zig").writeBytesMakingDirs(gpa, root, inside, "");

    const src = try std.fmt.allocPrint(gpa,
        \\function writer(name, path) {{
        \\  weft.command(name, () => {{
        \\    try {{ weft.fileWrite(path, "written", "a1"); weft.echo("wrote"); }}
        \\    catch (e) {{ weft.echo("threw"); }}
        \\  }});
        \\}}
        \\writer("in", "{s}");
        \\writer("out", "{s}");
        \\writer("abs", "/tmp/weft-agent-escape.zig");
    , .{ inside, outside });
    defer gpa.free(src);

    _ = try env.grants.grant(.{ .capability = "fs_write", .limit = .{ .fs_root = root } }, "confined", null);
    var plugin = try JsPlugin.load(gpa, &engine, &env.ctx, env.pool, .empty, "confined", null, src);
    defer plugin.deinit();

    // In root: the agent edit lands, exactly as before the gate.
    _ = try command.run(&env.commands, &env.ctx, "in", &.{});
    try t.expectEqualStrings("wrote", env.head.echo.items);
    try t.expect(env.buffers.findByPath(inside) != null);

    // Out of root, and an absolute path with nothing to do with the grant:
    // both REFUSED — a thrown denial, never a write the agent thinks landed.
    _ = try command.run(&env.commands, &env.ctx, "out", &.{});
    try t.expectEqualStrings("threw", env.head.echo.items);
    _ = try command.run(&env.commands, &env.ctx, "abs", &.{});
    try t.expectEqualStrings("threw", env.head.echo.items);

    // And refusal means NO buffer was bound to either path — the door's own
    // side effect (create + adoptPath) must not run ahead of its gate.
    try t.expect(env.buffers.findByPath(outside) == null);
    try t.expect(env.buffers.findByPath("/tmp/weft-agent-escape.zig") == null);
}

test "quickjs: an ungranted JS plugin cannot fileWrite at all — possession, not just its limit" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    const src =
        \\weft.command("w", () => {
        \\  try { weft.fileWrite("/tmp/weft-agent-ungranted.zig", "x"); weft.echo("wrote"); }
        \\  catch (e) { weft.echo("threw"); }
        \\});
    ;
    var plugin = try JsPlugin.load(gpa, &engine, &env.ctx, env.pool, .empty, "ungranted", null, src);
    defer plugin.deinit();

    _ = try command.run(&env.commands, &env.ctx, "w", &.{});
    try t.expectEqualStrings("threw", env.head.echo.items);
    try t.expect(env.buffers.findByPath("/tmp/weft-agent-ungranted.zig") == null);
}

test "quickjs: a refused agent write is ANSWERED, not swallowed — the rest of the batch still streams" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    // Gating `weft.fileWrite` made refusal REACHABLE from the shipped ACP
    // reactor, which parses a whole `procRead` batch in one loop: a throw
    // escaping `onMessage` would drop every line after it, and those lines
    // are already out of the plugin's inbox — gone for good. So a narrowed
    // `fs_write` grant could silently swallow whatever the agent said next,
    // up to and including a permission request. The refusal has to be an
    // ANSWER to that one request and nothing more.
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(dir);
    const root = try std.fmt.allocPrint(gpa, "{s}/allowed", .{dir});
    defer gpa.free(root);
    const keep = try std.fmt.allocPrint(gpa, "{s}/keep.txt", .{root});
    defer gpa.free(keep);
    try @import("file.zig").writeBytesMakingDirs(gpa, root, keep, "");
    const outside = try std.fmt.allocPrint(gpa, "{s}/secret.txt", .{dir});
    defer gpa.free(outside);

    // One batch: handshake, a write the grant cannot reach, then a message.
    const mock_path = try std.fmt.allocPrint(gpa, "{s}/mock.sh", .{dir});
    defer gpa.free(mock_path);
    const mock = try std.fmt.allocPrint(gpa,
        \\printf '{{"jsonrpc":"2.0","id":0,"result":{{"protocolVersion":1}}}}\n'
        \\printf '{{"jsonrpc":"2.0","id":1,"result":{{"sessionId":"s1"}}}}\n'
        \\printf '{{"jsonrpc":"2.0","id":8,"method":"fs/write_text_file","params":{{"path":"{s}","content":"escaped"}}}}\n'
        \\printf '{{"jsonrpc":"2.0","method":"session/update","params":{{"update":{{"sessionUpdate":"agent_message_chunk","content":{{"type":"text","text":"after the refusal"}}}}}}}}\n'
    , .{outside});
    defer gpa.free(mock);
    try @import("file.zig").writeBytes(gpa, mock_path, mock);

    const acp = try @import("file.zig").readAlloc(gpa, "config/plugins/acp.js");
    defer gpa.free(acp);
    const src = try std.fmt.allocPrint(gpa, "{s}\nstartAgent(\"/bin/sh {s}\", \"hi\");\n", .{ acp, mock_path });
    defer gpa.free(src);

    try env.grant("test", "proc");
    _ = try env.grants.grant(.{ .capability = "fs_write", .limit = .{ .fs_root = root } }, "test", null);
    var plugin = try JsPlugin.load(gpa, &engine, &env.ctx, env.pool, .empty, "test", null, src);
    defer plugin.deinit();

    const deadline = task.nowNs() + 3 * std.time.ns_per_s;
    var streamed = false;
    while (!streamed and task.nowNs() < deadline) {
        _ = plugin.tick();
        var it = env.buffers.iterator();
        while (it.next()) |b| {
            if (!std.mem.eql(u8, b.name, "*agent*")) continue;
            const txt = try b.textEditor().?.text().toOwnedSlice(gpa);
            defer gpa.free(txt);
            if (std.mem.indexOf(u8, txt, "after the refusal") != null) streamed = true;
        }
        std.Thread.yield() catch {};
    }
    // The message AFTER the refused write arrived: one denial, one dropped
    // request, and the stream carried on.
    try t.expect(streamed);
    // ...and the write really was refused — no buffer bound out of root.
    try t.expect(env.buffers.findByPath(outside) == null);
}

test "quickjs: a config syntax error surfaces as ConfigException, not silent" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    // Malformed JS: the eval must fail loudly, and nothing was bound.
    try t.expectError(error.ConfigException, evalConfig(&engine, &env.ctx, null, null, null, "this is (not valid javascript"));
    try t.expectEqual(@as(usize, 0), env.head.echo.items.len);
}

test "quickjs: weft.plugin loads a real .wasm, then its command runs" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    // A minimal loader over the resident engine: resolve the guest "edit"
    // plugin from its embedded bytes and load it under the perm handshake —
    // the same shape main.zig's PluginHost has, minus disk/name resolution.
    const wasm_abi = @import("wasm_abi.zig");
    const Loader = struct {
        engine: *wasm.Engine,
        ctx: *command.Context,
        held: ?*wasm_abi.WasmPlugin = null,
        fn load(cx: *anyopaque, name: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(cx));
            std.debug.assert(std.mem.eql(u8, name, "edit"));
            self.held = wasm_abi.loadPlugin(self.engine, self.ctx, "edit", @embedFile("guest_edit_wasm"), .{}) catch null;
        }
    };
    var loader: Loader = .{ .engine = &engine, .ctx = &env.ctx };
    defer if (loader.held) |p| p.deinit();

    // config.js loads the plugin and binds one of its commands. Load is now
    // deferred to after eval, but still completes inside evalConfig, so by the
    // time it returns the plugin is registered and the (late-bound) bind resolves.
    const cfg =
        \\weft.plugin("edit");
        \\weft.bind("normal", "D", "duplicate-line");
    ;
    try evalConfig(&engine, &env.ctx, .{ .ctx = &loader, .load = Loader.load }, null, null, cfg);

    // The plugin loaded and registered its command; the config's bind took.
    try t.expect(loader.held != null);
    try t.expect(env.commands.find("duplicate-line") != null);
    try env.head.setModeRaw(gpa, "normal");
    try t.expectEqualStrings("duplicate-line", env.keymap.lookup(env.head.currentMode(), "D").?);

    // And the command actually runs through the membrane: duplicate a line.
    try env.buffers.active().textEditor().?.insertText(gpa, "hi");
    env.buffers.active().textEditor().?.placeCursor(0);
    _ = try command.run(&env.commands, &env.ctx, "duplicate-line", &.{});
    const s = try env.buffers.active().textEditor().?.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("hi\nhi", s);
}

test "quickjs: R1 regression — weft.set for a .js plugin's STEM identity is not dropped as unowned" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    var cfgstore: kv.Store = .empty;
    defer cfgstore.deinit(gpa);

    // The DOCUMENTED ACP setup (config.js's commented block): weft.set
    // BEFORE weft.plugin, a path-form name ("acp.js") whose config-store
    // identity is its STEM ("acp" — config_load.zig's loadJs registers a
    // JsPlugin under `stem(basename(name))`, and `weft.config(key)` keys on
    // that stem). Pre-M3 this worked unconditionally (no ownership check
    // existed); the value-ownership closed-namespace check must not
    // silently drop it.
    const cfg =
        \\weft.set("acp", "cmd", "codex-acp");
        \\weft.plugin("acp.js");
    ;
    try evalConfig(&engine, &env.ctx, null, &cfgstore, null, cfg);

    const blob = cfgstore.get("acp", "cmd") orelse return error.ValueWronglyDropped;
    const value = firstFramedRecord(blob) orelse return error.BadFrame;
    try t.expectEqualStrings("codex-acp", value);
}

test "quickjs: deferred load — weft.set before the plugin line reaches its init" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    var config: kv.Store = .empty;
    defer config.deinit(gpa);

    const wasm_abi = @import("wasm_abi.zig");
    const Loader = struct {
        engine: *wasm.Engine,
        ctx: *command.Context,
        config: *kv.Store,
        held: ?*wasm_abi.WasmPlugin = null,
        fn load(cx: *anyopaque, name: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(cx));
            std.debug.assert(std.mem.eql(u8, name, "autopair"));
            self.held = wasm_abi.loadPlugin(self.engine, self.ctx, "autopair", @embedFile("guest_autopair_wasm"), .{ .config = self.config }) catch null;
        }
    };
    var loader: Loader = .{ .engine = &engine, .ctx = &env.ctx, .config = &config };
    defer if (loader.held) |p| p.deinit();

    // weft.set and a bind are written BEFORE the plugin line. Deferred load
    // makes both land: config is staged before the plugin instantiates (its
    // init reads `pairs`), and the late-bound key resolves after load.
    const cfg =
        \\weft.set("autopair", "pairs", ["pair-tick\t`\t`"]);
        \\weft.bind("insert", "grave", "pair-tick");
        \\weft.plugin("autopair");
    ;
    try evalConfig(&engine, &env.ctx, .{ .ctx = &loader, .load = Loader.load }, &config, null, cfg);

    // The plugin read its config at init: it registered the CONFIG pair command,
    // not the shipped defaults.
    try t.expect(loader.held != null);
    try t.expect(env.commands.find("pair-tick") != null);
    try t.expect(env.commands.find("pair-paren") == null);
    try env.head.setModeRaw(gpa, "insert");
    try t.expectEqualStrings("pair-tick", env.keymap.lookup(env.head.currentMode(), "grave").?);

    // And it runs through the membrane: inserts the configured backtick pair.
    _ = try command.run(&env.commands, &env.ctx, "pair-tick", &.{});
    const s = try env.buffers.active().textEditor().?.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("``", s);
}

test "quickjs: weft.menu declares a submenu the leader tree enters (doom-style)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    const cfg =
        \\weft.menu("leader-file");
        \\weft.bind("leader", "f", "leader-file");
        \\weft.bind("leader-file", "s", "save");
    ;
    try evalConfig(&engine, &env.ctx, null, null, null, cfg);

    // The submenu is a menu mode: which-key shows it, and the dispatch enters it
    // when a leader key's command names it (that's why "f" → "leader-file" is a
    // group, not a leaf).
    try t.expect(env.keymap.isMenuMode("leader-file"));

    // In the leader menu, "f" resolves to the submenu name (a group entry).
    try env.head.setModeRaw(gpa, "leader");
    try t.expectEqualStrings("leader-file", env.keymap.lookup(env.head.currentMode(), "f").?);

    // Inside the submenu: its own keys bind, and Escape/C-g leave via menu-escape.
    try env.head.setModeRaw(gpa, "leader-file");
    try t.expectEqualStrings("save", env.keymap.lookup(env.head.currentMode(), "s").?);
    try t.expectEqualStrings("menu-escape", env.keymap.lookup(env.head.currentMode(), "Escape").?);
    try t.expectEqualStrings("menu-escape", env.keymap.lookup(env.head.currentMode(), "C-g").?);
}

test "quickjs: every shipped example config evals without a JS error" {
    const gpa = t.allocator;
    // Each config's JS must parse and drive the weft.* surface cleanly. Plugins
    // no-op here (no loader), so this checks syntax + the bind/menu/set calls —
    // a typo or a bad API use surfaces as ConfigException. Read from the repo's
    // config/ (the test runs with cwd at the project root).
    const file = @import("file.zig");
    const paths = [_][]const u8{
        "config/config.js", "config/config.northstar.js", "config/vim-minimal.js",
        "config/helix.js",  "config/dual.js",             "config/agent-ux.js",
    };
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    for (paths) |path| {
        const src = file.readAlloc(gpa, path) catch continue; // skip if run outside the repo
        defer gpa.free(src);
        var env: Env = undefined;
        try Env.init(gpa, &env);
        defer env.deinit(gpa);
        var cfgstore: kv.Store = .empty;
        defer cfgstore.deinit(gpa);
        evalConfig(&engine, &env.ctx, null, &cfgstore, null, src) catch |e| {
            std.debug.print("config {s} failed: {t}\n", .{ path, e });
            return e;
        };
    }
}

test "quickjs: sealed eval — two evals of the same config produce identical manifest hashes" {
    const gpa = t.allocator;
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    const cfg =
        \\weft.plugin("edit");
        \\weft.bind("normal", "j", "cursor-down");
        \\weft.action("eval");
        \\weft.provide("eval", { lang: "zig" }, "zig-eval");
        \\weft.set("theme", "accent", "#8ec07c");
        \\weft.echo("loaded");
    ;

    var env1: Env = undefined;
    try Env.init(gpa, &env1);
    defer env1.deinit(gpa);
    const m1 = try evalToManifest(&engine, &env1.ctx, null, null, null, cfg, .config, "config");
    defer m1.destroy();

    var env2: Env = undefined;
    try Env.init(gpa, &env2);
    defer env2.deinit(gpa);
    const m2 = try evalToManifest(&engine, &env2.ctx, null, null, null, cfg, .config, "config");
    defer m2.destroy();

    // Deterministic: staging the SAME source twice, in two entirely separate
    // JS runtimes, yields byte-identical manifests (§2.3's sealed-eval claim
    // — this is what "an eval using a sealed API is deterministic" tests
    // against; the `.config` surface has no clock/env/random of its own,
    // see qjs_contract's "no clock/env/random-shaped .config import" test).
    try t.expectEqual(m1.hash(), m2.hash());

    // And a manifest that DIFFERS (one extra decl) hashes differently — the
    // hash is sensitive to content, not a constant.
    const cfg2 = cfg ++ "\nweft.bind(\"normal\", \"k\", \"cursor-up\");\n";
    var env3: Env = undefined;
    try Env.init(gpa, &env3);
    defer env3.deinit(gpa);
    const m3 = try evalToManifest(&engine, &env3.ctx, null, null, null, cfg2, .config, "config");
    defer m3.destroy();
    try t.expect(m1.hash() != m3.hash());
}

test "quickjs: R2 — Date.now()/Math.random() are SEALED (fixed, deterministic across evals)" {
    const gpa = t.allocator;
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    // A config that FEEDS the two nondeterministic engine builtins into
    // weft.set — exactly the leak review R2 flagged (the .config `weft.*`
    // surface itself has none of these, but Date/Math.random are QuickJS
    // built-ins the qjs_contract audit can't see). `weft_eval`'s seal
    // prelude (src/quickjs/weft_qjs.c) overrides both before this source
    // ever runs; if it didn't, `Date.now()` (wall clock) or `Math.random()`
    // would differ between the two evals below and the hashes would too.
    const cfg =
        \\weft.set("theme", "accent", "clock:" + Date.now());
        \\weft.set("theme", "cursor", "rand:" + Math.random());
        \\weft.set("theme", "selection", "date:" + (new Date()).getTime());
    ;

    var env1: Env = undefined;
    try Env.init(gpa, &env1);
    defer env1.deinit(gpa);
    const m1 = try evalToManifest(&engine, &env1.ctx, null, null, null, cfg, .config, "config");
    defer m1.destroy();

    var env2: Env = undefined;
    try Env.init(gpa, &env2);
    defer env2.deinit(gpa);
    const m2 = try evalToManifest(&engine, &env2.ctx, null, null, null, cfg, .config, "config");
    defer m2.destroy();

    try t.expectEqual(m1.hash(), m2.hash());
    // Not just equal hashes by coincidence — the actual staged VALUES agree
    // (and are the fixed, sealed constants: Date.now()==0, a repeatable
    // Math.random() sequence, `new Date()` epoch 0). `.value` is the shim's
    // FRAMED blob (uvarint-prefixed), same encoding `weft.set` always
    // produces — decode with `firstFramedRecord`, as `weft.config` does.
    try t.expectEqualStrings("clock:0", firstFramedRecord(m1.values.items[0].value).?);
    try t.expectEqualStrings("clock:0", firstFramedRecord(m2.values.items[0].value).?);
    try t.expectEqualStrings(
        firstFramedRecord(m1.values.items[1].value).?,
        firstFramedRecord(m2.values.items[1].value).?,
    );
    try t.expectEqualStrings("date:0", firstFramedRecord(m1.values.items[2].value).?);
    try t.expectEqualStrings("date:0", firstFramedRecord(m2.values.items[2].value).?);
}

test "quickjs: weft.grant stages a GrantDecl onto the manifest, and the hash is sensitive to it (§6 W4 slice 4)" {
    const gpa = t.allocator;
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    const cfg =
        \\weft.grant("git", "fs_write", { root: "repo" });
        \\weft.grant("git", "proc");
    ;

    var env1: Env = undefined;
    try Env.init(gpa, &env1);
    defer env1.deinit(gpa);
    const m1 = try evalToManifest(&engine, &env1.ctx, null, null, null, cfg, .config, "config");
    defer m1.destroy();

    try t.expectEqual(@as(usize, 2), m1.grants.items.len);
    try t.expectEqualStrings("git", m1.grants.items[0].plugin);
    try t.expectEqualStrings("fs_write", m1.grants.items[0].capability);
    try t.expectEqualStrings("repo", m1.grants.items[0].root);
    try t.expectEqualStrings("git", m1.grants.items[1].plugin);
    try t.expectEqualStrings("proc", m1.grants.items[1].capability);
    try t.expectEqualStrings("", m1.grants.items[1].root); // no opts — unrestricted

    // Sealed eval, extended to grants: the SAME source, in a totally
    // separate JS runtime, hashes identically.
    var env2: Env = undefined;
    try Env.init(gpa, &env2);
    defer env2.deinit(gpa);
    const m2 = try evalToManifest(&engine, &env2.ctx, null, null, null, cfg, .config, "config");
    defer m2.destroy();
    try t.expectEqual(m1.hash(), m2.hash());

    // A CHANGED grant (a different root — the limit itself changed) changes
    // the hash: the determinism claim covers grants, not just binds/values.
    const cfg2 =
        \\weft.grant("git", "fs_write", { root: "other-repo" });
        \\weft.grant("git", "proc");
    ;
    var env3: Env = undefined;
    try Env.init(gpa, &env3);
    defer env3.deinit(gpa);
    const m3 = try evalToManifest(&engine, &env3.ctx, null, null, null, cfg2, .config, "config");
    defer m3.destroy();
    try t.expect(m1.hash() != m3.hash());
}

test "quickjs: weft.grant FAILS CLOSED — a non-string/undefined opts.root throws, eval fails loudly (review nit 1)" {
    const gpa = t.allocator;
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    // A mistyped narrowing — {root: 123} — must NEVER silently degrade to
    // unrestricted; the whole eval must fail instead (sealed eval's M3
    // precedent: fail loudly, never widen quietly).
    {
        var env: Env = undefined;
        try Env.init(gpa, &env);
        defer env.deinit(gpa);
        const cfg = "weft.grant(\"git\", \"fs_write\", { root: 123 });\n";
        try t.expectError(error.ConfigException, evalToManifest(&engine, &env.ctx, null, null, null, cfg, .config, "config"));
    }

    // Same for an explicitly `undefined` root — the exact "a typo'd
    // variable that evaluated to undefined" case the send-back named.
    {
        var env: Env = undefined;
        try Env.init(gpa, &env);
        defer env.deinit(gpa);
        const cfg = "weft.grant(\"git\", \"fs_write\", { root: undefined });\n";
        try t.expectError(error.ConfigException, evalToManifest(&engine, &env.ctx, null, null, null, cfg, .config, "config"));
    }

    // But an OMITTED opts, or an opts object with no `root` key at all, is
    // the legitimate unrestricted case — no exception, root stays "".
    {
        var env: Env = undefined;
        try Env.init(gpa, &env);
        defer env.deinit(gpa);
        const cfg = "weft.grant(\"git\", \"proc\");\n";
        const m = try evalToManifest(&engine, &env.ctx, null, null, null, cfg, .config, "config");
        defer m.destroy();
        try t.expectEqualStrings("", m.grants.items[0].root);
    }
    {
        var env: Env = undefined;
        try Env.init(gpa, &env);
        defer env.deinit(gpa);
        const cfg = "weft.grant(\"git\", \"proc\", {});\n";
        const m = try evalToManifest(&engine, &env.ctx, null, null, null, cfg, .config, "config");
        defer m.destroy();
        try t.expectEqualStrings("", m.grants.items[0].root);
    }
}

test "quickjs: weft.grant is config-plane only — a resident JS plugin's call is a logged no-op" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    // A JS plugin registers a command that calls weft.grant from a LIVE
    // dispatch — `br.manifest == null` there, so `cGrant` must degrade to a
    // warning, never crash and never mutate anything (statusSegment's exact
    // precedent for a config-only verb reached from the plugin plane).
    const src =
        \\weft.command("try-grant", function() {
        \\  weft.grant("other", "fs_write", { root: "x" });
        \\  weft.echo("survived");
        \\});
    ;
    const plugin = try JsPlugin.load(gpa, &engine, &env.ctx, env.pool, .empty, "grantplugin", null, src);
    defer plugin.deinit();
    _ = try command.run(&env.commands, &env.ctx, "try-grant", &.{});
    try t.expectEqualStrings("survived", env.head.echo.items);
}

test "quickjs: weft.use produces a real imported sub-manifest at the imported tier" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    const dir = ".zig-cache/tmp/weft-use-manifest-test";
    const defaults_path = dir ++ "/shared.js";
    try @import("file.zig").writeBytesMakingDirs(gpa, dir, defaults_path,
        \\weft.bind("pick", "Down", "pick-next");
    );
    defer @import("file.zig").deleteFile(gpa, defaults_path);

    const cfg = "weft.use(\"shared\");\n";
    const m = try evalToManifest(&engine, &env.ctx, null, null, dir, cfg, .config, "config");
    defer m.destroy();

    try t.expectEqual(@as(usize, 1), m.imports.items.len);
    const sub = m.imports.items[0];
    try t.expectEqual(manifest_mod.Tier.imported, sub.tier);
    try t.expectEqualStrings("import:shared", sub.owner);
    try t.expectEqual(@as(usize, 1), sub.binds.items.len);
    try t.expectEqualStrings("pick-next", sub.binds.items[0].commands[0]);
}

test "quickjs: reconcile — reapplying the identical config is a verified no-op" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    const cfg =
        \\weft.bind("normal", "j", "cursor-down");
        \\weft.echo("hello");
    ;
    const m1 = try evalToManifest(&engine, &env.ctx, null, null, null, cfg, .config, "config");
    defer m1.destroy();
    var actx: manifest_mod.Manifest.ApplyCtx = .{ .ctx = &env.ctx, .loader = null, .config = null };
    try m1.apply(gpa, &actx);
    try env.head.setModeRaw(gpa, "normal");
    try t.expectEqualStrings("cursor-down", env.keymap.lookup(env.head.currentMode(), "j").?);
    try t.expectEqualStrings("hello", env.head.echo.items);

    // A second eval of the SAME source, reconciled against m1: same hash,
    // logged no-op, and critically the echo does NOT fire again (a echo
    // re-firing on every identical reload would be the "no-op" claim lying).
    env.head.echo.clearRetainingCapacity();
    const m2 = try evalToManifest(&engine, &env.ctx, null, null, null, cfg, .config, "config");
    defer m2.destroy();
    try manifest_mod.Manifest.reconcile(gpa, m1, m2, &actx);
    try t.expectEqualStrings("", env.head.echo.items); // no-op: nothing re-fired
    try t.expectEqualStrings("cursor-down", env.keymap.lookup(env.head.currentMode(), "j").?); // still bound

    // A CHANGED config removes the old bind and adds a new one — reconcile
    // tears down the removed decl and applies the added one.
    const cfg3 =
        \\weft.bind("normal", "k", "cursor-up");
        \\weft.echo("hello");
    ;
    const m3 = try evalToManifest(&engine, &env.ctx, null, null, null, cfg3, .config, "config");
    defer m3.destroy();
    try manifest_mod.Manifest.reconcile(gpa, m2, m3, &actx);
    try t.expectEqual(@as(?[]const u8, null), env.keymap.lookup(env.head.currentMode(), "j")); // removed
    try t.expectEqualStrings("cursor-up", env.keymap.lookup(env.head.currentMode(), "k").?); // added
}

test "quickjs: W4 slice 4 — reconcile round trip: a weft.grant removed leaves COHERENT state, no baseline fallback" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    const cfg1 = "weft.grant(\"git\", \"fs_write\", { root: \"repo\" });\n";
    const m1 = try evalToManifest(&engine, &env.ctx, null, null, null, cfg1, .config, "config");
    defer m1.destroy();
    var actx: manifest_mod.Manifest.ApplyCtx = .{ .ctx = &env.ctx, .loader = null, .config = null };
    try manifest_mod.Manifest.reconcile(gpa, null, m1, &actx);

    const h = env.grants.findLive("git", "fs_write").?;
    try t.expect(env.grants.check(h));
    switch (env.grants.limitFor(h)) {
        .fs_root => |root| try t.expectEqualStrings("repo", root),
        .none, .place, .doc_region, .graph_subtree => return error.TestUnexpectedResult,
    }

    // Reload WITHOUT the grant decl at all — reconcile tears it down.
    const m2 = try evalToManifest(&engine, &env.ctx, null, null, null, "", .config, "config");
    defer m2.destroy();
    try manifest_mod.Manifest.reconcile(gpa, m1, m2, &actx);

    try t.expect(!env.grants.check(h));
    try t.expectEqual(grants_mod.Reason.revoked, env.grants.reasonFor(h));
    // The composition rule's honest consequence (grants.zig's module doc):
    // no separate describe()-boolean baseline row was ever minted for a
    // config-narrowed pair, so there is nothing to "fall back" to — the
    // pair reads as fully ungranted now, not silently reverted to
    // unrestricted.
    try t.expectEqual(@as(?grants_mod.CapHandle, null), env.grants.findLive("git", "fs_write"));
}

test "quickjs: W4 slice 4 — an UNCHANGED weft.grant survives a reload that changes something else (no orphaned handle)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    const cfg1 =
        \\weft.grant("git", "fs_write", { root: "repo" });
        \\weft.bind("normal", "j", "cursor-down");
    ;
    const m1 = try evalToManifest(&engine, &env.ctx, null, null, null, cfg1, .config, "config");
    defer m1.destroy();
    var actx: manifest_mod.Manifest.ApplyCtx = .{ .ctx = &env.ctx, .loader = null, .config = null };
    try manifest_mod.Manifest.reconcile(gpa, null, m1, &actx);
    const h = env.grants.findLive("git", "fs_write").?;

    // Reload with the SAME grant decl but a DIFFERENT, unrelated bind — the
    // manifest's hash differs (reconcile's teardown+reapply DOES run), but
    // the grant itself must survive as the SAME live row, not a
    // revoke-then-remint (`reconcileGrants`'s whole point: an already-loaded
    // plugin's POSSESSED handle must not be silently orphaned by a reload
    // that didn't touch ITS grant).
    const cfg2 =
        \\weft.grant("git", "fs_write", { root: "repo" });
        \\weft.bind("normal", "k", "cursor-up");
    ;
    const m2 = try evalToManifest(&engine, &env.ctx, null, null, null, cfg2, .config, "config");
    defer m2.destroy();
    try manifest_mod.Manifest.reconcile(gpa, m1, m2, &actx);

    try t.expect(env.grants.check(h)); // still the SAME live handle
    const h2 = env.grants.findLive("git", "fs_write").?;
    try t.expectEqual(h.idx, h2.idx);
    try t.expectEqual(h.gen, h2.gen);
}

test {
    std.testing.refAllDecls(@This());
}

test "quickjs: weft.bind takes an intention or a fallback list — one staged representation, order-sensitive hash (configuration.md §5.2)" {
    const gpa = t.allocator;
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    const list_cfg =
        \\weft.bind("normal", "Return", ["target.activate", "editing.insert-line-break"]);
    ;
    var env1: Env = undefined;
    try Env.init(gpa, &env1);
    defer env1.deinit(gpa);
    const m1 = try evalToManifest(&engine, &env1.ctx, null, null, null, list_cfg, .config, "config");
    defer m1.destroy();
    try t.expectEqual(@as(usize, 1), m1.binds.items.len);
    try t.expectEqual(@as(usize, 2), m1.binds.items[0].commands.len);
    try t.expectEqualStrings("target.activate", m1.binds.items[0].commands[0]);
    try t.expectEqualStrings("editing.insert-line-break", m1.binds.items[0].commands[1]);

    // Sealed eval: the same source, a separate runtime, an identical hash.
    var env2: Env = undefined;
    try Env.init(gpa, &env2);
    defer env2.deinit(gpa);
    const m2 = try evalToManifest(&engine, &env2.ctx, null, null, null, list_cfg, .config, "config");
    defer m2.destroy();
    try t.expectEqual(m1.hash(), m2.hash());

    // The STRING form stages the identical shape, one entry long.
    var env3: Env = undefined;
    try Env.init(gpa, &env3);
    defer env3.deinit(gpa);
    const m3 = try evalToManifest(&engine, &env3.ctx, null, null, null,
        \\weft.bind("normal", "Return", "target.activate");
    , .config, "config");
    defer m3.destroy();
    try t.expectEqual(@as(usize, 1), m3.binds.items[0].commands.len);
    try t.expectEqualStrings("target.activate", m3.binds.items[0].commands[0]);
    try t.expect(m1.hash() != m3.hash());

    // Reordering the list is a content change the hash sees.
    var env4: Env = undefined;
    try Env.init(gpa, &env4);
    defer env4.deinit(gpa);
    const m4 = try evalToManifest(&engine, &env4.ctx, null, null, null,
        \\weft.bind("normal", "Return", ["editing.insert-line-break", "target.activate"]);
    , .config, "config");
    defer m4.destroy();
    try t.expect(m1.hash() != m4.hash());

    // Applying a multi-entry list binds the FIRST entry (the catalog that
    // resolves the rest lands later); the fallback rides on the decl.
    var actx: manifest_mod.Manifest.ApplyCtx = .{ .ctx = &env1.ctx, .loader = null, .config = null };
    try m1.apply(gpa, &actx);
    try env1.head.setModeRaw(gpa, "normal");
    try t.expectEqualStrings("target.activate", env1.keymap.lookup(env1.head.currentMode(), "Return").?);

    // Reconciling the identical config is a no-op: still the first entry.
    try manifest_mod.Manifest.reconcile(gpa, m1, m2, &actx);
    try t.expectEqualStrings("target.activate", env1.keymap.lookup(env1.head.currentMode(), "Return").?);
}

test "quickjs: a degenerate weft.bind list fails the eval loudly — never a silently dropped binding" {
    const gpa = t.allocator;
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    const bad = [_][]const u8{
        "weft.bind(\"normal\", \"Return\", []);\n",
        "weft.bind(\"normal\", \"Return\", [\"target.activate\", 7]);\n",
    };
    for (bad) |cfg| {
        var env: Env = undefined;
        try Env.init(gpa, &env);
        defer env.deinit(gpa);
        try t.expectError(error.ConfigException, evalToManifest(&engine, &env.ctx, null, null, null, cfg, .config, "config"));
    }
}

// The §18 isolation gate for ACP: "Two repositories, REPLs, DAP sessions, and
// ACP conversations remain isolated." Two mock agents run CONCURRENTLY through
// the real `config/plugins/acp.js` — each mints its own transcript instance
// (`*agent*`, `*agent:2*`), its own CRDT sub-peer (`claude#1`, `codex#2`), and
// its own pending permission request. Answering one permission resolves ONLY
// its own tool call: the other agent stays blocked until its OWN answer, which
// is continuation identity (§14.7) rather than "whatever was pending".
test "quickjs: two ACP conversations stream into their own transcripts, and a permission answered for one never unblocks the other" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    try pick_mod.install(gpa, &env.commands, &env.keymap);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    // One mock ACP agent, parameterized by TAG (sh builtins only): handshake,
    // a message chunk, a file write, then a permission request — and after
    // that it BLOCKS on stdin, acking only when its own answer arrives. So
    // "TAG ack" in a transcript is proof that THAT agent was unblocked.
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const template =
        \\printf '{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1}}\n'
        \\printf '{"jsonrpc":"2.0","id":1,"result":{"sessionId":"TAG"}}\n'
        \\printf '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"TAG one"}}}}\n'
        \\printf '{"jsonrpc":"2.0","id":8,"method":"fs/write_text_file","params":{"path":"SHARED","content":"TAG wrote"}}\n'
        \\printf '{"jsonrpc":"2.0","id":9,"method":"session/request_permission","params":{"toolCall":{"toolCallId":"TAG-call","title":"TAG edit"},"options":[{"optionId":"allow","name":"Allow"},{"optionId":"deny","name":"Deny"}]}}\n'
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *outcome*) printf '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"TAG ack"}}}}\n' ;;
        \\  esac
        \\done
    ;
    const shared = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/shared.txt", .{tmp.sub_path});
    defer gpa.free(shared);
    const with_path = try std.mem.replaceOwned(u8, gpa, template, "SHARED", shared);
    defer gpa.free(with_path);
    var mocks: [2][]u8 = undefined;
    defer for (mocks) |m| gpa.free(m);
    const tags = [_][]const u8{ "alpha", "beta" };
    for (tags, 0..) |tag, i| {
        mocks[i] = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/{s}.sh", .{ tmp.sub_path, tag });
        const body = try std.mem.replaceOwned(u8, gpa, with_path, "TAG", tag);
        defer gpa.free(body);
        try @import("file.zig").writeBytes(gpa, mocks[i], body);
    }

    // The REAL plugin, plus one start command per agent (named, so each
    // conversation's sub-peer is its own agent's — `claude#1`, `codex#2`).
    const acp = try @import("file.zig").readAlloc(gpa, "config/plugins/acp.js");
    defer gpa.free(acp);
    const src = try std.fmt.allocPrint(gpa,
        \\{s}
        \\weft.command("start-a", () => startAgent("/bin/sh {s}", "hi", "claude"));
        \\weft.command("start-b", () => startAgent("/bin/sh {s}", "hi", "codex"));
    , .{ acp, mocks[0], mocks[1] });
    defer gpa.free(src);

    try env.grant("test", "proc");
    // …and `fs_write`, which the mocks' `fs/write_text_file` step needs: the
    // shared-file assertion below (both sub-peers authored it) is only
    // reachable through that door, and the door is possession-gated.
    try env.grant("test", "fs_write");
    // Two live agents pin two reader tasks (each mock BLOCKS on stdin waiting
    // for its own answer), so the shared fixture's single-thread pool would
    // starve the second spawn — concurrency here is the subject, not scenery.
    const pool = try task.Pool.init(gpa, .{ .threads = 4 });
    defer pool.deinit();
    var plugin = try JsPlugin.load(gpa, &engine, &env.ctx, pool, .empty, "test", null, src);
    defer plugin.deinit();
    // A bail with a request still open must not leave the head's pick session
    // live — teardown asserts every acceptor was answered.
    defer if (env.head.pick.active) {
        _ = command.run(&env.commands, &env.ctx, "pick-cancel", &.{}) catch {};
    };

    const H = struct {
        fn text(e: *Env, gpa2: Allocator, name: []const u8) ?[]u8 {
            var it = e.buffers.iterator();
            while (it.next()) |b| {
                if (!std.mem.eql(u8, b.name, name)) continue;
                const ed = b.textEditor() orelse return null;
                return ed.text().toOwnedSlice(gpa2) catch null;
            }
            return null;
        }
        /// Tick the plugin until `name`'s buffer contains `needle`.
        fn until(p: *JsPlugin, e: *Env, gpa2: Allocator, name: []const u8, needle: []const u8) bool {
            const deadline = task.nowNs() + 5 * std.time.ns_per_s;
            while (task.nowNs() < deadline) {
                _ = p.tick();
                if (text(e, gpa2, name)) |txt| {
                    defer gpa2.free(txt);
                    if (std.mem.indexOf(u8, txt, needle) != null) return true;
                }
                std.Thread.yield() catch {};
            }
            return false;
        }
        /// Tick until the head's picker opens. Bounded: a pick that never
        /// arrives is a failure, never a hung run.
        fn untilPick(p: *JsPlugin, e: *Env) bool {
            const deadline = task.nowNs() + 5 * std.time.ns_per_s;
            while (task.nowNs() < deadline) {
                if (e.head.pick.active) return true;
                _ = p.tick();
                std.Thread.yield() catch {};
            }
            return false;
        }
        /// Tick for a bounded stretch, asserting `needle` never shows up.
        fn absent(p: *JsPlugin, e: *Env, gpa2: Allocator, name: []const u8, needle: []const u8) bool {
            const deadline = task.nowNs() + 300 * std.time.ns_per_ms;
            while (task.nowNs() < deadline) {
                _ = p.tick();
                if (text(e, gpa2, name)) |txt| {
                    defer gpa2.free(txt);
                    if (std.mem.indexOf(u8, txt, needle) != null) return false;
                }
                std.Thread.yield() catch {};
            }
            return true;
        }
    };

    // Agent one: its own transcript instance, and its permission pick opens
    // (from the BACKGROUND output handler, through the nested-run door).
    _ = try command.run(&env.commands, &env.ctx, "start-a", &.{});
    try t.expect(H.until(plugin, &env, gpa, "*agent*", "alpha one"));
    try t.expect(H.untilPick(plugin, &env));

    // Agent two: a SECOND instance — its own buffer, its own model. Its
    // permission request queues behind agent one's open pick.
    _ = try command.run(&env.commands, &env.ctx, "start-b", &.{});
    try t.expect(H.until(plugin, &env, gpa, "*agent:2*", "beta one"));

    // Interleaved updates landed in the right transcripts, both directions.
    {
        const a = H.text(&env, gpa, "*agent*").?;
        defer gpa.free(a);
        const b = H.text(&env, gpa, "*agent:2*").?;
        defer gpa.free(b);
        try t.expect(std.mem.indexOf(u8, a, "beta") == null);
        try t.expect(std.mem.indexOf(u8, b, "alpha") == null);
    }
    // Two conversations, two models — not one doc with two views.
    try t.expectEqual(@as(usize, 2), plugin.conversations.items.len);
    try t.expect(plugin.conversation("*agent*") != plugin.conversation("*agent:2*"));

    // Each agent's edit authors as its OWN sub-peer, so selective undo can
    // separate claude#1 from codex#2 on the file they both wrote.
    {
        const id = env.buffers.findByPath(shared) orelse return error.NoAgentBuffer;
        const doc = &env.buffers.get(id).?.textEditor().?.doc;
        var seen_claude = false;
        var seen_codex = false;
        for (doc.peers.items) |slot| {
            const p = slot orelse continue;
            if (std.mem.eql(u8, p.name, "claude#1")) seen_claude = true;
            if (std.mem.eql(u8, p.name, "codex#2")) seen_codex = true;
        }
        try t.expect(seen_claude and seen_codex);
    }

    // Answer the OPEN pick — agent one's. Only agent one unblocks: agent two
    // is still waiting for the answer to ITS own tool call.
    _ = try command.run(&env.commands, &env.ctx, "pick-accept", &.{});
    try t.expect(H.until(plugin, &env, gpa, "*agent*", "alpha ack"));
    try t.expect(H.absent(plugin, &env, gpa, "*agent:2*", "beta ack"));

    // Agent two's queued request opened on the freed head; answering IT
    // resolves ITS call, and its ack lands in ITS transcript.
    try t.expect(env.head.pick.active);
    _ = try command.run(&env.commands, &env.ctx, "pick-accept", &.{});
    try t.expect(H.until(plugin, &env, gpa, "*agent:2*", "beta ack"));
    {
        const a = H.text(&env, gpa, "*agent*").?;
        defer gpa.free(a);
        try t.expect(std.mem.indexOf(u8, a, "beta ack") == null);
    }
}
