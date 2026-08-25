//! The `WasmPlugin` runtime state — a loaded wasm plugin under the perm
//! handshake — and the small membrane types the host table hands it by handle
//! (commands, pending pick items, anchored ranges, query captures). The host
//! import table (wasm_host) operates on this; the load/run path lives in
//! wasm_abi/runtime.zig. Split out of the wasm_abi facade to keep each focused.

const std = @import("std");
const Allocator = std.mem.Allocator;
const wasm = @import("../wasm.zig");
const command = @import("../command.zig");
const pick = @import("../pick.zig");
const kv = @import("../kv.zig");
const Buffers = @import("../Buffers.zig");
const syntax = @import("../syntax.zig");
const subbuffer = @import("../subbuffer.zig");
const register_mod = @import("../register.zig");
const surface_mod = @import("../surface.zig");
const async_loop = @import("../async.zig");
const position = @import("../position.zig");
const capability = @import("../capability.zig");
const repl_session = @import("../repl_session.zig");
const net_session = @import("../net_session.zig");
const proc_stream = @import("../proc_stream.zig");
const Pool = @import("../task.zig").Pool;
const grants_mod = @import("../grants.zig");
const plugin_semantic = @import("weft_plugin_semantic");
const semantic_model = @import("weft_semantic");
const fs_runtime = @import("weft_fs_runtime");
const semantic_runtime = @import("../semantic.zig");
const transfer_attachment = @import("../wasm_host/transfer_attachment.zig");

// The host-import table operates on `WasmPlugin` (principal() routes edits
// through its peer resolver); the two @import each other (Zig allows it).
const wasm_host = @import("../wasm_host.zig");

const WasmPlugin = @This();

/// A direct-child ordinary file shares its parent's provider root, so its
/// paired lifetime is a target registration plus router binding (there is no
/// derived root to release).
pub const SemanticFileRegistration = struct {
    registration: fs_runtime.publication.Registration,
    router: *fs_runtime.Router,
};

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

/// A live CRDT range the guest holds by opaque handle. The endpoints are
/// document-owned anchors, not offsets paired with a version. `buffer` gives
/// the handles their locus and rejects buffer-identity reuse after one closes.
pub const RangeSlot = struct {
    buffer: Buffers.Ref,
    start: @import("../Document.zig").AnchorHandle,
    end: @import("../Document.zig").AnchorHandle,
    /// Ordinary motion/operator handles are dispatch-scoped. Interactive
    /// tools explicitly retain the ranges they need across callbacks.
    retained: bool = false,
};

/// An opaque witness for one active document causal frontier. The frontier is
/// owned by the plugin until the guest releases the handle; no scalar version
/// or ordering is exposed across the membrane.
pub const DocSnapshotSlot = struct {
    buffer: Buffers.Ref,
    frontier: []u8,
};

/// A materialized tree-sitter query capture the guest reads by index (design
/// §4 `syntax.query` — the tree stays host-side, captures cross). `name` owned.
pub const QueryCap = struct { name: []u8, start: usize, end: usize };

