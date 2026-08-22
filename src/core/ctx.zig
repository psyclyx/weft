//! Ctx — the captured interaction value (north-star-plan §2.1, W2b). A
//! `Ctx` is a snapshot taken at dispatch entry: the live scope stack
//! (workspace → system → head → buffer → subbuffer → mode → transient,
//! F4's seven kinds — `pane` is a FACT on the head scope, `principal` is
//! identity and never a scope axis), the invoking principal, a captured
//! locus, resolved grants (a placeholder today — real capture-time grant
//! resolution is W4, §2.4), and an epoch (a cache key; see below).
//!
//! **This is the value the plan describes, plus one honest addition.**
//! §2.1's pseudocode shows `Ctx` as pure data (scopes/principal/locus/
//! grants/epoch). That's the immutable HALF; the other half is that
//! `ctx.setMode`/`ctx.pushTransient` have to actually reach the mechanism
//! (`Head`/`Keymap`) to do anything — a value with no way back to the live
//! dispatching state could describe a decision but never enact one. `host`
//! is that back-reference: the `*command.Context` this `Ctx` was captured
//! from. It is NOT part of the "facts" half (never read by
//! `mergedFacts`/resolution — those only ever see `scopes`), and it is
//! exactly what makes `capture` cheap: no allocation, a handful of borrowed
//! slices, one pointer.
//!
//! **The POLICY door, not the mechanism.** `Head.setMode`/`Head.enterMode`
//! stay the mechanism (unchanged, still the thing that actually mutates
//! `Head.mode`) — see north-star-plan §5 "Mode changes — REVISED": the
//! user's call was that the imperative call STAYS, what changes is where it
//! lives. `Ctx.setMode` is the ONLY door core/host code should call it
//! through going forward: it requires a `Ctx`, and a `Ctx` requires a live
//! `*command.Context` to `capture` from. Code with no `*command.Context` in
//! scope — a raw host-import trampoline reached from a background poll, a
//! timer, a proc-fill callback — has no local binding to call `capture` on
//! in the first place, so routing mode changes through this door is what
//! makes "shell forces normal mode from a fill" (the historical leak class,
//! `doc/mode-leak-class.md`) structurally awkward to reintroduce, not
//! merely discouraged by convention. See the bottom of this file
//! ("BACKGROUND CODE CANNOT — a worked, honest example") for exactly how
//! far that guarantee reaches today and where it does not yet (W2b judgment
//! call — the escape hatch is named, not hidden).
//!
//! **Migration status (W2b):** `Head.setMode`'s ~150 existing call sites
//! (guest `weft.setMode`, `dispatch.zig`'s menu machinery, `Pick.zig`'s
//! save/restore, `Buffers.switchTo`'s mode restore, `builtins.zig`) are
//! NOT bulk-migrated in this pass — see this module's and `System.zig`'s
//! doc for why (mostly: they each carry their own nuanced restore/sticky/
//! menu-return semantics that deserve a dedicated migration + full
//! regression pass, not a rushed swap that risks the "byte-identical"
//! requirement). What IS real and load-bearing: the door exists, is
//! tested end-to-end (capture → setMode → Head.mode changes), and is the
//! documented target for every NEW dispatch-path mode change.
//!
//! **F3 follow-up, named (review):** once the production menu-enter path
//! (`dispatch.zig`'s legacy mode-menu path, `Pick.zig`'s save/restore)
//! actually migrates onto `pushTransient`, the `mode` scope's fact source
//! should become `Head.transient_stack`'s top frame when one is open
//! (today `Ctx.capture`'s `mode` scope always reads `Head.currentMode()`
//! directly, which happens to already reflect the top transient's mode
//! since `pushTransientMode` calls `enterMode` — but that's Head's
//! internal wiring, not something `capture` reads as "the mode scope's
//! source of truth IS the transient stack" the way §2.1 implies once
//! transients are the norm rather than the exception). Not needed until
//! the migration above happens; noted so it isn't lost.
//!
//! **Paired transients** (§2.1: "`ctx.push(transient)` returns a value
//! whose going-out-of-scope IS the pop"). Zig has no destructors, so
//! "going out of scope" is an owned value with a `deinit` CONTRACT, not a
//! language guarantee — the same idiom every other owned resource in this
//! codebase already uses (`Pick`, `ArrayList`, …). `pushTransient` pushes a
//! frame onto `Head.transient_stack` (the durable record — it outlives any
//! one Zig stack frame, so a transient can span many keypresses, exactly
//! like a real menu) and returns a `TransientHandle`; `.deinit()` pops it.
//! Popping is LIFO-checked: an out-of-order pop (something else pushed on
//! top and never popped) is REFUSED, not silently misapplied — the
//! "menu-mode leaks" bug class becomes a loud, detectable event
//! (`Head.hasOpenTransients`) instead of quietly corrupting the mode
//! stack. `.deinit()` is idempotent, so `defer handle.deinit()` is always
//! safe even on an error path that already popped explicitly.

