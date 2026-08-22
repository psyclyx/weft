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
///     touching the editor — sealed evaluation (north-star-plan §2.3).
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
    fn activeCtx(self: *Bridge) *command.Context {
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
    .{ .name = "qjs_provide", .handler = cProvide },
    .{ .name = "qjs_status_segment", .handler = cStatusSegment },
};

/// The `.plugin`-group handlers a RESIDENT JS plugin's linker binds (real —
/// `defineStubs` above covers the config linker's stand-ins).
const plugin_handlers = .{
    .{ .name = "qjs_register", .handler = cRegister },
    .{ .name = "qjs_proc_spawn", .handler = cProcSpawn },
    .{ .name = "qjs_proc_send", .handler = cProcSend },
    .{ .name = "qjs_proc_read", .handler = cProcRead },
    .{ .name = "qjs_proc_close", .handler = cProcClose },
    .{ .name = "qjs_buffer_append", .handler = cBufferAppend },
    .{ .name = "qjs_buffer_fold", .handler = cBufferFold },
    .{ .name = "qjs_buffer_len", .handler = cBufferLen },
    .{ .name = "qjs_config", .handler = cConfig },
    .{ .name = "qjs_breakpoints", .handler = cBreakpoints },
    .{ .name = "qjs_file_read", .handler = cFileRead },
    .{ .name = "qjs_file_write", .handler = cAgentWrite },
    .{ .name = "qjs_line_text", .handler = cLineText },
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
/// declaration to the returned manifest (north-star-plan §2.3: "nothing
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

    var module = try engine.compile(quickjs_wasm);
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
/// the hash-log + fresh `apply` pass (north-star-plan §2.3's "the approved
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

    const Cmd = struct { plugin: *JsPlugin, id: i32, name: []u8 };

    /// Instantiate `quickjs.wasm`, wire the membrane + registrar, and run the
    /// plugin body (`src`), which registers its commands. Heap-owned so the
    /// membrane's `&self.bridge` and the trampolines' `plugin` pointers stay
    /// valid (the instance is resident for the plugin's life). `pool`/`environ`
    /// back the proc-stream membrane (agent subprocesses).
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
            // LIVE mode (`manifest` left null) — see Bridge's doc: a resident
            // JS plugin's `weft.*` calls mutate the editor immediately, not
            // staged.
            .bridge = .{ .ctx = ctx, .loader = null, .config = null, .engine = engine },
            .module = try engine.compile(quickjs_wasm),
            .linker = undefined,
            .instance = undefined,
        };
        errdefer {
            gpa.free(self.name);
            self.module.deinit();
        }
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
        for (self.streams.items, 0..) |maybe, h| {
            const s = maybe orelse continue;
            if (s.pending() == 0) continue;
            self.instance.callVoid("weft_on_output", &.{@intCast(h)}) catch {};
            fired = true;
        }
        return fired;
    }

    pub fn deinit(self: *JsPlugin) void {
        const gpa = self.gpa;
        gpa.free(self.name);
        for (self.streams.items) |maybe| if (maybe) |s| s.deinit();
        self.streams.deinit(gpa);
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
// child, handles indexing the plugin's `streams`. ──

fn cProcSpawn(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const self: *JsPlugin = @ptrCast(@alignCast(data.?));
    const gpa = self.gpa;
    const cmd = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch {
        results[0] = -1;
        return;
    };
    defer gpa.free(cmd);
    const cwd = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch {
        results[0] = -1;
        return;
    };
    defer gpa.free(cwd);
    const s = proc_stream.ProcStream.start(gpa, self.pool, cmd, if (cwd.len > 0) cwd else null, self.environ) catch {
        results[0] = -1;
        return;
    };
    const h: i32 = @intCast(self.streams.items.len);
    self.streams.append(gpa, s) catch {
        s.deinit();
        results[0] = -1;
        return;
    };
    results[0] = h;
}

fn streamAt(self: *JsPlugin, h: i32) ?*proc_stream.ProcStream {
    if (h < 0 or @as(usize, @intCast(h)) >= self.streams.items.len) return null;
    return self.streams.items[@intCast(h)];
}

fn cProcSend(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const self: *JsPlugin = @ptrCast(@alignCast(data.?));
    const s = streamAt(self, args[0]) orelse return;
    const bytes = caller.readMemory(self.gpa, @intCast(args[1]), @intCast(args[2])) catch return;
    defer self.gpa.free(bytes);
    s.send(bytes);
}

fn cProcRead(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const self: *JsPlugin = @ptrCast(@alignCast(data.?));
    const s = streamAt(self, args[0]) orelse {
        results[0] = 0;
        return;
    };
    const cap: usize = @intCast(args[2]);
    const buf = self.gpa.alloc(u8, cap) catch {
        results[0] = 0;
        return;
    };
    defer self.gpa.free(buf);
    const n = s.read(buf);
    results[0] = @intCast(caller.writeMemory(@intCast(args[1]), @intCast(cap), buf[0..n]) catch 0);
}

fn cProcClose(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const self: *JsPlugin = @ptrCast(@alignCast(data.?));
    const h = args[0];
    if (streamAt(self, h)) |s| {
        s.deinit();
        self.streams.items[@intCast(h)] = null; // slot kept null so handles stay stable
    }
}

/// The CRDT peer JS-plugin transcript/tool-buffer output authors as.
const transcript_peer = "agent-ui";

/// Append `text` to the end of the buffer named `name` (created if absent),
/// authored as a fixed tool peer — the streamed-transcript path, targeting a
/// buffer by name so it need not be focused (mirrors repl_session.drain).
fn appendNamed(ctx: *command.Context, gpa: Allocator, name: []const u8, text: []const u8, class: u8) void {
    const bufs = ctx.buffers;
    const b = bufs.get(bufs.ensureNamed(gpa, name) catch return) orelse return;
    const doc = &b.editor.doc;
    const start = b.editor.text().byteLen();
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
    const doc = &b.editor.doc;
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
    results[0] = @intCast(b.editor.text().byteLen());
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

/// weft.breakpoints(path) → the file's breakpoint lines as a "l1,l2,…" CSV (set
/// by the debug plugin via publishBreakpoints), or "" if none. The DAP client
/// reads this to send setBreakpoints, so the session stops where you marked.
fn cBreakpoints(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const self: *JsPlugin = @ptrCast(@alignCast(data.?));
    const path = caller.readMemory(self.gpa, @intCast(args[0]), @intCast(args[1])) catch {
        results[0] = 0;
        return;
    };
    defer self.gpa.free(path);
    const csv = @import("breakpoints.zig").get(path);
    results[0] = @intCast(caller.writeMemory(@intCast(args[2]), @intCast(args[3]), csv) catch 0);
}

/// weft.fileRead(path) → the file's content for the agent's fs/read: the LIVE
/// buffer text if the file is open (uncommitted edits included — the honest
/// current state, not stale disk), else the disk file. Capped at the guest's
/// receive buffer for now.
fn cFileRead(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const self: *JsPlugin = @ptrCast(@alignCast(data.?));
    const gpa = self.gpa;
    const path = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch {
        results[0] = 0;
        return;
    };
    defer gpa.free(path);
    var content: ?[]u8 = null;
    if (self.bridge.activeCtx().buffers.findByPath(path)) |id| {
        if (self.bridge.activeCtx().buffers.get(id)) |b| content = b.editor.text().toOwnedSlice(gpa) catch null;
    }
    if (content == null) content = @import("file.zig").readAlloc(gpa, path) catch null;
    const bytes = content orelse {
        results[0] = 0;
        return;
    };
    defer gpa.free(bytes);
    results[0] = @intCast(caller.writeMemory(@intCast(args[2]), @intCast(args[3]), bytes) catch 0);
}

/// A JS plugin's open pick — dispatches the accepted index back into the
/// instance via `weft_on_pick`. Freed by `jsPickCleanup`.
const JsBoundPick = struct { plugin: *JsPlugin };

/// weft.pick(prompt, options): open a pick over the newline-joined options,
/// bound to this JS plugin; the accepted index returns via `weft_on_pick` (the
/// async approve/deny round-trip — an agent's permission request).
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
    var entries: std.ArrayList(pick_mod.Entry) = .empty;
    defer entries.deinit(gpa);
    var it = std.mem.splitScalar(u8, opts, '\n');
    while (it.next()) |o| if (o.len > 0) entries.append(gpa, .{ .text = o, .doc = "" }) catch {};
    const bp = gpa.create(JsBoundPick) catch return;
    bp.* = .{ .plugin = self };
    // pick.open copies the entry text/doc, so `opts` may free after this.
    const ctx = self.bridge.activeCtx();
    ctx.head.pick.open(ctx, prompt, entries.items, .{
        .handler = jsPickAccept,
        .cleanup = jsPickCleanup,
        .data = bp,
    }) catch gpa.destroy(bp);
}

/// DISPATCHING (mirrors `wasm_host/pick.zig`'s `wpPickAccept`): `ctx` is the
/// head whose pick session just accepted. `ctx.head.pick.accepted_index`
/// itself already reads through it correctly (it's the parameter, not
/// `self.ctx`); route `bridge.active_ctx` through it too for the
/// `weft_on_pick` call, so anything the JS handler does in response (echo,
/// bind, another pick) sees the SAME head, not the plugin's load-time one.
fn jsPickAccept(ctx: *command.Context, data: ?*anyopaque, choice: []const u8) anyerror!void {
    _ = choice;
    const bp: *JsBoundPick = @ptrCast(@alignCast(data.?));
    const idx: i32 = if (ctx.head.pick.accepted_index) |i| @intCast(i) else -1;
    const saved_ctx = bp.plugin.bridge.active_ctx;
    const saved_dispatch = bp.plugin.bridge.in_dispatch;
    bp.plugin.bridge.active_ctx = ctx;
    bp.plugin.bridge.in_dispatch = true; // DISPATCHING (task #19 item 4) — see onCommand's doc
    defer {
        bp.plugin.bridge.active_ctx = saved_ctx;
        bp.plugin.bridge.in_dispatch = saved_dispatch;
    }
    bp.plugin.instance.callVoid("weft_on_pick", &.{idx}) catch {};
}

fn jsPickCleanup(data: ?*anyopaque, gpa: Allocator) void {
    const bp: *JsBoundPick = @ptrCast(@alignCast(data.?));
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
    const ed = self.bridge.activeCtx().editor();
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

/// The CRDT peer an agent's file writes author as (a single agent identity for
/// now; per-conversation naming is a refinement).
const agent_peer = "agent";

/// weft.fileWrite(path, content) → the agent's fs/write_text_file: replace the
/// buffer for `path` with `content`, authored as the agent peer — a gated,
/// attributed, selectively-undoable edit (the harness payoff), not a raw disk
/// write. Opens (binds) the path if it isn't already a buffer; the user saves.
/// A whole-file write, so the buffer's whole content is replaced.
fn cAgentWrite(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const self: *JsPlugin = @ptrCast(@alignCast(data.?));
    const gpa = self.gpa;
    const path = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(path);
    const content = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer gpa.free(content);
    const agent = caller.readMemory(gpa, @intCast(args[4]), @intCast(args[5])) catch return;
    defer gpa.free(agent);
    const peer = if (agent.len > 0) agent else agent_peer;
    const bufs = self.bridge.activeCtx().buffers;
    const id = bufs.findByPath(path) orelse blk: {
        const new_id = bufs.create(gpa, std.fs.path.basename(path)) catch return;
        const nb = bufs.get(new_id) orelse return;
        nb.editor.adoptPath(gpa, path) catch return; // bind the path (save creates it)
        break :blk new_id;
    };
    const b = bufs.get(id) orelse return;
    const doc = &b.editor.doc;
    const end = b.editor.text().byteLen();
    command.renderInto(gpa, doc, .agent, peer, &.{.{ .range = .{ .start = 0, .end = end }, .bytes = content }}) catch return;
}

/// Decode the first record of a framed config blob (uvarint count, then
/// uvarint(len)++bytes). Core-local copy of the app-side decoder.
fn firstFramedRecord(blob: []const u8) ?[]const u8 {
    var cur = blob;
    _ = framedUvarint(&cur) orelse return null; // record count
    const n = framedUvarint(&cur) orelse return null;
    if (n > cur.len) return null;
    return cur[0..@intCast(n)];
}
fn framedUvarint(cur: *[]const u8) ?u64 {
    var shift: u6 = 0;
    var v: u64 = 0;
    while (cur.len > 0) {
        const b = cur.*[0];
        cur.* = cur.*[1..];
        v |= @as(u64, b & 0x7f) << shift;
        if (b & 0x80 == 0) return v;
        if (shift >= 57) return null;
        shift += 7;
    }
    return null;
}

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
// Each mirrors an abi.Abi config-surface method; failures degrade quietly
// (a bad bind is dropped) — the JS side already validated arity/types. ──

fn readStr(br: *Bridge, caller: *wasm.Caller, ptr: i32, len: i32) ?[]u8 {
    return caller.readMemory(br.activeCtx().gpa, @intCast(ptr), @intCast(len)) catch null;
}

fn cBindKey(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const br: *Bridge = @ptrCast(@alignCast(data.?));
    const gpa = br.activeCtx().gpa;
    const mode = readStr(br, caller, args[0], args[1]) orelse return;
    defer gpa.free(mode);
    const key = readStr(br, caller, args[2], args[3]) orelse return;
    defer gpa.free(key);
    const cmd = readStr(br, caller, args[4], args[5]) orelse return;
    defer gpa.free(cmd);
    if (br.manifest) |m| {
        m.addBind(mode, key, cmd) catch {};
        return;
    }
    // LIVE mode (a resident JS plugin): user config shadows plugins and core
    // defaults (highest tier) — unchanged from before manifest.zig existed.
    br.activeCtx().keymap.bind(gpa, mode, key, cmd, @import("Keymap.zig").prio_config, "config") catch {};
}

/// `weft.use(name)` backing: evaluate `<config_dir>/<name>.js` into ITS OWN
/// manifest — a NESTED, independent `evalToManifest` call (its own fresh
/// quickjs runtime, exactly like the top-level config's own eval), attached
/// as an import at `.imported` tier (north-star-plan §2.2/§2.3: "imported
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
    // — nothing in the shipped catalog nests weft.use more than one level").
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

fn cRun(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const br: *Bridge = @ptrCast(@alignCast(data.?));
    const gpa = br.activeCtx().gpa;
    const cmd = readStr(br, caller, args[0], args[1]) orelse return;
    defer gpa.free(cmd);
    if (br.manifest) |m| {
        m.addRun(cmd) catch {};
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
    _ = command.run(br.activeCtx().commands, br.activeCtx(), cmd, &.{}) catch {};
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
    km.setTextCommand(gpa, name, null) catch {}; // swallow text — a menu, not typing
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
/// seg` segment onto the manifest (north-star-plan §6 W3, task #19 item 3's
/// mesh-reachability verb). CONFIG-ONLY: unlike `weft.provide`/`weft.action`
/// this has no LIVE (resident-JS-plugin, `br.manifest == null`) behavior —
/// the direct-bind path would need this (core-layer) module to know the
/// gfx-layer `ui_mesh.zig` provider shape, exactly the dependency
/// `manifest.StatusSegBinder`'s doc explains core can't take; a resident
/// plugin reaching `ui/*` live is a later step (D2/W0b), not this one.
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
    quit: bool,
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
        self.quit = false;
        self.ctx = .{
            .gpa = gpa,
            .buffers = &self.buffers,
            .commands = &self.commands,
            .keymap = &self.keymap,
            .actions = &self.actions,
            .caps = &self.caps,
            .quit = &self.quit,
            .head = &self.head,
        };
    }
    fn deinit(self: *Env, gpa: Allocator) void {
        self.actions.deinit();
        self.caps.deinit();
        self.container.deinit();
        self.head.deinit(gpa);
        self.keymap.deinit(gpa);
        self.commands.deinit(gpa);
        self.buffers.deinit(gpa);
        self.pool.deinit();
    }
};

test "quickjs: config.js drives the weft ABI — binds a key and echoes" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();

    const cfg =
        \\weft.bind("normal", "j", "cursor-down");
        \\weft.bind("normal", "k", "cursor-up");
        \\weft.echo("config loaded (" + (1 + 1) + " keys)");
    ;
    try evalConfig(&engine, &env.ctx, null, null, null, cfg);

    // The JS ran real logic (string concat + arithmetic) and reached the host:
    try env.head.setMode(gpa, "normal");
    try t.expectEqualStrings("cursor-down", env.keymap.lookup(env.head.currentMode(), "j").?);
    try t.expectEqualStrings("cursor-up", env.keymap.lookup(env.head.currentMode(), "k").?);
    try t.expectEqualStrings("config loaded (2 keys)", env.head.echo.items);
}

test "quickjs: weft.use includes a shared bindings module from the config dir" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
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

    try env.head.setMode(gpa, "pick");
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

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    try evalConfig(&engine, &env.ctx, null, null, null, "weft.run(\"mark\");");
    try t.expectEqualStrings("ran!", env.head.echo.items);
}

