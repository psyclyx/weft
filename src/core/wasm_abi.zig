//! wasm_abi — run a `.wasm` plugin against the weft ABI. The host defines the
//! `weft.*` functions the guest imports, marshalling each to
//! `command.Context`: `cursor` reads the caret; `edit` reads the guest's
//! bytes out of its linear memory and applies them through `Context.edit` —
//! the SAME grade gate, authored as the plugin's own peer. This is plan 05's
//! core: a plugin compiled to `.wasm` reaches the editor only across the
//! sandbox membrane, yet lands its edits on the identical authority path an
//! in-process catalog plugin uses. The full ABI (log/kv/layers/pick/…) marshals
//! the same way — one host function per import; this proves the shape.

const std = @import("std");
const wasm = @import("wasm.zig");
const command = @import("command.zig");
const Document = @import("Document.zig");
const position = @import("position.zig");

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

// ── Full lifecycle: a loaded wasm plugin under the perm handshake ─────
// The bidirectional membrane, the full ABI, and the manifest cross-check —
// the wasm mirror of abi.zig's in-process Host:
//   describe() → the guest declares its commands + perms (no authority) →
//   [host would prompt the user] → grants flip on → init() registers →
//   every register/effect is cross-checked against the declaration, an
//   undeclared one fails the load and rolls the partial plugin back.
// Commands the guest registers bind into the shared registry with a
// trampoline that dispatches BACK into the guest's `on_command` export; its
// edits land on the SAME grade gate an in-process catalog plugin uses,
// authored as the plugin's own peer. Every host import mirrors one abi.Abi
// method — the transport is wasm, the shape is unchanged.

const Allocator = std.mem.Allocator;
const kv = @import("kv.zig");
const capability = @import("capability.zig");
const pick_mod = @import("pick.zig");
const Buffers = @import("Buffers.zig");
const syntax = @import("syntax.zig");
const subbuffer = @import("subbuffer.zig");
const async_loop = @import("async.zig");
/// The host-import table + trampolines (the `weft.*` marshalling) live in a
/// sibling file to keep this one focused on the plugin lifecycle. They operate
/// on the `WasmPlugin` defined here; the two @import each other (Zig allows it).
const wasm_host = @import("wasm_host.zig");

/// Resolves a buffer's live tree-sitter `Syntax` (kept opaque in the shell's
/// `Buffer.frontend`) — the host provides this so the membrane can expose
/// structural reads without core learning the frontend's shape. Mirrors
/// abi.SyntaxResolver.
pub const SyntaxResolver = *const fn (buf: *Buffers.Buffer) ?*syntax.Syntax;

/// The guest-side `Perm` enum order (weft.zig): fs_read, fs_write, net, proc,
/// timer. Kept in lockstep with abi.Perm so a wasm plugin's declaration means
/// the same thing as an in-process one's.
pub const perm_count = 5;

pub const WasmCmd = struct { plugin: *WasmPlugin, id: u32, name: []u8 };

/// One accumulated pick item (owned) between `pickBegin` and `pickEnd`.
pub const PendingItem = struct { text: []u8, doc: []u8 };

/// An open pick's binding: which plugin + which of its picks (the guest's
/// `pick_id`, dispatched to `on_pick_accept`). Freed by the pick's cleanup.
pub const WasmBoundPick = struct { plugin: *WasmPlugin, pick_id: u32 };

const Phase = enum { describing, active };

/// A stamped range the guest holds by handle (index into `WasmPlugin.stamps`).
/// The slot owns `version` (the token the range is stamped against).
pub const StampSlot = struct { range: position.StampedRange, version: []u8 };

/// A materialized tree-sitter query capture the guest reads by index (design
/// §4 `syntax.query` — the tree stays host-side, captures cross). `name` owned.
pub const QueryCap = struct { name: []u8, start: usize, end: usize };

