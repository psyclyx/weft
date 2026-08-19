//! Actions — abstract intents resolved to a concrete command by CONTEXT. The
//! middle tier of weft's dispatch, between the keymap (key → name) and the
//! command registry (name → handler):
//!
//!   key ─(keymap layers)→ NAME ─(action: providers + when + priority)→ command
//!
//! A command is a concrete leaf ("zig-eval", "save"). An *action* is a name a
//! key can bind to that many plugins PROVIDE for, each with a `when` predicate
//! and a priority; firing it runs whichever provider's `when` holds in the
//! current context, highest priority winning. Bind `SPC e → eval` once; a
//! `.zig` buffer runs `zig-eval`, a `.py` buffer `python-repl`, and a new
//! language plugin just registers another provider — "dispatching for free".
//!
//! Actions ride the command door: declaring one registers a trampoline
//! `Command` of the same name (see command.registerAction), so the keymap, ex
//! commands, the palette, and programmatic `command.run` all dispatch actions
//! uniformly — no bespoke firing path. The trampoline resolves the provider
//! against the live `Ctx` and tail-calls the chosen command.
//!
//! Two dispatch policies. `pick` (implemented here) runs the single best
//! applicable provider — the synchronous, command-shaped intents (eval, format,
//! repl, run, test). `race` is the async fan-out already embodied by the
//! capability system (capability.zig): completion/hover/definition merge many
//! providers' results over time. They are the same "resolve by context +
//! priority" idea at two latencies; `race` actions are declared here as a
//! reserved policy and delegate to `Caps` at their (few, UI-bound) call sites,
//! folded in incrementally rather than migrated wholesale.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Actions = @This();

pub const Policy = enum {
    /// Run the single highest-priority applicable provider now (synchronous).
    pick,
    /// Async fan-out + merge — the capability system's race. Reserved: a
    /// `race` action names an intent whose providers answer over time; its
    /// call sites drive `Caps` directly (see capability.zig) until they are
    /// folded onto this registry.
    race,
};

/// A context predicate over the ambient facts of the moment. Every PRESENT
/// field must hold (conjunction); an absent field is "don't care", so an empty
/// `When` matches everything (the default provider). v1 vocabulary is `mode`
/// and `lang`; the shape is deliberately small and grow-only — disjunction and
/// negation are a later addition, not a rewrite (a provider list already gives
/// OR across providers, and priority gives override).
pub const When = struct {
    /// Keymap mode that must be active (`normal`, `insert`, `dired`, …).
    mode: ?[]const u8 = null,
    /// Buffer language — the active buffer name's extension without the dot
    /// (`zig`, `py`, `md`). Matched case-sensitively.
    lang: ?[]const u8 = null,

    /// How specific this predicate is — the count of constraints it imposes.
    /// Breaks priority ties in favour of the narrower provider, so a
    /// `lang:zig` bind beats an unconstrained default at equal priority.
    fn specificity(self: When) u8 {
        return @as(u8, @intFromBool(self.mode != null)) + @intFromBool(self.lang != null);
    }

    fn holds(self: When, ctx: Ctx) bool {
        if (self.mode) |m| if (!std.mem.eql(u8, m, ctx.mode)) return false;
        if (self.lang) |l| if (!std.mem.eql(u8, l, ctx.lang)) return false;
        return true;
    }
};

/// The ambient facts a `When` tests against — snapshotted at fire time from the
/// live editor (active mode + active buffer). `lang` is "" when the buffer has
/// no extension (a tool buffer, `*scratch*`).
pub const Ctx = struct {
    mode: []const u8,
    lang: []const u8 = "",
};

/// The extension (sans dot) of a buffer display name, or "" — the `lang` key a
/// `When` matches. `build.zig` → "zig", `*scratch*` / `Makefile` → "".
pub fn langOfName(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    if (dot == 0 or dot + 1 >= name.len) return "";
    // A leading-dot name (".envrc") is not an extension; require a stem.
    return name[dot + 1 ..];
}

const Provider = struct {
    when: When, // owned strings (when.mode/.lang)
    priority: i32,
    command: []u8, // owned — the concrete command this provider runs
    owner: []u8, // owned — plugin/config name, for teardown

    fn deinit(self: *Provider, gpa: Allocator) void {
        if (self.when.mode) |m| gpa.free(m);
        if (self.when.lang) |l| gpa.free(l);
        gpa.free(self.command);
        gpa.free(self.owner);
    }
};

const Action = struct {
    policy: Policy,
    providers: std.ArrayList(Provider) = .empty,

    fn deinit(self: *Action, gpa: Allocator) void {
        for (self.providers.items) |*p| p.deinit(gpa);
        self.providers.deinit(gpa);
    }
};