const std = @import("std");
const Allocator = std.mem.Allocator;
const command = @import("command.zig");
const facts_mod = @import("facts.zig");
const authority = @import("authority.zig");
const locus_mod = @import("locus.zig");
const action_mod = @import("action.zig");
const Head = @import("Head.zig");

pub const Facts = facts_mod.Facts;
pub const Principal = authority.Principal;
pub const Locus = locus_mod.Locus;

/// The seven scope kinds (north-star-plan F4, DECIDED): "The seven scope
/// kinds; `pane` is a fact on head scopes; `principal` is identity, never a
/// scope axis." Order matters for `mergedFacts`: outermost first, innermost
/// (later) shadows — §2.1's "facts merge across ALL live scopes ... buffer/
/// subbuffer ... head/mode/transient ... innermost shadows".
pub const ScopeKind = enum { workspace, system, head, buffer, subbuffer, mode, transient };

pub const Scope = struct {
    kind: ScopeKind,
    facts: Facts = .{},
};

/// The 6 ALWAYS-present scopes a capture assembles: workspace, system,
/// head, buffer, subbuffer, mode. (Not `transient` — those are however
/// many `Head.transient_stack` currently holds, 0..`Head.max_open_transients`.)
pub const max_fixed_scopes = 6;

/// Fixed capacity for one capture's scope stack (review F2: this is now a
/// REAL, ENFORCED limit, not a soft target) — the 6 fixed scopes plus
/// `Head.max_open_transients`. The transient side of that budget is
/// enforced at PUSH time (`Head.pushTransientMode` refuses a push past
/// `max_open_transients` — see its doc): a `Ctx.capture` can therefore
/// never legitimately overflow `ScopeList`, because a Head can never hold
/// more open transients than this array has room for. Bounded so `capture`
/// never allocates on the hot dispatch path (§2.1: "cheap ... no
/// allocation on the hot path if possible").
pub const max_scopes = max_fixed_scopes + Head.max_open_transients;

/// A fixed-capacity scope list — `std.BoundedArray` doesn't exist in this
/// Zig; this is the same idea, sized to `max_scopes`, used only here.
pub const ScopeList = struct {
    items: [max_scopes]Scope = undefined,
    len: usize = 0,

    /// Append a scope. In the ORDINARY case (`len < max_scopes`) this is
    /// the obvious push. Overflowing should be UNREACHABLE — the transient
    /// side is capacity-checked before it ever reaches here (see
    /// `max_scopes`'s doc) and the 6 fixed scopes always fit — so this is
    /// belt-and-suspenders for a future fixed scope added without updating
    /// the budget, not a path any test here expects to hit. If it DOES
    /// happen: fail LOUDLY (`std.log.warn`, never silent) and drop the
    /// OUTERMOST scope (index 0), not the newest (review F2's directed
    /// policy) — the newest carries the most specific, currently-live facts
    /// (the innermost transient/mode shadow a resolution call actually
    /// wants); the outermost (`workspace`) carries none yet in this phase.
    pub fn append(self: *ScopeList, s: Scope) void {
        if (self.len < max_scopes) {
            self.items[self.len] = s;
            self.len += 1;
            return;
        }
        std.log.warn("ctx: scope capture overflowed max_scopes ({d}) — dropping the OUTERMOST scope (kind {t}); this should be unreachable, see ScopeList.append's doc", .{ max_scopes, self.items[0].kind });
        var i: usize = 0;
        while (i + 1 < max_scopes) : (i += 1) self.items[i] = self.items[i + 1];
        self.items[max_scopes - 1] = s;
    }

    pub fn constSlice(self: *const ScopeList) []const Scope {
        return self.items[0..self.len];
    }

    pub fn get(self: *const ScopeList, i: usize) Scope {
        return self.items[i];
    }
};