pub const WasmPlugin = struct {
    gpa: Allocator,
    ctx: *command.Context,
    name: []u8,
    store: ?*kv.Store,
    /// Host effect services the membrane forwards to (mirrors abi.Services).
    syntax_of: ?SyntaxResolver,
    subbuffers: ?*subbuffer.SubBuffers,
    loop: ?*async_loop.Loop,
    /// Subbuffers this plugin claimed, indexed by the handle the guest holds.
    /// Owned by the `subbuffers` service; we keep borrowed pointers only.
    subs: std.ArrayList(*subbuffer.SubBuffer) = .empty,
    module: wasm.Module,
    linker: wasm.Linker, // MUST outlive `instance` (owns the host-func boxes)
    instance: wasm.Instance,
    commands: std.ArrayList(*WasmCmd) = .empty,

    // ── Perm handshake state ──
    phase: Phase = .describing,
    /// Command names the guest declared during `describe()` (owned).
    declared: std.ArrayList([]u8) = .empty,
    /// Capability names the guest declared during `describe()` (owned).
    declared_caps: std.ArrayList([]u8) = .empty,
    perms: [perm_count]bool = @splat(false),
    /// A cross-check failure inside an import callback (which cannot itself
    /// abort instantiation): recorded here, checked after `init()` to fail
    /// the load and roll back.
    load_error: ?anyerror = null,

    // ── Command dispatch (args in, result out) ──
    /// The args of the command currently dispatching (valid only during an
    /// `on_command` call), readable by the guest through `wl_arg_*`.
    cur_args: []const command.Value = &.{},
    /// The result the guest set for the current command (via `wl_set_result_*`);
    /// returned to the caller of `command.run`. String results borrow
    /// `result_buf`, valid until the next dispatch (the same lifetime the
    /// in-process kv-backed commands give).
    result: command.Value = .nil,
    result_buf: std.ArrayList(u8) = .empty,

    /// Per-dispatch table of stamped ranges the guest names by `u32` handle
    /// ([FIX 1/3]): a motion stamps a range here and returns its handle, an
    /// operator receives one as an arg and applies an edit through it. The
    /// version token stays host-side (opaque-handle ABI, design §2) — only the
    /// handle crosses the membrane. Reset at the top of every command dispatch;
    /// each slot owns its version bytes.
    stamps: std.ArrayList(StampSlot) = .empty,

    /// The captures from the guest's most recent `syntax.query`, read back by
    /// index. Reset at the start of each query; each entry owns its name.
    query_caps: std.ArrayList(QueryCap) = .empty,

    // ── Pick (built incrementally between begin/end, then opened) ──
    pick_prompt: std.ArrayList(u8) = .empty,
    pick_id: u32 = 0,
    pick_items: std.ArrayList(PendingItem) = .empty,
    /// The accepted choice, valid only during an `on_pick_accept` call.
    cur_choice: []const u8 = &.{},

    // ── Completion provider (host→guest data-gather) ──
    /// The caps provider id this plugin registered (owned), torn down on
    /// unload. Null until it calls `provideCompletion`.
    provider_id: ?[]u8 = null,
    /// Transient state for the duration of one `on_complete` call: the
    /// request's prefix, and the sink the guest's `pushCompletion` fills.
    cur_prefix: []const u8 = &.{},
    completion_out: ?*std.ArrayList([]const u8) = null,

    /// Stamp `[start, end)` against the current document version and hand the
    /// guest an opaque handle into `stamps`. Takes ownership of `version_owned`
    /// (freed when the table is reset). Returns the handle.
    pub fn pushRange(self: *WasmPlugin, version_owned: []u8, start: usize, end: usize) !u32 {
        try self.stamps.append(self.gpa, .{
            .range = position.StampedRange.at(version_owned, start, end),
            .version = version_owned,
        });
        return @intCast(self.stamps.items.len - 1);
    }

    /// Reset the per-dispatch stamp table, freeing each slot's version token.
    pub fn stampsClear(self: *WasmPlugin) void {
        for (self.stamps.items) |s| self.gpa.free(s.version);
        self.stamps.clearRetainingCapacity();
    }

    /// Reset the query-capture buffer, freeing each capture's name.
    pub fn queryCapsClear(self: *WasmPlugin) void {
        for (self.query_caps.items) |q| self.gpa.free(q.name);
        self.query_caps.clearRetainingCapacity();
    }

    pub fn declaresCommand(self: *WasmPlugin, name: []const u8) bool {
        for (self.declared.items) |d| if (std.mem.eql(u8, d, name)) return true;
        return false;
    }

    pub fn declaresCapability(self: *WasmPlugin, name: []const u8) bool {
        for (self.declared_caps.items) |d| if (std.mem.eql(u8, d, name)) return true;
        return false;
    }

    /// This plugin as an edit principal: authors as its own peer on whatever
    /// document is active at edit time (resolved, never captured).
    pub fn principal(self: *WasmPlugin) command.Principal {
        return .{ .role = .plugin, .name = self.name, .ctx = self, .resolve = wasm_host.resolvePeerWp };
    }

    pub fn deinit(self: *WasmPlugin) void {
        const gpa = self.gpa;
        // Completion provider dies with the plugin (unregister before freeing
        // its id — the caps registry holds the id by reference).
        if (self.provider_id) |id| {
            self.ctx.caps.unregisterByIdPrefix(id);
            gpa.free(id);
        }
        for (self.commands.items) |wc| {
            if (self.ctx.commands.find(wc.name)) |n| {
                if (self.ctx.commands.lookup(n)) |cmd| {
                    if (cmd.data == @as(?*anyopaque, wc)) self.ctx.commands.unbind(n);
                }
            }
            gpa.free(wc.name);
            gpa.destroy(wc);
        }
        self.commands.deinit(gpa);
        self.stampsClear();
        self.stamps.deinit(gpa);
        self.queryCapsClear();
        self.query_caps.deinit(gpa);
        self.result_buf.deinit(gpa);
        self.pick_prompt.deinit(gpa);
        for (self.pick_items.items) |it| {
            gpa.free(it.text);
            gpa.free(it.doc);
        }
        self.pick_items.deinit(gpa);
        self.subs.deinit(gpa); // the SubBuffers service owns the entries
        for (self.declared.items) |d| gpa.free(d);
        self.declared.deinit(gpa);
        for (self.declared_caps.items) |d| gpa.free(d);
        self.declared_caps.deinit(gpa);
        self.instance.deinit();
        self.linker.deinit();
        self.module.deinit();
        gpa.free(self.name);
        gpa.destroy(self);
    }
};