gpa: Allocator,
/// The LOAD-TIME ctx (set once by `construct`, always the ctx `loadPlugin`
/// was called with — the system's primary head today). Background host→guest
/// entries (init/describe, `on_poll`, `on_fill`, `on_complete` — see
/// `wasm_host/commands.zig`'s classification doc) read through `activeCtx()`
/// which falls back to this when no dispatch is in progress, so they always
/// see the system default, never a stale "whichever head last dispatched".
ctx: *command.Context,
/// The ctx a DISPATCHING host→guest call (on_command, on_pick_accept) should
/// route every host-import read/mutation through for the call's duration —
/// the interaction state (mode/pending/pick/echo/dot-repeat) of the HEAD that
/// issued the call, not necessarily the plugin's load-time head. Set (save/
/// restore around the guest call, reentrancy-safe — `wl_run` nests) by each
/// dispatching entry; every other entry leaves it alone, so it stays at
/// whatever the innermost enclosing dispatch set (or `ctx` outside any
/// dispatch). Every `wasm_host/*` handler reads state through `activeCtx()`,
/// never `ctx` directly — see `wasm_host/commands.zig`'s module doc for the
/// full dispatching/background classification.
active_ctx: *command.Context,
/// Whether the guest call CURRENTLY in flight is a DISPATCHING host→guest
/// entry (`on_command`/`on_pick_accept`) rather than a BACKGROUND one (task
/// #19 item 4 — closing the `activeCtx()` escape hatch `ctx.zig`'s
/// "BACKGROUND CODE CANNOT" doc block names: a background entry could still
/// reach a head-touching import and mutate the load-time ctx's `Head`
/// through it — convention, not structure). Set/cleared by the SAME save/
/// restore sites that manage `active_ctx` (`wpCmdTrampoline`/`wpPickAccept`),
/// so it shares that field's reentrancy story exactly: a nested `wl_run`
/// re-enters one of those same trampolines, which sets this true again
/// (already true, or promoting it from false — see `wasm_host/plugin.zig`'s
/// `requireDispatch` doc for what that promotion means) and restores
/// whatever it was on the way out — LIFO, never a bare set. Every head-
/// gated `wasm_host/*` handler (`contract_data.zig`'s `.head_gated = true`
/// entries) calls `requireDispatch` first, which reads this field (and
/// `loading`, below).
in_dispatch: bool = false,
/// True for the duration of `describe()`/`init()` — the ONE-TIME load
/// handshake (`wasm_abi/runtime.zig`'s `loadPlugin`), a THIRD entry class
/// `requireDispatch` also admits, distinct from both `in_dispatch` and a
/// plain denied background call (task #19 item 4, corrected mid-build: the
/// original design assumed `init` never needs a head-gated import — WRONG,
/// caught by the full test suite, not by inspection. `vim.zig`/`helix.zig`/
/// `emacs.zig`'s `init()` all end with `weft.setMode("normal")` /
/// equivalent, establishing the guest's STARTING mode — a real, load-
/// bearing pattern every modal-editor guest uses, not an oversight to
/// route around). Why this is safe though it "touches Head": at the moment
/// `describe()`/`init()` runs, `active_ctx` is STILL `ctx` by construction
/// (`construct()` just set both to the same pointer, nothing has run yet)
/// — there is no OTHER head that could be mid-interaction with a plugin
/// that didn't exist a moment ago, so a head-gated call here can only ever
/// set the SAME (single, load-time) head's starting state, never hijack a
/// second one. NUANCE (review of #19 item 4): at STARTUP that head is fresh;
/// on a RUNTIME `config-reload` that loads a NEW plugin, the load-time head
/// is the LIVE editing head — a modal plugin's `init` `setMode("normal")`
/// then stomps the live mode. That is pre-existing reload behavior this
/// exemption PRESERVES (necessary — trapping it would break every modal
/// guest's load), not a new hole it opens; a mid-chord stomp is unreachable
/// (dispatching `config-reload` consumed the chord). The argument stops
/// holding the instant load finishes — every
/// LATER background entry (`on_poll`/`on_fill`/`on_activate`/`on_complete`/
/// `on_menu`) still traps, exactly as `in_dispatch` alone would enforce. Set
/// true/false by `loadPlugin` bracketing `describe()`+`init()`; never true
/// again after `loadPlugin` returns (no save/restore needed — load doesn't
/// nest with itself).
loading: bool = false,
name: []u8,
/// Opaque identity for this loaded instance's persistent semantic resources.
/// Two concurrent/reloading instances may share `name` but never this value.
semantic_owner: ?semantic_model.owner.Id = null,
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
register: ?*register_mod.Bank = null,
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
/// north-star-plan §6 W4 slice 1 — the grant table this plugin's possessed
/// handles (`grant_handles`, below) are checked against. `null` (the default
/// every pre-W4 construction gets) means "no table wired": `hasPerm` then
/// falls back to reading `perms` directly, exactly as before this slice —
/// see `wasm_host/plugin.zig`'s `hasPerm` doc. Set from `LoadOptions.grant_table`
/// by `construct`; a real value only when the loader (a `System`, or a test
/// that opts in) supplies one.
grant_table: ?*grants_mod.HandleTable = null,
/// This plugin's POSSESSED handles, one slot per `Perm` — the "use =
/// possession" state `hasPerm` checks when `grant_table` is wired. Minted
/// once, at load time, from `perms` (`wasm_host/plugin.zig`'s
/// `mintGrantHandles`, called by `loadPlugin` right after `describe()`
/// finishes) — NOT re-derived per use. `CapHandle.none` for every
/// undeclared perm, and for every slot when `grant_table` is null (nothing
/// ever mints into it).
grant_handles: [perm_count]grants_mod.CapHandle = @splat(.none),
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
/// Nested command results need distinct backing while the outer guest resumes
/// and consumes them. Retire these buffers together at the next top-level
/// dispatch; a nested result can never overwrite its caller's result bytes.
retired_result_bufs: std.ArrayList(std.ArrayList(u8)) = .empty,
dispatch_depth: usize = 0,

