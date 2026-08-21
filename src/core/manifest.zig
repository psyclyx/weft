//! Manifest — config evaluation's output VALUE (north-star-plan §2.3, M3).
//! `quickjs.zig`'s `weft.*` config surface used to mutate the editor
//! DIRECTLY, inline, as each JS call landed (with `weft.plugin`/`weft.run`
//! deferred by hand to a tail replay — see quickjs.zig's old module doc).
//! This module is the promotion of that ad hoc staging into a REAL,
//! inspectable value: every `weft.*` declaration becomes one entry in an
//! ordered list here, config evaluation produces a `Manifest` and touches
//! nothing else, and `apply`/`reconcile` are the only functions that ever
//! mutate the editor from it — a separate, pure-function-of-the-value step.
//!
//! `manifest.zig` knows nothing of quickjs (no `wasm.zig`, no `qjs_contract`
//! import) — quickjs.zig PRODUCES a `Manifest` by calling this module's
//! `add*` methods from its `weft.*` host-import handlers; this module only
//! defines the value and what applying it means.
//!
//! **Tiers** (container.zig's `Tier`, reused directly — no parallel enum):
//! the ROOT config manifest is `.config`; a manifest reached through
//! `weft.use(name)` is `.imported` — a flat assignment (not `tier - 1`
//! arithmetic), so nested imports-of-imports stay at `.imported` too. This
//! is a deliberate simplification: nothing in the shipped catalog nests
//! `weft.use` more than one level, and `.imported` already sits below
//! `.config` in `container.Tier`'s total order, which is all the override
//! contract (`defaults.js` loses to `config.js`'s own later binds) needs.
//! `keymapPriorityForTier` maps this onto `Keymap.zig`'s SEPARATE priority
//! ladder, which needed a genuinely new rung (`prio_imported`, between
//! `prio_plugin` and `prio_config`) since a plain `tier - 1` there would
//! collide imports with plugins — see that function's doc.
//!
//! **Sealed eval** (§2.3, §4 C11): the `weft.*` config-group host surface
//! (`bind_key`/`run`/`echo`/`log`/`plugin`/`use`/`set`/`menu`/`action`/
//! `provide` — see `membrane/qjs_contract.zig`'s `.config` group) is the
//! ONLY channel a config script can use to affect a `Manifest`; none of
//! those ten imports reads wall-clock, environment, or filesystem outside
//! the config's own directory (`qjs_use`'s file read is confined to
//! `<config_dir>/<name>.js`) — verified by
//! `qjs_contract_test.zig`'s "no clock/env-shaped .config import" check.
//! `hash()` is a pure, length-framed content hash of the staged
//! declarations (never engine side effects — and framed, not bare
//! concatenation, so e.g. a `bind("a","b","c")` and a `bind("ab","","c")`
//! can never collide to the same hash), so two evals of byte-identical
//! source produce byte-identical manifests and identical hashes (tested
//! below).
//!
//! QuickJS-ng's own BUILT-IN `Date`/`Math.random` (engine features, not
//! `weft.*` imports — the qjs_contract audit above can't see them) are
//! CLOSED too (M3 review R2): `src/quickjs/weft_qjs.c`'s `weft_eval`
//! evaluates a fixed seal prelude (`SEAL_PRELUDE`) immediately after
//! installing the `weft.*` globals and BEFORE any user source ever runs —
//! it overrides `Date`, `Date.now`, and `Math.random` with fixed-seed
//! deterministic replacements (`Date.now()` → `0`; `new Date()` → the
//! epoch; `Math.random()` → a fixed-seed xorshift32 sequence, identical
//! every eval). This is `weft_eval` (the CONFIG plane) only —
//! `weft_plugin_init` (the resident, LIVE `JsPlugin` plane) deliberately
//! does NOT get the seal: a resident plugin isn't a one-shot declarative
//! eval, and sealing its clock would make an agent/proc-timing plugin's
//! `Date.now()` lie for the rest of the session. Tested end-to-end in
//! quickjs.zig ("R2 — Date.now()/Math.random() are SEALED"): a config that
//! feeds both into `weft.set(...)` still hashes identically across two
//! independent evals.