test "quickjs: weft.action + weft.provide wire the pick dispatch layer" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
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
    try env.head.setMode(gpa, "normal");
    try t.expectEqualStrings("eval", env.keymap.lookup(env.head.currentMode(), "space").?);

    // The `when` predicates crossed the JS→host membrane intact: eval resolves
    // per language, and the unconstrained default covers everything else.
    try t.expectEqualStrings("zig-eval", env.ctx.actions.resolve("eval", .{ .mode = "normal", .lang = "zig" }).?);
    try t.expectEqualStrings("python-repl", env.ctx.actions.resolve("eval", .{ .mode = "normal", .lang = "py" }).?);
    try t.expectEqualStrings("eval-line", env.ctx.actions.resolve("eval", .{ .mode = "normal", .lang = "md" }).?);
}

test "quickjs: a JS plugin registers a command dispatched back into JS" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init();
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

test "quickjs: a JS plugin drives a duplex subprocess and reads its output" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init();
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
    var plugin = try JsPlugin.load(gpa, &engine, &env.ctx, env.pool, .empty, "test", null, src);
    defer plugin.deinit();

    _ = try command.run(&env.commands, &env.ctx, "go", &.{});
    // Pump the frame-boundary output dispatch until the reply arrives.
    const deadline = task.nowNs() + 2 * std.time.ns_per_s;
    while (std.mem.indexOf(u8, env.head.echo.items, "ping") == null and task.nowNs() < deadline) {
        _ = plugin.tick();
        std.atomic.spinLoopHint();
    }
    try t.expect(std.mem.indexOf(u8, env.head.echo.items, "ping") != null);
}