/// Guest-visible live ranges keyed by monotonic, never-recycled capabilities.
/// A stale release can therefore never hit a later range (no handle ABA).
/// Ephemeral entries die at the next command dispatch, while a tool may
/// explicitly retain an entry across asynchronous UI callbacks. The table
/// owns every document anchor until release or plugin teardown.
ranges: std.AutoHashMapUnmanaged(u32, RangeSlot) = .empty,
next_range_handle: u32 = 0,
/// Issuance log for dispatch-scoped handles. Retention leaves an entry here;
/// the next top-level dispatch skips retained/live capabilities and clears the
/// log in one pass. This keeps cleanup O(handles issued), not a table rescan.
ephemeral_range_handles: std.ArrayList(u32) = .empty,

/// Guest-owned equality witnesses for document snapshots. Handles are
/// monotonic and never recycled, so a late release cannot target a new
/// frontier.
doc_snapshots: std.AutoHashMapUnmanaged(u32, DocSnapshotSlot) = .empty,
next_doc_snapshot_handle: u32 = 0,

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
/// Raw persistent subprocess streams (`wl_proc_spawn`), indexed by handle. Unlike
/// `sessions` (which stream into a buffer), these hand raw stdout bytes back to
/// the guest via `wl_proc_read` — the transport an in-guest protocol client
/// (the `lsp` plugin) deframes. Null slot once closed (handles stay stable).
proc_streams: std.ArrayList(?*proc_stream.ProcStream) = .empty,

// ── Pick (built incrementally between begin/end, then opened) ──
pick_prompt: std.ArrayList(u8) = .empty,
pick_id: u32 = 0,
pick_items: std.ArrayList(PendingItem) = .empty,
/// The immutable terminal event, valid only during `on_pick_accept`. The
/// trampoline saves/restores it, so nested guest dispatch cannot overwrite an
/// outer callback's acceptance facts.
cur_pick_outcome: ?pick.Outcome = null,

// ── Surface (retained overlay: which-key/dired/magit render here) ──
/// This plugin's retained overlay, populated via the surface membrane and
/// drawn every frame by the view while active. One per plugin.
surface: surface_mod.Surface = .{},

// ── Sandboxed semantic field providers ──
/// Stable heap proxies + host-owned snapshots for fields registered by this
/// guest. The system registry owns handle generations; this bridge owns only
/// callback/cache memory and is torn down immediately after owner revocation.
semantic_fields: plugin_semantic.field.Bridge = .empty,

// ── Sandboxed semantic action provider ──
/// One owner-scoped provider endpoint. Requests and aggregate responses cross
/// as canonical portable values; no guest pointer survives the callback.
semantic_actions: plugin_semantic.action.Bridge = .empty,

// ── Sandboxed semantic target handlers ──
/// Tokenized discovery/open endpoints. Registry entries are owner-revoked
/// before their stable proxy storage is released during plugin teardown.
semantic_targets: plugin_semantic.target.Bridge = .empty,

// ── Sandboxed semantic relation providers ──
/// Tokenized named-edge providers. Query answers are immutable located target
/// values; the guest receives no target-registry implementation authority.
semantic_relations: plugin_semantic.relation.Bridge = .empty,

// ── Provider-confined semantic directory publications ──
/// Direct-child targets derived through the filesystem authority boundary.
/// The guest owns ordinary semantic handles; this host-side collection owns
/// the paired target binding and provider root so generic target close and
/// plugin teardown revoke the complete capability, not only its description.
semantic_directories: std.ArrayList(fs_runtime.publication.ChildRegistration) = .empty,

/// Keeping the router beside each registration makes teardown symmetrical
/// with `semantic_directories` without teaching the target registry about
/// filesystem authority.
semantic_files: std.ArrayList(SemanticFileRegistration) = .empty,

// ── Sandboxed semantic transfer attachments ──
/// Guest references are owner-scoped and are revoked with this plugin. Host
/// transfer owners retain the resolved resource independently.
semantic_attachments: transfer_attachment.Registry,

// ── Completion provider (host→guest data-gather) ──
/// The caps provider id this plugin registered (owned), torn down on
/// unload. Null until it calls `provideCompletion`.
provider_id: ?[]u8 = null,
/// The request's word prefix, exposed to the guest via `wl_completion_prefix`
/// for the duration of one `on_complete` call (valid then; a deferred provider
/// copies what it needs before returning).
cur_prefix: []const u8 = &.{},
/// Rich items the guest is accreting for a session via `wl_caps_item`, flushed
/// as one batch on `wl_caps_commit`. Each item's bytes are gpa-owned here and
/// freed after the push (which deep-copies) or on teardown.
caps_builder: std.ArrayList(capability.CompletionItem) = .empty,
caps_builder_session: u64 = 0,