pub const LoadOptions = struct {
    /// The kv store this plugin's Group-E admin calls persist into (namespaced
    /// by plugin name). Null = kv unavailable (kvGet→absent, kvPut→dropped).
    kv: ?*kv.Store = null,
    /// Resolves a buffer's grammar for `nodeAt`. Null = structural reads
    /// return "no node" (the honest degrade).
    syntax_of: ?SyntaxResolver = null,
    /// The subbuffer service `claimSubbuffer` claims into. Null = unavailable.
    subbuffers: ?*subbuffer.SubBuffers = null,
    /// The async loop `shellInsert` schedules its off-thread work on. Null =
    /// shell effects are unavailable (dropped).
    loop: ?*async_loop.Loop = null,
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
    var module = try engine.compile(wasm_bytes);
    errdefer module.deinit();
    var linker = try wasm.Linker.init(engine);
    errdefer linker.deinit();
    p.* = .{
        .gpa = gpa,
        .ctx = ctx,
        .name = name_dup,
        .store = opts.kv,
        .syntax_of = opts.syntax_of,
        .subbuffers = opts.subbuffers,
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

// ── Test ────────────────────────────────────────────────────────────

const t = std.testing;

test "wasm plugin: a .wasm guest edits the buffer through the host ABI, as its peer" {
    const gpa = t.allocator;
    const task = @import("task.zig");
    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var buffers = try @import("Buffers.zig").init(gpa, pool, "user");
    defer buffers.deinit(gpa);
    var commands: command.Commands = .empty;
    defer commands.deinit(gpa);
    var keymap: @import("Keymap.zig") = .empty;
    defer keymap.deinit(gpa);
    var pick: @import("pick.zig").Pick = .empty;
    defer pick.deinit(gpa);
    var caps = @import("capability.zig").Caps.init(gpa, task.nowNs);
    defer caps.deinit();
    var quit = false;
    var echo: std.ArrayList(u8) = .empty;
    defer echo.deinit(gpa);
    var ctx: command.Context = .{
        .gpa = gpa,
        .buffers = &buffers,
        .commands = &commands,
        .keymap = &keymap,
        .pick = &pick,
        .caps = &caps,
        .quit = &quit,
        .echo = &echo,
    };

    try buffers.active().editor.insertText(gpa, "ab");
    buffers.active().editor.placeCursor(1); // between 'a' and 'b'

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    try runGuest(&engine, &ctx, "wasm.hello", guest_hello);

    // The .wasm guest inserted "wasm!" at the cursor through the host edit.
    const s = try buffers.active().editor.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("awasm!b", s);
    // Authored as the wasm plugin's peer, not the user (the authority gate
    // holds across the membrane).
    const doc = &buffers.active().editor.doc;
    try t.expect(doc.commitAt(doc.commitCount() - 1).author != .user);
}

test "wasm plugin: init registers a command that dispatches back into the guest" {
    const gpa = t.allocator;
    const task = @import("task.zig");
    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var buffers = try @import("Buffers.zig").init(gpa, pool, "user");
    defer buffers.deinit(gpa);
    var commands: command.Commands = .empty;
    defer commands.deinit(gpa);
    var keymap: @import("Keymap.zig") = .empty;
    defer keymap.deinit(gpa);
    var pick: @import("pick.zig").Pick = .empty;
    defer pick.deinit(gpa);
    var caps = @import("capability.zig").Caps.init(gpa, task.nowNs);
    defer caps.deinit();
    var quit = false;
    var echo: std.ArrayList(u8) = .empty;
    defer echo.deinit(gpa);
    var ctx: command.Context = .{
        .gpa = gpa,
        .buffers = &buffers,
        .commands = &commands,
        .keymap = &keymap,
        .pick = &pick,
        .caps = &caps,
        .quit = &quit,
        .echo = &echo,
    };

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &ctx, "wasm.plugin", @embedFile("guest_plugin_wasm"), .{});
    defer plugin.deinit();

    // The guest's init() registered "wasm-mark" through the host.
    try t.expect(commands.resolve("wasm-mark") != null);

    // Running it dispatches back into the guest, which edits via the host
    // gate — authored as the plugin's peer, across the membrane.
    try buffers.active().editor.insertText(gpa, "xy");
    buffers.active().editor.placeCursor(1);
    _ = try command.run(&commands, &ctx, "wasm-mark", &.{});
    const s = try buffers.active().editor.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("x[wasm]y", s);
    const doc = &buffers.active().editor.doc;
    try t.expect(doc.commitAt(doc.commitCount() - 1).author != .user);
}

// A compact editor environment for the membrane tests below.
const Env = struct {
    pool: *@import("task.zig").Pool,
    buffers: @import("Buffers.zig"),
    commands: command.Commands,
    keymap: @import("Keymap.zig"),
    pick: @import("pick.zig").Pick,
    caps: @import("capability.zig").Caps,
    quit: bool,
    echo: std.ArrayList(u8),
    ctx: command.Context,

    fn init(gpa: Allocator, self: *Env) !void {
        const task = @import("task.zig");
        self.pool = try task.Pool.init(gpa, .{ .threads = 1 });
        self.buffers = try @import("Buffers.zig").init(gpa, self.pool, "user");
        self.commands = .empty;
        self.keymap = .empty;
        self.pick = .empty;
        self.caps = @import("capability.zig").Caps.init(gpa, task.nowNs);
        self.quit = false;
        self.echo = .empty;
        self.ctx = .{
            .gpa = gpa,
            .buffers = &self.buffers,
            .commands = &self.commands,
            .keymap = &self.keymap,
            .pick = &self.pick,
            .caps = &self.caps,
            .quit = &self.quit,
            .echo = &self.echo,
        };
    }
    fn deinit(self: *Env, gpa: Allocator) void {
        self.caps.deinit();
        self.pick.deinit(gpa);
        self.keymap.deinit(gpa);
        self.commands.deinit(gpa);
        self.echo.deinit(gpa);
        self.buffers.deinit(gpa);
        self.pool.deinit();
    }
};

test "wasm plugin: the edit catalog plugin runs identically as .wasm (duplicate-line)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "edit", @embedFile("guest_edit_wasm"), .{});
    defer plugin.deinit();

    // Both commands declared in describe() bound through the handshake.
    try t.expect(env.commands.resolve("duplicate-line") != null);
    try t.expect(env.commands.resolve("upcase-line") != null);

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "hello\nworld");
    ed.placeCursor(2); // inside the first line

    _ = try command.run(&env.commands, &env.ctx, "duplicate-line", &.{});
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    // Same result the in-process edit.zig produces: the line copied below.
    try t.expectEqualStrings("hello\nhello\nworld", s);
    // Authored as the plugin's peer, across the membrane, through the gate.
    try t.expect(ed.doc.commitAt(ed.doc.commitCount() - 1).author != .user);
}

test "wasm plugin: upcase-line edits in place across the membrane" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "edit", @embedFile("guest_edit_wasm"), .{});
    defer plugin.deinit();

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "abc\ndef");
    ed.placeCursor(5); // inside "def"
    _ = try command.run(&env.commands, &env.ctx, "upcase-line", &.{});
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("abc\nDEF", s);
}