const std = @import("std");
const Allocator = std.mem.Allocator;
const command = @import("command.zig");
const kv = @import("kv.zig");
const container_mod = @import("container.zig");
const Keymap = @import("Keymap.zig");

pub const Tier = container_mod.Tier;

/// Opaque callback into the resident plugin loader (main.zig's
/// `config_load.PluginHost`) — kept structurally identical to (and re-
/// exported by) `quickjs.zig`'s old `PluginLoader` so call sites don't churn,
/// but DEFINED here so this module stays quickjs-independent.
pub const PluginLoader = struct {
    ctx: *anyopaque,
    load: *const fn (ctx: *anyopaque, name: []const u8) void,
};

// ── Declaration types — one per `weft.*` call, in AUTHORED order. ──────────

pub const PluginDecl = struct { name: []u8, path_form: bool };
pub const BindDecl = struct { mode: []u8, key: []u8, command: []u8 };
pub const MenuDecl = struct { name: []u8 };
pub const ActionDecl = struct { name: []u8 };
pub const ProvideDecl = struct { action: []u8, mode: []u8, lang: []u8, command: []u8, priority: i32 };
pub const ValueDecl = struct { owner: []u8, key: []u8, value: []u8 };
pub const RunDecl = struct { command: []u8 };
pub const EchoDecl = struct { message: []u8 };
pub const LogDecl = struct { message: []u8 };

/// Whether a `weft.plugin(name)` names the bundled catalog or an explicit
/// path — the trust-root choke point (north-star-plan §5 "Trust root —
/// DECIDED", §4 C17). A bare name ("vim") resolves against the bundled
/// plugin directory and is accepted under the catalog's curated grant
/// bundle — today's behavior, no prompt. A path-form name (contains '/', or
/// literally names a `.wasm`/`.js` file) is OUTSIDE the trust root: not
/// curated, its grants unverified. Behavior is unchanged today (both load);
/// this function exists so W4 has exactly one place to hang an approval
/// prompt on the path-form branch. Mirrors `config_load.PluginHost.resolve`'s
/// literal-vs-bare test — the two must agree, or a plugin could resolve
/// differently than it was trust-classified.
pub const PluginTrust = enum { catalog, path_form };
pub fn pluginTrust(name: []const u8) PluginTrust {
    if (std.mem.indexOfScalar(u8, name, '/') != null or
        std.mem.endsWith(u8, name, ".wasm") or std.mem.endsWith(u8, name, ".js"))
        return .path_form;
    return .catalog;
}

/// `Manifest`'s `Tier` (`.config`/`.imported`) mapped onto `Keymap.zig`'s
/// SEPARATE priority ladder (`prio_core`/`prio_plugin`/`prio_config`). Not a
/// generic arithmetic transform: `Keymap` needed a genuinely NEW rung
/// (`prio_imported`, 50) sitting between `prio_plugin` (0) and `prio_config`
/// (100) — reusing `prio_plugin` for imports (what plain `tier - 1` would
/// give, since `container.Tier.imported` sits below `.plugin`) would let an
/// ordinary catalog plugin's own bind beat `defaults.js`, which is not the
/// override contract (`config.js`'s later binds must win over `defaults.js`;
/// `defaults.js` itself is not competing with the catalog for keymap slots
/// in practice, but the plan is explicit that imports get their own rung).
pub fn keymapPriorityForTier(tier: Tier) i32 {
    return switch (tier) {
        .core => Keymap.prio_core,
        .imported => Keymap.prio_imported,
        .plugin => Keymap.prio_plugin,
        .config => Keymap.prio_config,
        .transient => std.math.maxInt(i32),
    };
}

/// Value namespaces core itself owns (not a loaded plugin's name) — see
/// `Manifest.applyDecls`'s ownership check (north-star-plan §2.4 "`weft.set`
/// value namespaces are closed by default"). `"theme"` (`view.Theme`'s
/// fields) and `"editor"` (generic core knobs with no plugin owner — e.g.
/// `flash-ms`) are legitimate DECLARED core namespaces; the finding §8's
/// forcing function surfaced was narrower than "kill 'editor'" — it was
/// specifically that `which-key-delay-ms` belongs to the `which_key`
/// PLUGIN, not core, and was squatting in the grab-bag namespace instead.
/// Grow this list, never widen the check to "assume unknown owners are
/// fine".
const core_value_namespaces = [_][]const u8{ "theme", "editor" };

