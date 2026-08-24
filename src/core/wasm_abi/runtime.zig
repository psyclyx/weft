//! The wasm plugin load/run path. `runGuest` binds a minimal `weft.{cursor,edit}`
//! ABI and calls a guest's `run` export (the milestone-2 proof). `loadPlugin`
//! runs the full lifecycle under the perm handshake:
//!   describe() → the guest declares its commands + perms (no authority) →
//!   [host would prompt the user] → grants flip on → init() registers →
//!   every register/effect is cross-checked against the declaration, an
//!   undeclared one fails the load and rolls the partial plugin back.
//! Commands the guest registers bind into the shared registry with a trampoline
//! that dispatches BACK into the guest's `on_command` export; its edits land on
//! the SAME grade gate an in-process catalog plugin uses, authored as the
//! plugin's own peer. Every host import mirrors one abi.Abi method — the
//! transport is wasm, the shape is unchanged.

const std = @import("std");
const Allocator = std.mem.Allocator;
const wasm = @import("../wasm.zig");
const command = @import("../command.zig");
const Document = @import("../Document.zig");
const kv = @import("../kv.zig");
const file = @import("../file.zig");
const subbuffer = @import("../subbuffer.zig");
const register_mod = @import("../register.zig");
const async_loop = @import("../async.zig");
const Pool = @import("../task.zig").Pool;

const wasm_host = @import("../wasm_host.zig");
const WasmPlugin = @import("WasmPlugin.zig");
const SyntaxResolver = WasmPlugin.SyntaxResolver;
const contract = @import("../membrane/contract.zig");

/// The embedded reference guest (compiled from `src/guest/hello.zig` to
/// wasm32 by build.zig, embedded like `font_mono`).
pub const guest_hello: []const u8 = @embedFile("guest_hello_wasm");

/// Host state behind the `weft.*` imports: which editor the guest drives and
/// the peer name its edits author as. Passed as each import's callback data.
const HostCtx = struct {
    ctx: *command.Context,
    name: []const u8,
};

fn hostCursor(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    const h: *HostCtx = @ptrCast(@alignCast(data.?));
    results[0] = @intCast(h.ctx.editor().cursorOffset());
}

/// W4 slice 3 (north-star-plan §2.4/§6, review B2's repair): `hostEdit` is a
/// wasm-transport trampoline too (this minimal ABI's `run` door, per the
/// module doc's "milestone-2 proof" — `caller` is a real `*wasm.Caller`, not
/// a stand-in), so the SAME "denied effects trap" bar
/// `wasm_host/edit.zig`'s `hEdit`/`hEditAs`/`hEditRange` meet applies here.
/// A twin of that file's `trapDocRegion` (kept separate rather than shared:
/// this ABI's `HostCtx` carries a `*command.Context` directly, not a
/// `*WasmPlugin` — sharing would need a needless duck-typed coupling for one
/// caller).
fn trapDocRegion(h: *HostCtx, caller: *wasm.Caller, start: usize, end: usize, err: anyerror) void {
    switch (err) {
        error.OutOfLimit => switch (h.ctx.checkDocRegion(start, end)) {
            .out_of_limit => |b| caller.trap("plugin '{s}' doc-edit [{d},{d}) is outside its granted region [{d},{d})", .{ h.name, start, end, b.start, b.end }),
            .ok, .collapsed => caller.trap("plugin '{s}' doc-edit [{d},{d}) denied: outside its granted doc_region", .{ h.name, start, end }),
        },
        error.Collapsed => caller.trap("plugin '{s}' doc-edit grant COLLAPSED — its identity anchors no longer resolve (deleted or compacted); re-grant needed", .{h.name}),
        else => unreachable,
    }
}

fn hostEdit(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const h: *HostCtx = @ptrCast(@alignCast(data.?));
    const gpa = h.ctx.gpa;
    const bytes = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer gpa.free(bytes);
    // Author as the plugin peer, through the grade gate — the one edit door.
    const saved = h.ctx.principal;
    h.ctx.principal = .{ .role = .plugin, .name = h.name, .ctx = h, .resolve = resolvePeer };
    defer h.ctx.principal = saved;
    const start: usize = @intCast(args[0]);
    const end: usize = @intCast(args[1]);
    // `error.Unauthorized`/`Document.AddPeerError` still swallow silently
    // here — the SAME pre-existing gap `wasm_host/edit.zig`'s module doc
    // names for its three doors, now named here too rather than left
    // implicit; only the two W4 slice 3 errors are new and MUST trap.
    h.ctx.edit(.{ .start = start, .end = end }, bytes) catch |e| switch (e) {
        error.OutOfLimit, error.Collapsed => trapDocRegion(h, caller, start, end, e),
        else => {},
    };
}

