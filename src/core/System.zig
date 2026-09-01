//! System — the system-scoped state bundle a manifest applies INTO
//! (doc/configuration.md §5): the keymap TABLES, the buffer set, the
//! command/action/capability surfaces, the config-value store, and a
//! headless "default" `Head` background/direct-`command.run` dispatch
//! targets. A `Host` (below) is the container-level registry: "the
//! container hosts N systems" (§2.7) — a live process may hold the editor
//! system headed and a second, minimal system (agent-ux) headless, and a
//! head may `swap` which hosted system it's attached to without either
//! system's OTHER state (buffers, keymap tables, in-flight commands)
//! being disturbed.
//!
//! **The System/Session boundary (§6 W2b judgment call — reported, not
//! forced).** `app/session.zig`'s `Session` and this module overlap in
//! shape (both bundle buffers+commands+keymap+caps+actions+a head) but are
//! NOT the same thing, and this module does not replace `Session`:
//!
//!   - `System` is SHAREABLE and HOSTABLE HEADLESS — the thing a manifest
//!     targets, the thing `Host` can hold N of, the thing that exists with
//!     zero attached heads and keeps servicing `command.run`. It owns no
//!     platform/rendering state at all.
//!   - `Session` is `main()`'s APP GLUE for the ONE system the desktop
//!     binary actually runs today: it additionally carries `menu_overlay`
//!     (which-key edge-detection — app-layer, can't live on `core.Head`,
//!     see `frame.MenuOverlay`'s doc), `completion_ui`/`cursor_cfg`
//!     (capability-consumer UI + caret config — arguably per-head, not yet
//!     split that finely), and a single long-lived, SELF-REFERENTIAL
//!     `cmd_ctx` built in place in `main()`'s frame (borrowed by the
//!     wayland window, the render state, the plugin host, the collab
//!     machinery — dozens of call sites across `main.zig`/`app/*.zig`
//!     that all assume ONE stable `*command.Context` for the process's
//!     one system).
//!
//!   `System.contextFor` deliberately does NOT try to be that stable
//!   object — it hands back a fresh, cheap-to-build `command.Context`
//!   VALUE (every field a borrowed pointer) each time, which is exactly
//!   what a rebind needs (mutate the pointers, or just build a new one) but
//!   is NOT a drop-in replacement for `Session.cmd_ctx`'s "one object every
//!   subsystem holds a pointer to" role. Rewiring `main.zig`/`Session` to
//!   hold a `*System` instead of its own fields — so the DESKTOP app could
//!   itself live-`swap` — would mean either (a) making `cmd_ctx` re-buildable
//!   on every rebind and auditing every long-lived borrow of it across
//!   `main.zig`'s ~30 wired subsystems (wayland window, render state, collab,
//!   window layout, providers/LSP attach, the plugin host), or (b) adding a
//!   pointer-to-pointer indirection layer in front of all of them. Both are
//!   real, bounded, W3/W0b-shaped follow-ups (the render membrane work
//!   already has to touch this same "who holds a pointer into the live
//!   session" question) — NOT done here. What IS done and load-bearing: the
//!   primitive (`System`, `Host.swap`) is real, tested end-to-end against
//!   its own `command.Context`s (this file's gate tests), and
//!   `main.zig`/`Session`'s existing single-system behavior is completely
//!   unmodified (byte-identical — `Session` does not use `System` at all).
//!
//! Plugin instances (wasm `WasmPlugin`/resident `JsPlugin`) are PER-SYSTEM
//! by design (§6 W2b-1: "Plugin instances are PER-SYSTEM — they register
//! into system state") but are NOT stored as a `System` field here: today
//! they're `main()`-locals (`plugins`/`js_plugins`/`plugin_kv`/the wasm
//! `Engine`/the async `Loop`) wired through `config_load.PluginHost`, which
//! borrows `*command.Context` and a handful of loose option pointers — not
//! `*System`. `Manifest.ApplyCtx.loader` already carries a plugin loader
//! optionally (`?PluginLoader`), so `System.applyManifest` accepts one the
//! same way; the gate manifest (`config/agent-ux.js`) deliberately loads no
//! plugins ("a few binds, no heavy plugins" per the task) so this system
//! is fully exercisable without also relocating the wasm engine/loop into
//! `System` — another named, bounded follow-up rather than forced here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const command = @import("command.zig");
const pick = @import("pick.zig");
const Buffers = @import("Buffers.zig");
const Keymap = @import("Keymap.zig");
const Head = @import("Head.zig");
const capability = @import("capability.zig");
const Caps = capability.Caps;
const Actions = @import("action.zig");
const SlotHost = @import("slot.zig").SlotHost;
const kv = @import("kv.zig");
const env_mod = @import("env.zig");
const place_mod = @import("place.zig");
const builtins = @import("builtins.zig");
const manifest = @import("manifest.zig");
const task = @import("task.zig");
const container_mod = @import("container.zig");
const wasm = @import("wasm.zig");
const wasm_abi = @import("wasm_abi.zig");
const quickjs = @import("quickjs.zig");
const async_loop = @import("async.zig");
const subbuffer = @import("subbuffer.zig");
const register_mod = @import("register.zig");
const grants_mod = @import("grants.zig");
const semantic_mod = @import("semantic.zig");
const intent_mod = @import("intent.zig");
const placement_mod = @import("placement.zig");
const focus_feed = @import("focus_feed.zig");
const viewport_mod = @import("viewport.zig");
const fs_runtime = @import("weft_fs_runtime");

pub const System = @This();