test "wasm plugin: an undeclared registration fails the load (perm handshake)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    // The guest registers a command it never declared — the cross-check must
    // reject it and roll back, exactly as abi.zig does in-process.
    try t.expectError(error.UndeclaredCommand, loadPlugin(&engine, &env.ctx, "rogue", @embedFile("guest_rogue_wasm"), .{}));
    // Nothing left behind: neither the declared nor the undeclared name bound.
    try t.expect(env.commands.resolve("undeclared") == null);
    try t.expect(env.commands.resolve("declared") == null);
}

test "wasm plugin: hot-reload — teardown unbinds, re-instantiation is clean" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "x");
    ed.placeCursor(0);

    // Load, use, then tear down (the hot-reload's unload half): the command
    // must unbind and the store drop with no residue.
    {
        const v1 = try loadPlugin(&engine, &env.ctx, "edit", @embedFile("guest_edit_wasm"), .{});
        _ = try command.run(&env.commands, &env.ctx, "duplicate-line", &.{});
        v1.deinit();
        // After teardown the command is gone — nothing dangles behind it.
        try t.expect(env.commands.resolve("duplicate-line") == null);
    }

    // Re-instantiate from scratch (a fresh store, no shared mutable state):
    // the same source loads and runs identically — the reload contract.
    {
        const v2 = try loadPlugin(&engine, &env.ctx, "edit", @embedFile("guest_edit_wasm"), .{});
        defer v2.deinit();
        try t.expect(env.commands.resolve("duplicate-line") != null);
        ed.placeCursor(0);
        _ = try command.run(&env.commands, &env.ctx, "duplicate-line", &.{});
    }
    // Two duplications of "x" across two independent instances: "x\nx\nx".
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("x\nx\nx", s);
}

test "wasm plugin: a completion provider gathers candidates across the membrane" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "complete", @embedFile("guest_complete_wasm"), .{});
    defer plugin.deinit();

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "alpha alphabet beta alpha");

    // Fire a completion for prefix "alph": the host calls the guest's
    // on_complete, which scans the buffer and pushes matches back. Same
    // result the in-process complete.zig gives: {alpha, alphabet}, deduped.
    const sid = (try env.caps.fire(.completion, &ed.doc, ed.backingPath(), .{ .text = "alph" })).?;
    const session = env.caps.session(sid).?;
    var found: std.ArrayList([]const u8) = .empty;
    defer found.deinit(gpa);
    for (session.all()) |r| {
        if (r.payload != .completion) continue;
        for (r.payload.completion) |item| try found.append(gpa, item.text);
    }
    try t.expectEqual(@as(usize, 2), found.items.len);
    var has_alpha = false;
    var has_alphabet = false;
    for (found.items) |w| {
        if (std.mem.eql(u8, w, "alpha")) has_alpha = true;
        if (std.mem.eql(u8, w, "alphabet")) has_alphabet = true;
    }
    try t.expect(has_alpha and has_alphabet);
}

test "wasm plugin: demo-config composes commands + binds a key (config surface)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    // Load the edit plugin (provides duplicate-line/upcase-line) then the
    // config that composes them — the same layering as std + user config.
    const edit = try loadPlugin(&engine, &env.ctx, "edit", @embedFile("guest_edit_wasm"), .{});
    defer edit.deinit();
    const cfg = try loadPlugin(&engine, &env.ctx, "demo-config", @embedFile("guest_demo_config_wasm"), .{});
    defer cfg.deinit();

    // init() bound C-d → dup-up through the config surface.
    try env.keymap.setMode(gpa, "default");
    try t.expectEqualStrings("dup-up", env.keymap.lookup("C-d").?);

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "ab");
    ed.placeCursor(0);
    _ = try command.run(&env.commands, &env.ctx, "dup-up", &.{});
    // dup-up ran duplicate-line ("ab\nab") then upcase-line on the current
    // line (cursor still at 0 → the first line) across the membrane.
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("AB\nab", s);
}

test "wasm plugin: project command args/result + kv cross the membrane" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var store: kv.Store = .empty;
    defer store.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "project", @embedFile("guest_project_wasm"), .{ .kv = &store });
    defer plugin.deinit();

    // Seed the recent list host-side (namespaced to the plugin); the guest
    // reads it back through kv and returns it as a string result.
    try store.put(gpa, "project", "recent", "a.zig\nb.zig");
    const r = try command.run(&env.commands, &env.ctx, "project-recent", &.{});
    try t.expectEqualStrings("a.zig\nb.zig", r.string);

    // The scratch buffer has no backing path → remember returns -1 (the
    // integer result crosses the membrane).
    const r2 = try command.run(&env.commands, &env.ctx, "project-remember", &.{});
    try t.expectEqual(command.Value{ .integer = -1 }, r2);
}

test "wasm plugin: palette status echoes the active buffer (introspection)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "std", @embedFile("guest_palette_wasm"), .{});
    defer plugin.deinit();

    // status walks the buffers (bufferCount/bufferAt) and echoes the active
    // one's name — the whole introspection surface across the membrane.
    _ = try command.run(&env.commands, &env.ctx, "status", &.{});
    try t.expectEqualStrings(env.buffers.active().name, env.echo.items);
}

test "wasm plugin: palette opens a command pick; accept dispatches back and runs the choice" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    // The pick UI is ordinary commands in the "pick" keymap mode.
    try pick_mod.install(gpa, &env.commands, &env.keymap);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "std", @embedFile("guest_palette_wasm"), .{});
    defer plugin.deinit();

    // pick-commands builds a pick over the whole registry and opens it.
    _ = try command.run(&env.commands, &env.ctx, "pick-commands", &.{});
    try t.expect(env.pick.active);

    // Narrow to "status" and accept: the accept crosses back into the guest's
    // on_pick_accept, which runs the chosen command — which echoes the buffer.
    _ = try command.run(&env.commands, &env.ctx, "pick-input", &.{.{ .string = "status" }});
    _ = try command.run(&env.commands, &env.ctx, "pick-accept", &.{});
    try t.expect(!env.pick.active); // accept closed the pick
    try t.expectEqualStrings(env.buffers.active().name, env.echo.items);
}

