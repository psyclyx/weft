//! The `WasmPlugin` runtime state — a loaded wasm plugin under the perm
//! handshake — and the small membrane types the host table hands it by handle
//! (commands, pending pick items, stamped ranges, query captures). The host
//! import table (wasm_host) operates on this; the load/run path lives in
//! wasm_abi/runtime.zig. Split out of the wasm_abi facade to keep each focused.

const std = @import("std");
const Allocator = std.mem.Allocator;
const wasm = @import("../wasm.zig");
const command = @import("../command.zig");
const kv = @import("../kv.zig");
const Buffers = @import("../Buffers.zig");
const syntax = @import("../syntax.zig");
const subbuffer = @import("../subbuffer.zig");
const register_mod = @import("../register.zig");
const surface_mod = @import("../surface.zig");
const async_loop = @import("../async.zig");
const position = @import("../position.zig");
const repl_session = @import("../repl_session.zig");
const net_session = @import("../net_session.zig");
const Pool = @import("../task.zig").Pool;

// The host-import table operates on `WasmPlugin` (principal() routes edits
// through its peer resolver); the two @import each other (Zig allows it).
const wasm_host = @import("../wasm_host.zig");

const WasmPlugin = @This();

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

gpa: Allocator,
ctx: *command.Context,
name: []u8,
/// A transient author identity, set only for the duration of a single
/// `wl_edit_as` call: subsequent edits (and the peer resolver) author as this
/// named `role=.agent` sub-peer instead of the plugin's own peer. Borrowed (the
/// name being applied), never persisted — an agent plugin edits on behalf of a
/// distinct identity per conversation ("claude", "codex") so attribution and
/// per-peer selective undo are per-agent, not blurred into one plugin peer.
author_override: ?[]const u8 = null,
store: ?*kv.Store,
/// Read-only config data the config plane staged for this plugin (namespaced
/// by plugin name), a store DISTINCT from `store` so runtime kv scratch can
/// never stomp injected config (and vice versa). Read via `wl_config_get`.
config_store: ?*kv.Store,
/// Host effect services the membrane forwards to (mirrors abi.Services).
syntax_of: ?SyntaxResolver,
subbuffers: ?*subbuffer.SubBuffers,
/// The core register/kill service (shared by every editor). Null = no
/// register wired: yankRange/pasteAt degrade to no-ops. See register.zig.
register: ?*register_mod.Register = null,
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

/// The path of the buffer being activated (design §3): valid only during an
/// `on_activate` dispatch, readable by the guest via `wl_activate_path`.
cur_activate_path: []const u8 = &.{},

/// The task pool interactive REPL sessions run their reader on (design
/// §6.3). Null → repl-start is unavailable.
pool: ?*Pool = null,
/// Live persistent subprocess sessions this plugin started, indexed by the
/// handle the guest holds (null once quit — the slot stays for handle
/// stability). The frame loop drains their output; `deinit` tears them down.
sessions: std.ArrayList(?*repl_session.Session) = .empty,
/// Live network connections this plugin opened (design §6.5), same handle/
/// lifecycle model as `sessions`.
net_sessions: std.ArrayList(?*net_session.Session) = .empty,

// ── Pick (built incrementally between begin/end, then opened) ──
pick_prompt: std.ArrayList(u8) = .empty,
pick_id: u32 = 0,
pick_items: std.ArrayList(PendingItem) = .empty,
/// The accepted choice, valid only during an `on_pick_accept` call.
cur_choice: []const u8 = &.{},

// ── Surface (retained overlay: which-key/dired/magit render here) ──
/// This plugin's retained overlay, populated via the surface membrane and
/// drawn every frame by the view while active. One per plugin.
surface: surface_mod.Surface = .{},

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
/// document is active at edit time (resolved, never captured). With an
/// `author_override` set (inside a `wl_edit_as` call) it authors as that named
/// `role=.agent` sub-peer instead — the resolver keys on the same name.
pub fn principal(self: *WasmPlugin) command.Principal {
    if (self.author_override) |agent_name| {
        return .{ .role = .agent, .name = agent_name, .ctx = self, .resolve = wasm_host.resolvePeerWp };
    }
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
    // Action providers this plugin registered (weft.provide) die with it, owned
    // by its name. The declared actions themselves persist (cheap names; another
    // plugin/config may still provide for them).
    self.ctx.actions.unregisterByOwnerPrefix(self.name);
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
    for (self.sessions.items) |maybe| if (maybe) |s| s.deinit(); // kill + join
    self.sessions.deinit(gpa);
    for (self.net_sessions.items) |maybe| if (maybe) |s| s.deinit(); // shut + join
    self.net_sessions.deinit(gpa);
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
    self.surface.deinit(gpa);
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