/// The captured interaction value. Facts/principal/locus/grants/epoch are
/// the immutable "value" half (§2.1's pseudocode); `host` is the live
/// back-reference `setMode`/`pushTransient` need — see the module doc.
pub const Ctx = struct {
    scopes: ScopeList = .{},
    principal: Principal = Principal.user,
    /// Captured locus ([FIX 4]: "holds by construction"). `.here` — the
    /// always-present local sentinel — until a remote-attach head fills a
    /// real one (W6).
    locus: Locus = .here,
    /// W4 placeholder (§2.4: "grants riding the Ctx", resolved at capture
    /// against the principal's `GrantDecl`s). Empty until W4 wires capture-
    /// time grant resolution; a real slice of resolved handles lands then.
    grants: []const u8 = &.{},
    /// Cache key: the shared `container.Container`'s own `epoch` (task
    /// #19's shared-Container fold-in), read straight off
    /// `ctx.actions.container.epoch` at capture time — `ctx.caps.container`
    /// is the SAME instance (System/Session's ONE Container; see
    /// `System.zig`'s `container` field doc), so either would read
    /// identically. This REPLACES the old `System.generation`-over-
    /// approximation this field used to document: `generation` was never
    /// actually wired to `Ctx.capture` in the first place (no
    /// `command.Context` held a `*System` to read it from), so this is the
    /// field's first REAL value, not a precision upgrade of a working one.
    /// Bumped on every `declareSlot`/`bind`/`unbindOwnerPrefix`/
    /// `unbindOwnerExact` across EVERY domain sharing the Container (an
    /// action `provide`, a capability `register`, a `ui/*` mesh bind all
    /// bump the same counter) — Container-wide, not yet per-SLOT (a bind on
    /// slot A still bumps the epoch a resolution against unrelated slot B
    /// would read), but a true, live, unconditionally-correct-to-read
    /// counter end to end, which the old field never was.
    epoch: u64 = 0,
    /// The dispatching `command.Context` this value was captured from — see
    /// the module doc's "This is the value the plan describes, plus one
    /// honest addition."
    host: *command.Context,

    /// Capture a `Ctx` from the dispatching `ctx` — cheap: fixed-size scope
    /// array, every fact a BORROWED slice (head's mode string, the active
    /// buffer's name), zero allocation. Assembles the seven scope kinds in
    /// outer→inner order; `workspace`/`system`/`subbuffer` carry empty
    /// facts today (no workspace-multi-root or subbuffer-fact source
    /// exists yet — honest placeholders, structurally present so a future
    /// fact source has a scope to land in without another migration).
    /// `transient` scopes are NOT captured here — they come from the LIVE
    /// `Head.transient_stack` a `pushTransient` call built, appended after
    /// `mode` in declaration order (innermost transient last).
    pub fn capture(ctx: *command.Context) Ctx {
        var self: Ctx = .{ .host = ctx, .principal = ctx.principal, .epoch = ctx.actions.container.epoch };
        self.scopes.append(.{ .kind = .workspace });
        self.scopes.append(.{ .kind = .system });
        self.scopes.append(.{ .kind = .head, .facts = .{ .pane = ctx.head.focused_pane } });
        const buf = ctx.buffers.active();
        self.scopes.append(.{ .kind = .buffer, .facts = .{
            .path = buf.name,
            .name = buf.name,
            .lang = action_mod.langOfName(buf.name),
            .tool = ctx.editor().toolName() orelse "",
        } });
        self.scopes.append(.{ .kind = .subbuffer });
        self.scopes.append(.{ .kind = .mode, .facts = .{ .mode = ctx.head.currentMode() } });
        for (ctx.head.transient_stack.items) |frame| {
            self.scopes.append(.{ .kind = .transient, .facts = .{ .mode = frame.mode } });
        }
        return self;
    }

    /// Merge every live scope's facts, outermost first, innermost
    /// shadowing — §2.1's third rule ("scopes do NOT rank bindings ... a
    /// scope's roles are exactly (a) supplying facts and (b) bounding
    /// LIFETIME"). This is what `Context.actionCtx`/Container resolution
    /// call sites should consume instead of re-snapshotting ad hoc — see
    /// `Context.actionCtx`'s doc.
    pub fn mergedFacts(self: *const Ctx) Facts {
        var out: Facts = .{};
        for (self.scopes.constSlice()) |s| out = mergeOne(out, s.facts);
        return out;
    }

    /// The POLICY door for a mode change (§2.1, §5 "Mode changes —
    /// REVISED"). Mechanism unchanged: this calls straight through to
    /// `Head.setMode`. What's new is that only code holding a `Ctx` — which
    /// requires a live `*command.Context` to `capture` from — can reach
    /// this door at all. See the module doc's migration-status note: this
    /// is the target for new dispatch-path mode changes; the ~150 existing
    /// direct `Head.setMode` call sites are a named, deliberate residual.
    pub fn setMode(self: *const Ctx, target: []const u8) Allocator.Error!void {
        try self.host.head.setMode(self.host.gpa, target);
    }

    /// Guest-shaped variant: routes through `Head.enterMode` (records a
    /// menu return target when `target` is a declared menu mode) instead
    /// of the bare host-side `setMode`. See `Head.enterMode`'s doc for the
    /// save/restore distinction this preserves.
    pub fn enterMode(self: *const Ctx, km: *const @import("Keymap.zig"), target: []const u8) Allocator.Error!void {
        try self.host.head.enterMode(self.host.gpa, km, target);
    }

    /// Push a transient/menu scope, entering `mode` via `Head.enterMode`.
    /// Returns a handle whose `.deinit()` pops it (restores the pre-push
    /// mode) — the structural pairing §2.1 asks for. See the module doc's
    /// "Paired transients" section for the LIFO/leak-detection contract.
    pub fn pushTransient(self: *const Ctx, km: *const @import("Keymap.zig"), mode: []const u8) (Allocator.Error || Head.TransientPushError)!TransientHandle {
        const depth = try self.host.head.pushTransientMode(self.host.gpa, km, mode);
        return .{ .host = self.host, .depth = depth };
    }
};