/// The trampoline closure a declared action's `Command` carries as its `data`
/// payload: the action name to resolve at fire time. Owned by the registry.
pub const Trampoline = struct { name: []u8 };

gpa: Allocator,
actions: std.StringArrayHashMapUnmanaged(Action) = .empty,
trampolines: std.ArrayList(*Trampoline) = .empty,

pub fn init(gpa: Allocator) Actions {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *Actions) void {
    const gpa = self.gpa;
    for (self.actions.keys(), self.actions.values()) |name, *a| {
        gpa.free(name);
        a.deinit(gpa);
    }
    self.actions.deinit(gpa);
    for (self.trampolines.items) |tr| {
        gpa.free(tr.name);
        gpa.destroy(tr);
    }
    self.trampolines.deinit(gpa);
}

/// Declare an action `name` with a dispatch `policy`, idempotently. Returns the
/// trampoline payload the caller binds a `Command` of the same name to (see
/// command.registerAction) — stable for the registry's lifetime. Re-declaring
/// keeps the existing action (and its providers) and returns its trampoline, so
/// declaration order across plugins/config doesn't matter.
pub fn declare(self: *Actions, name: []const u8, policy: Policy) !*Trampoline {
    const gpa = self.gpa;
    const gop = try self.actions.getOrPut(gpa, name);
    if (!gop.found_existing) {
        gop.key_ptr.* = try gpa.dupe(u8, name);
        gop.value_ptr.* = .{ .policy = policy };
    }
    // A trampoline per declaration site is cheap and lets re-declaration stay
    // idempotent without deduping command binds; they all resolve the same name.
    const tr = try gpa.create(Trampoline);
    errdefer gpa.destroy(tr);
    tr.* = .{ .name = try gpa.dupe(u8, name) };
    try self.trampolines.append(gpa, tr);
    return tr;
}

pub fn isAction(self: *const Actions, name: []const u8) bool {
    return self.actions.contains(name);
}

pub fn policyOf(self: *const Actions, name: []const u8) ?Policy {
    const a = self.actions.getPtr(name) orelse return null;
    return a.policy;
}

pub const ProvideSpec = struct {
    action: []const u8,
    when: When = .{},
    command: []const u8,
    priority: i32 = 0,
    owner: []const u8 = "plugin",
    /// Policy to auto-declare the action with if it doesn't exist yet — a
    /// provider can arrive before its `declare` (load order is free).
    declare_policy: Policy = .pick,
};

/// Register a provider for `spec.action`, auto-declaring the action if needed
/// (so `provide` before `declare` is fine). Owns copies of every string.
pub fn provide(self: *Actions, spec: ProvideSpec) !void {
    const gpa = self.gpa;
    const gop = try self.actions.getOrPut(gpa, spec.action);
    if (!gop.found_existing) {
        gop.key_ptr.* = try gpa.dupe(u8, spec.action);
        gop.value_ptr.* = .{ .policy = spec.declare_policy };
    }
    var p: Provider = .{
        .when = .{},
        .priority = spec.priority,
        .command = try gpa.dupe(u8, spec.command),
        .owner = try gpa.dupe(u8, spec.owner),
    };
    errdefer p.deinit(gpa);
    if (spec.when.mode) |m| p.when.mode = try gpa.dupe(u8, m);
    if (spec.when.lang) |l| p.when.lang = try gpa.dupe(u8, l);
    try gop.value_ptr.providers.append(gpa, p);
}

/// The concrete command an action resolves to in `ctx`, or null when no
/// provider's `when` holds. The winner is the highest priority among applicable
/// providers; ties break toward the MORE SPECIFIC `when` (a `lang:zig` provider
/// over an unconstrained default), then toward the later registration — a pure
/// function of the provider set and the context, never load-order dependent
/// beyond the deliberate same-(priority,specificity) last-wins.
pub fn resolve(self: *const Actions, name: []const u8, ctx: Ctx) ?[]const u8 {
    const a = self.actions.getPtr(name) orelse return null;
    var best: ?*const Provider = null;
    for (a.providers.items) |*p| {
        if (!p.when.holds(ctx)) continue;
        if (best) |b| {
            if (p.priority < b.priority) continue;
            if (p.priority == b.priority and
                p.when.specificity() < b.when.specificity()) continue;
        }
        best = p;
    }
    return if (best) |b| b.command else null;
}

