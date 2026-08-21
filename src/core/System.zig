//! System — the system-scoped state bundle a manifest applies INTO
//! (north-star-plan §2.3/§2.7, W2b): the keymap TABLES, the buffer set, the
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
const Buffers = @import("Buffers.zig");
const Keymap = @import("Keymap.zig");
const Head = @import("Head.zig");
const capability = @import("capability.zig");
const Caps = capability.Caps;
const Actions = @import("action.zig");
const kv = @import("kv.zig");
const builtins = @import("builtins.zig");
const manifest = @import("manifest.zig");
const task = @import("task.zig");

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
caps: Caps,
actions: Actions,
/// Config-value store (`weft.set`) for THIS system's manifest — distinct
/// from any other hosted system's, so `weft.set("acp", "cmd", ...)` in
/// the editor's config.js can never leak into agent-ux's store or vice
/// versa (mirrors `main.zig`'s `config_kv`/`plugin_kv` split, one level
/// up: per-SYSTEM now, not just per-store-kind).
config_kv: kv.Store = .empty,
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
/// Bumped on every `applyManifest` call — the cache key `ctx.zig`'s
/// `Ctx.epoch` reads. See that field's doc for exactly what this
/// over-approximates (every binding-affecting mutation in this system,
/// not a precise per-slot invalidation) and why: `action.zig`/
/// `capability.zig` each still hold their OWN `container.Container`
/// instance (F5's fold-in is a named W3 deletion gate, not done yet), so
/// there is no single Container to read a true epoch from today. A
/// coarser-than-necessary cache key that never under-invalidates is the
/// honest W2b interim, not a precise miss.
generation: u64 = 0,

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
        .caps = Caps.init(gpa, task.nowNs),
        .actions = Actions.init(gpa),
    };
    errdefer self.buffers.deinit(gpa);
    try builtins.install(gpa, &self.commands, &self.keymap, &self.default_head, &self.actions);
    return self;
}