/// A live, paired transient-scope push. See `Ctx.pushTransient`.
pub const TransientHandle = struct {
    host: *command.Context,
    depth: usize,
    popped: bool = false,

    /// Pop this transient, restoring the mode captured at push time.
    /// Idempotent — a second call is a no-op, so `defer handle.deinit()` is
    /// always safe alongside an explicit early pop. An out-of-LIFO-order
    /// pop (something pushed after this handle and never popped it) is
    /// REFUSED and logged — see `Head.popTransientMode` — never silently
    /// misapplied.
    pub fn deinit(self: *TransientHandle) void {
        if (self.popped) return;
        self.popped = true;
        self.host.head.popTransientMode(self.host.gpa, self.depth) catch |e| {
            std.log.warn("ctx: transient pop refused ({t}) — a later push was never popped (leak) or this handle is stale", .{e});
        };
    }
};

fn mergeOne(base: Facts, over: Facts) Facts {
    var out = base;
    if (over.locality != .none) out.locality = over.locality;
    if (over.path != null) out.path = over.path;
    if (over.name.len != 0) out.name = over.name;
    if (over.first_line.len != 0) out.first_line = over.first_line;
    if (over.tags.len != 0) out.tags = over.tags;
    if (over.size != 0) out.size = over.size;
    if (over.mode.len != 0) out.mode = over.mode;
    if (over.lang.len != 0) out.lang = over.lang;
    if (over.tool.len != 0) out.tool = over.tool;
    if (over.pane != 0) out.pane = over.pane;
    return out;
}