/// **Pinning invariant (review nit — stated explicitly):** a hosted
/// `System` must never be RELOCATED (moved to a different address) once
/// `Host.hostSystem` holds it. `Host.systemOf` identifies "which system is
/// this `command.Context` currently wired to" by comparing `&s.buffers`
/// against `c.buffers` — raw address identity — and every `contextFor`
/// call bakes `&self.buffers`/`&self.commands`/etc. into the `Context` it
/// returns. `create` returns `*System` (heap-allocated via `gpa.create`)
/// specifically so `Host` can hold pointers that stay valid across
/// `systems` (a `StringArrayHashMapUnmanaged`) growing/rehashing — the
/// `System` VALUES themselves never move, only the map of pointers to them
/// does. Do not embed a `System` by value inside another moving container.
gpa: Allocator,
/// This system's name — the `system-swap <name>` / `Host.hostSystem`
/// registration key ("editor", "agent-ux", ...).
name: []u8,
buffers: Buffers,
commands: command.Commands = .empty,
/// The keymap TABLES (bindings, fallback chains, menu/locked/resting/
/// sticky declarations) — shared by every head attached to this system;
/// see `Keymap.zig`'s module doc for the table/cursor split this mirrors
/// at system scope.
keymap: Keymap = .empty,
/// The ONE `container.Container` this system's `caps`/`actions` bind into,
/// and the target `gfx/view/ui_mesh.zig`'s `declareSlots`/
/// `bindDefaultStatusline` are pointed at by an embedder (doc/cwa-prior-docs-audit.md §5
/// task #19, the shared-Container fold-in). Action names, `edit/*`
/// capability names, and `ui/*` mesh names are one flat slot namespace —
/// they already couldn't collide (see `container.zig`'s doc) — so folding
/// three separate resolution stores (this system's `actions`/`caps`, plus
/// whatever UI mesh Container an embedder builds against `&self.container`)
/// into one is purely a STORAGE change: `Actions`/`Caps` still adapt onto
/// it through their own domain shapes (F5's adapter, not yet deleted — see
/// their module docs for exactly what remains). `Ctx.epoch` (`ctx.zig`)
/// reads `self.container.epoch` (via `ctx.actions.container.epoch`,
/// equivalently `ctx.caps.container.epoch` — same instance) as its cache
/// key — the TRUE per-mutation counter that replaces this system's old
/// `generation` field (removed: it was an unread, never-actually-wired
/// placeholder — nothing gave `Ctx.capture` a path to a `*System` to read
/// it from in the first place).
container: container_mod.Container = undefined,
caps: Caps,
actions: Actions,
/// D2's generic, schema-directed slot host (`core/slot.zig`) — `Caps`'s
/// sibling for RUNTIME-declared `wl_slot_*` slots, binding into the SAME
/// `container` as `caps`/`actions` do.
///
/// Nothing owned one before this. `Context.slot_host` defaults to `null` and
/// `contextFor` never set it, so D2 shipped the membrane, the schema
/// marshaller and an end-to-end proof while, in the running editor, every
/// `wl_slot_*` door was a silent no-op: `wl_slot_fire` answered -1 and
/// `wl_payload_push` dropped on the floor. The `badge`/`badge_consumer`
/// fixtures passed throughout because the wasm-membrane test harness brought
/// its own host. A plugin could declare, bind and fire a slot in the shipped
/// binary and get nothing back, with no diagnostic anywhere.
slot_host: SlotHost,
/// Config-value store (`weft.set`) for THIS system's manifest — distinct
/// from any other hosted system's, so `weft.set("acp", "cmd", ...)` in
/// the editor's config.js can never leak into agent-ux's store or vice
/// versa (mirrors `main.zig`'s `config_kv`/`plugin_kv` split, one level
/// up: per-SYSTEM now, not just per-store-kind).
config_kv: kv.Store = .empty,
/// Per-place environment overlays (`env.zig`) — the sibling of the working
/// directory: WHERE an effect runs and WITH WHAT it runs are the same
/// question asked twice, and both are resolved at the spawn door.
environments: env_mod.Environments = undefined,
/// Dense opaque ids for the places this run has seen (`place.Ids`), so a
/// guest can key a session table on "which place" without being handed one.
place_ids: place_mod.Ids = undefined,
/// This system's headless/background head: what `command.run` dispatches
/// against when no OTHER head is specified, and (once plugins are wired
/// per-system — see the module doc) what a background wasm entry
/// (`on_poll`) targets, mirroring `WasmPlugin`'s existing load-time-ctx
/// convention one level up. A system with zero ATTACHED heads (the
/// "headless" gate) still has this one — "zero-head systems are a
/// first-class resting state" (§2.7) means zero EXTRA heads, not zero
/// dispatch target.
default_head: Head = .empty,
quit: bool = false,
/// The manifest last applied/reconciled into this system (M3's
/// `Manifest.reconcile` contract: a second `applyManifest` diffs against
/// this instead of blindly re-applying). Owned; destroyed on replacement
/// and in `destroy`.
applied_manifest: ?*manifest.Manifest = null,
/// Per-system plugin bundle (task #19 item 3; §6 W2b-1: "Plugin instances
/// are PER-SYSTEM — they register into system state"). `null` until
/// `initPlugins` runs — a system hosting a manifest with no plugins (today,
/// every system except "editor"; the agent-ux gate manifest deliberately
/// loads none) never pays for an `Engine`/`Loop` it doesn't use. This is a
/// STRUCTURAL move only: `main.zig` calls `initPlugins` once, for the
/// editor system, and wires `app/config_load.zig`'s `PluginHost` against
/// the fields below in place of its old bare `main()` locals — no second
/// system actually loads a plugin yet (that would be a separate, later
/// change: reading a manifest's own `weft.plugin(...)` calls against
/// `--plugin`-style resolution for a non-editor system).
plugins: ?Plugins = null,
/// The GRANT TABLE this system owns (doc/contextual-workspace-architecture.md §13.5:
/// "the GRANT TABLE a System owns"). Wire `&self.grants` into a plugin
/// load's `wasm_abi.LoadOptions.grant_table` to make its `describe()`-
/// declared perms revocable rows instead of static booleans — see
/// `grants.zig`'s module doc for the full shape, `revoke` (below) for the
/// live-revocation entry point, and `contextFor`'s `Context.grant_table`
/// wiring for how a captured `Ctx` resolves against it. Every `Context`
/// this system hands out (`contextFor`) points at the SAME table, so
/// `Ctx.capture`'s grant resolution and a loaded plugin's possession checks
/// both consult exactly one source of truth.
grants: grants_mod.HandleTable = undefined,
/// Semantic targets/views/fields and target-handler registrations belong to
/// the system, just like buffers and commands. Heads carry only focus and
/// active interactions into whichever system they are attached to.
semantic: semantic_mod.Services,
/// Authority routes are system state; concrete provider storage belongs to
/// the embedder and can be swapped without changing this interface.
filesystems: fs_runtime.Router,
/// This system's intention plane (`intent.zig`) — the offer catalog every
/// provider publishes into and the invoker registry decisions run through.
/// System-scoped like the keymap tables: heads resolve against it, they do
/// not own it. Pinned (the published core table borrows a field of it),
/// which `System`'s own no-relocation invariant already guarantees.
intent: intent_mod.Plane = undefined,
/// Where an "open a workspace entry" outcome lands (§9.4). System-scoped
/// like the keymap tables and for the same reason: the pane tree is shared
/// by every head attached here, so the rule deciding which pane an open
/// reaches must be one rule, not one per head.
placement: placement_mod.Policy = .empty,
/// Primary-viewport focus changes (§7). Consumed by companion viewports,
/// statuslines, titles, and presence alike; published by the workspace's
/// layout phase, which is the only place focus actually moves.
focus: focus_feed.Feed = .empty,
/// The viewports this system's manifest declares (`weft.viewport` /
/// `weft.present`). Declarations, plus the layout phase's note of which are
/// realized — the workspace materializes them; nothing here draws.
viewports: viewport_mod.Registry = .empty,

/// Build a system from scratch: fresh buffers (one scratch buffer, per
/// `Buffers.init`), empty commands/keymap, and the built-in command/keymap
/// floor installed (`core.builtins.install` — the same modeless baseline
/// `app.Session.init` installs), so a headless system can service
/// `command.run` immediately, with no manifest applied yet.
pub fn create(gpa: Allocator, pool: *task.Pool, name: []const u8, user: []const u8) !*System {
    const self = try gpa.create(System);
    errdefer gpa.destroy(self);
    self.* = .{
        .gpa = gpa,
        .name = try gpa.dupe(u8, name),
        .buffers = try Buffers.init(gpa, pool, user),
        .container = container_mod.Container.init(gpa),
        .caps = undefined,
        .actions = undefined,
        .slot_host = undefined,
        .grants = grants_mod.HandleTable.init(gpa),
        .semantic = .init(.here),
        .filesystems = .init(gpa),
        .environments = .init(gpa),
        .place_ids = try place_mod.Ids.init(gpa),
    };
    errdefer self.buffers.deinit(gpa);
    errdefer self.semantic.deinit(gpa);
    errdefer self.filesystems.deinit();
    // `caps`/`actions` borrow `&self.container` (task #19's shared-Container
    // fold-in) — set AFTER the struct literal above so `self.container`
    // already holds its final value at a stable address (`self` is already
    // heap-allocated) before anything points into it.
    self.caps = Caps.init(gpa, task.nowNs, &self.container);
    self.actions = Actions.init(gpa, &self.container);
    self.slot_host = SlotHost.init(gpa, &self.container);
    // The one slot core both fires and decodes (`pick/annotate.zig`). Core
    // declares it because core has to READ the answers, and it can only do
    // that against a shape it knows; a plugin-declared schema would leave
    // core holding bytes it cannot interpret. Nothing else about annotation
    // is core's — no category, no note, no policy about who may write one.
    try pick.declareAnnotation(&self.container);
    try self.intent.init(gpa);
    errdefer self.intent.deinit(gpa);
    try self.intent.attachActions(gpa, &self.actions);
    try builtins.install(gpa, &self.commands, &self.keymap, &self.default_head, &self.actions);
    return self;
}