test "wasm plugins: consult-line jumps to the accepted row by its add index" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    try @import("pick.zig").install(gpa, &env.commands, &env.keymap);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "consult", @embedFile("guest_consult_wasm"), .{});
    defer plugin.deinit();

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "aaa\nbbb\nccc");
    ed.placeCursor(0);

    // Open the line pick, narrow to the third line, accept: the guest resolves
    // the accepted ROW INDEX (2) to the offset it recorded, jumping to line 3.
    _ = try command.run(&env.commands, &env.ctx, "consult-line", &.{});
    try t.expect(env.pick.active);
    _ = try command.run(&env.commands, &env.ctx, "pick-input", &.{.{ .string = "ccc" }});
    _ = try command.run(&env.commands, &env.ctx, "pick-accept", &.{});
    try t.expect(!env.pick.active);
    try t.expectEqual(@as(usize, 8), ed.cursorOffset()); // start of "ccc"
}

test "wasm plugins: consult-imenu picks a definition and jumps to it" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    try @import("pick.zig").install(gpa, &env.commands, &env.keymap);

    const src = "fn foo() void {}\nfn bar() void {}";
    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, src);
    const sx = @import("syntax.zig");
    const syn = try sx.Syntax.create(gpa, sx.forPath("t.zig").?, &ed.doc);
    defer syn.destroy();
    env.buffers.active().frontend = syn;
    const R = struct {
        fn resolve(buf: *@import("Buffers.zig").Buffer) ?*sx.Syntax {
            return @ptrCast(@alignCast(buf.frontend orelse return null));
        }
    };

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "consult", @embedFile("guest_consult_wasm"), .{ .syntax_of = R.resolve });
    defer plugin.deinit();

    ed.placeCursor(0);
    _ = try command.run(&env.commands, &env.ctx, "consult-imenu", &.{});
    try t.expect(env.pick.active);
    _ = try command.run(&env.commands, &env.ctx, "pick-input", &.{.{ .string = "bar" }});
    _ = try command.run(&env.commands, &env.ctx, "pick-accept", &.{});
    try t.expectEqual(std.mem.indexOf(u8, src, "fn bar").?, ed.cursorOffset());
}

test "wasm plugin: structural node-kind/delete-node degrade honestly with no grammar" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    // No syntax service wired → nodeAt reports "no node" across the membrane.
    const plugin = try loadPlugin(&engine, &env.ctx, "structural", @embedFile("guest_structural_wasm"), .{});
    defer plugin.deinit();

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "foo");
    const r1 = try command.run(&env.commands, &env.ctx, "node-kind", &.{});
    try t.expect(r1 == .nil); // no grammar → nil
    const r2 = try command.run(&env.commands, &env.ctx, "delete-node", &.{});
    try t.expectEqual(command.Value{ .integer = 0 }, r2);
    try t.expect(ed.text().byteLen() == 3); // nothing deleted
}

test "wasm plugin: ts expands selection to the enclosing node + runs a query" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    const src = "const x = 42;";
    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, src);

    // Attach a real zig grammar via the buffer's frontend slot; a resolver hands
    // it to the membrane (the host owns that slot).
    const sx = @import("syntax.zig");
    const syn = try sx.Syntax.create(gpa, sx.forPath("t.zig").?, &ed.doc);
    defer syn.destroy();
    env.buffers.active().frontend = syn;
    const R = struct {
        fn resolve(buf: *@import("Buffers.zig").Buffer) ?*sx.Syntax {
            return @ptrCast(@alignCast(buf.frontend orelse return null));
        }
    };

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "ts", @embedFile("guest_ts_wasm"), .{ .syntax_of = R.resolve });
    defer plugin.deinit();

    // Cursor on "42": select-node selects the literal; expand grows to a
    // strictly larger enclosing node (design §6.2, via native syntax reads).
    ed.placeCursor(std.mem.indexOf(u8, src, "42").?);
    _ = try command.run(&env.commands, &env.ctx, "ts-select-node", &.{});
    const leaf = ed.selectedRange().?;
    _ = try command.run(&env.commands, &env.ctx, "ts-expand-selection", &.{});
    const parent = ed.selectedRange().?;
    try t.expect(parent.end - parent.start > leaf.end - leaf.start);

    // A query over the buffer materializes captures across the membrane: the
    // identifier "x" is found (>= 1 capture).
    const n = try command.run(&env.commands, &env.ctx, "ts-query", &.{.{ .string = "(identifier) @i" }});
    try t.expect(n == .integer and n.integer >= 1);
}

test "wasm plugins: a tree text object (a-function) an operator deletes (daf)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    const src = "fn foo() void {}\nconst x = 1;";
    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, src);

    const sx = @import("syntax.zig");
    const syn = try sx.Syntax.create(gpa, sx.forPath("t.zig").?, &ed.doc);
    defer syn.destroy();
    env.buffers.active().frontend = syn;
    const R = struct {
        fn resolve(buf: *@import("Buffers.zig").Buffer) ?*sx.Syntax {
            return @ptrCast(@alignCast(buf.frontend orelse return null));
        }
    };

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const textobjects = try loadPlugin(&engine, &env.ctx, "textobjects", @embedFile("guest_textobjects_wasm"), .{ .syntax_of = R.resolve });
    defer textobjects.deinit();
    const operators = try loadPlugin(&engine, &env.ctx, "operators", @embedFile("guest_operators_wasm"), .{ .syntax_of = R.resolve });
    defer operators.deinit();

    // Cursor inside the function; a-function selects the whole function node,
    // the operator deletes it — a tree object composed with the SAME operator.
    ed.placeCursor(std.mem.indexOf(u8, src, "foo").?);
    const rv = try command.run(&env.commands, &env.ctx, "textobj.a-function", &.{});
    try t.expect(rv == .range);
    _ = try command.run(&env.commands, &env.ctx, "op.delete", &.{rv});
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expect(std.mem.indexOf(u8, s, "foo") == null); // the function is gone
    try t.expect(std.mem.indexOf(u8, s, "const x") != null); // the rest remains
}