/// Remove every provider registered by an owner whose name starts with
/// `owner_prefix` (plugin teardown). Actions themselves persist (they are
/// names, cheap and idempotent to re-declare).
pub fn unregisterByOwnerPrefix(self: *Actions, owner_prefix: []const u8) void {
    for (self.actions.values()) |*a| {
        var i: usize = 0;
        while (i < a.providers.items.len) {
            if (std.mem.startsWith(u8, a.providers.items[i].owner, owner_prefix)) {
                var p = a.providers.swapRemove(i);
                p.deinit(self.gpa);
            } else i += 1;
        }
    }
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "action: pick resolves by context, priority, and specificity" {
    var acts = Actions.init(t.allocator);
    defer acts.deinit();

    // eval: a zig provider, a python provider, and an unconstrained default.
    try acts.provide(.{ .action = "eval", .when = .{ .lang = "zig" }, .command = "zig-eval" });
    try acts.provide(.{ .action = "eval", .when = .{ .lang = "py" }, .command = "python-repl" });
    try acts.provide(.{ .action = "eval", .command = "eval-line-default", .priority = -10 });

    try t.expectEqualStrings("zig-eval", acts.resolve("eval", .{ .mode = "normal", .lang = "zig" }).?);
    try t.expectEqualStrings("python-repl", acts.resolve("eval", .{ .mode = "normal", .lang = "py" }).?);
    // No language-specific provider → the low-priority default still applies.
    try t.expectEqualStrings("eval-line-default", acts.resolve("eval", .{ .mode = "normal", .lang = "md" }).?);

    // Specificity breaks an equal-priority tie: a lang-scoped provider beats an
    // unconstrained one bound at the SAME priority.
    try acts.provide(.{ .action = "fmt", .command = "fmt-generic" });
    try acts.provide(.{ .action = "fmt", .when = .{ .lang = "zig" }, .command = "zig-fmt" });
    try t.expectEqualStrings("zig-fmt", acts.resolve("fmt", .{ .mode = "normal", .lang = "zig" }).?);
    try t.expectEqualStrings("fmt-generic", acts.resolve("fmt", .{ .mode = "normal", .lang = "c" }).?);

    // An unknown action, and an action with no applicable provider, resolve null.
    try t.expectEqual(@as(?[]const u8, null), acts.resolve("nope", .{ .mode = "normal" }));
    try acts.provide(.{ .action = "run", .when = .{ .mode = "debug" }, .command = "run-target" });
    try t.expectEqual(@as(?[]const u8, null), acts.resolve("run", .{ .mode = "normal", .lang = "zig" }));
}

test "action: declare is idempotent and provider load-order-independent" {
    var acts = Actions.init(t.allocator);
    defer acts.deinit();

    // provide-before-declare works (auto-declares).
    try acts.provide(.{ .action = "eval", .when = .{ .lang = "zig" }, .command = "zig-eval" });
    _ = try acts.declare("eval", .pick);
    try t.expect(acts.isAction("eval"));
    try t.expectEqual(Policy.pick, acts.policyOf("eval").?);

    // Higher priority wins regardless of registration order.
    try acts.provide(.{ .action = "eval", .when = .{ .lang = "zig" }, .command = "zig-eval-lsp", .priority = 100 });
    try t.expectEqualStrings("zig-eval-lsp", acts.resolve("eval", .{ .mode = "normal", .lang = "zig" }).?);
}

test "action: owner-prefix teardown drops a plugin's providers" {
    var acts = Actions.init(t.allocator);
    defer acts.deinit();

    try acts.provide(.{ .action = "eval", .when = .{ .lang = "zig" }, .command = "zig-eval", .owner = "zig-tools#3" });
    try acts.provide(.{ .action = "eval", .command = "eval-default", .owner = "config", .priority = -10 });
    try t.expectEqualStrings("zig-eval", acts.resolve("eval", .{ .mode = "normal", .lang = "zig" }).?);

    acts.unregisterByOwnerPrefix("zig-tools#");
    // The plugin's provider is gone; the config default remains.
    try t.expectEqualStrings("eval-default", acts.resolve("eval", .{ .mode = "normal", .lang = "zig" }).?);
}

test "action: langOfName extracts the extension, or empty" {
    try t.expectEqualStrings("zig", langOfName("build.zig"));
    try t.expectEqualStrings("py", langOfName("a/b/c.py"));
    try t.expectEqualStrings("", langOfName("*scratch*"));
    try t.expectEqualStrings("", langOfName("Makefile"));
    try t.expectEqualStrings("", langOfName(".envrc")); // leading dot ≠ extension
    try t.expectEqualStrings("", langOfName("trailing.")); // no stem after dot
}

test {
    std.testing.refAllDecls(@This());
}