// ── BACKGROUND CODE CANNOT — a worked, honest example (§6 W2b gate (e)) ──
//
// A dispatch-path command handler has exactly the shape `Ctx.capture` needs:
//
//   fn myCommand(ctx: *command.Context, data: ?*anyopaque, args: []const command.Value) anyerror!command.Value {
//       const c = ctx_mod.Ctx.capture(ctx);
//       try c.setMode("normal");   // compiles: `ctx` is a live *command.Context
//       return .nil;
//   }
//
// A BACKGROUND host-import trampoline — the exact shape wasm_host's
// `hRestingMode`/`hSetFallback`/quickjs's `cUse` and every `on_poll`-driven
// entry actually have (grep `wasm_host/keymap.zig`, `quickjs.zig`'s `cUse`) —
// receives no `*command.Context` at all:
//
//   fn hSomeBackgroundThing(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
//       const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
//       // const c = ctx_mod.Ctx.capture(???);   // <- no `*command.Context` binding exists to pass
//       // try c.setMode("normal");              // never reached: nothing above compiles
//   }
//
// There is no local binding of type `*command.Context` in that function's
// scope — reaching one requires going through `p.activeCtx()` (the pre-
// existing, already-reviewed background/dispatching classification from
// task #14) and calling `Ctx.capture` on ITS result, i.e. an extra,
// deliberate two-line detour a reviewer sees in the diff, not something
// that falls out of writing the obvious code. That is the honest extent of
// today's guarantee: NEW code that never reaches for `activeCtx()` cannot
// express the leak by accident (the common case, and the shape every
// shipped background trampoline actually has); code that deliberately
// reaches through `activeCtx()` still can, because that escape hatch
// predates this module and W2b does not close it — closing it fully wants
// background-classified call sites to receive a DISTINCT type with no path
// to a `*command.Context` at all, which is real, valuable, and out of this
// phase's scope (see this file's module doc and the phase report).

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

const TestEnv = struct {
    gpa: Allocator,
    pool: *@import("task.zig").Pool,
    buffers: @import("Buffers.zig"),
    commands: command.Commands = .empty,
    keymap: @import("Keymap.zig") = .empty,
    /// The ONE shared Container `caps`/`actions` bind into (task #19).
    container: @import("container.zig").Container = undefined,
    caps: @import("capability.zig").Caps,
    actions: @import("action.zig"),
    head: Head = .empty,
    quit: bool = false,
    ctx: command.Context = undefined,

    fn init(gpa: Allocator) !*TestEnv {
        const task = @import("task.zig");
        const pool = try task.Pool.init(gpa, .{ .threads = 1 });
        const self = try gpa.create(TestEnv);
        self.* = .{
            .gpa = gpa,
            .pool = pool,
            .buffers = try @import("Buffers.zig").init(gpa, pool, "user"),
            .container = @import("container.zig").Container.init(gpa),
            .caps = undefined,
            .actions = undefined,
        };
        self.caps = @import("capability.zig").Caps.init(gpa, task.nowNs, &self.container);
        self.actions = @import("action.zig").init(gpa, &self.container);
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
        try self.head.setMode(gpa, "normal");
        return self;
    }

    fn deinit(self: *TestEnv) void {
        const gpa = self.gpa;
        self.head.deinit(gpa);
        self.actions.deinit();
        self.caps.deinit();
        self.container.deinit();
        self.commands.deinit(gpa);
        self.keymap.deinit(gpa);
        self.buffers.deinit(gpa);
        self.pool.deinit();
        gpa.destroy(self);
    }
};