pub fn destroy(self: *System) void {
    const gpa = self.gpa;
    if (self.applied_manifest) |m| m.destroy();
    self.default_head.deinit(gpa);
    self.actions.deinit();
    self.caps.deinit();
    self.keymap.deinit(gpa);
    self.commands.deinit(gpa);
    self.buffers.deinit(gpa);
    self.config_kv.deinit(gpa);
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
        .quit = &self.quit,
        .head = head,
    };
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
    const active = self.buffers.active();
    if (active.mode.len > 0) {
        try head.setMode(gpa, active.mode);
    } else if (self.buffers.default_mode.len > 0) {
        try head.setMode(gpa, self.buffers.default_mode);
    } else {
        try head.setMode(gpa, "");
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
/// applied before it. Bumps `generation`.
pub fn applyManifest(self: *System, gpa: Allocator, m: *manifest.Manifest, loader: ?manifest.PluginLoader) !void {
    var c = self.contextFor(&self.default_head);
    var actx: manifest.Manifest.ApplyCtx = .{ .ctx = &c, .loader = loader, .config = &self.config_kv };
    try manifest.Manifest.reconcile(gpa, self.applied_manifest, m, &actx);
    if (self.applied_manifest) |old| old.destroy();
    self.applied_manifest = m;
    self.generation +%= 1;
}

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

    pub const SwapError = error{ UnknownSystem, OpenTransient } || Allocator.Error;

    /// Re-bind `head` (dispatching through `c`) onto the hosted system
    /// named `target` — the `system-swap <name>` mechanism (§6 W2b gate
    /// (b)). If `c` currently targets a DIFFERENT hosted system, that
    /// system's `detachHead` runs first (saving `head`'s resting mode onto
    /// IT); `c`'s table pointers (buffers/commands/keymap/actions/caps/
    /// quit) are then repointed at `target` in place — every OTHER holder
    /// of `c` sees the new system from its next read on — and `target.
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
    ///     `deinit`, doesn't wipe it.
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
    pub fn swap(self: *Host, gpa: Allocator, c: *command.Context, head: *Head, target: []const u8) SwapError!void {
        const to = self.get(target) orelse return error.UnknownSystem;
        if (head.hasOpenTransients()) {
            std.log.warn("system-swap: refused — head has an open transient/menu (mode '{s}'); pop it before swapping systems", .{head.currentMode()});
            return error.OpenTransient;
        }
        if (self.systemOf(c)) |from| {
            if (from == to) return;
            try from.detachHead(gpa, head);
        }
        head.pick.cancelActive(gpa);
        c.buffers = &to.buffers;
        c.commands = &to.commands;
        c.keymap = &to.keymap;
        c.actions = &to.actions;
        c.caps = &to.caps;
        c.quit = &to.quit;
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

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

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
    try sys.default_head.setMode(gpa, "default");
    _ = try command.run(&sys.commands, &c, "insert-text", &.{.{ .string = "hi" }});
    const rope = c.editor().text();
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
    try editor_head.setMode(gpa, "default");
    _ = try command.run(&editor_sys.commands, &ec, "insert-text", &.{.{ .string = "editor text" }});

    // The agent-ux system is HEADLESS: no head ever attaches to it, but its
    // OWN default_head lets a direct command.run edit its buffer anyway.
    var ac = agent_sys.contextFor(&agent_sys.default_head);
    try agent_sys.default_head.setMode(gpa, "default");
    _ = try command.run(&agent_sys.commands, &ac, "insert-text", &.{.{ .string = "agent text" }});

    // Both landed on their OWN buffer, entirely independent of the other.
    const editor_got = try ec.editor().text().toOwnedSlice(gpa);
    defer gpa.free(editor_got);
    try t.expectEqualStrings("editor text", editor_got);

    const agent_got = try ac.editor().text().toOwnedSlice(gpa);
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
    try head.setMode(gpa, "visual"); // a transient-ish editing mode, not menu

    var c = editor_sys.contextFor(&head);
    // Direct table lookups (by explicit mode name, not through `head` —
    // `head` itself is in "visual" right now, a different mode than either
    // bind): the editor's own bind is live on its OWN table; agent-ux's
    // "chat" bind is nowhere in the editor's table.
    try t.expect(editor_sys.keymap.lookup("normal", "i") != null);
    try t.expectEqual(@as(?[]const u8, null), editor_sys.keymap.lookup("chat", "q"));

    // Swap onto agent-ux: keymap tables switch (head now resolves AGENT's
    // binds, not the editor's), and the OLD (editor) system's active buffer
    // remembers "visual"'s BASE (normal) — the detach-time resting rule —
    // exactly as `Buffers.switchTo` would for an ordinary buffer switch.
    try host.swap(gpa, &c, &head, "agent-ux");
    try t.expectEqualStrings("normal", editor_sys.buffers.active().mode);
    try t.expect(c.buffers == &agent_sys.buffers);
    try t.expect(c.keymap == &agent_sys.keymap);
    // review nit: EVERY table pointer repoints, not just buffers/keymap.
    try t.expect(c.commands == &agent_sys.commands);
    try t.expect(c.actions == &agent_sys.actions);
    try t.expect(c.caps == &agent_sys.caps);
    try t.expect(c.quit == &agent_sys.quit);

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
    try head.setMode(gpa, "normal");
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
        fn accept(_: *command.Context, _: ?*anyopaque, _: []const u8) anyerror!void {}
    };
    try head.pick.open(&c, "find", &.{.{ .text = "apple" }}, .{ .handler = Sink.accept });
    try t.expect(head.pick.active);

    // Head-personal state that should SURVIVE the swap untouched.
    try head.echo.appendSlice(gpa, "kept across swap");
    head.dot.reg_n = 1;
    head.dot.reg[0] = .{ .slen = 1, .tlen = 0 };
    head.dot.reg[0].spec[0] = 'x';

    try host.swap(gpa, &c, &head, "agent-ux");

    // The pick is gone (cancelled, not carried across).
    try t.expect(!head.pick.active);
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

    const quickjs = @import("quickjs.zig");
    const wasm = @import("wasm.zig");
    var engine = try wasm.Engine.init();
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

test {
    std.testing.refAllDecls(@This());
}