// ── D2's generic schema-directed slot verbs (core/slot.zig, wasm_host/
// slot.zig) — `wl_slot_declare`'s host-owned parsed schema trees and
// `wl_slot_bind`'s host-owned predicate leaf strings, both freed on unload
// (Container itself never frees a slot's schema/a binding's predicate — see
// `container.SlotDecl.schema`'s doc — so whichever side allocated it owns
// the free; here, that's this plugin).
declared_schemas: std.ArrayList(*const @import("weft_schema").Schema) = .empty,
slot_predicate_strs: std.ArrayList([]u8) = .empty,

/// Anchor `[start, end)` in the active CRDT document and hand the guest an
/// opaque handle. The document advances both endpoints through every local or
/// merged edit. The slot owns the anchors until it is released.
pub fn anchorRange(self: *WasmPlugin, start: usize, end: usize) !u32 {
    const buffer = self.activeCtx().buffers.active();
    const doc = &buffer.editor.doc;
    const len = doc.text().byteLen();
    if (start > end or end > len) return error.InvalidRange;
    const a = try doc.addAnchor(self.gpa, start, .right);
    errdefer doc.removeAnchor(a);
    const b = try doc.addAnchor(self.gpa, end, .left);
    errdefer doc.removeAnchor(b);
    const slot: RangeSlot = .{
        .buffer = buffer.ref(),
        .start = a,
        .end = b,
    };
    // The wasm ABI reserves negative i32 results for failure, so the positive
    // half of its 32-bit space is the capability budget. Exhaustion fails
    // closed; recycling would let a late release or callback target new state.
    if (self.next_range_handle > std.math.maxInt(i32)) return error.RangeHandlesExhausted;
    const handle = self.next_range_handle;
    self.next_range_handle += 1;
    try self.ranges.putNoClobber(self.gpa, handle, slot);
    errdefer _ = self.ranges.remove(handle);
    try self.ephemeral_range_handles.append(self.gpa, handle);
    return handle;
}

/// Capture the active document's opaque causal frontier at its current buffer
/// locus. The guest receives only a capability handle; frontier bytes remain
/// host-owned and are compared for equality by `docSnapshotIsCurrent`.
pub fn docSnapshot(self: *WasmPlugin) !u32 {
    const buffer = self.activeCtx().buffers.active();
    const frontier = try buffer.editor.doc.version(self.gpa);
    errdefer self.gpa.free(frontier);
    if (self.next_doc_snapshot_handle > std.math.maxInt(i32)) return error.DocSnapshotHandlesExhausted;
    const handle = self.next_doc_snapshot_handle;
    self.next_doc_snapshot_handle += 1;
    try self.doc_snapshots.putNoClobber(self.gpa, handle, .{
        .buffer = buffer.ref(),
        .frontier = frontier,
    });
    return handle;
}

/// Return true only when the handle still names the active buffer and its
/// causal frontier is byte-for-byte equal to the document's current frontier.
/// Any missing buffer or frontier error fails closed.
pub fn docSnapshotIsCurrent(self: *WasmPlugin, handle: u32) bool {
    const slot = self.doc_snapshots.get(handle) orelse return false;
    const buffer = self.activeCtx().buffers.active();
    if (slot.buffer.id != buffer.id or slot.buffer.generation != buffer.generation) return false;
    const current = buffer.editor.doc.version(self.gpa) catch return false;
    defer self.gpa.free(current);
    return std.mem.eql(u8, slot.frontier, current);
}

/// Release one document snapshot witness. Stale or repeated releases are
/// harmless.
pub fn releaseDocSnapshot(self: *WasmPlugin, handle: u32) void {
    const removed = self.doc_snapshots.fetchRemove(handle) orelse return;
    self.gpa.free(removed.value.frontier);
}

pub fn clearDocSnapshots(self: *WasmPlugin) void {
    var it = self.doc_snapshots.valueIterator();
    while (it.next()) |slot| self.gpa.free(slot.frontier);
    self.doc_snapshots.clearRetainingCapacity();
}