pub fn destroy(self: *System) void {
    const gpa = self.gpa;
    // A pick's acceptor belongs to the plugin plane, so deliver its terminal
    // cancellation while both the dispatch context and plugin still exist.
    var ctx = self.contextFor(&self.default_head);
    self.default_head.pick.terminate(&ctx);
    // After interaction cancellation, plugins die before any of this
    // system's OTHER state (buffers,
    // commands, caps) — mirroring `main.zig`'s pre-System defer order
    // exactly (every plugin/engine/loop-related defer ran before
    // `Session`'s own, so a plugin's registered command — its `.data`
    // pointing INTO a `WasmPlugin` — never outlives the wasmtime engine
    // that compiled it, and nothing plugin-owned is still resident when
    // buffers/commands unwind).
    if (self.plugins) |*p| p.deinit(gpa);
    self.semantic.deinit(gpa);
    self.filesystems.deinit();
    if (self.applied_manifest) |m| m.destroy();
    self.default_head.deinit(gpa);
    self.slot_host.deinit();
    self.actions.deinit();
    self.caps.deinit();
    // The shared Container outlives every borrower above (no `deinit`
    // touches it) — torn down here, once, by its owner. See `action.zig`'s/
    // `capability.zig`'s `deinit` docs for why the relative order is safe.
    self.container.deinit();
    self.intent.deinit(gpa);
    self.placement.deinit(gpa);
    self.focus.deinit(gpa);
    self.viewports.deinit(gpa);
    self.keymap.deinit(gpa);
    self.commands.deinit(gpa);
    self.buffers.deinit(gpa);
    self.place_ids.deinit();
    self.environments.deinit();
    self.config_kv.deinit(gpa);
    self.grants.deinit();
    gpa.free(self.name);
    gpa.destroy(self);
}

/// A fresh `command.Context` wired to this system's tables, dispatching AS
/// `head` (`&self.default_head`, or any head this system has `attachHead`ed
/// — see this struct's doc for why this is a cheap, rebuildable VALUE
/// rather than a persistent self-referential object like `Session.cmd_ctx`).
pub fn contextFor(self: *System, head: *Head) command.Context {
    return .{
        .gpa = self.gpa,
        .buffers = &self.buffers,
        .commands = &self.commands,
        .keymap = &self.keymap,
        .actions = &self.actions,
        .caps = &self.caps,
        .slot_host = &self.slot_host,
        .quit = &self.quit,
        .head = head,
        .grant_table = &self.grants,
        .semantic = &self.semantic,
        .filesystems = &self.filesystems,
        .intent = &self.intent,
        .viewports = &self.viewports,
        .environments = &self.environments,
        .place_ids = &self.place_ids,
    };
}

/// Revoke `capability` from `principal` (§6 W4 gate: "revoke fs from a
/// RUNNING plugin → its next fs call traps"). Invalidates every LIVE row
/// this table holds for that exact (principal, capability) pair — a plugin
/// currently possessing a handle into one of those rows fails its very
/// next `hasPerm` check (no re-load, no re-describe) and traps with a
/// REVOKED-specific message (`wasm_host/plugin.zig`'s `trapPermDenied`),
/// distinct from "never requested". Returns how many rows were invalidated
/// (0 = no match — a typo'd principal/capability name, or it was never
/// granted / already revoked). See `registerRevokeCommand` for the live
/// `revoke <plugin> <capability>` debug command this backs.
pub fn revoke(self: *System, principal: []const u8, cap_name: []const u8) usize {
    return self.grants.revoke(principal, cap_name);
}

/// The "attach" half of a rebind (§6 W2b gate (b)): land `head` in this
/// system's ACTIVE buffer's resting mode (its own saved mode, or the
/// system's base `default_mode`) — the same restore rule `Buffers.
/// switchTo` uses for an ordinary buffer switch, one level up (system
/// granularity instead of buffer granularity). Clears any half-typed
/// chord (a stale pending sequence must never combine with the new
/// system's next key).
pub fn attachHead(self: *System, gpa: Allocator, head: *Head) Allocator.Error!void {
    try head.setPending(gpa, "");
    // mechanism-not-policy (task #19 item 3): the system-attach/detach
    // rebind mechanism (`Host.swap`'s two halves) — no `*command.Context`
    // exists yet for THIS head at this point (attach IS what makes one
    // meaningful), same reasoning as `Buffers.switchTo`'s restore. Raw
    // mechanism entry (`Head.setModeRaw`), by design.
    const active = self.buffers.active();
    if (active.mode.len > 0) {
        try head.setModeRaw(gpa, active.mode);
    } else {
        // Same posture pairing `Buffers.switchTo` uses (§10.4) — an entry
        // this head has never visited still rests where its DECLARED posture
        // says, not in whatever the outgoing system was doing.
        try head.setModeRaw(gpa, self.buffers.restingModeFor(active.posture(head.semantic_focus.field != null)));
    }
}

/// The "detach" half of a rebind: stamp `head`'s current BASE mode
/// (`Keymap.baseMode`, skipping menu modes — mirrors `Buffers.switchTo`'s
/// "outgoing" half exactly) onto THIS system's active buffer, so a later
/// re-`attachHead` restores into it. Called BEFORE `head` is pointed at
/// another system (its mode/keymap lookups must still resolve against
/// THIS system's tables while this runs).
/// F4 (review): fallible, like `Buffers.switchTo`'s mirrored "outgoing"
/// half — `try gpa.dupe` propagates OOM instead of swallowing it. A
/// swallowed OOM here would leave `old.mode` holding whatever it had
/// before (stale, but not corrupt) while the CALLER (`Host.swap`) sails on
/// to repoint `c`'s tables and `attachHead` the new system regardless — a
/// silently wrong resting mode recorded for later, exactly the kind of
/// quiet drift this phase's discipline refuses. Propagating means `swap`
/// itself fails atomically instead (see its doc).
pub fn detachHead(self: *System, gpa: Allocator, head: *Head) Allocator.Error!void {
    const old = self.buffers.active();
    const base = self.keymap.baseMode(head.currentMode());
    if (!self.keymap.isMenuMode(base)) {
        const held = try gpa.dupe(u8, base);
        gpa.free(old.mode);
        old.mode = held;
    }
}