test "quickjs: the ACP plugin drives a mock agent's message into the transcript" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init();
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
            const txt = try b.editor.text().toOwnedSlice(gpa);
            defer gpa.free(txt);
            if (std.mem.indexOf(u8, txt, "hello from agent") != null) found = true;
        }
        std.atomic.spinLoopHint();
    }
    try t.expect(found);
}

test "quickjs: a JS plugin reads a file through weft.fileRead" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init();
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
    var plugin = try JsPlugin.load(gpa, &engine, &env.ctx, env.pool, .empty, "test", null, src);
    defer plugin.deinit();

    _ = try command.run(&env.commands, &env.ctx, "r", &.{});
    try t.expectEqualStrings("file contents here", env.head.echo.items);
}

test "quickjs: a JS plugin writes a file as an attributed agent peer edit" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init();
    defer engine.deinit();

    // fs/write to a path that isn't open → weft binds a buffer to it and applies
    // the content as the agent peer (gated + attributed), not a raw disk write.
    const src =
        \\weft.command("w", () => weft.fileWrite("/tmp/weft-agent-out.zig", "const x = 1;"));
    ;
    var plugin = try JsPlugin.load(gpa, &engine, &env.ctx, env.pool, .empty, "test", null, src);
    defer plugin.deinit();
    _ = try command.run(&env.commands, &env.ctx, "w", &.{});

    const id = env.buffers.findByPath("/tmp/weft-agent-out.zig") orelse return error.NoAgentBuffer;
    const b = env.buffers.get(id).?;
    const txt = try b.editor.text().toOwnedSlice(gpa);
    defer gpa.free(txt);
    try t.expectEqualStrings("const x = 1;", txt);
    // Authored by a non-user peer — the agent, not the user's undo history.
    const doc = &b.editor.doc;
    try t.expect(doc.commitAt(doc.commitCount() - 1).author != .user);
}