test "wasm plugin: region claims a subbuffer + attaches a fact across the membrane" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var subs: subbuffer.SubBuffers = .empty;
    defer subs.deinit(gpa); // frees the claimed entries (runs after plugin.deinit)

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "region", @embedFile("guest_region_wasm"), .{ .subbuffers = &subs });
    defer plugin.deinit();

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "line one\nline two");
    ed.placeCursor(2); // inside the first line ("line one" — 8 bytes)

    const r = try command.run(&env.commands, &env.ctx, "mark-region", &.{.{ .string = "js" }});
    try t.expectEqual(command.Value{ .integer = 8 }, r);
    // The claimed subbuffer (handle 0) carries the language fact the guest set.
    try t.expectEqualStrings("js", plugin.subs.items[0].fact("language").?);
}

test "wasm plugin: shell insert-shell runs a command off-thread and inserts, rebased" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var loop = async_loop.Loop.init(gpa, env.pool, @import("task.zig").nowNs);
    defer loop.deinit();

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "shell", @embedFile("guest_shell_wasm"), .{ .loop = &loop });
    defer plugin.deinit();

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "X");
    ed.placeCursor(1); // capture the insert point at offset 1

    _ = try command.run(&env.commands, &env.ctx, "insert-shell", &.{.{ .string = "printf hi" }});

    // Concurrently insert at the head: the deferred insert's stamped offset
    // (1) must rebase to 3 before "hi" lands.
    ed.placeCursor(0);
    try ed.insertText(gpa, "YY"); // doc → "YYX"

    var rounds: usize = 0;
    while (ed.text().byteLen() < 5 and rounds < 5_000_000) : (rounds += 1) {
        _ = loop.tick();
        std.Thread.yield() catch {};
    }
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    // "hi" landed at the REBASED offset 3 (after "YYX"), authored as the peer.
    try t.expectEqualStrings("YYXhi", s);
    try t.expect(ed.doc.commitAt(ed.doc.commitCount() - 1).author != .user);
}

test "wasm plugin: shell insert is a no-op when the async service is absent" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    // No loop wired: the shell plugin declared proc+timer, but with no async
    // service the effect drops honestly (no ghost edit).
    const plugin = try loadPlugin(&engine, &env.ctx, "shell", @embedFile("guest_shell_wasm"), .{});
    defer plugin.deinit();
    try t.expect(plugin.perms[wasm_host.perm_proc] and plugin.perms[wasm_host.perm_timer]); // declared

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "Z");
    _ = try command.run(&env.commands, &env.ctx, "insert-shell", &.{.{ .string = "printf hi" }});
    try t.expect(ed.text().byteLen() == 1); // nothing inserted
}

test "wasm plugin: git-status runs git into a focused tool buffer (async)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    try @import("builtins.zig").install(gpa, &env.commands, &env.keymap); // buffer-create

    var loop = async_loop.Loop.init(gpa, env.pool, @import("task.zig").nowNs);
    defer loop.deinit();

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "git", @embedFile("guest_git_wasm"), .{ .loop = &loop });
    defer plugin.deinit();
    try t.expect(plugin.perms[wasm_host.perm_proc] and plugin.perms[wasm_host.perm_timer]);

    _ = try command.run(&env.commands, &env.ctx, "git-status", &.{});
    // The tool buffer was created + focused synchronously (before any output).
    const buf = blk: {
        var it = env.buffers.iterator();
        while (it.next()) |b| if (std.mem.eql(u8, b.name, "*git-status*")) break :blk b;
        break :blk null;
    };
    try t.expect(buf != null);

    // Drive the async loop until git's output lands (bounded; this repo is a
    // git checkout). If git is unavailable the buffer stays empty — the
    // structural checks above still hold.
    var rounds: usize = 0;
    while (rounds < 20_000_000 and buf.?.editor.text().byteLen() == 0) : (rounds += 1) {
        _ = loop.tick();
        std.Thread.yield() catch {};
    }
    if (buf.?.editor.text().byteLen() > 0) {
        const s = try buf.?.editor.text().toOwnedSlice(gpa);
        defer gpa.free(s);
        try t.expect(std.mem.indexOfScalar(u8, s, '#') != null); // "## <branch>"
        const doc = &buf.?.editor.doc;
        try t.expect(doc.commitAt(doc.commitCount() - 1).author != .user); // the plugin peer
    }
}

test "wasm plugin: run-command runs a shell command into a tool buffer (async)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    try @import("builtins.zig").install(gpa, &env.commands, &env.keymap);

    var loop = async_loop.Loop.init(gpa, env.pool, @import("task.zig").nowNs);
    defer loop.deinit();
    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "run", @embedFile("guest_run_wasm"), .{ .loop = &loop });
    defer plugin.deinit();

    // A deterministic command (echo) — proves the proc→buffer path end to end.
    _ = try command.run(&env.commands, &env.ctx, "run-command", &.{.{ .string = "echo weft-ok" }});
    const buf = blk: {
        var it = env.buffers.iterator();
        while (it.next()) |b| if (std.mem.eql(u8, b.name, "*output*")) break :blk b;
        break :blk null;
    };
    try t.expect(buf != null);
    var rounds: usize = 0;
    while (rounds < 20_000_000 and buf.?.editor.text().byteLen() == 0) : (rounds += 1) {
        _ = loop.tick();
        std.Thread.yield() catch {};
    }
    const s = try buf.?.editor.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("weft-ok", s); // stdout, trailing newline trimmed
    const doc = &buf.?.editor.doc;
    try t.expect(doc.commitAt(doc.commitCount() - 1).author != .user); // the plugin peer
}

