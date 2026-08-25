//! InProcClient — the in-process transport's client identity (W0b,
//! doc/north-star-plan.md §2.5/§2.7): the native counterpart to
//! `wasm_abi/WasmPlugin.zig`'s identity fields, minus the wasm instance and
//! the guest-marshalling handle tables (ranges/query_caps/pick items/...) —
//! an in-process client holds real Zig pointers/slices directly, so it never
//! needs an opaque handle into a table the way a sandboxed guest does (see
//! this file's "what's deliberately NOT here" section).
//!
//! Two first-party clients hold one of these: `app/window_head.zig`'s
//! WindowHead (first-party, all perms granted under its named `head/attach`
//! identity — see that file) and `e2e`'s TestHead (the second head
//! implementation W0b's gate asks for).
//!
//! ## Why `anytype`, not a shared base struct
//!
//! `wasm_host/plugin.zig`'s `hasPerm`/`canDispatch` (the ONE grant-check and
//! ONE dispatch-check both transports share — see that file) are `anytype`
//! over a duck-typed field shape (`perms`/`in_dispatch`/`loading`/`name`),
//! not over a nominal `*ClientIdentity` type WasmPlugin and InProcClient
//! both embed. This was a judgment call (task W0b item 2 offered either
//! shape): embedding a shared struct into `WasmPlugin` means relocating
//! `name`/`perms`/`active_ctx`/`in_dispatch`/`loading` off its top-level
//! fields into `p.identity.name` etc — a mechanical but WIDE rename across
//! every `wasm_host/*.zig` file that reads them today (dozens of call
//! sites, `WasmPlugin.zig` itself, `wasm_abi/runtime.zig`'s load/dispatch
//! trampolines). `anytype` gets the SAME "one function, no drift" property
//! (the compiler still enforces the shape at every call site — a typo'd
//! field name on either struct fails to COMPILE the guard call, exactly
//! like a nominal interface would) while keeping this a genuinely small,
//! reviewable diff on the wasm side. This mirrors a convention already
//! established in this codebase for the same reason: `platform/platform.zig`'s
//! `assertPlatform` is a comptime duck-typed decl set, not a vtable or a
//! shared base type — `assertClientIdentity` below is the identical move one layer down (a
//! shared FIELD shape instead of a shared DECL shape).
//!
//! ## what's deliberately NOT here
//!
//! - No wasm `Module`/`Linker`/`Instance` — there is no guest to sandbox
//!   (C17: structure against MISTAKES on both transports; malice is
//!   wasm-only — an in-process client is trusted, first-party code).
//! - No handle tables (`ranges`, `query_caps`, pick items, sessions,
//!   proc_streams, the caps-provider builder) — those exist ONLY because a
//!   wasm guest cannot hold a real pointer across the membrane and must name
//!   host state by an opaque `u32`. An in-process client holds real `*Foo`/
//!   `[]const u8` values directly; minting a handle for its own use would be
//!   pure overhead. (A future semantic body that TAKES a handle — e.g. a
//!   anchored range from `wl_anchor_range` — would still need a table if an
//!   in-process client wants to call THAT specific import; none of the
//!   split imports today do, so this is deferred, not solved — see
//!   doc/north-star-plan.md's W0b report for the honest coverage note.)
//! - No `author_override`/agent sub-peer machinery — an in-process client
//!   that wants a distinct edit identity sets `Principal` directly (already
//!   general enough, see `command.Principal`/`authority.zig`); it doesn't
//!   need the transient-override dance `wl_edit_as` uses to cross the
//!   membrane one call at a time.
//! - No real capture-time GRANT machinery — `perms` here is declared once at
//!   construction (self-granted by a first-party client, named in the diff
//!   — the honest "no UNNAMED authority" framing of §2.4), not resolved
//!   against a manifest's `GrantDecl`s at Ctx-capture time. That mechanism
//!   is W4; this struct's SHAPE is what W4 will populate, not a stand-in
//!   implementation of it.

const std = @import("std");
const command = @import("../command.zig");
const fs_impl = @import("../wasm_host/fs.zig");
const keymap_impl = @import("../wasm_host/keymap.zig");
const wasm_host_plugin = @import("../wasm_host/plugin.zig");
const WasmPlugin = @import("../wasm_abi/WasmPlugin.zig");
const grants_mod = @import("../grants.zig");

/// The guest-side `Perm` enum order (`WasmPlugin.perm_count`'s doc: fs_read,
/// fs_write, net, proc, timer) — an in-process client's `perms` array is the
/// SAME length/order, so `wasm_host/plugin.zig`'s `hasPerm`/`canDispatch`
/// (indexed by `Perm`'s ordinal) read either identity's array identically.
pub const perm_count = WasmPlugin.perm_count;
pub const Perm = wasm_host_plugin.Perm;

