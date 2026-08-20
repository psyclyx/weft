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
    h.ctx.edit(.{ .start = @intCast(args[0]), .end = @intCast(args[1]) }, bytes) catch {};
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
    try instance.callVoid("run", &.{});
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
    // cross-checked against the declaration.
    p.phase = .describing;
    p.instance.callVoid("describe", &.{}) catch |e| {
        if (e != error.MissingExport) return failLoad(p, e);
    };
    p.phase = .active;
    p.instance.callVoid("init", &.{}) catch |e| return failLoad(p, e);
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
    var module = try compileCached(engine, gpa, opts.module_cache_dir, wasm_bytes);
    errdefer module.deinit();
    var linker = try wasm.Linker.init(engine);
    errdefer linker.deinit();
    p.* = .{
        .gpa = gpa,
        .ctx = ctx,
        .name = name_dup,
        .store = opts.kv,
        .config_store = opts.config,
        .pool = opts.pool,
        .syntax_of = opts.syntax_of,
        .subbuffers = opts.subbuffers,
        .register = opts.register,
        .loop = opts.loop,
        .module = module,
        .linker = linker,
        .instance = undefined,
    };
    try wasm_host.defineImports(&p.linker, p);
    p.instance = try p.linker.instantiate(&p.module);
    return p;
}

/// Tear down a fully-constructed plugin and surface the load error. Only
/// called after `construct` succeeded, so `deinit` is the sole owner.
fn failLoad(p: *WasmPlugin, e: anyerror) anyerror {
    p.deinit();
    return e;
}