test "quickjs: a config syntax error surfaces as ConfigException, not silent" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
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

    var engine = try wasm.Engine.init();
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
    try env.head.setMode(gpa, "normal");
    try t.expectEqualStrings("duplicate-line", env.keymap.lookup(env.head.currentMode(), "D").?);

    // And the command actually runs through the membrane: duplicate a line.
    try env.buffers.active().editor.insertText(gpa, "hi");
    env.buffers.active().editor.placeCursor(0);
    _ = try command.run(&env.commands, &env.ctx, "duplicate-line", &.{});
    const s = try env.buffers.active().editor.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("hi\nhi", s);
}

test "quickjs: R1 regression — weft.set for a .js plugin's STEM identity is not dropped as unowned" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init();
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

    var engine = try wasm.Engine.init();
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
    try env.head.setMode(gpa, "insert");
    try t.expectEqualStrings("pair-tick", env.keymap.lookup(env.head.currentMode(), "grave").?);

    // And it runs through the membrane: inserts the configured backtick pair.
    _ = try command.run(&env.commands, &env.ctx, "pair-tick", &.{});
    const s = try env.buffers.active().editor.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("``", s);
}

test "quickjs: weft.menu declares a submenu the leader tree enters (doom-style)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
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
    try env.head.setMode(gpa, "leader");
    try t.expectEqualStrings("leader-file", env.keymap.lookup(env.head.currentMode(), "f").?);

    // Inside the submenu: its own keys bind, and Escape/C-g leave via menu-escape.
    try env.head.setMode(gpa, "leader-file");
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
    var engine = try wasm.Engine.init();
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
    var engine = try wasm.Engine.init();
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
    var engine = try wasm.Engine.init();
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

test "quickjs: weft.use produces a real imported sub-manifest at the imported tier" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init();
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
    try t.expectEqualStrings("pick-next", sub.binds.items[0].command);
}

test "quickjs: reconcile — reapplying the identical config is a verified no-op" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init();
    defer engine.deinit();

    const cfg =
        \\weft.bind("normal", "j", "cursor-down");
        \\weft.echo("hello");
    ;
    const m1 = try evalToManifest(&engine, &env.ctx, null, null, null, cfg, .config, "config");
    defer m1.destroy();
    var actx: manifest_mod.Manifest.ApplyCtx = .{ .ctx = &env.ctx, .loader = null, .config = null };
    try m1.apply(gpa, &actx);
    try env.head.setMode(gpa, "normal");
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

test {
    std.testing.refAllDecls(@This());
}