/// Apply (first load, `self.applied_manifest == null`) or reconcile
/// (subsequent loads) `m` into this system's stores — M3's `Manifest.
/// apply`/`.reconcile`, targeted at a `command.Context` dispatching as
/// `default_head` (so a fully headless system's `weft.bind`/`weft.echo`/
/// `weft.run` land somewhere real even with no attached head). Takes
/// ownership of `m`: stored as `applied_manifest`, freeing whatever was
/// applied before it. No separate "generation" bump anymore — `applyDecls`'s
/// `weft.bind`/`weft.provide`/etc. mutate `self.container` directly (through
/// `actions`/`caps`), which bumps `self.container.epoch` itself; that IS the
/// cache key now (`Ctx.epoch`, `ctx.zig`) — see `container`'s field doc.
/// `ui_bind` left unset (`ApplyCtx.ui_bind` defaults to `null`): `System` is
/// core-layer and has no path to a gfx-layer `ui_mesh` binder to wire one —
/// an embedder that wants `weft.statusSegment` reachable through THIS
/// system's manifests builds its own `ApplyCtx` (with `.ui_bind` set)
/// against `&self.container` directly instead of calling this convenience
/// wrapper (see `app/config_load.zig`'s `ConfigSession` for the app-layer
/// example).
pub fn applyManifest(self: *System, gpa: Allocator, m: *manifest.Manifest, loader: ?manifest.PluginLoader) !void {
    var c = self.contextFor(&self.default_head);
    var actx: manifest.Manifest.ApplyCtx = .{ .ctx = &c, .loader = loader, .config = &self.config_kv };
    try manifest.Manifest.reconcile(gpa, self.applied_manifest, m, &actx);
    if (self.applied_manifest) |old| old.destroy();
    self.applied_manifest = m;
}

/// Stand up this system's plugin bundle (task #19 item 3) — idempotent (a
/// second call is a no-op, so `main.zig` can call it unconditionally
/// without tracking whether it already did). Only the editor system calls
/// this today; a headless system with no plugins (agent-ux) simply never
/// does, leaving `self.plugins == null` — `command.run`/manifest apply
/// don't touch this field at all, so a plugin-free system pays nothing.
pub fn initPlugins(self: *System, pool: *task.Pool) !void {
    if (self.plugins != null) return;
    self.plugins = try Plugins.init(self.gpa, pool);
}

/// The per-system plugin bundle (task #19 item 3): the wasm `Engine`, the
/// resident wasm/JS plugin lists, the plugin-scoped `kv.Store` (runtime
/// scratch — distinct from `System.config_kv`, mirroring the old
/// `plugin_kv`/`config_kv` split one level up, now per-system), the
/// subbuffer service, the shared register/kill store, and the async `Loop`
/// shell effects schedule onto. Every field here used to be a `main()`
/// local; moving OWNERSHIP onto `System` is what makes "a second hosted
/// system could have its own plugins" structurally true, without actually
/// wiring a second system's manifest to load any (the agent-ux gate
/// manifest loads none — see this struct's field doc on `System.plugins`).
/// `app/config_load.zig`'s `PluginHost`/`WasmPlugin`/`JsPlugin` types are
/// untouched — this only relocates where instances of them are STORED.
pub const Plugins = struct {
    engine: wasm.Engine,
    loop: async_loop.Loop,
    kv: kv.Store = .empty,
    subbuffers: subbuffer.SubBuffers = .empty,
    register: register_mod.Bank = .{},
    list: std.ArrayList(*wasm_abi.WasmPlugin) = .empty,
    js_list: std.ArrayList(*quickjs.JsPlugin) = .empty,

    pub fn init(gpa: Allocator, pool: *task.Pool) !Plugins {
        return .{
            .engine = try wasm.Engine.init(gpa),
            .loop = async_loop.Loop.init(gpa, pool, task.nowNs),
        };
    }

    /// Frees in exactly the order `main.zig`'s old `defer` stack unwound
    /// (LIFO over: plugin_kv, config_kv, plugin_subs, plugin_register,
    /// plugin_loop, wasm_engine, plugins-list, js_plugins-list — config_kv
    /// is `System.config_kv` now, torn down separately by `System.destroy`,
    /// not part of this bundle): js plugins, then wasm plugins (both may
    /// hold registered commands whose `.data` points INTO them), then the
    /// engine (invalidates any compiled module those plugins referenced),
    /// then the loop, then register/subbuffers/kv (no other teardown step
    /// depends on these, so their relative order is unconstrained).
    pub fn deinit(self: *Plugins, gpa: Allocator) void {
        for (self.js_list.items) |p| p.deinit();
        self.js_list.deinit(gpa);
        for (self.list.items) |p| p.deinit();
        self.list.deinit(gpa);
        self.engine.deinit();
        self.loop.deinit();
        self.register.deinit(gpa);
        self.subbuffers.deinit(gpa);
        self.kv.deinit(gpa);
    }
};