/// Resolve one opaque range slot only at the buffer locus which minted it.
/// Handles may cross callbacks; compact buffer ids may not.
pub fn activeRange(self: *WasmPlugin, handle: u32) ?*const RangeSlot {
    const slot = self.ranges.getPtr(handle) orelse return null;
    const active = self.activeCtx().buffers.active().ref();
    if (slot.buffer.id != active.id or slot.buffer.generation != active.generation) return null;
    return slot;
}

/// Resolve an anchored slot in its live buffer. Active-buffer identity is
/// checked separately by `activeRange` before any guest-visible operation.
pub fn resolveRange(self: *WasmPlugin, slot: *const RangeSlot) ?@import("stemma").Range {
    const buffer = self.ctx.buffers.resolve(slot.buffer) orelse return null;
    const doc = &buffer.editor.doc;
    const a = doc.anchorOffset(slot.start);
    const b = doc.anchorOffset(slot.end);
    return .{ .start = @min(a, b), .end = @max(a, b) };
}

pub fn borrowedRange(self: *WasmPlugin, slot: *const RangeSlot) ?position.LiveRange {
    const buffer = self.ctx.buffers.resolve(slot.buffer) orelse return null;
    return .{ .document = &buffer.editor.doc, .start = slot.start, .end = slot.end };
}

/// Keep a range alive across command dispatches. This is intentionally
/// separate from anchoring: the common motion/operator path remains scoped
/// without asking every guest to clean up on every early return.
pub fn retainRange(self: *WasmPlugin, handle: u32) bool {
    const slot = self.ranges.getPtr(handle) orelse return false;
    slot.retained = true;
    return true;
}

fn destroyRange(self: *WasmPlugin, s: RangeSlot) void {
    const buffer = self.ctx.buffers.resolve(s.buffer) orelse return;
    buffer.editor.doc.removeAnchor(s.start);
    buffer.editor.doc.removeAnchor(s.end);
}

fn releaseRangeAt(self: *WasmPlugin, handle: u32) void {
    const removed = self.ranges.fetchRemove(handle) orelse return;
    self.destroyRange(removed.value);
}

/// Release the dispatch-scoped entries while preserving explicitly retained
/// tool state. Closed buffers need no special path: `Document.deinit` already
/// owned and destroyed their anchor sets.
pub fn clearEphemeralRanges(self: *WasmPlugin) void {
    for (self.ephemeral_range_handles.items) |handle| {
        const slot = self.ranges.get(handle) orelse continue;
        if (!slot.retained) self.releaseRangeAt(handle);
    }
    self.ephemeral_range_handles.clearRetainingCapacity();
}

/// Release one guest-owned range resource. Idempotent: a callback may defer
/// cleanup without caring whether an earlier stale-target branch released it.
pub fn releaseRange(self: *WasmPlugin, handle: u32) void {
    self.releaseRangeAt(handle);
}

/// Plugin teardown owns retained state too.
pub fn clearAllRanges(self: *WasmPlugin) void {
    var it = self.ranges.valueIterator();
    while (it.next()) |slot| self.destroyRange(slot.*);
    self.ranges.clearRetainingCapacity();
    self.ephemeral_range_handles.clearRetainingCapacity();
}

pub fn clearRetiredResultBuffers(self: *WasmPlugin) void {
    for (self.retired_result_bufs.items) |*buf| buf.deinit(self.gpa);
    self.retired_result_bufs.clearRetainingCapacity();
}

/// Drop the pending completion batch, freeing each item's owned bytes.
pub fn capsBuilderClear(self: *WasmPlugin) void {
    const gpa = self.gpa;
    for (self.caps_builder.items) |it| {
        gpa.free(it.text);
        gpa.free(it.label);
        gpa.free(it.detail);
        gpa.free(it.documentation);
    }
    self.caps_builder.clearRetainingCapacity();
    self.caps_builder_session = 0;
}

/// Reset the query-capture buffer, freeing each capture's name.
pub fn queryCapsClear(self: *WasmPlugin) void {
    for (self.query_caps.items) |q| self.gpa.free(q.name);
    self.query_caps.clearRetainingCapacity();
}

/// The ctx every `wasm_host/*` handler should read/mutate through — the
/// dispatching head's ctx while a guest call is in flight, else the load-time
/// default. See the `active_ctx` field doc.
pub fn activeCtx(self: *WasmPlugin) *command.Context {
    return self.active_ctx;
}

pub const SemanticScope = struct {
    services: *semantic_runtime.Services,
    owner: semantic_model.owner.Id,
};