test "wasm plugin: vim wires the modal keymap and runs motions/operators as .wasm" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "vim", @embedFile("guest_vim_wasm"), .{});
    defer plugin.deinit();

    // init() booted into normal and wired the whole keymap through the config
    // surface — motions, operators, insert entries — all across the membrane.
    try t.expectEqualStrings("normal", env.keymap.currentMode());
    try t.expectEqualStrings("vim-insert", env.keymap.lookup("i").?);
    try t.expectEqualStrings("enter-op-delete", env.keymap.lookup("d").?);

    // Mode switches: i → insert, Escape (vim-normal) → normal.
    _ = try command.run(&env.commands, &env.ctx, "vim-insert", &.{});
    try t.expectEqualStrings("insert", env.keymap.currentMode());
    _ = try command.run(&env.commands, &env.ctx, "vim-normal", &.{});
    try t.expectEqualStrings("normal", env.keymap.currentMode());

    // yank-line + paste duplicates the current line (register is guest state).
    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "hello");
    ed.placeCursor(0);
    _ = try command.run(&env.commands, &env.ctx, "yank-line", &.{});
    _ = try command.run(&env.commands, &env.ctx, "paste", &.{});
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("hello\nhello", s);
    try t.expect(ed.doc.commitAt(ed.doc.commitCount() - 1).author != .user);
}

test "wasm plugins: a motion returns a range an operator awaits + applies (dw)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const motions = try loadPlugin(&engine, &env.ctx, "motions", @embedFile("guest_motions_wasm"), .{});
    defer motions.deinit();
    const operators = try loadPlugin(&engine, &env.ctx, "operators", @embedFile("guest_operators_wasm"), .{});
    defer operators.deinit();

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "foo bar");
    ed.placeCursor(0);

    // The motion returns a version-stamped RANGE Value across the membrane —
    // never a bare offset. Cursor is one end (0), the target the other (4).
    const rv = try command.run(&env.commands, &env.ctx, "motion.word-fwd", &.{});
    try t.expect(rv == .range);

    // The operator awaits that range (as its arg) and applies the gated edit —
    // authored as the operators plugin's peer, not the user.
    _ = try command.run(&env.commands, &env.ctx, "op.delete", &.{rv});
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("bar", s);
    try t.expect(ed.doc.commitAt(ed.doc.commitCount() - 1).author != .user);
}

test "wasm plugins: an awaited range rebases through a concurrent edit" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const motions = try loadPlugin(&engine, &env.ctx, "motions", @embedFile("guest_motions_wasm"), .{});
    defer motions.deinit();
    const operators = try loadPlugin(&engine, &env.ctx, "operators", @embedFile("guest_operators_wasm"), .{});
    defer operators.deinit();

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "foo bar");
    ed.placeCursor(0);

    // Compute a word-forward range [0,4) stamped at the current version.
    const rv = try command.run(&env.commands, &env.ctx, "motion.word-fwd", &.{});
    try t.expect(rv == .range);

    // A concurrent edit lands BEFORE the operator applies: insert "XX" at 0.
    // The stamped range must rebase to [2,6) — "Buffer changed" is inexpressible.
    ed.placeCursor(0);
    try ed.insertText(gpa, "XX");

    _ = try command.run(&env.commands, &env.ctx, "op.delete", &.{rv});
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("XXbar", s); // "foo " deleted at its rebased site
}

test "wasm plugins: vim composes motions + operators — dw through the keymap" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const motions = try loadPlugin(&engine, &env.ctx, "motions", @embedFile("guest_motions_wasm"), .{});
    defer motions.deinit();
    const operators = try loadPlugin(&engine, &env.ctx, "operators", @embedFile("guest_operators_wasm"), .{});
    defer operators.deinit();
    const vim = try loadPlugin(&engine, &env.ctx, "vim", @embedFile("guest_vim_wasm"), .{});
    defer vim.deinit();

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "foo bar");
    ed.placeCursor(0);

    // `d` enters operator-pending; the `w` binding there is vim's op wrapper,
    // which runs motion.word-fwd and hands its range to op.delete.
    _ = try command.run(&env.commands, &env.ctx, "enter-op-delete", &.{});
    try t.expectEqualStrings("op-pending", env.keymap.currentMode());
    try t.expectEqualStrings("vim/o/motion.word-fwd", env.keymap.lookup("w").?);
    _ = try command.run(&env.commands, &env.ctx, env.keymap.lookup("w").?, &.{});
    try t.expectEqualStrings("normal", env.keymap.currentMode());

    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("bar", s);
}

test "wasm plugins: a text object returns a range an operator applies (di\")" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const textobjects = try loadPlugin(&engine, &env.ctx, "textobjects", @embedFile("guest_textobjects_wasm"), .{});
    defer textobjects.deinit();
    const operators = try loadPlugin(&engine, &env.ctx, "operators", @embedFile("guest_operators_wasm"), .{});
    defer operators.deinit();

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "say \"hi\" ok");
    ed.placeCursor(5); // inside the quotes

    // inner-quote-double yields the span between the quotes ("hi"); the operator
    // deletes it — the range is absolute (the construct), not cursor-relative.
    const rv = try command.run(&env.commands, &env.ctx, "textobj.inner-quote-double", &.{});
    try t.expect(rv == .range);
    _ = try command.run(&env.commands, &env.ctx, "op.delete", &.{rv});
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("say \"\" ok", s);
}