pub const InProcClient = struct {
    /// This client's name — trap/error messages and edit-authorship both
    /// name it, exactly like `WasmPlugin.name`.
    name: []const u8,
    /// Declared grants — see this file's module doc, "no real capture-time
    /// GRANT machinery" above.
    perms: [perm_count]bool = @splat(false),
    /// north-star-plan §6 W4 slice 1 — mirrors `WasmPlugin.grant_table`
    /// exactly (see that field's doc). `null` for every client today (the
    /// two first-party clients this module's doc names self-grant `perms`
    /// directly and are never routed through a `System`'s table) — kept
    /// here so `hasPerm`'s duck-typed contract stays IDENTICAL across both
    /// transports, not because anything currently wires it.
    grant_table: ?*grants_mod.HandleTable = null,
    /// Mirrors `WasmPlugin.grant_handles` — see that field's doc. Unused
    /// (`.none` throughout) unless a caller mints into it via a wired
    /// `grant_table`.
    grant_handles: [perm_count]grants_mod.CapHandle = @splat(.none),
    /// The ctx a DISPATCHING call routes reads/mutations through — mirrors
    /// `WasmPlugin.active_ctx` exactly (same field name, so the same
    /// `activeCtx()`-shaped access pattern reads naturally for both).
    active_ctx: *command.Context,
    /// Whether THIS client's call stack is currently inside a dispatching
    /// entry (an injected key/pointer/command — the native counterpart of
    /// `on_command`/`on_pick_accept`) — mirrors `WasmPlugin.in_dispatch`.
    /// Set/cleared by `beginDispatch`/`endDispatch`, never directly.
    in_dispatch: bool = false,
    /// The one-time load/attach handshake window — mirrors
    /// `WasmPlugin.loading`. An in-process client that needs to touch head
    /// state while constructing/attaching (mirroring a wasm plugin's
    /// `describe()`+`init()` exemption — see `wasm_host/plugin.zig`'s
    /// `canDispatch` doc) sets this around that window, same discipline.
    loading: bool = false,

    /// This client as an edit principal — mirrors `WasmPlugin.principal()`.
    /// `role = .plugin` names it as the SAME authority CLASS a wasm plugin
    /// gets (first-party in-process code is not a second, unnamed tier of
    /// trust — C17/§2.4's "no UNNAMED authority"); its `.name` is what
    /// distinguishes it in the peer/attribution log.
    pub fn principal(self: *const InProcClient) command.Principal {
        return .{ .role = .plugin, .name = self.name };
    }

    /// Bracket a dispatching call (an injected key/pointer/command) the SAME
    /// way `wasm_abi/runtime.zig`'s `wpCmdTrampoline`/`wpPickAccept` bracket
    /// a guest's `on_command`/`on_pick_accept`: save the prior `in_dispatch`
    /// (LIFO-safe under reentrancy — a dispatched command that itself
    /// injects another dispatch, same as a nested `wl_run`), set it true for
    /// the call, restore on return via `endDispatch(prior)`. Callers:
    /// `app/window_head.zig`'s key injection, `e2e`'s TestHead — this is
    /// where the "same guard" requirement actually bites: without this
    /// bracket, a future semantic-body call from a background source (a
    /// timer, an async completion) on this client's identity would silently
    /// look "dispatching" forever once one real dispatch had run.
    pub fn beginDispatch(self: *InProcClient) bool {
        const prior = self.in_dispatch;
        self.in_dispatch = true;
        return prior;
    }
    pub fn endDispatch(self: *InProcClient, prior: bool) void {
        self.in_dispatch = prior;
    }

    /// `fs.read(path)` reached natively — the SAME semantic body
    /// (`wasm_host/fs.zig`'s `fsRead`) the wasm `hFsRead` trampoline calls,
    /// with a native `[]const u8` path and no marshalling. Denial propagates
    /// as an ordinary Zig error (`error.PermissionDenied`) — the in-process
    /// mirror of the guest's trap (see this file's + `fs.zig`'s module docs).
    pub fn fsRead(self: *InProcClient, gpa: std.mem.Allocator, path: []const u8) fs_impl.PermError!?[]u8 {
        return fs_impl.fsRead(gpa, self, path);
    }

    /// `weft.fs.write(path, bytes)` reached natively — mirrors `fsRead`,
    /// above, for `hFsWrite`'s semantic body (`wasm_host/fs.zig`'s
    /// `fsWrite`). Denial (including `error.OutOfLimit` — task #8 / W4
    /// slice 2's `.fs_root` confinement) propagates as an ordinary Zig
    /// error, same story as `fsRead`.
    pub fn fsWrite(self: *InProcClient, gpa: std.mem.Allocator, path: []const u8, bytes: []const u8) fs_impl.PermError!bool {
        return fs_impl.fsWrite(gpa, self, path, bytes);
    }

    /// `weft.fs.append(path, bytes)` reached natively — mirrors `fsWrite`.
    pub fn fsAppend(self: *InProcClient, gpa: std.mem.Allocator, path: []const u8, bytes: []const u8) fs_impl.PermError!bool {
        return fs_impl.fsAppend(gpa, self, path, bytes);
    }

    /// `weft.fs.exists(path)` reached natively — mirrors `fsRead`.
    pub fn fsExists(self: *InProcClient, gpa: std.mem.Allocator, path: []const u8) fs_impl.PermError!@import("../file.zig").Kind {
        return fs_impl.fsExists(gpa, self, path);
    }

    /// `weft.setMode(mode)` reached natively — the SAME semantic body
    /// (`wasm_host/keymap.zig`'s `setMode`) `hSetMode`'s wasm trampoline
    /// calls. Must be called from within a `beginDispatch`/`endDispatch`
    /// bracket (or during `loading`), exactly like the wasm side's
    /// `on_command`/`on_pick_accept` — else `error.NotDispatching`, the
    /// in-process mirror of the guest's trap.
    pub fn setMode(self: *InProcClient, gpa: std.mem.Allocator, mode: []const u8) keymap_impl.DispatchError!void {
        return keymap_impl.setMode(gpa, self.active_ctx, self, mode);
    }
};