test "ctx: capture assembles the seven scope kinds" {
    const gpa = t.allocator;
    var env = try TestEnv.init(gpa);
    defer env.deinit();

    const c = Ctx.capture(&env.ctx);
    try t.expectEqual(@as(usize, 6), c.scopes.len); // 7 kinds minus 0 open transients
    try t.expectEqual(ScopeKind.workspace, c.scopes.get(0).kind);
    try t.expectEqual(ScopeKind.system, c.scopes.get(1).kind);
    try t.expectEqual(ScopeKind.head, c.scopes.get(2).kind);
    try t.expectEqual(ScopeKind.buffer, c.scopes.get(3).kind);
    try t.expectEqual(ScopeKind.subbuffer, c.scopes.get(4).kind);
    try t.expectEqual(ScopeKind.mode, c.scopes.get(5).kind);
}

test "ctx: capture is PROVABLY non-allocating" {
    // Two independent proofs, not one renamed assertion (review nit):
    //   1. Structural: `capture`'s signature is `fn (ctx: *command.Context)
    //      Ctx` — no error union — so it has NO WAY to propagate an
    //      allocation failure even if it wanted to allocate. A future edit
    //      that added `try gpa.alloc(...)` inside it would fail to COMPILE
    //      (an unhandled `Allocator.Error` in a function with no error
    //      return type), not silently start allocating.
    //   2. Runtime: a `FailingAllocator` with `fail_index = 0` (the very
    //      first allocation attempt traps) survives a real `capture` call
    //      untouched — `.allocations` stays 0.
    const gpa = t.allocator;
    var env = try TestEnv.init(gpa);
    defer env.deinit();

    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    var starved = env.ctx; // same borrowed table pointers, a zero-budget allocator
    starved.gpa = failing.allocator();

    const c = Ctx.capture(&starved);
    try t.expectEqual(@as(usize, 0), failing.allocations);
    try t.expectEqual(@as(usize, 6), c.scopes.len);
}

test "ctx: epoch is the shared Container's TRUE per-mutation counter — task #19 (replaces System.generation)" {
    const gpa = t.allocator;
    var env = try TestEnv.init(gpa);
    defer env.deinit();

    const c0 = Ctx.capture(&env.ctx);
    const e0 = c0.epoch;

    // A Container mutation — an action provider bind — bumps the epoch a
    // later capture reads.
    try env.actions.provide(.{ .action = "eval", .command = "zig-eval" });
    const c1 = Ctx.capture(&env.ctx);
    try t.expect(c1.epoch != e0);
    const e1 = c1.epoch;

    // A capability registration ALSO bumps it — same shared Container,
    // reached through a different domain (`caps`, not `actions`).
    const NoOp = struct {
        fn h(_: ?*anyopaque, _: *@import("capability.zig").Caps, _: *const @import("capability.zig").Request) anyerror!void {}
    };
    try env.caps.register(.{ .capability = "edit/completion", .id = "test.probe", .handler = NoOp.h });
    const c2 = Ctx.capture(&env.ctx);
    try t.expect(c2.epoch != e1);
    const e2 = c2.epoch;

    // An UNRELATED mutation — editing the buffer, changing mode — never
    // touches the Container (no declareSlot/bind/unbind), so it does NOT
    // bump the epoch: proof this is a true per-mutation counter, not a
    // coarse "anything in the system changed" flag (the property
    // `System.generation` — removed — never actually delivered, since
    // nothing wired it to `Ctx.capture` in the first place).
    try env.head.setMode(gpa, "insert");
    try env.buffers.active().editor.insertText(gpa, "hi");
    const c3 = Ctx.capture(&env.ctx);
    try t.expectEqual(e2, c3.epoch);
}