test "wasm plugins: vim di( through the keymap (operator + text object)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const textobjects = try loadPlugin(&engine, &env.ctx, "textobjects", @embedFile("guest_textobjects_wasm"), .{});
    defer textobjects.deinit();
    const operators = try loadPlugin(&engine, &env.ctx, "operators", @embedFile("guest_operators_wasm"), .{});
    defer operators.deinit();
    const vim = try loadPlugin(&engine, &env.ctx, "vim", @embedFile("guest_vim_wasm"), .{});
    defer vim.deinit();

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "f(a, b)");
    ed.placeCursor(4); // inside the parens

    // di( : d → op-pending, i → op-to (inner), ( → the paren object.
    _ = try command.run(&env.commands, &env.ctx, "enter-op-delete", &.{});
    _ = try command.run(&env.commands, &env.ctx, env.keymap.lookup("i").?, &.{});
    try t.expectEqualStrings("op-to", env.keymap.currentMode());
    _ = try command.run(&env.commands, &env.ctx, env.keymap.lookup("parenleft").?, &.{});
    try t.expectEqualStrings("normal", env.keymap.currentMode());

    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("f()", s);
}

test "wasm plugins: a view-grade peer's op.delete refuses (zero permission code)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const motions = try loadPlugin(&engine, &env.ctx, "motions", @embedFile("guest_motions_wasm"), .{});
    defer motions.deinit();
    const operators = try loadPlugin(&engine, &env.ctx, "operators", @embedFile("guest_operators_wasm"), .{});
    defer operators.deinit();

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "foo bar");
    ed.placeCursor(0);
    ed.doc.my_grant = .view; // the document is read-only for us

    // The motion (read-only) still computes a range — reads are never gated.
    const rv = try command.run(&env.commands, &env.ctx, "motion.word-fwd", &.{});
    try t.expect(rv == .range);
    // But the operator's edit dies at the gate: the buffer is unchanged, and no
    // ghost commit was authored.
    const before = ed.doc.commitCount();
    _ = try command.run(&env.commands, &env.ctx, "op.delete", &.{rv});
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("foo bar", s);
    try t.expectEqual(before, ed.doc.commitCount());
}

test "wasm plugin: comment toggles a line comment, preserving indent" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "comment", @embedFile("guest_comment_wasm"), .{});
    defer plugin.deinit();

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "  hi");
    ed.placeCursor(4);
    _ = try command.run(&env.commands, &env.ctx, "comment-line", &.{});
    {
        const s = try ed.text().toOwnedSlice(gpa);
        defer gpa.free(s);
        try t.expectEqualStrings("  // hi", s);
    }
    _ = try command.run(&env.commands, &env.ctx, "comment-line", &.{});
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("  hi", s);
}

test "wasm plugin: whitespace trims trailing spaces on the line" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "whitespace", @embedFile("guest_whitespace_wasm"), .{});
    defer plugin.deinit();

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "hi   \nok");
    ed.placeCursor(0);
    _ = try command.run(&env.commands, &env.ctx, "trim-trailing-line", &.{});
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("hi\nok", s);
}

test "wasm plugin: numbers increments the integer under the cursor" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "numbers", @embedFile("guest_numbers_wasm"), .{});
    defer plugin.deinit();

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "x 41 y");
    ed.placeCursor(2); // on the '4'
    _ = try command.run(&env.commands, &env.ctx, "increment-number", &.{});
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("x 42 y", s);
}

test "wasm plugin: autopair inserts a matched pair around the cursor" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "autopair", @embedFile("guest_autopair_wasm"), .{});
    defer plugin.deinit();

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "ab");
    ed.placeCursor(0);
    _ = try command.run(&env.commands, &env.ctx, "pair-paren", &.{});
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("()ab", s);
    try t.expectEqual(@as(usize, 1), ed.cursorOffset());
}

test "wasm plugin: notes capture appends via fs and open reads it back" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    try @import("builtins.zig").install(gpa, &env.commands, &env.keymap); // buffer-create

    const tmp = "weft-notes-test.md"; // cwd-relative; cleaned up below
    const file = @import("file.zig");
    file.deleteFile(gpa, tmp);
    defer file.deleteFile(gpa, tmp);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "notes", @embedFile("guest_notes_wasm"), .{});
    defer plugin.deinit();
    try t.expect(plugin.perms[wasm_host.perm_fs_read] and plugin.perms[wasm_host.perm_fs_write]);

    // Two captures append to the file; open reads it into *notes*.
    _ = try command.run(&env.commands, &env.ctx, "notes-capture", &.{ .{ .string = "todo x" }, .{ .string = tmp } });
    _ = try command.run(&env.commands, &env.ctx, "notes-capture", &.{ .{ .string = "todo y" }, .{ .string = tmp } });
    _ = try command.run(&env.commands, &env.ctx, "notes-open", &.{.{ .string = tmp }});

    const buf = blk: {
        var it = env.buffers.iterator();
        while (it.next()) |b| if (std.mem.eql(u8, b.name, "*notes*")) break :blk b;
        break :blk null;
    };
    try t.expect(buf != null);
    const s = try buf.?.editor.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("todo x\ntodo y\n", s);
}

test "wasm plugin: kv admin round-trips across the membrane, namespaced" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var store: kv.Store = .empty;
    defer store.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "edit", @embedFile("guest_edit_wasm"), .{ .kv = &store });
    defer plugin.deinit();
    // The host wired the kv service; a value put under this plugin is
    // namespaced to its name (proven directly through the store).
    try store.put(gpa, "edit", "k", "v");
    try t.expectEqualStrings("v", store.get("edit", "k").?);
    try t.expectEqual(@as(?[]const u8, null), store.get("other", "k"));
}

test {
    std.testing.refAllDecls(@This());
}