/// Config evaluation's output value (§2.3). Every `weft.*` call the config
/// (or a `weft.use`-imported file) makes lands here as ONE entry in the
/// matching list, in call order — order is authored DATA, preserved and
/// replayed identically by `apply`. Always heap-allocated (`create`/
/// `destroy`) so `imports` can hold plain `*Manifest` without a second
/// ownership story.
pub const Manifest = struct {
    gpa: Allocator,
    /// The binder identity `apply` uses for `Keymap.bind`/`Actions.provide`
    /// owner and `reconcile`'s teardown — `"config"` for the root, `"import:
    /// <name>"` for a `weft.use(name)` sub-manifest.
    owner: []u8,
    tier: Tier,
    plugins: std.ArrayList(PluginDecl) = .empty,
    imports: std.ArrayList(*Manifest) = .empty,
    binds: std.ArrayList(BindDecl) = .empty,
    menus: std.ArrayList(MenuDecl) = .empty,
    actions: std.ArrayList(ActionDecl) = .empty,
    provides: std.ArrayList(ProvideDecl) = .empty,
    values: std.ArrayList(ValueDecl) = .empty,
    runs: std.ArrayList(RunDecl) = .empty,
    echoes: std.ArrayList(EchoDecl) = .empty,
    logs: std.ArrayList(LogDecl) = .empty,

    pub fn create(gpa: Allocator, owner: []const u8, tier: Tier) !*Manifest {
        const self = try gpa.create(Manifest);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .owner = try gpa.dupe(u8, owner), .tier = tier };
        return self;
    }

    pub fn destroy(self: *Manifest) void {
        const gpa = self.gpa;
        for (self.imports.items) |imp| imp.destroy();
        self.imports.deinit(gpa);
        gpa.free(self.owner);
        for (self.plugins.items) |d| gpa.free(d.name);
        self.plugins.deinit(gpa);
        for (self.binds.items) |d| {
            gpa.free(d.mode);
            gpa.free(d.key);
            gpa.free(d.command);
        }
        self.binds.deinit(gpa);
        for (self.menus.items) |d| gpa.free(d.name);
        self.menus.deinit(gpa);
        for (self.actions.items) |d| gpa.free(d.name);
        self.actions.deinit(gpa);
        for (self.provides.items) |d| {
            gpa.free(d.action);
            gpa.free(d.mode);
            gpa.free(d.lang);
            gpa.free(d.command);
        }
        self.provides.deinit(gpa);
        for (self.values.items) |d| {
            gpa.free(d.owner);
            gpa.free(d.key);
            gpa.free(d.value);
        }
        self.values.deinit(gpa);
        for (self.runs.items) |d| gpa.free(d.command);
        self.runs.deinit(gpa);
        for (self.echoes.items) |d| gpa.free(d.message);
        self.echoes.deinit(gpa);
        for (self.logs.items) |d| gpa.free(d.message);
        self.logs.deinit(gpa);
        gpa.destroy(self);
    }

    // ── Staging (quickjs.zig's `weft.*` handlers call these) ────────────

    pub fn addPlugin(self: *Manifest, name: []const u8) !void {
        try self.plugins.append(self.gpa, .{ .name = try self.gpa.dupe(u8, name), .path_form = pluginTrust(name) == .path_form });
    }
    pub fn addBind(self: *Manifest, mode: []const u8, key: []const u8, cmd: []const u8) !void {
        try self.binds.append(self.gpa, .{ .mode = try self.gpa.dupe(u8, mode), .key = try self.gpa.dupe(u8, key), .command = try self.gpa.dupe(u8, cmd) });
    }
    pub fn addMenu(self: *Manifest, name: []const u8) !void {
        try self.menus.append(self.gpa, .{ .name = try self.gpa.dupe(u8, name) });
    }
    pub fn addAction(self: *Manifest, name: []const u8) !void {
        try self.actions.append(self.gpa, .{ .name = try self.gpa.dupe(u8, name) });
    }
    pub fn addProvide(self: *Manifest, action: []const u8, mode: []const u8, lang: []const u8, cmd: []const u8, priority: i32) !void {
        try self.provides.append(self.gpa, .{
            .action = try self.gpa.dupe(u8, action),
            .mode = try self.gpa.dupe(u8, mode),
            .lang = try self.gpa.dupe(u8, lang),
            .command = try self.gpa.dupe(u8, cmd),
            .priority = priority,
        });
    }
    pub fn addValue(self: *Manifest, owner: []const u8, key: []const u8, value: []const u8) !void {
        try self.values.append(self.gpa, .{ .owner = try self.gpa.dupe(u8, owner), .key = try self.gpa.dupe(u8, key), .value = try self.gpa.dupe(u8, value) });
    }
    pub fn addRun(self: *Manifest, cmd: []const u8) !void {
        try self.runs.append(self.gpa, .{ .command = try self.gpa.dupe(u8, cmd) });
    }
    pub fn addEcho(self: *Manifest, message: []const u8) !void {
        try self.echoes.append(self.gpa, .{ .message = try self.gpa.dupe(u8, message) });
    }
    pub fn addLog(self: *Manifest, message: []const u8) !void {
        try self.logs.append(self.gpa, .{ .message = try self.gpa.dupe(u8, message) });
    }
    /// Attach a fully-evaluated sub-manifest (a `weft.use(name)` import).
    /// Takes ownership: `destroy` frees it recursively.
    pub fn addImport(self: *Manifest, sub: *Manifest) !void {
        try self.imports.append(self.gpa, sub);
    }

    // ── Content hash (§2.3, §4 C11: hash-approved evaluation) ───────────

    /// A deterministic content hash of the staged declarations (never of
    /// engine side effects) — two evals of byte-identical config source
    /// yield byte-identical `Manifest`s and hence identical hashes. Fixed
    /// seed, so the hash is stable across process runs (log-comparable).
    pub fn hash(self: *const Manifest) u64 {
        var h = std.hash.Wyhash.init(0xc0ffee_5eed_c0de);
        self.hashInto(&h);
        return h.final();
    }

    fn hashInto(self: *const Manifest, h: *std.hash.Wyhash) void {
        hStr(h, self.owner);
        h.update(std.mem.asBytes(&self.tier));
        hLen(h, self.plugins.items.len);
        for (self.plugins.items) |d| {
            hStr(h, d.name);
            h.update(&[_]u8{@intFromBool(d.path_form)});
        }
        hLen(h, self.binds.items.len);
        for (self.binds.items) |d| {
            hStr(h, d.mode);
            hStr(h, d.key);
            hStr(h, d.command);
        }
        hLen(h, self.menus.items.len);
        for (self.menus.items) |d| hStr(h, d.name);
        hLen(h, self.actions.items.len);
        for (self.actions.items) |d| hStr(h, d.name);
        hLen(h, self.provides.items.len);
        for (self.provides.items) |d| {
            hStr(h, d.action);
            hStr(h, d.mode);
            hStr(h, d.lang);
            hStr(h, d.command);
            h.update(std.mem.asBytes(&d.priority));
        }
        hLen(h, self.values.items.len);
        for (self.values.items) |d| {
            hStr(h, d.owner);
            hStr(h, d.key);
            hStr(h, d.value);
        }
        hLen(h, self.runs.items.len);
        for (self.runs.items) |d| hStr(h, d.command);
        hLen(h, self.echoes.items.len);
        for (self.echoes.items) |d| hStr(h, d.message);
        hLen(h, self.logs.items.len);
        for (self.logs.items) |d| hStr(h, d.message);
        hLen(h, self.imports.items.len);
        for (self.imports.items) |imp| imp.hashInto(h);
    }

    // ── Apply (§2.3: a separate, ordered, pure-function-of-the-value step) ─

    pub const ApplyCtx = struct {
        ctx: *command.Context,
        loader: ?PluginLoader,
        config: ?*kv.Store,
    };

    /// Apply this manifest FRESH — every declaration is applied as if for
    /// the first time (the initial config load). For a RELOAD against a
    /// previously-applied manifest, use `reconcile` instead.
    pub fn apply(self: *const Manifest, gpa: Allocator, actx: *ApplyCtx) !void {
        var known: std.StringHashMapUnmanaged(void) = .empty;
        defer known.deinit(gpa);
        try self.populateKnownPlugins(gpa, &known);
        try self.applyDecls(gpa, actx, &known);
        try self.loadPlugins(actx);
        try self.runCommands(actx);
    }

    fn populateKnownPlugins(self: *const Manifest, gpa: Allocator, out: *std.StringHashMapUnmanaged(void)) !void {
        for (self.imports.items) |imp| try imp.populateKnownPlugins(gpa, out);
        for (self.plugins.items) |d| {
            try out.put(gpa, d.name, {});
            // A path-form / `.js` plugin's VALUE-STORE identity is its STEM
            // (`config_load.zig`'s `PluginHost.load`/`loadJs`: a `.wasm` is
            // registered under `std.fs.path.stem(name)`, a `.js` under
            // `std.fs.path.stem(std.fs.path.basename(name))`) — NOT the raw
            // declared name. `weft.plugin("acp.js")` reads its config as
            // plugin "acp" (`weft.config(key)` keys on `JsPlugin.name`,
            // which IS the stem). Without this, `weft.set("acp", "cmd", …)`
            // — the documented ACP setup — silently dropped as an unknown
            // owner (R1: a real pre-M3-working config broken by the
            // ownership check). The stem is a substring of `d.name`'s own
            // backing memory (no allocation), valid for the same lifetime.
            const stem = std.fs.path.stem(std.fs.path.basename(d.name));
            if (!std.mem.eql(u8, stem, d.name)) try out.put(gpa, stem, {});
        }
    }

    fn collectPluginNames(self: *const Manifest, gpa: Allocator, out: *std.ArrayList([]const u8)) !void {
        for (self.imports.items) |imp| try imp.collectPluginNames(gpa, out);
        for (self.plugins.items) |d| try out.append(gpa, d.name);
    }

    fn collectRunCommands(self: *const Manifest, gpa: Allocator, out: *std.ArrayList([]const u8)) !void {
        for (self.imports.items) |imp| try imp.collectRunCommands(gpa, out);
        for (self.runs.items) |d| try out.append(gpa, d.command);
    }

    /// Apply binds/menus/actions/provides/values/echoes/logs — everything
    /// EXCEPT plugin loads and `weft.run`, which are deferred passes (so
    /// `weft.set` for a plugin always lands before that plugin instantiates,
    /// regardless of declaration order — the invariant quickjs.zig's old
    /// doc comment described, now a property of `apply`'s pass order rather
    /// than a hand-rolled replay list). Imports apply BEFORE this manifest's
    /// own decls; harmless either way for `Keymap.bind` (tier-gated, not
    /// order-gated), but keeps "outer wraps inner" intuitive.
    fn applyDecls(self: *const Manifest, gpa: Allocator, actx: *ApplyCtx, known: *const std.StringHashMapUnmanaged(void)) !void {
        for (self.imports.items) |imp| try imp.applyDecls(gpa, actx, known);

        const prio = keymapPriorityForTier(self.tier);
        for (self.binds.items) |d| actx.ctx.keymap.bind(gpa, d.mode, d.key, d.command, prio, self.owner) catch {};
        for (self.menus.items) |d| applyMenu(actx.ctx, gpa, d.name, prio);
        for (self.actions.items) |d| command.registerAction(gpa, actx.ctx.commands, actx.ctx.actions, d.name, .pick) catch {};
        for (self.provides.items) |d| {
            actx.ctx.actions.provide(.{
                .action = d.action,
                .when = .{ .mode = optStr(d.mode), .lang = optStr(d.lang) },
                .command = d.command,
                .priority = d.priority,
                .owner = self.owner,
                .tier = self.tier,
            }) catch |e| if (e == error.RaceRejectsProvider) echoProvideRefused(actx.ctx, gpa, d.action);
        }
        for (self.values.items) |d| {
            if (!ownerIsKnown(d.owner, known)) {
                // No silent third result (design rule): stderr AND the
                // user-visible echo line, same channel `echoProvideRefused`
                // uses — a GUI user never sees a terminal (nit a).
                std.log.warn("config: weft.set(\"{s}\", \"{s}\", ...) — '{s}' is not a loaded plugin or a declared value namespace; dropped", .{ d.owner, d.key, d.owner });
                echoValueDropped(actx.ctx, gpa, d.owner, d.key);
                continue;
            }
            if (actx.config) |store| store.put(gpa, d.owner, d.key, d.value) catch {};
        }
        for (self.echoes.items) |d| {
            actx.ctx.echo.clearRetainingCapacity();
            actx.ctx.echo.appendSlice(gpa, d.message) catch {};
        }
        for (self.logs.items) |d| std.log.info("config: {s}", .{d.message});
    }

    fn loadPlugins(self: *const Manifest, actx: *ApplyCtx) !void {
        for (self.imports.items) |imp| try imp.loadPlugins(actx);
        for (self.plugins.items) |d| {
            switch (pluginTrust(d.name)) {
                .catalog => {},
                .path_form => std.log.info("config: plugin '{s}' loaded from OUTSIDE the bundled catalog trust root — grants unverified (W4: approval prompt belongs here)", .{d.name}),
            }
            if (actx.loader) |ld| ld.load(ld.ctx, d.name);
        }
    }

    fn runCommands(self: *const Manifest, actx: *ApplyCtx) !void {
        for (self.imports.items) |imp| try imp.runCommands(actx);
        for (self.runs.items) |d| _ = command.run(actx.ctx.commands, actx.ctx, d.command, &.{}) catch {};
    }

    // ── Reconcile (§2.3, §6: config reload is a diff against the
    // previously-applied manifest, not a re-run of the JS program) ──────

    /// Apply `new` against the editor, diffed against `old` (the manifest
    /// last applied, or null for the initial load — degenerates to `apply`).
    /// Same manifest twice (`old.hash() == new.hash()`) is a verified no-op:
    /// nothing is re-bound, no plugin re-loaded, no `weft.run`/echo re-fires.
    /// A changed manifest tears down every bind/provide/value `old` owned
    /// (see `teardownOwned`) then applies `new` in full, EXCEPT plugin loads
    /// and `weft.run`s — those are add-only (a plugin already loaded is not
    /// re-instantiated; a `weft.run` already executed is not re-run); a
    /// plugin present in `old` but absent from `new` is logged (unload isn't
    /// wired — restart to fully remove it, an honest limitation, not silent
    /// drift).
    pub fn reconcile(gpa: Allocator, old: ?*const Manifest, new: *const Manifest, actx: *ApplyCtx) !void {
        if (old) |o| {
            if (o.hash() == new.hash()) {
                std.log.info("config: reload — manifest unchanged (0x{x}), no-op", .{new.hash()});
                return;
            }
            std.log.info("config: reload — manifest changed (0x{x} -> 0x{x}), reconciling", .{ o.hash(), new.hash() });
            try o.teardownOwned(gpa, actx);
        }

        var known: std.StringHashMapUnmanaged(void) = .empty;
        defer known.deinit(gpa);
        try new.populateKnownPlugins(gpa, &known);
        try new.applyDecls(gpa, actx, &known);

        var old_plugins: std.StringHashMapUnmanaged(void) = .empty;
        defer old_plugins.deinit(gpa);
        var new_plugin_list: std.ArrayList([]const u8) = .empty;
        defer new_plugin_list.deinit(gpa);
        try new.collectPluginNames(gpa, &new_plugin_list);
        if (old) |o| {
            var old_plugin_list: std.ArrayList([]const u8) = .empty;
            defer old_plugin_list.deinit(gpa);
            try o.collectPluginNames(gpa, &old_plugin_list);
            for (old_plugin_list.items) |n| try old_plugins.put(gpa, n, {});
            for (old_plugin_list.items) |n| {
                var found = false;
                for (new_plugin_list.items) |n2| {
                    if (std.mem.eql(u8, n, n2)) {
                        found = true;
                        break;
                    }
                }
                if (!found) std.log.warn("config: reload — plugin '{s}' removed from config but unload isn't supported yet; restart to fully remove it", .{n});
            }
        }
        try new.loadPluginsDiffed(actx, &old_plugins);

        var old_runs: std.StringHashMapUnmanaged(void) = .empty;
        defer old_runs.deinit(gpa);
        if (old) |o| {
            var old_run_list: std.ArrayList([]const u8) = .empty;
            defer old_run_list.deinit(gpa);
            try o.collectRunCommands(gpa, &old_run_list);
            for (old_run_list.items) |c| try old_runs.put(gpa, c, {});
        }
        try new.runCommandsDiffed(actx, &old_runs);
    }

    fn loadPluginsDiffed(self: *const Manifest, actx: *ApplyCtx, old_plugins: *const std.StringHashMapUnmanaged(void)) !void {
        for (self.imports.items) |imp| try imp.loadPluginsDiffed(actx, old_plugins);
        for (self.plugins.items) |d| {
            if (old_plugins.contains(d.name)) continue; // already loaded — reload isn't wired
            switch (pluginTrust(d.name)) {
                .catalog => {},
                .path_form => std.log.info("config: plugin '{s}' loaded from OUTSIDE the bundled catalog trust root — grants unverified (W4: approval prompt belongs here)", .{d.name}),
            }
            if (actx.loader) |ld| ld.load(ld.ctx, d.name);
        }
    }

    fn runCommandsDiffed(self: *const Manifest, actx: *ApplyCtx, old_runs: *const std.StringHashMapUnmanaged(void)) !void {
        for (self.imports.items) |imp| try imp.runCommandsDiffed(actx, old_runs);
        for (self.runs.items) |d| {
            if (old_runs.contains(d.command)) continue; // already ran on a prior load
            _ = command.run(actx.ctx.commands, actx.ctx, d.command, &.{}) catch {};
        }
    }

    /// Tear down every bind/provide/value THIS manifest (self + imports)
    /// applied, by owner — the reconcile "have\want" half. Binds are
    /// removed only if still owned by this manifest's owner (`Keymap.unbind`
    /// never steals a slot a later/different apply has since taken).
    /// Provides are removed wholesale per owner (`Actions` has no
    /// single-provider removal; re-`applyDecls` above re-adds `new`'s set
    /// right after, so net effect is correct — see `reconcile`'s doc).
    /// Plugins/runs are intentionally NOT torn down here (add-only, see
    /// `reconcile`).
    fn teardownOwned(self: *const Manifest, gpa: Allocator, actx: *ApplyCtx) !void {
        for (self.imports.items) |imp| try imp.teardownOwned(gpa, actx);
        for (self.binds.items) |d| actx.ctx.keymap.unbind(gpa, d.mode, d.key, self.owner);
        // EXACT match, not prefix: two imports named e.g. "def" and
        // "defaults" own "import:def" and "import:defaults" — a
        // literal string-prefix pair a `startsWith` teardown would
        // wrongly conflate (nit R-b).
        if (self.provides.items.len > 0) actx.ctx.actions.unregisterByOwner(self.owner);
        if (actx.config) |store| {
            for (self.values.items) |d| _ = store.del(gpa, d.owner, d.key);
        }
    }
};