fn resolvePeer(ctx: *anyopaque, doc: *Document) Document.AddPeerError!Document.PeerId {
    const h: *HostCtx = @ptrCast(@alignCast(ctx));
    return doc.peerNamed(h.ctx.gpa, h.name);
}

/// Instantiate `wasm_bytes` with the weft ABI imports bound over `ctx`
/// (authored as `name`) and call its `run` export.
pub fn runGuest(engine: *wasm.Engine, ctx: *command.Context, name: []const u8, wasm_bytes: []const u8) !void {
    var module = try engine.compile(wasm_bytes);
    defer module.deinit();
    var host: HostCtx = .{ .ctx = ctx, .name = name };
    var linker = try wasm.Linker.init(engine);
    defer linker.deinit();
    try linker.defineFn("weft", "cursor", 0, 1, hostCursor, &host);
    try linker.defineFn("weft", "edit", 4, 0, hostEdit, &host);
    var instance = try linker.instantiate(&module);
    defer instance.deinit();
    try contract.callRequiredExport("run", &instance, .{});
}

pub const LoadOptions = struct {
    /// The kv store this plugin's Group-E admin calls persist into (namespaced
    /// by plugin name). Null = kv unavailable (kvGet→absent, kvPut→dropped).
    kv: ?*kv.Store = null,
    /// Read-only config data (from the config plane's `weft.set`), namespaced by
    /// plugin name. A distinct store from `kv` — structural isolation, so config
    /// and runtime scratch never collide. Null = no config (configGet→absent).
    config: ?*kv.Store = null,
    /// Resolves a buffer's grammar for `nodeAt`. Null = structural reads
    /// return "no node" (the honest degrade).
    syntax_of: ?SyntaxResolver = null,
    /// The subbuffer service `claimSubbuffer` claims into. Null = unavailable.
    subbuffers: ?*subbuffer.SubBuffers = null,
    /// The core register/kill service `yankRange`/`pasteAt` operate on (shared
    /// across every editor plugin). Null = register unavailable (both no-op).
    register: ?*register_mod.Register = null,
    /// The async loop `shellInsert` schedules its off-thread work on. Null =
    /// shell effects are unavailable (dropped).
    loop: ?*async_loop.Loop = null,
    /// The task pool interactive REPL sessions run on. Null = repl-start drops.
    pool: ?*Pool = null,
    /// Directory for the compiled-module (`.cwasm`) cache. Null = no caching
    /// (always compile fresh — the default, and what tests use). When set, a
    /// module is keyed by content hash: deserialize on a hit, else compile +
    /// serialize + persist. wasmtime validates engine/version on deserialize,
    /// so a stale image is rejected and recompiled safely.
    module_cache_dir: ?[]const u8 = null,
    /// north-star-plan §6 W4 slice 1 — the grant table this plugin's
    /// `describe()`-declared perms mint POSSESSED handles into (see
    /// `WasmPlugin.grant_table`/`grant_handles`). Null = no table (the
    /// pre-W4 default): `hasPerm` degrades to reading `perms` directly, and
    /// nothing about this plugin is revocable. A real `System` sets this to
    /// `&system.grants`.
    grant_table: ?*@import("../grants.zig").HandleTable = null,
};

/// Load a `.wasm` plugin under the perm handshake: bind the `weft.*` import
/// membrane, instantiate, run `describe()` (declarations only, no authority),
/// then `init()` (registrations, cross-checked). An undeclared registration
/// fails the load and rolls the partial plugin back — the same contract
/// abi.zig enforces in-process.
pub fn loadPlugin(engine: *wasm.Engine, ctx: *command.Context, name: []const u8, wasm_bytes: []const u8, opts: LoadOptions) !*WasmPlugin {
    // `construct` owns the pre-handshake resources via errdefer; once it
    // returns, `deinit` is the single owner of teardown. Keeping the two
    // phases in separate functions is what makes that clean: no errdefer in
    // this scope can double-free what `deinit` already released.
    const p = try construct(engine, ctx, name, opts, wasm_bytes);

    // describe(): declarations only (optional export — a guest with a static
    // manifest may skip it). Then [approval], then init(): registrations,
    // cross-checked against the declaration. `p.loading` (task #19 item 4,
    // `WasmPlugin.loading`'s doc) brackets BOTH — a head-gated import (e.g.
    // `weft.setMode` establishing the guest's starting mode, the pattern
    // every modal-editor guest's `init()` ends with) is legitimate here:
    // `active_ctx` is still the fresh load-time `ctx`, so there is no
    // second head to hijack yet. NOT a `defer`: every early-return path
    // below is through `failLoad`, which `deinit`s `p` — writing a field on
    // it AFTER that (what a `defer p.loading = false` would do, since
    // defers run after the deferred-from expression is evaluated) is a
    // use-after-free. Set back to `false` explicitly, only on the path
    // where `p` survives to be returned.
    p.loading = true;
    p.phase = .describing;
    contract.callOptionalExport("describe", &p.instance, .{}) catch |e| {
        if (e != error.MissingExport) return failLoad(p, e);
    };
    p.phase = .active;
    // north-star-plan §6 W4 slice 1: `perms` is final now (describe() has
    // run) — if a grant table is wired, mint this plugin's POSSESSED
    // handles from it before `init()` runs, so even init-time fs/proc/etc
    // calls already go through the revocable handle path (see
    // `wasm_host/plugin.zig`'s `mintGrantHandles`/`hasPerm`).
    if (p.grant_table) |table| wasm_host.mintGrantHandles(table, p.name, p.perms, &p.grant_handles);
    contract.callRequiredExport("init", &p.instance, .{}) catch |e| return failLoad(p, e);
    p.loading = false;
    if (p.load_error) |e| return failLoad(p, e);
    return p;
}