/// Persistent semantic endpoints are owned by the system that loaded the
/// plugin. A dispatch may borrow another head in that same system, but it may
/// not publish provider pointers into a different system's registries.
pub fn semanticScope(self: *WasmPlugin) ?SemanticScope {
    const owner = self.semantic_owner orelse return null;
    const home = self.ctx.semantic orelse return null;
    const active = self.active_ctx.semantic orelse return null;
    if (active != home) return null;
    return .{ .services = home, .owner = owner };
}

pub fn ownsSemanticFilesystemTarget(self: *const WasmPlugin, ref: semantic_model.target.Ref) bool {
    for (self.semantic_directories.items) |directory|
        if (directory.registration.ref.eql(ref)) return true;
    for (self.semantic_files.items) |file|
        if (file.registration.ref.eql(ref)) return true;
    return false;
}

/// Close a provider-confined target through the same generic target-close ABI
/// every other owned target uses. `null` means the handle is not one of these
/// paired publications and the ordinary semantic registry should decide it.
pub fn closeSemanticFilesystemTarget(
    self: *WasmPlugin,
    targets: *@import("weft_target_runtime").target.Registry,
    ref: semantic_model.target.Ref,
) ?bool {
    for (self.semantic_directories.items, 0..) |*directory, index| {
        if (!directory.registration.ref.eql(ref)) continue;
        if (!directory.close(self.gpa, targets)) return false;
        _ = self.semantic_directories.swapRemove(index);
        return true;
    }
    for (self.semantic_files.items, 0..) |*file, index| {
        if (!file.registration.ref.eql(ref)) continue;
        if (!file.registration.close(self.gpa, targets, file.router)) return false;
        _ = self.semantic_files.swapRemove(index);
        return true;
    }
    return null;
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
    // Semantic resources hold provider pointers into this plugin. Revoke the
    // whole owner namespace while the guest instance is still alive; every
    // retained handle becomes stale before either side can dangle.
    if (self.semantic_owner) |owner| {
        if (self.ctx.semantic) |services| {
            // Paired filesystem publications must close before bulk semantic
            // owner revocation: their provider roots are an independent
            // lifetime that the semantic registry neither knows nor owns.
            while (self.semantic_directories.items.len != 0) {
                var directory = self.semantic_directories.pop().?;
                _ = directory.close(gpa, &services.targets);
            }
            while (self.semantic_files.items.len != 0) {
                var file = self.semantic_files.pop().?;
                _ = file.registration.close(gpa, &services.targets, file.router);
            }
            _ = services.releaseOwner(gpa, owner);
        }
    }
    self.semantic_directories.deinit(gpa);
    self.semantic_files.deinit(gpa);
    self.semantic_fields.deinit();
    self.semantic_actions.deinit();
    self.semantic_targets.deinit();
    self.semantic_relations.deinit();
    self.semantic_attachments.deinit();
    // Completion provider dies with the plugin (unregister before freeing
    // its id — the caps registry holds the id by reference).
    if (self.provider_id) |id| {
        self.ctx.caps.unregisterByIdPrefix(id);
        gpa.free(id);
    }
    self.capsBuilderClear();
    self.caps_builder.deinit(gpa);
    // Action providers this plugin registered (weft.provide) die with it, owned
    // by its name. The declared actions themselves persist (cheap names; another
    // plugin/config may still provide for them).
    self.ctx.actions.unregisterByOwnerPrefix(self.name);
    // D2 slot providers (wl_slot_bind) die with it too — same shape. Slots
    // THEMSELVES (wl_slot_declare) persist, exactly like declared actions —
    // Container has no slot-removal API (matches every other domain's
    // "declarations outlive a single provider" convention).
    if (self.ctx.slot_host) |host| host.unregisterByOwnerPrefix(self.name);
    for (self.declared_schemas.items) |s| @import("weft_schema").freeSchema(gpa, s);
    self.declared_schemas.deinit(gpa);
    for (self.slot_predicate_strs.items) |s| gpa.free(s);
    self.slot_predicate_strs.deinit(gpa);
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
    for (self.proc_streams.items) |maybe| if (maybe) |s| s.deinit(); // kill + join
    self.proc_streams.deinit(gpa);
    self.clearAllRanges();
    self.ranges.deinit(gpa);
    self.ephemeral_range_handles.deinit(gpa);
    self.clearDocSnapshots();
    self.doc_snapshots.deinit(gpa);
    self.queryCapsClear();
    self.query_caps.deinit(gpa);
    self.clearRetiredResultBuffers();
    self.retired_result_bufs.deinit(gpa);
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