fn optStr(s: []const u8) ?[]const u8 {
    return if (s.len > 0) s else null;
}

/// `hash()`'s framing primitives (R3 fix): every string is LENGTH-prefixed
/// and every decl LIST is length-prefixed before its items, so bare byte
/// concatenation can never make two structurally different manifests hash
/// identically — `bind("a","b","c")` and `bind("ab","","c")` used to
/// concatenate to the same bytes ("a"+"b"+"c" == "ab"+""+"c"); prefixing
/// each field's length breaks that (the very first prefix, 1 vs 2, already
/// diverges the hash streams). The length-prefix is `usize`'s native bytes
/// — not a portable wire format (this hash is a same-process approval/
/// reconcile key, never persisted or compared cross-build).
fn hStr(h: *std.hash.Wyhash, s: []const u8) void {
    hLen(h, s.len);
    h.update(s);
}
fn hLen(h: *std.hash.Wyhash, n: usize) void {
    h.update(std.mem.asBytes(&n));
}

fn ownerIsKnown(owner: []const u8, known_plugins: *const std.StringHashMapUnmanaged(void)) bool {
    if (known_plugins.contains(owner)) return true;
    for (core_value_namespaces) |ns| if (std.mem.eql(u8, owner, ns)) return true;
    return false;
}