/// Compile `wasm_bytes`, using an on-disk `.cwasm` cache under `cache_dir` when
/// set. Keyed by content hash (auto-invalidates on any plugin/build change);
/// a stale image (different wasmtime) is rejected on deserialize and recompiled.
/// All cache I/O is best-effort — a miss or a failed read/write just costs a
/// fresh compile, never a load failure.
fn compileCached(engine: *wasm.Engine, gpa: Allocator, cache_dir: ?[]const u8, wasm_bytes: []const u8) !wasm.Module {
    const dir = cache_dir orelse return engine.compile(wasm_bytes);
    const hash = std.hash.Wyhash.hash(0, wasm_bytes);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{x}.cwasm", .{ dir, hash }) catch
        return engine.compile(wasm_bytes);
    if (file.readAlloc(gpa, path)) |image| {
        defer gpa.free(image);
        if (engine.deserialize(image)) |m| return m;
    } else |_| {}
    // Miss or stale: compile fresh, then persist the image for next start.
    var module = try engine.compile(wasm_bytes);
    if (module.serialize(gpa)) |image| {
        defer gpa.free(image);
        file.writeBytesMakingDirs(gpa, dir, path, image) catch {};
    } else |_| {}
    return module;
}

/// Build the plugin up through instantiation. Every step's errdefer frees
/// exactly what preceded it, and `p` is destroyed WITHOUT `deinit` on failure
/// — so no resource is released twice. On success the returned `p` is fully
/// constructed (instance live) with no pending errdefer.
fn construct(engine: *wasm.Engine, ctx: *command.Context, name: []const u8, opts: LoadOptions, wasm_bytes: []const u8) !*WasmPlugin {
    const gpa = ctx.gpa;
    const p = try gpa.create(WasmPlugin);
    errdefer gpa.destroy(p);
    const name_dup = try gpa.dupe(u8, name);
    errdefer gpa.free(name_dup);
    const semantic_owner = if (ctx.semantic) |services| try services.acquireOwner() else null;
    var module = try compileCached(engine, gpa, opts.module_cache_dir, wasm_bytes);
    errdefer module.deinit();
    var linker = try wasm.Linker.init(engine);
    errdefer linker.deinit();
    p.* = .{
        .gpa = gpa,
        .ctx = ctx,
        .active_ctx = ctx,
        .name = name_dup,
        .semantic_owner = semantic_owner,
        .store = opts.kv,
        .config_store = opts.config,
        .pool = opts.pool,
        .syntax_of = opts.syntax_of,
        .subbuffers = opts.subbuffers,
        .register = opts.register,
        .loop = opts.loop,
        .grant_table = opts.grant_table,
        .module = module,
        .linker = linker,
        .instance = undefined,
    };
    try wasm_host.defineImports(&p.linker, p);
    p.instance = try p.linker.instantiate(&p.module);
    p.semantic_fields = wasm_host.initSemanticFieldBridge(p);
    p.semantic_actions = wasm_host.initSemanticActionBridge(p);
    p.semantic_targets = wasm_host.initSemanticTargetBridge(p);
    return p;
}

/// Tear down a fully-constructed plugin and surface the load error. Only
/// called after `construct` succeeded, so `deinit` is the sole owner.
fn failLoad(p: *WasmPlugin, e: anyerror) anyerror {
    p.deinit();
    return e;
}