/// The container-level registry: "the container hosts N systems" (§2.7).
/// Owns every hosted `*System` (destroyed by `Host.deinit`).
pub const Host = struct {
    gpa: Allocator,
    systems: std.StringArrayHashMapUnmanaged(*System) = .empty,

    pub fn init(gpa: Allocator) Host {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Host) void {
        for (self.systems.values()) |s| s.destroy();
        self.systems.deinit(self.gpa);
        self.* = undefined;
    }

    /// Register `system` under its own `.name`. Ownership transfers to the
    /// `Host` (freed by `deinit`); `error.AlreadyHosted` on a name clash —
    /// hosting is an explicit, one-shot act, not last-wins.
    pub fn hostSystem(self: *Host, system: *System) !void {
        const gop = try self.systems.getOrPut(self.gpa, system.name);
        if (gop.found_existing) return error.AlreadyHosted;
        gop.value_ptr.* = system;
    }

    pub fn get(self: *const Host, name: []const u8) ?*System {
        return self.systems.get(name);
    }

    /// Which hosted system `c` currently targets, found by pointer
    /// identity of its `buffers` table (the field every `contextFor` wires
    /// distinctly per system). O(hosted systems) — a handful, never a hot
    /// path.
    pub fn systemOf(self: *const Host, c: *const command.Context) ?*System {
        for (self.systems.values()) |s| {
            if (&s.buffers == c.buffers) return s;
        }
        return null;
    }

    pub const SwapError = error{ UnknownSystem, OpenTransient, PickReopenedDuringCancellation } || Allocator.Error;

    /// Re-bind `head` (dispatching through `c`) onto the hosted system
    /// named `target` — the `system-swap <name>` mechanism (§6 W2b gate
    /// (b)). If `c` currently targets a DIFFERENT hosted system, that
    /// system's `detachHead` runs first (saving `head`'s resting mode onto
    /// IT); `c`'s table/service pointers (buffers/commands/keymap/actions/
    /// caps/quit/grants/semantic) are then repointed at `target` in place —
    /// every OTHER holder of `c` sees the new system from its next read on — and `target.
    /// attachHead` lands `head` in the new system's resting mode. A swap
    /// onto the system `c` already targets is a no-op (not an error).
    ///
    /// **What else lives on `head` and what a swap does to it (review F1 —
    /// decided and documented, not left implicit):**
    ///
    ///   - `head.transient_stack` (paired transients, `ctx.zig`): REFUSES
    ///     the swap with `error.OpenTransient` (logged loudly) if any are
    ///     open. A transient frame's `return_to`/`mode` strings are minted
    ///     against the OLD system's keymap/mode vocabulary — silently
    ///     carrying them across a system boundary would let a LATER pop
    ///     land `head` in a mode that names nothing in the system it would
    ///     be popped INTO (or worse, coincidentally names something real
    ///     but unrelated there). Nothing safe to do but refuse: the caller
    ///     must pop/cancel its transients (menus) before swapping, exactly
    ///     the discipline the pairing mechanism exists to make checkable.
    ///   - `head.pick`: CANCELLED (`Pick.cancelActive`) if a session is
    ///     live. A pick's items/acceptor/source were opened against the OLD
    ///     system's buffers/commands — carrying it across would leave a
    ///     dangling reference to state the new system's `command.Context`
    ///     can't reach (accept would dispatch through the NEW system's
    ///     commands against picks built from the OLD one). Frecency
    ///     (learned ranking) is untouched — `cancelActive`, unlike
    ///     `deinit`, doesn't wipe it. If the cancellation callback opens a
    ///     replacement pick, the swap refuses rather than carrying that new
    ///     old-system session across the boundary.
    ///   - `head.dot` (dot-repeat register) and `head.echo` (status line):
    ///     KEPT, untouched. Both are head-PERSONAL, not system-referencing
    ///     state: `echo` is just displayed text, harmless anywhere. `dot`
    ///     already carries a `buf: Buffers.Id` + `synced` guard for the
    ///     structurally IDENTICAL problem of "a head arriving somewhere its
    ///     bookkeeping wasn't built for" (the two-head gate, W2a) — a `.`
    ///     replay after a swap compares against the NEW system's active
    ///     buffer id, which cannot coincidentally match a stale `buf` id
    ///     from the old system in any way `synced`'s existing guard doesn't
    ///     already handle (a replay against a genuinely different buffer is
    ///     the SAME case dot-repeat already treats as "can't repeat here" —
    ///     see `dispatch.zig`'s `dotAtRest`). No new mechanism needed.
    ///   - `head.working_target`: CLEARED. It is a revision-stamped handle
    ///     into the old system's semantic target registry; carrying it into a
    ///     different registry could make equal wire bits name unrelated
    ///     authority. A no-op swap preserves it because no registry changes.
    pub fn swap(self: *Host, gpa: Allocator, c: *command.Context, head: *Head, target: []const u8) SwapError!void {
        const to = self.get(target) orelse return error.UnknownSystem;
        if (head.hasOpenTransients()) {
            std.log.warn("system-swap: refused — head has an open transient/menu (mode '{s}'); pop it before swapping systems", .{head.currentMode()});
            return error.OpenTransient;
        }
        if (self.systemOf(c)) |from| {
            if (from == to) return;
            head.pick.cancelActive(c);
            if (head.pick.active) return error.PickReopenedDuringCancellation;
            try from.detachHead(gpa, head);
        }
        head.working_target = null;
        c.buffers = &to.buffers;
        c.commands = &to.commands;
        c.keymap = &to.keymap;
        c.actions = &to.actions;
        c.caps = &to.caps;
        c.slot_host = &to.slot_host;
        c.quit = &to.quit;
        c.grant_table = &to.grants;
        c.semantic = &to.semantic;
        c.filesystems = &to.filesystems;
        c.intent = &to.intent;
        try to.attachHead(gpa, head);
    }
};

/// The `system-swap <name>` command — `data` is the owning `*Host`. Wires
/// `Host.swap` onto the ordinary command surface, so a keybinding (or a
/// test driving it through `command.run`, exactly like any other command)
/// can trigger a live re-bind. Not installed by `builtins.install` (a
/// `Host` is optional app/embedder wiring, not a kernel default) —
/// `registerSwapCommand` below binds it explicitly onto a system that
/// wants it.
pub fn systemSwapHandler(ctx: *command.Context, data: ?*anyopaque, args: []const command.Value) anyerror!command.Value {
    const host: *Host = @ptrCast(@alignCast(data.?));
    if (args.len == 0 or args[0] != .string) return .nil;
    try host.swap(ctx.gpa, ctx, ctx.head, args[0].string);
    return .nil;
}

pub fn registerSwapCommand(gpa: Allocator, commands: *command.Commands, host: *Host) !void {
    _ = try commands.bind(gpa, "system-swap", .{
        .name = "system-swap",
        .summary = "Re-bind this head to another hosted system.",
        .args = &.{.{ .name = "name", .type = .string }},
        .handler = systemSwapHandler,
        .data = host,
    });
}

/// The `revoke <plugin> <capability>` debug command (§6 W4 gate: "a `revoke
/// <plugin> <capability>` debug command proves it live") — `data` is the
/// owning `*System`. Thin wrapper over `System.revoke`, echoing how many
/// rows it invalidated so the effect is visible without a debugger.
pub fn revokeHandler(ctx: *command.Context, data: ?*anyopaque, args: []const command.Value) anyerror!command.Value {
    const sys: *System = @ptrCast(@alignCast(data.?));
    if (args.len < 2 or args[0] != .string or args[1] != .string) return .nil;
    const n = sys.revoke(args[0].string, args[1].string);
    var buf: [160]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "revoke: {s}/{s} — {d} row(s) invalidated", .{ args[0].string, args[1].string, n }) catch "revoke: done";
    ctx.head.echo.clearRetainingCapacity();
    ctx.head.echo.appendSlice(ctx.gpa, msg) catch {};
    return .nil;
}

/// Not installed by `builtins.install` (same rationale as `registerSwapCommand`
/// — optional, per-embedder wiring): a system that wants the live `revoke`
/// debug command binds it explicitly against itself.
pub fn registerRevokeCommand(gpa: Allocator, commands: *command.Commands, system: *System) !void {
    _ = try commands.bind(gpa, "revoke", .{
        .name = "revoke",
        .summary = "Revoke a capability from a principal/plugin — its next matching use traps.",
        .args = &.{ .{ .name = "principal", .type = .string }, .{ .name = "capability", .type = .string } },
        .handler = revokeHandler,
        .data = system,
    });
}

/// `Limit`'s one-line display form for `grantsShowHandler` — `grants.zig`'s
/// `Limit` union rendered as `none` / `fs_root(<path>)` / `doc_region(<doc_id>)`.
/// Writes into `buf`, returns the written slice (never longer than `buf`;
/// truncated with no crash if a path/doc_id somehow doesn't fit — an
/// inspection command degrading gracefully beats it failing to list
/// anything).
fn formatLimit(buf: []u8, limit: grants_mod.Limit) []const u8 {
    return switch (limit) {
        .none => "none",
        // Deliberately NOT rendered as a directory: the row does not hold one.
        // `place` is resolved per dispatch, so printing today's answer beside
        // a grant that means "wherever you are" would read as a promise the
        // row never made (doc/place.md §4.1).
        .place => "place",
        .fs_root => |root| std.fmt.bufPrint(buf, "fs_root({s})", .{root}) catch buf,
        .doc_region => |dr| std.fmt.bufPrint(buf, "doc_region({s})", .{dr.doc_id}) catch buf,
        .graph_subtree => |gs| std.fmt.bufPrint(buf, "graph_subtree({s})", .{gs.doc_id}) catch buf,
    };
}