/// `weft.menu(name)` application (see quickjs.zig's old `cMenu` doc — same
/// behavior, now tier-prioritized instead of hardcoded to config tier, so an
/// imported manifest's `weft.menu` gets the imported rung too).
fn applyMenu(ctx: *command.Context, gpa: Allocator, name: []const u8, prio: i32) void {
    const km = ctx.keymap;
    km.markMenuMode(gpa, name) catch {};
    km.setTextCommand(gpa, name, null) catch {};
    km.bind(gpa, name, "Escape", "menu-escape", prio, "config") catch {};
    km.bind(gpa, name, "C-g", "menu-escape", prio, "config") catch {};
    km.bind(gpa, name, "F1", "which-key-now", prio, "config") catch {};
}

/// Surface a rejected `provide` to the config author (same message/channel
/// as quickjs.zig's old `echoProvideRefused` — a race action doesn't take a
/// pick provider).
fn echoProvideRefused(ctx: *command.Context, gpa: Allocator, action: []const u8) void {
    const msg = std.fmt.allocPrint(gpa, "provide: '{s}' is a race action — register a capability provider instead", .{action}) catch return;
    defer gpa.free(msg);
    ctx.echo.clearRetainingCapacity();
    ctx.echo.appendSlice(gpa, msg) catch {};
}