test "ctx: mergedFacts merges across scopes, innermost shadows" {
    const gpa = t.allocator;
    var env = try TestEnv.init(gpa);
    defer env.deinit();
    const b0 = env.buffers.active();
    gpa.free(b0.name);
    b0.name = try gpa.dupe(u8, "main.zig");

    const c = Ctx.capture(&env.ctx);
    const f = c.mergedFacts();
    try t.expectEqualStrings("normal", f.mode); // from the mode scope
    try t.expectEqualStrings("zig", f.lang); // from the buffer scope
    try t.expectEqualStrings("main.zig", f.name);
}

test "ctx: setMode is the POLICY door — a dispatch-path capture can change Head.mode" {
    const gpa = t.allocator;
    var env = try TestEnv.init(gpa);
    defer env.deinit();

    const c = Ctx.capture(&env.ctx);
    try c.setMode("insert");
    try t.expectEqualStrings("insert", env.head.currentMode());
}

test "ctx: paired transient — push then deinit restores the pre-push mode" {
    const gpa = t.allocator;
    var env = try TestEnv.init(gpa);
    defer env.deinit();
    try env.keymap.markMenuMode(gpa, "leader");

    const c = Ctx.capture(&env.ctx);
    var handle = try c.pushTransient(&env.keymap, "leader");
    try t.expectEqualStrings("leader", env.head.currentMode());
    try t.expect(env.head.hasOpenTransients());

    handle.deinit();
    try t.expectEqualStrings("normal", env.head.currentMode());
    try t.expect(!env.head.hasOpenTransients());

    // Idempotent: a second deinit is a safe no-op, not a double-restore.
    handle.deinit();
    try t.expectEqualStrings("normal", env.head.currentMode());
}

test "ctx: paired transient — nested pushes pop LIFO; a leaked outer frame is detectable" {
    const gpa = t.allocator;
    var env = try TestEnv.init(gpa);
    defer env.deinit();
    try env.keymap.markMenuMode(gpa, "leader");
    try env.keymap.markMenuMode(gpa, "leader-file");

    const c = Ctx.capture(&env.ctx);
    var outer = try c.pushTransient(&env.keymap, "leader");
    var inner = try c.pushTransient(&env.keymap, "leader-file");
    try t.expectEqualStrings("leader-file", env.head.currentMode());

    // Correct order: pop inner, then outer.
    inner.deinit();
    try t.expectEqualStrings("leader", env.head.currentMode());
    try t.expect(env.head.hasOpenTransients()); // outer still open — the leak-detecting query
    outer.deinit();
    try t.expectEqualStrings("normal", env.head.currentMode());
    try t.expect(!env.head.hasOpenTransients());
}

test "ctx: paired transient — an out-of-order pop is refused, not silently misapplied" {
    const gpa = t.allocator;
    var env = try TestEnv.init(gpa);
    defer env.deinit();
    try env.keymap.markMenuMode(gpa, "leader");
    try env.keymap.markMenuMode(gpa, "leader-file");

    const c = Ctx.capture(&env.ctx);
    var outer = try c.pushTransient(&env.keymap, "leader");
    var inner = try c.pushTransient(&env.keymap, "leader-file");
    _ = &inner;

    // Popping the OUTER handle while the inner one is still open is refused
    // (LIFO violation) — the mode stays exactly where the inner push left
    // it, never corrupted into some third state.
    outer.deinit();
    try t.expectEqualStrings("leader-file", env.head.currentMode());
    try t.expect(env.head.hasOpenTransients());

    // The inner handle still pops correctly afterward.
    inner.deinit();
    try t.expectEqualStrings("leader", env.head.currentMode());
    // The outer frame is now the true leak: pushed, marked "popped" on our
    // handle (deinit is idempotent — we won't retry it), never actually
    // removed from the stack. `hasOpenTransients` still reports it — the
    // detector the module doc promises, not a silent third result.
    try t.expect(env.head.hasOpenTransients());
}

test {
    std.testing.refAllDecls(@This());
}