/// The `grants-show` debug command (§6 W4 slice 4: "the INSPECTION surface"
/// half of the approval-as-manifest-diff residual — a blocking approve/deny
/// prompt is explicitly NOT v1; this is). `data` is the owning `*System`.
/// Lists EVERY row this System's `HandleTable` has ever minted (alive or
/// not) as `<principal>/<capability> limit=<...> state=<alive|revoked|
/// scope_expired>` — a dead row stays listed (with its state), not erased,
/// so "what got revoked and why" is answerable without a debugger. One
/// echo line (the ordinary debug-command surface); `std.log.info` mirrors
/// each row too, for a reload-time transcript.
pub fn grantsShowHandler(ctx: *command.Context, data: ?*anyopaque, args: []const command.Value) anyerror!command.Value {
    _ = args;
    const sys: *System = @ptrCast(@alignCast(data.?));
    const gpa = ctx.gpa;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    out.appendSlice(gpa, "grants-show:") catch {};
    for (sys.grants.rows.items) |r| {
        const state: []const u8 = if (r.alive) "alive" else if (r.scope_dead) "scope_expired" else "revoked";
        var limit_buf: [256]u8 = undefined;
        const limit_str = formatLimit(&limit_buf, r.limit);
        const line = std.fmt.allocPrint(gpa, " {s}/{s} limit={s} state={s}", .{ r.principal, r.capability, limit_str, state }) catch continue;
        defer gpa.free(line);
        out.appendSlice(gpa, line) catch {};
        std.log.info("grants-show:{s}", .{line});
    }
    if (sys.grants.rows.items.len == 0) out.appendSlice(gpa, " (empty)") catch {};
    ctx.head.echo.clearRetainingCapacity();
    ctx.head.echo.appendSlice(gpa, out.items) catch {};
    return .nil;
}