/// Verify `T` satisfies the field shape `wasm_host/plugin.zig`'s
/// `hasPerm`/`canDispatch` duck-type against (`perms`, `in_dispatch`,
/// `loading`, `name`) — the compile-time proof that `InProcClient` and
/// `WasmPlugin` really do share ONE guard contract, not two that happen to
/// look alike today. Mirrors `platform/platform.zig`'s `assertPlatform`
/// convention (comptime duck-typed contract, not a vtable or a shared
/// nominal base).
pub fn assertClientIdentity(comptime T: type) void {
    if (@typeInfo(T) != .@"struct") @compileError(@typeName(T) ++ ": a client identity must be a struct");
    inline for (.{ "perms", "in_dispatch", "loading", "name", "grant_table", "grant_handles" }) |name| {
        if (!@hasField(T, name)) @compileError(@typeName(T) ++ ": missing field `" ++ name ++ "` — the shared client-identity contract `wasm_host/plugin.zig`'s hasPerm/canDispatch duck-type against");
    }
}

comptime {
    assertClientIdentity(InProcClient);
    assertClientIdentity(WasmPlugin);
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "InProcClient: hasPerm/canDispatch accept it exactly like a WasmPlugin (the shared-guard proof)" {
    var dummy_ctx: command.Context = undefined; // never dereferenced by hasPerm/canDispatch
    var c: InProcClient = .{ .name = "test-client", .active_ctx = &dummy_ctx };
    try t.expect(!wasm_host_plugin.hasPerm(&c, .fs_read));
    c.perms[wasm_host_plugin.perm_fs_read] = true;
    try t.expect(wasm_host_plugin.hasPerm(&c, .fs_read));

    try t.expect(!wasm_host_plugin.canDispatch(&c));
    const prior = c.beginDispatch();
    try t.expect(wasm_host_plugin.canDispatch(&c));
    c.endDispatch(prior);
    try t.expect(!wasm_host_plugin.canDispatch(&c));
}

test "InProcClient: fsRead denies without the grant, reads with it — SAME semantic body as hFsRead" {
    const gpa = t.allocator;
    var dummy_ctx: command.Context = undefined;
    var c: InProcClient = .{ .name = "test-client", .active_ctx = &dummy_ctx };

    try t.expectError(error.PermissionDenied, c.fsRead(gpa, "build.zig"));

    c.perms[wasm_host_plugin.perm_fs_read] = true;
    const bytes = (try c.fsRead(gpa, "does-not-exist-anywhere.xyz")) orelse null;
    try t.expectEqual(@as(?[]u8, null), bytes); // mundane failure, not a PermissionDenied
}

test "InProcClient: an fs_root-limited grant confines fs — in-root ok, out-of-root and traversal fail closed (task #8 / W4 slice 2)" {
    const gpa = t.allocator;
    var dummy_ctx: command.Context = undefined;
    var c: InProcClient = .{ .name = "test-client", .active_ctx = &dummy_ctx };

    // A throwaway root under .zig-cache/tmp — see file.zig's own tests for
    // this convention (real cwd-relative paths, matching what `fsRead`/
    // `fsWrite`'s "local cwd-relative" contract already assumes).
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    // Mint the limited row DIRECTLY (grants.zig's module doc: mintGrantHandles
    // only ever translates the boolean describe() handshake into `.none`-limit
    // rows — a `.fs_root`-limited row is minted by hand until a config verb
    // exists to declare one).
    var table = grants_mod.HandleTable.init(gpa);
    defer table.deinit();
    const hr = try table.grant(.{ .capability = "fs_read", .limit = .{ .fs_root = root } }, "test-client", null);
    const hw = try table.grant(.{ .capability = "fs_write", .limit = .{ .fs_root = root } }, "test-client", null);
    c.grant_table = &table;
    c.grant_handles[wasm_host_plugin.perm_fs_read] = hr;
    c.grant_handles[wasm_host_plugin.perm_fs_write] = hw;

    // In-root write, then read, round-trips — through the SAME semantic
    // bodies `hFsWrite`/`hFsRead`'s wasm trampolines call.
    var in_path_buf: [300]u8 = undefined;
    const in_path = try std.fmt.bufPrint(&in_path_buf, "{s}/note.txt", .{root});
    try t.expect(try c.fsWrite(gpa, in_path, "hello from in-root"));
    const got = (try c.fsRead(gpa, in_path)).?;
    defer gpa.free(got);
    try t.expectEqualStrings("hello from in-root", got);

    // Out-of-root: a path that doesn't even lexically start with the root —
    // denied at layer 1 (the lexical gate), no filesystem access at all.
    try t.expectError(error.OutOfLimit, c.fsRead(gpa, "totally/unrelated/path.txt"));
    try t.expectError(error.OutOfLimit, c.fsWrite(gpa, "totally/unrelated/path.txt", "x"));

    // Traversal: LEXICALLY prefixed by the root (passes layer 1) but escapes
    // it via `..` — denied by the KERNEL (layer 2, RESOLVE_BENEATH), fails
    // closed exactly like an outright unrelated path, not silently allowed
    // because the string happened to start right.
    var esc_path_buf: [300]u8 = undefined;
    const esc_path = try std.fmt.bufPrint(&esc_path_buf, "{s}/../../etc/passwd", .{root});
    try t.expectError(error.OutOfLimit, c.fsRead(gpa, esc_path));
    try t.expectError(error.OutOfLimit, c.fsAppend(gpa, esc_path, "x"));

    // The grant table's own possession check still applies underneath: a
    // capability never granted at all is PermissionDenied, not OutOfLimit —
    // the two stay distinguishable even for a limited principal.
    var no_write_c: InProcClient = .{ .name = "test-client", .active_ctx = &dummy_ctx, .grant_table = &table };
    no_write_c.grant_handles[wasm_host_plugin.perm_fs_read] = hr;
    try t.expectError(error.PermissionDenied, no_write_c.fsWrite(gpa, in_path, "nope"));
}

test "InProcClient: setMode traps NotDispatching outside a dispatch bracket, same guard as wl_set_mode" {
    const gpa = t.allocator;
    const Buffers = @import("../Buffers.zig");
    const Keymap = @import("../Keymap.zig");
    const Head = @import("../Head.zig");
    const Commands = command.Commands;
    const capability = @import("../capability.zig");
    const Actions = @import("../action.zig");
    const container_mod = @import("../container.zig");
    const task = @import("../task.zig");

    const pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var buffers = try Buffers.init(gpa, pool, "user");
    defer buffers.deinit(gpa);
    var commands: Commands = .empty;
    defer commands.deinit(gpa);
    var keymap: Keymap = .empty;
    defer keymap.deinit(gpa);
    var cont = container_mod.Container.init(gpa);
    defer cont.deinit();
    var caps = capability.Caps.init(gpa, task.nowNs, &cont);
    defer caps.deinit();
    var actions = Actions.init(gpa, &cont);
    defer actions.deinit();
    var quit = false;
    var head: Head = .empty;
    defer head.deinit(gpa);
    try head.setModeRaw(gpa, "normal");
    try keymap.markRestingMode(gpa, "normal");

    var ctx: command.Context = .{
        .gpa = gpa,
        .buffers = &buffers,
        .commands = &commands,
        .keymap = &keymap,
        .actions = &actions,
        .caps = &caps,
        .quit = &quit,
        .head = &head,
    };
    var c: InProcClient = .{ .name = "test-client", .active_ctx = &ctx };

    try t.expectError(error.NotDispatching, c.setMode(gpa, "insert"));
    try t.expectEqualStrings("normal", head.currentMode()); // refused, unchanged

    const prior = c.beginDispatch();
    defer c.endDispatch(prior);
    try keymap.markRestingMode(gpa, "insert");
    try c.setMode(gpa, "insert");
    try t.expectEqualStrings("insert", head.currentMode());
}

test {
    std.testing.refAllDecls(@This());
}