/// Surface a dropped `weft.set` to the config author (nit a: the closed-
/// namespace drop must not be stderr-only — a GUI user never sees stderr).
fn echoValueDropped(ctx: *command.Context, gpa: Allocator, owner: []const u8, key: []const u8) void {
    const msg = std.fmt.allocPrint(gpa, "config: weft.set(\"{s}\", \"{s}\", ...) dropped — '{s}' is not a loaded plugin or a declared value namespace", .{ owner, key, owner }) catch return;
    defer gpa.free(msg);
    ctx.echo.clearRetainingCapacity();
    ctx.echo.appendSlice(gpa, msg) catch {};
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "manifest: staging + hash — two identical manifests hash identically" {
    const gpa = t.allocator;
    const a = try Manifest.create(gpa, "config", .config);
    defer a.destroy();
    try a.addBind("normal", "j", "cursor-down");
    try a.addValue("theme", "accent", "#8ec07c");
    try a.addPlugin("vim");

    const b = try Manifest.create(gpa, "config", .config);
    defer b.destroy();
    try b.addBind("normal", "j", "cursor-down");
    try b.addValue("theme", "accent", "#8ec07c");
    try b.addPlugin("vim");

    try t.expectEqual(a.hash(), b.hash());

    // A changed manifest hashes differently.
    try b.addBind("normal", "k", "cursor-up");
    try t.expect(a.hash() != b.hash());
}

test "manifest: pluginTrust classifies bare catalog names vs path-form" {
    try t.expectEqual(PluginTrust.catalog, pluginTrust("vim"));
    try t.expectEqual(PluginTrust.path_form, pluginTrust("dap.js"));
    try t.expectEqual(PluginTrust.path_form, pluginTrust("./local/x.wasm"));
    try t.expectEqual(PluginTrust.path_form, pluginTrust("/abs/x.wasm"));
}

test "manifest: keymapPriorityForTier places imported strictly between plugin and config" {
    try t.expect(Keymap.prio_plugin < keymapPriorityForTier(.imported));
    try t.expect(keymapPriorityForTier(.imported) < Keymap.prio_config);
}

test "manifest: R3 — length-framed hash distinguishes a bare-concatenation collision" {
    const gpa = t.allocator;
    // bind("a","b","c") and bind("ab","","c") concatenate to the identical
    // byte string "abc" under naive field concatenation — the exact
    // collision the length-prefix framing (hStr/hLen) exists to break.
    const a = try Manifest.create(gpa, "config", .config);
    defer a.destroy();
    try a.addBind("a", "b", "c");

    const b = try Manifest.create(gpa, "config", .config);
    defer b.destroy();
    try b.addBind("ab", "", "c");

    try t.expect(a.hash() != b.hash());
}

test {
    std.testing.refAllDecls(@This());
}