/// Not installed by `builtins.install` (same rationale as `registerRevokeCommand`
/// above): a system that wants the live `grants-show` inspection command
/// binds it explicitly against itself.
pub fn registerGrantsShowCommand(gpa: Allocator, commands: *command.Commands, system: *System) !void {
    _ = try commands.bind(gpa, "grants-show", .{
        .name = "grants-show",
        .summary = "List every row in the grant table: principal, capability, limit, state.",
        .args = &.{},
        .handler = grantsShowHandler,
        .data = system,
    });
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;
const schema_mod = @import("weft_schema");

fn testSystem(gpa: Allocator, pool: *task.Pool, name: []const u8) !*System {
    return System.create(gpa, pool, name, "user");
}

test "system: create/destroy — a fresh headless system services command.run immediately" {
    const gpa = t.allocator;
    const pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    const sys = try testSystem(gpa, pool, "editor");
    defer sys.destroy();

    var c = sys.contextFor(&sys.default_head);
    try sys.default_head.setModeRaw(gpa, "default");
    _ = try command.run(&sys.commands, &c, "insert-text", &.{.{ .string = "hi" }});
    const rope = (try c.textEditor()).text();
    const got = try rope.toOwnedSlice(gpa);
    defer gpa.free(got);
    try t.expectEqualStrings("hi", got);
}

test "system: GATE (a) — the container hosts TWO systems concurrently, one headed, one headless, both servicing" {
    const gpa = t.allocator;
    const pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();

    var host = Host.init(gpa);
    defer host.deinit();
    const editor_sys = try testSystem(gpa, pool, "editor");
    try host.hostSystem(editor_sys);
    const agent_sys = try testSystem(gpa, pool, "agent-ux");
    try host.hostSystem(agent_sys);

    // The editor system is HEADED: a real Head attached to it.
    var editor_head: Head = .empty;
    defer editor_head.deinit(gpa);
    try editor_sys.attachHead(gpa, &editor_head);
    var ec = editor_sys.contextFor(&editor_head);
    try editor_head.setModeRaw(gpa, "default");
    _ = try command.run(&editor_sys.commands, &ec, "insert-text", &.{.{ .string = "editor text" }});

    // The agent-ux system is HEADLESS: no head ever attaches to it, but its
    // OWN default_head lets a direct command.run edit its buffer anyway.
    var ac = agent_sys.contextFor(&agent_sys.default_head);
    try agent_sys.default_head.setModeRaw(gpa, "default");
    _ = try command.run(&agent_sys.commands, &ac, "insert-text", &.{.{ .string = "agent text" }});

    // Both landed on their OWN buffer, entirely independent of the other.
    const editor_got = try (try ec.textEditor()).text().toOwnedSlice(gpa);
    defer gpa.free(editor_got);
    try t.expectEqualStrings("editor text", editor_got);

    const agent_got = try (try ac.textEditor()).text().toOwnedSlice(gpa);
    defer gpa.free(agent_got);
    try t.expectEqualStrings("agent text", agent_got);

    // review nit: config_kv isolation — a value set in ONE system's store
    // (as `weft.set`/`Manifest.applyDecls` would) is simply absent from the
    // other's, not merely differently-valued. Two per-system `kv.Store`s,
    // not one shared table with a system-prefixed key.
    try editor_sys.config_kv.put(gpa, "theme", "accent", "#8ec07c");
    try t.expectEqualStrings("#8ec07c", editor_sys.config_kv.get("theme", "accent").?);
    try t.expectEqual(@as(?[]const u8, null), agent_sys.config_kv.get("theme", "accent"));
}

test "system: GATE (b) — a head re-binds editor<->agent-ux live: tables switch, mode restored per resting rules" {
    const gpa = t.allocator;
    const pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();

    var host = Host.init(gpa);
    defer host.deinit();
    const editor_sys = try testSystem(gpa, pool, "editor");
    try host.hostSystem(editor_sys);
    try editor_sys.keymap.bind(gpa, "normal", "i", "enter-insert-noop", Keymap.prio_plugin, "test");
    try editor_sys.keymap.setFallback(gpa, "visual", "normal"); // vim-style: visual's BASE is normal
    const agent_sys = try testSystem(gpa, pool, "agent-ux");
    try host.hostSystem(agent_sys);
    try agent_sys.keymap.bind(gpa, "chat", "q", "agent-quit-noop", Keymap.prio_plugin, "test");

    var head: Head = .empty;
    defer head.deinit(gpa);
    try editor_sys.attachHead(gpa, &head);
    try head.setModeRaw(gpa, "visual"); // a transient-ish editing mode, not menu

    var c = editor_sys.contextFor(&head);
    // Direct table lookups (by explicit mode name, not through `head` —
    // `head` itself is in "visual" right now, a different mode than either
    // bind): the editor's own bind is live on its OWN table; agent-ux's
    // "chat" bind is nowhere in the editor's table.
    try t.expect(editor_sys.keymap.lookup("normal", "i") != null);
    try t.expectEqual(@as(?[]const u8, null), editor_sys.keymap.lookup("chat", "q"));
    head.working_target = .{
        .target = .{ .authority = .here, .slot = 7, .generation = 1 },
        .revision = 3,
    };
    try host.swap(gpa, &c, &head, "editor");
    try t.expect(head.working_target != null); // a no-op keeps the same registry

    // Swap onto agent-ux: keymap tables switch (head now resolves AGENT's
    // binds, not the editor's), and the OLD (editor) system's active buffer
    // remembers "visual"'s BASE (normal) — the detach-time resting rule —
    // exactly as `Buffers.switchTo` would for an ordinary buffer switch.
    try host.swap(gpa, &c, &head, "agent-ux");
    try t.expect(head.working_target == null);
    try t.expectEqualStrings("normal", editor_sys.buffers.active().mode);
    try t.expect(c.buffers == &agent_sys.buffers);
    try t.expect(c.keymap == &agent_sys.keymap);
    // review nit: EVERY table pointer repoints, not just buffers/keymap.
    try t.expect(c.commands == &agent_sys.commands);
    try t.expect(c.actions == &agent_sys.actions);
    try t.expect(c.caps == &agent_sys.caps);
    try t.expect(c.quit == &agent_sys.quit);
    try t.expect(c.semantic.? == &agent_sys.semantic);
    try t.expect(c.filesystems.? == &agent_sys.filesystems);
    // W4 slice 1: the grant table repoints too — a captured Ctx after a
    // swap must resolve against the NEW system's grants, never the old
    // one's (each system owns its own table, `System.create`'s doc).
    try t.expect(c.grant_table.? == &agent_sys.grants);

    // Interaction state does NOT leak across: the head's mode is whatever
    // agent-ux's resting rule gives a fresh attach (its buffer never
    // visited "visual" — it lands on agent-ux's own default/empty resting
    // mode), not a carried-over "visual".
    try t.expect(!std.mem.eql(u8, "visual", head.currentMode()));

    // Swapping BACK restores the editor system's remembered resting mode
    // ("normal", stamped by the earlier detach) — proof the round trip
    // doesn't silently drop state either.
    try host.swap(gpa, &c, &head, "editor");
    try t.expectEqualStrings("normal", head.currentMode());
    try t.expect(c.keymap == &editor_sys.keymap);
    try t.expect(c.filesystems.? == &editor_sys.filesystems);
}

test "system: GATE (b) via the system-swap COMMAND — same mechanism, real command.run" {
    const gpa = t.allocator;
    const pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();

    var host = Host.init(gpa);
    defer host.deinit();
    const editor_sys = try testSystem(gpa, pool, "editor");
    try host.hostSystem(editor_sys);
    const agent_sys = try testSystem(gpa, pool, "agent-ux");
    try host.hostSystem(agent_sys);

    var head: Head = .empty;
    defer head.deinit(gpa);
    try editor_sys.attachHead(gpa, &head);
    var c = editor_sys.contextFor(&head);
    try registerSwapCommand(gpa, &editor_sys.commands, &host);

    _ = try command.run(&editor_sys.commands, &c, "system-swap", &.{.{ .string = "agent-ux" }});
    try t.expect(c.buffers == &agent_sys.buffers);
}

test "system: F1 — swap REFUSES while a transient/menu is open, nothing repointed" {
    const gpa = t.allocator;
    const pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();

    var host = Host.init(gpa);
    defer host.deinit();
    const editor_sys = try testSystem(gpa, pool, "editor");
    try host.hostSystem(editor_sys);
    try editor_sys.keymap.markMenuMode(gpa, "leader");
    const agent_sys = try testSystem(gpa, pool, "agent-ux");
    try host.hostSystem(agent_sys);

    var head: Head = .empty;
    defer head.deinit(gpa);
    try editor_sys.attachHead(gpa, &head);
    try head.setModeRaw(gpa, "normal");
    var c = editor_sys.contextFor(&head);

    const cc = c.capturedCtx();
    var handle = try cc.pushTransient(&editor_sys.keymap, "leader");
    try t.expect(head.hasOpenTransients());

    try t.expectError(error.OpenTransient, host.swap(gpa, &c, &head, "agent-ux"));
    // Refused atomically: `c` still targets the editor system, `head` is
    // still in the menu it was in, and the transient is still open — a
    // rejected swap must not have partially repointed anything.
    try t.expect(c.buffers == &editor_sys.buffers);
    try t.expect(c.keymap == &editor_sys.keymap);
    try t.expectEqualStrings("leader", head.currentMode());
    try t.expect(head.hasOpenTransients());

    // Popping the transient first makes the SAME swap succeed.
    handle.deinit();
    try t.expect(!head.hasOpenTransients());
    try host.swap(gpa, &c, &head, "agent-ux");
    try t.expect(c.buffers == &agent_sys.buffers);
}

test "system: F1 — swap CANCELS an open pick (references the system being left), keeps dot/echo" {
    const gpa = t.allocator;
    const pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();

    var host = Host.init(gpa);
    defer host.deinit();
    const editor_sys = try testSystem(gpa, pool, "editor");
    try host.hostSystem(editor_sys);
    const agent_sys = try testSystem(gpa, pool, "agent-ux");
    try host.hostSystem(agent_sys);

    var head: Head = .empty;
    defer head.deinit(gpa);
    try editor_sys.attachHead(gpa, &head);
    var c = editor_sys.contextFor(&head);

    // A live pick session, opened against the EDITOR system (its acceptor/
    // items are meaningless once `c` points elsewhere).
    const Sink = struct {
        cancelled: bool = false,
        fn accept(_: *command.Context, data: ?*anyopaque, outcome: pick.Outcome) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.cancelled = outcome == .cancelled;
        }
    };
    var sink: Sink = .{};
    try head.pick.open(&c, "find", &.{.{ .text = "apple" }}, .{ .handler = Sink.accept, .data = &sink });
    try t.expect(head.pick.active);

    // Head-personal state that should SURVIVE the swap untouched.
    try head.echo.appendSlice(gpa, "kept across swap");
    head.dot.reg_n = 1;
    head.dot.reg[0] = .{ .slen = 1, .tlen = 0 };
    head.dot.reg[0].spec[0] = 'x';

    try host.swap(gpa, &c, &head, "agent-ux");

    // The pick is gone (cancelled, not carried across).
    try t.expect(!head.pick.active);
    try t.expect(sink.cancelled);
    // dot/echo untouched — head-personal, not system-referencing.
    try t.expectEqualStrings("kept across swap", head.echo.items);
    try t.expectEqual(@as(usize, 1), head.dot.reg_n);
}

test "system: GATE (c) — a manifest-driven provide scoped to one buffer's lang doesn't apply globally" {
    // "Override one slot in one buffer without global effect" — proven
    // through a REAL manifest (`weft.provide`), applied to a System, using
    // the buffer-fact predicate (`lang`) exactly as config would write it.
    // Two buffers, only one matching, prove the override is buffer-scoped
    // (via the merged Ctx facts), not process-global.
    const gpa = t.allocator;
    const pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    const sys = try testSystem(gpa, pool, "editor");
    defer sys.destroy();

    const m = try manifest.Manifest.create(gpa, "config", .config);
    try m.addAction("format-file");
    try m.addProvide("format-file", "", "nix", "nix-fmt", 0); // lang=nix only
    try sys.applyManifest(gpa, m, null);

    const nix_id = try sys.buffers.create(gpa, "flake.nix");
    const zig_id = try sys.buffers.create(gpa, "main.zig");

    var c = sys.contextFor(&sys.default_head);
    try sys.buffers.switchTo(gpa, nix_id, &sys.default_head, &sys.keymap);
    try t.expectEqualStrings("nix-fmt", sys.actions.resolve("format-file", c.actionCtx()).?);

    try sys.buffers.switchTo(gpa, zig_id, &sys.default_head, &sys.keymap);
    try t.expectEqual(@as(?[]const u8, null), sys.actions.resolve("format-file", c.actionCtx()));
}

test "system: the real config/agent-ux.js manifest hosts a SECOND system end-to-end" {
    // "Hosting a second system = evaluating a second manifest into a second
    // bundle" (§2.3), proven against the ACTUAL shipped file (not a Zig
    // stand-in for it) — the same `evalToManifest` entry point `main.zig`
    // uses for the primary editor system, targeted at a headless System's
    // own Context. Skips (not fails) when run outside the repo checkout —
    // same discipline as quickjs.zig's "every shipped example config evals"
    // test, which now also covers this file in its own path list.
    const gpa = t.allocator;
    const src = @import("file.zig").readAlloc(gpa, "config/agent-ux.js") catch return;
    defer gpa.free(src);

    const pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    const agent_sys = try testSystem(gpa, pool, "agent-ux");
    defer agent_sys.destroy();

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    var c = agent_sys.contextFor(&agent_sys.default_head);
    const m = try quickjs.evalToManifest(&engine, &c, null, &agent_sys.config_kv, "config", src, .config, "agent-ux");
    try agent_sys.applyManifest(gpa, m, null);

    // The binds landed on THIS system's keymap — nowhere else.
    try t.expectEqualStrings("agent-ux-quit", agent_sys.keymap.lookup("normal", "q").?);
    try t.expectEqualStrings("agent-ux-status", agent_sys.keymap.lookup("normal", "space a s").?); // "SPC a s" normalizes to "space a s" — Keymap.zig's canonical form
    // The startup echo landed on the system's default head.
    try t.expectEqualStrings("agent-ux: minimal system loaded", agent_sys.default_head.echo.items);

    // Headless the whole time: no Head other than `default_head` ever
    // attached, and the system fully evaluated + applied its own manifest.
    try t.expect(!agent_sys.default_head.hasOpenTransients());
}

test "system: W4 slice 1 — the System-owned grant table, capture-time resolution, and the live revoke command" {
    const gpa = t.allocator;
    const pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    const sys = try testSystem(gpa, pool, "editor");
    defer sys.destroy();

    // A plugin-lifetime grant, minted the way `wasm_host/plugin.zig`'s
    // `mintGrantHandles` would at load time — directly against the System's
    // OWN table (`grants.zig`'s module doc: "the GRANT TABLE a System
    // owns").
    const h = try sys.grants.grant(.{ .capability = "fs_read" }, "notes", null);
    try t.expect(sys.grants.check(h));

    // CAPTURE-TIME resolution (§2.4): a `Ctx` captured for the "notes"
    // principal, through a `Context` this system handed out, collects the
    // matching row — `contextFor` wires `grant_table` automatically.
    var c = sys.contextFor(&sys.default_head);
    c.principal = .{ .role = .plugin, .name = "notes" };
    const captured = c.capturedCtx();
    try t.expectEqual(@as(usize, 1), captured.grants.len);
    try t.expectEqual(h.idx, captured.grants.constSlice()[0].idx);

    // A DIFFERENT principal's capture sees nothing of "notes"'s grant — no
    // wallet, no cross-principal leak.
    c.principal = .{ .role = .plugin, .name = "vim" };
    try t.expectEqual(@as(usize, 0), c.capturedCtx().grants.len);
    c.principal = .{ .role = .plugin, .name = "notes" };

    // The live `revoke` debug command (§6 W4 gate) invalidates the row —
    // through the ordinary command surface, exactly as a keybinding would.
    try registerRevokeCommand(gpa, &sys.commands, sys);
    _ = try command.run(&sys.commands, &c, "revoke", &.{ .{ .string = "notes" }, .{ .string = "fs_read" } });

    try t.expect(!sys.grants.check(h));
    try t.expectEqual(grants_mod.Reason.revoked, sys.grants.reasonFor(h));
    try t.expectEqualStrings("revoke: notes/fs_read — 1 row(s) invalidated", sys.default_head.echo.items);

    // A capture AFTER revocation no longer collects the dead row.
    try t.expectEqual(@as(usize, 0), c.capturedCtx().grants.len);
}

test "system: W4 slice 4 — grants-show lists every row, alive and dead, with its limit and state" {
    const gpa = t.allocator;
    const pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    const sys = try testSystem(gpa, pool, "editor");
    defer sys.destroy();

    _ = try sys.grants.grant(.{ .capability = "fs_read" }, "notes", null);
    _ = try sys.grants.grant(.{ .capability = "fs_write", .limit = .{ .fs_root = "repo" } }, "git", null);
    _ = sys.grants.revoke("notes", "fs_read");

    try registerGrantsShowCommand(gpa, &sys.commands, sys);
    var c = sys.contextFor(&sys.default_head);
    _ = try command.run(&sys.commands, &c, "grants-show", &.{});

    const echoed = sys.default_head.echo.items;
    try t.expect(std.mem.indexOf(u8, echoed, "notes/fs_read limit=none state=revoked") != null);
    try t.expect(std.mem.indexOf(u8, echoed, "git/fs_write limit=fs_root(repo) state=alive") != null);
}

test "a System-produced context can actually fire a slot" {
    const gpa = t.allocator;
    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    const sys = try System.create(gpa, pool, "editor", "user");
    defer sys.destroy();

    var head: Head = .empty;
    defer head.deinit(gpa);
    try sys.attachHead(gpa, &head);
    var ctx = sys.contextFor(&head);

    // The regression this slice exists for: `contextFor` set every other
    // field and never this one, so the whole `wl_slot_*` surface was a
    // no-op in the shipped binary while its fixtures — which bring their own
    // host — passed. A null here means a plugin can declare, bind and fire
    // and silently get nothing.
    try t.expect(ctx.slot_host != null);
    try t.expect(ctx.slot_host.? == &sys.slot_host);

    // …and it is wired to the SAME container `caps`/`actions` bind into, so
    // a slot name shares the one flat namespace rather than living in a
    // parallel registry nothing else can see.
    const str_ty: schema_mod.Schema = .str;
    const schema: schema_mod.Schema = .{ .@"struct" = &[_]schema_mod.Schema.Field{
        .{ .name = "label", .ty = &str_ty },
    } };
    try sys.container.declareSlot(.{
        .name = "ui/probe",
        .shape = .query,
        .composition = .ordered_union,
        .schema = &schema,
    });
    const Impl = struct {
        fn handle(_: ?*anyopaque, h: *SlotHost, req: *const @import("slot.zig").Request) anyerror!void {
            const vals = [_]schema_mod.Value{.{ .str = "answered" }};
            const bytes = try schema_mod.encode(h.gpa, req.schema, .{ .@"struct" = &vals });
            defer h.gpa.free(bytes);
            try h.push(req.session, .{ .owner = "probe-provider" }, bytes);
        }
    };
    try ctx.slot_host.?.register(.{ .slot = "ui/probe", .owner = "probe-provider", .handler = Impl.handle });

    const id = (try ctx.slot_host.?.fire("ui/probe", .{}, "v0", .{})).?;
    defer ctx.slot_host.?.finish(id);
    const session = ctx.slot_host.?.session(id).?;
    try t.expectEqual(@as(usize, 1), session.all().len);
    try t.expectEqualStrings("probe-provider", session.all()[0].provider);
}

test {
    std.testing.refAllDecls(@This());
}
