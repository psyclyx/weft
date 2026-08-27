//! Manifest — config evaluation's output VALUE (doc/configuration.md §5, M3).
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
//! `provide`/`statusSegment`/`grant` — see `membrane/qjs_contract.zig`'s
//! `.config` group) is the ONLY channel a config script can use to affect a
//! `Manifest`; none of those thirteen imports reads wall-clock, environment,
//! or filesystem outside
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
const builtins = @import("builtins.zig");
const kv = @import("kv.zig");
const container_mod = @import("container.zig");
const Keymap = @import("Keymap.zig");
const surface = @import("surface.zig");
const grants_mod = @import("grants.zig");
const schema_mod = @import("weft_schema");

pub const Tier = container_mod.Tier;

/// Opaque callback into the resident plugin loader (main.zig's
/// `config_load.PluginHost`) — kept structurally identical to (and re-
/// exported by) `quickjs.zig`'s old `PluginLoader` so call sites don't churn,
/// but DEFINED here so this module stays quickjs-independent.
pub const PluginLoader = struct {
    ctx: *anyopaque,
    load: *const fn (ctx: *anyopaque, name: []const u8) void,
};

/// Opaque seam so `weft.statusSegment` can bind a `StatusSegmentDecl` into
/// the `ui/statusline-seg` Container slot WITHOUT this (core-layer) module
/// depending on `gfx/view/ui_mesh.zig` (a gfx-layer module — core never
/// imports gfx; `ui_mesh.zig`'s `StatuslineArgs`/`Seg` types need `Theme`
/// for `fg_override`/`bg_override`, which is genuinely gfx-coupled, so
/// those types can't move down to core without a much bigger move). Mirrors
/// `PluginLoader`'s shape exactly: an opaque ctx + a function pointer the
/// EMBEDDER wires (`app/config_load.zig`'s `ConfigSession.ui_bind`, wired
/// from `main.zig` to `gfx/view/ui_mesh.zig`'s `bindManifestSegment` against
/// `&session.container`). `ApplyCtx.ui_bind` defaults to `null` — every
/// existing `ApplyCtx` struct-literal call site (config-eval tests,
/// `System.applyManifest`, …) compiles unchanged and `weft.statusSegment`
/// becomes a documented, logged no-op wherever no binder is wired, exactly
/// like `loader == null` already does for `weft.plugin`.
pub const StatusSegBinder = struct {
    ctx: *anyopaque,
    /// Bind `decl` — BORROWED, not copied: the caller (`applyDecls`)
    /// guarantees it outlives the binding, because `decl` points directly
    /// into `self.status_segments.items` (a `*const Manifest`'s decl lists
    /// are treated as immutable for the manifest's whole lifetime — nothing
    /// appends to them after config eval finishes) and `teardownOwned`
    /// (called strictly before `Manifest.destroy`, see `reconcile`'s doc)
    /// unbinds every one of THIS manifest's owner's bindings before that
    /// memory is freed.
    ///
    /// `decl` is `*StatusSegmentDecl` (mutable), not `*const`, on purpose:
    /// the implementation is expected to resolve `decl.role` into
    /// `decl.resolved_role` HERE, once, at bind time (see that field's
    /// doc) — `applyDecls` hands over a `@constCast`ed pointer into its own
    /// `*const Manifest`, sound because nothing else touches this
    /// manifest's decls while `applyDecls` runs and every READ of
    /// `resolved_role` happens strictly after `bind` returns. `apply_ctx`
    /// is the SAME `*command.Context` `applyDecls` is running against —
    /// passed through so a binder can echo a role-typo warning through the
    /// ordinary user-facing channel, the `weft.set`/`echoValueDropped`
    /// precedent (this module stays free of the warning's TEXT — that's
    /// the binder's call, since it owns the vocabulary `role` names).
    bind: *const fn (ctx: *anyopaque, apply_ctx: *command.Context, owner: []const u8, tier: Tier, decl: *StatusSegmentDecl) anyerror!void,
};

// ── Declaration types — one per `weft.*` call, in AUTHORED order. ──────────

pub const PluginDecl = struct { name: []u8, path_form: bool };
/// `weft.bind(scope, key, intention | [intentions])` (doc/configuration.md
/// §5.2) — `commands` is the authored first-applicable fallback list; the
/// string form is a one-entry list, so there is a single representation.
pub const BindDecl = struct { mode: []u8, key: []u8, commands: []const []const u8 };
pub const MenuDecl = struct { name: []u8 };
pub const ActionDecl = struct { name: []u8 };
pub const SemanticActionDecl = struct { name: []u8 };
pub const ProvideDecl = struct { action: []u8, mode: []u8, lang: []u8, command: []u8, priority: i32 };
pub const ValueDecl = struct { owner: []u8, key: []u8, value: []u8 };
pub const RunArg = struct { value: []u8 };
pub const RunDecl = struct { command: []u8, args: []RunArg };
/// Fallback-list ceiling, matching the shim's `WEFT_BIND_MAX_CMDS`.
pub const maxBindCommands = 8;
const maxRunArgs = 8;
const maxRunArgBytes = 1024;
const maxRunArgTotal = 4096;
pub const EchoDecl = struct { message: []u8 };
pub const LogDecl = struct { message: []u8 };
/// `weft.statusSegment(text, role, priority)`
/// (doc/contextual-workspace-architecture.md §11, the mesh-reachability
/// verb) — a STATIC status-line segment: literal `text`, a `role` naming a
/// `core.surface.Role`, and `priority` (the `ui/statusline-seg` slot's
/// ordinary ordered_union sort key). Deliberately NOT `text_or_command`
/// despite the field name a first draft of this verb used in review notes:
/// a command-BACKED dynamic segment (re-evaluated per HUD build) needs a
/// `ui_provider` whose `call` re-invokes `command.run` — a real, separate
/// feature (needs a `*command.Context` at fire time, which a config-time
/// `StatusSegmentDecl` doesn't have and shouldn't fake) left for a later
/// step; this type stays honestly static-only until that lands.
pub const StatusSegmentDecl = struct {
    text: []u8,
    role: []u8,
    priority: i32,
    /// `role`'s parsed `core.surface.Role` — resolved ONCE at BIND time,
    /// inside `StatusSegBinder.bind`'s implementation (`gfx/view/ui_mesh.
    /// zig`'s `bindManifestSegment`), not at fire time: the fire path
    /// (`manifestSegProvider`) stays silent and cheap, never re-parsing a
    /// string on every HUD build. Deliberately not resolved earlier, in
    /// `applyDecls` (which COULD — `core.surface` is core-layer, no gfx
    /// dependency needed to parse the enum): a decl that's staged but never
    /// bound (no `ui_bind` wired) should never warn about a role typo it
    /// will never render. `.normal` until bound.
    resolved_role: surface.Role = .normal,
};

/// `weft.grant(plugin, capability, opts)`
/// (doc/contextual-workspace-architecture.md §13.5 — the deferred verb
/// `grants.zig`'s module doc named): stage a `GrantDecl` onto the
/// manifest, minted into the System's `grants. HandleTable` by
/// `reconcileGrants` (see that function's doc — `apply` calls it too,
/// with `old = null`) strictly BEFORE the named plugin's `describe()`
/// handshake runs.
///
/// `root` is `opts.root` flattened to a plain string by the qjs shim before
/// it ever reaches `manifest.zig` (`quickjs.zig`'s `cGrant`) — `""` (the
/// default; `opts` itself is optional at the JS call site) means
/// `Limit.none` (unrestricted within the capability); a non-empty string
/// narrows to `Limit.fs_root`.
///
/// **Why `opts` carries no `region`/`.doc_region` field, on purpose**: a
/// `Limit.doc_region` is keyed by stemma `EventAnchor`s — identities
/// resolved against a LIVE `Document`'s CRDT history (`grants.zig`'s
/// `DocRegion` doc). Config evaluation is sealed and runs before any buffer
/// exists (`Manifest`'s own module doc: "nothing mutates the editor during
/// eval") — there is no document, no anchor, nothing to author a region
/// AGAINST at config-eval time. Doc-region limits are RUNTIME identities;
/// authoring one is necessarily a runtime act (a command invoked against a
/// live buffer, not a `weft.*` config call), so it stays out of this verb's
/// `opts` shape rather than accepting a string that could only ever be
/// wrong (a byte range that drifts the instant anything upstream edits).
pub const ManifestGrantDecl = struct {
    plugin: []u8,
    capability: []u8,
    root: []u8,
};

/// D2's `weft.slot(name, {shape, composition, schema})` (doc/
/// d2-schema-payloads.md §2.2 form 3) — stages a runtime slot declaration
/// onto the manifest, rhyming with `StatusSegmentDecl`/`ManifestGrantDecl`
/// exactly: one entry per call, applied through `applyDecls` in authored
/// order. Unlike `StatusSegmentDecl` this needs NO opaque binder seam
/// (`StatusSegBinder`'s doc explains why THAT verb needs one — `ui_mesh.zig`'s
/// gfx-coupled `Seg`/`StatuslineArgs` types): `Container.declareSlot` is
/// already core-layer and schema-directed, so `applyDecls` calls it
/// directly (see that function, below).
///
/// **Scope note, disclosed (D2 slice report)**: this type, its hash
/// participation, and its `applyDecls` wiring ARE built and tested here —
/// what is NOT built in this slice is the `weft.slot(...)` JS SURFACE
/// itself (a `qjs_slot_declare` C-shim import in src/quickjs/weft_qjs.c
/// that walks a JS schema-literal object tree into a `Schema` value, the
/// way `js_grant`/`js_status_segment` flatten their own JS args today). That
/// C-side JS-object-tree walk is a real, separate unit of work with no new
/// CORE mechanism riding on it — every mechanism it would call
/// (`Manifest.addSlot`, the hash, `Container.declareSlot`) is already here,
/// tested exactly like `weft.grant`'s own tests exercise `Manifest.addGrant`
/// directly (`manifest.zig`'s own test discipline — see this file's
/// "manifest: staging — weft.grant lands..." test for the precedent this
/// type's tests follow).
pub const SlotDeclDecl = struct {
    name: []u8,
    shape: container_mod.Shape,
    composition: container_mod.Composition,
    /// Heap-owned (`schema_mod.cloneSchema`'d at `addSlot` time, freed by
    /// `Manifest.destroy`) — independent of whatever storage duration the
    /// caller's schema value had, matching every other decl field's
    /// dupe-on-stage convention.
    schema: *const schema_mod.Schema,
};

/// Whether a `weft.plugin(name)` names the bundled catalog or an explicit
/// path — the trust-root choke point (doc/cwa-prior-docs-audit.md §5 "Trust root —
/// DECIDED", §4 C17). A bare name ("vim") resolves against the bundled
/// plugin directory and is accepted under the catalog's curated grant
/// bundle — today's behavior, no prompt. A path-form name (contains '/', or
/// literally names a `.wasm`/`.js` file) is OUTSIDE the trust root: not
/// curated, its grants unverified. Behavior is unchanged today (both load);
/// this function exists so W4 has exactly one place to hang an approval
/// prompt on the path-form branch. `config_load.zig`'s `PluginHost.resolve`
/// calls this directly (not a parallel test) — a plugin must never resolve
/// differently than it was trust-classified.
pub const PluginTrust = enum { catalog, path_form };
pub fn pluginTrust(name: []const u8) PluginTrust {
    if (std.mem.indexOfScalar(u8, name, '/') != null or
        std.mem.endsWith(u8, name, ".wasm") or std.mem.endsWith(u8, name, ".js"))
        return .path_form;
    return .catalog;
}

/// The identity a loaded plugin registers itself, and its config values,
/// under — `weft.config`/`weft.set` key against THIS, never the raw
/// declared name (`config_load.zig`'s `PluginHost.load`/`loadJs` pass this
/// same value as `wasm_abi.loadPlugin`'s/`quickjs.JsPlugin.load`'s `name`
/// param). `std.fs.path.stem` already strips both a leading directory
/// (`stem` calls `basename` internally) and a trailing extension, so a bare
/// catalog name ("git"), a bare `.js`/`.wasm` file ("dap.js"), and an
/// explicit path ("/x/y/acp.js") all reduce to the same short identity
/// ("git", "dap", "acp"). `Manifest.populateKnownPlugins` must PREDICT this
/// identity before the plugin actually loads (so a `weft.set("acp", ...)`
/// that precedes `weft.plugin("acp.js")` in authored order still resolves
/// against a known owner — R1, see that function's doc) — the two
/// derivations must never drift, hence one function both sides call.
pub fn pluginNamespace(name: []const u8) []const u8 {
    return std.fs.path.stem(name);
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
/// `Manifest.applyDecls`'s ownership check
/// (doc/contextual-workspace-architecture.md §13.5 "`weft.set` value
/// namespaces are closed by default"). `"theme"` (`view.Theme`'s fields)
/// and `"editor"` (generic core knobs with no plugin owner — e.g.
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
    semantic_actions: std.ArrayList(SemanticActionDecl) = .empty,
    provides: std.ArrayList(ProvideDecl) = .empty,
    values: std.ArrayList(ValueDecl) = .empty,
    runs: std.ArrayList(RunDecl) = .empty,
    echoes: std.ArrayList(EchoDecl) = .empty,
    logs: std.ArrayList(LogDecl) = .empty,
    status_segments: std.ArrayList(StatusSegmentDecl) = .empty,
    grants: std.ArrayList(ManifestGrantDecl) = .empty,
    slots: std.ArrayList(SlotDeclDecl) = .empty,

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
            for (d.commands) |c| gpa.free(c);
            gpa.free(d.commands);
        }
        self.binds.deinit(gpa);
        for (self.menus.items) |d| gpa.free(d.name);
        self.menus.deinit(gpa);
        for (self.actions.items) |d| gpa.free(d.name);
        self.actions.deinit(gpa);
        for (self.semantic_actions.items) |d| gpa.free(d.name);
        self.semantic_actions.deinit(gpa);
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
        for (self.runs.items) |d| {
            gpa.free(d.command);
            for (d.args) |a| gpa.free(a.value);
            gpa.free(d.args);
        }
        self.runs.deinit(gpa);
        for (self.echoes.items) |d| gpa.free(d.message);
        self.echoes.deinit(gpa);
        for (self.logs.items) |d| gpa.free(d.message);
        self.logs.deinit(gpa);
        for (self.status_segments.items) |d| {
            gpa.free(d.text);
            gpa.free(d.role);
        }
        self.status_segments.deinit(gpa);
        for (self.slots.items) |d| {
            gpa.free(d.name);
            schema_mod.freeSchema(gpa, d.schema);
        }
        self.slots.deinit(gpa);
        for (self.grants.items) |d| {
            gpa.free(d.plugin);
            gpa.free(d.capability);
            gpa.free(d.root);
        }
        self.grants.deinit(gpa);
        gpa.destroy(self);
    }

    // ── Staging (quickjs.zig's `weft.*` handlers call these) ────────────

    pub fn addPlugin(self: *Manifest, name: []const u8) !void {
        try self.plugins.append(self.gpa, .{ .name = try self.gpa.dupe(u8, name), .path_form = pluginTrust(name) == .path_form });
    }
    /// `cmds` is the authored fallback list, in first-applicable order; the
    /// `weft.bind` string form arrives as a one-entry slice.
    pub fn addBind(self: *Manifest, mode: []const u8, key: []const u8, cmds: []const []const u8) !void {
        if (cmds.len == 0) return error.BindListEmpty;
        if (cmds.len > maxBindCommands) return error.BindListTooLong;
        const mode_owned = try self.gpa.dupe(u8, mode);
        errdefer self.gpa.free(mode_owned);
        const key_owned = try self.gpa.dupe(u8, key);
        errdefer self.gpa.free(key_owned);
        const cmds_owned = try self.gpa.alloc([]const u8, cmds.len);
        errdefer self.gpa.free(cmds_owned);
        var copied: usize = 0;
        errdefer for (cmds_owned[0..copied]) |c| self.gpa.free(c);
        for (cmds, 0..) |c, i| {
            cmds_owned[i] = try self.gpa.dupe(u8, c);
            copied += 1;
        }
        try self.binds.append(self.gpa, .{ .mode = mode_owned, .key = key_owned, .commands = cmds_owned });
    }
    pub fn addMenu(self: *Manifest, name: []const u8) !void {
        try self.menus.append(self.gpa, .{ .name = try self.gpa.dupe(u8, name) });
    }
    pub fn addAction(self: *Manifest, name: []const u8) !void {
        try self.actions.append(self.gpa, .{ .name = try self.gpa.dupe(u8, name) });
    }

    /// Declare an open semantic-view action command. Unlike `addAction`, this
    /// does not participate in context/provider resolution; it invokes the
    /// focused retained view with the exact protocol name.
    pub fn addSemanticAction(self: *Manifest, name: []const u8) !void {
        try self.semantic_actions.append(self.gpa, .{ .name = try self.gpa.dupe(u8, name) });
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
    pub fn addRun(self: *Manifest, cmd: []const u8, values: []const command.Value) !void {
        if (cmd.len > maxRunArgBytes) return error.RunCommandTooLarge;
        if (values.len > maxRunArgs) return error.RunArgumentsTooMany;
        var total: usize = 0;
        for (values) |value| {
            if (value != .string) return error.RunArgumentType;
            if (value.string.len > maxRunArgBytes) return error.RunArgumentTooLarge;
            total = std.math.add(usize, total, value.string.len) catch return error.RunArgumentsTooLarge;
        }
        if (total > maxRunArgTotal) return error.RunArgumentsTooLarge;
        const command_owned = try self.gpa.dupe(u8, cmd);
        errdefer self.gpa.free(command_owned);
        const args_owned = try self.gpa.alloc(RunArg, values.len);
        errdefer self.gpa.free(args_owned);
        var copied: usize = 0;
        errdefer for (args_owned[0..copied]) |a| self.gpa.free(a.value);
        for (values, 0..) |value, i| {
            args_owned[i] = .{ .value = try self.gpa.dupe(u8, value.string) };
            copied += 1;
        }
        try self.runs.append(self.gpa, .{ .command = command_owned, .args = args_owned });
    }
    pub fn addEcho(self: *Manifest, message: []const u8) !void {
        try self.echoes.append(self.gpa, .{ .message = try self.gpa.dupe(u8, message) });
    }
    pub fn addLog(self: *Manifest, message: []const u8) !void {
        try self.logs.append(self.gpa, .{ .message = try self.gpa.dupe(u8, message) });
    }
    pub fn addStatusSegment(self: *Manifest, text: []const u8, role: []const u8, priority: i32) !void {
        try self.status_segments.append(self.gpa, .{
            .text = try self.gpa.dupe(u8, text),
            .role = try self.gpa.dupe(u8, role),
            .priority = priority,
        });
    }
    /// Stage a `weft.slot` declaration. `schema` is deep-cloned
    /// (`schema_mod.cloneSchema`) — the caller's value need not outlive
    /// this call.
    pub fn addSlot(self: *Manifest, name: []const u8, shape: container_mod.Shape, composition: container_mod.Composition, schema: *const schema_mod.Schema) !void {
        const cloned = try schema_mod.cloneSchema(self.gpa, schema);
        errdefer schema_mod.freeSchema(self.gpa, cloned);
        try self.slots.append(self.gpa, .{
            .name = try self.gpa.dupe(u8, name),
            .shape = shape,
            .composition = composition,
            .schema = cloned,
        });
    }
    pub fn addGrant(self: *Manifest, plugin: []const u8, capability: []const u8, root: []const u8) !void {
        try self.grants.append(self.gpa, .{
            .plugin = try self.gpa.dupe(u8, plugin),
            .capability = try self.gpa.dupe(u8, capability),
            .root = try self.gpa.dupe(u8, root),
        });
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
            hLen(h, d.commands.len);
            for (d.commands) |c| hStr(h, c);
        }
        hLen(h, self.menus.items.len);
        for (self.menus.items) |d| hStr(h, d.name);
        hLen(h, self.actions.items.len);
        for (self.actions.items) |d| hStr(h, d.name);
        hLen(h, self.semantic_actions.items.len);
        for (self.semantic_actions.items) |d| hStr(h, d.name);
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
        for (self.runs.items) |d| {
            hStr(h, d.command);
            hLen(h, d.args.len);
            for (d.args) |a| hStr(h, a.value);
        }
        hLen(h, self.echoes.items.len);
        for (self.echoes.items) |d| hStr(h, d.message);
        hLen(h, self.logs.items.len);
        for (self.logs.items) |d| hStr(h, d.message);
        hLen(h, self.status_segments.items.len);
        for (self.status_segments.items) |d| {
            hStr(h, d.text);
            hStr(h, d.role);
            h.update(std.mem.asBytes(&d.priority));
        }
        hLen(h, self.grants.items.len);
        for (self.grants.items) |d| {
            hStr(h, d.plugin);
            hStr(h, d.capability);
            hStr(h, d.root);
        }
        hLen(h, self.slots.items.len);
        for (self.slots.items) |d| {
            hStr(h, d.name);
            h.update(std.mem.asBytes(&d.shape));
            h.update(std.mem.asBytes(&d.composition));
            // The schema is PART OF THE MANIFEST HASH (§2.2 form 3: "changing
            // a slot's schema changes the approved artifact, exactly as
            // changing a grant does") — canonicalizeSchema never allocates
            // failably-in-a-way-this-hot-path-can't-just-skip, but `hashInto`
            // has no error return (matches every other field here), so an
            // OOM degrades to hashing nothing for this one field rather than
            // panicking — see the test below for why that's still sound (an
            // OOM here means the process is about to fail allocating for
            // real work anyway).
            if (schema_mod.canonicalizeSchema(std.heap.page_allocator, d.schema)) |blob| {
                defer std.heap.page_allocator.free(blob);
                hStr(h, blob);
            } else |_| {}
        }
        hLen(h, self.imports.items.len);
        for (self.imports.items) |imp| imp.hashInto(h);
    }

    // ── Apply (§2.3: a separate, ordered, pure-function-of-the-value step) ─

    pub const ApplyCtx = struct {
        ctx: *command.Context,
        loader: ?PluginLoader,
        config: ?*kv.Store,
        /// `weft.statusSegment`'s mesh-reachability seam (task #19 item 3)
        /// — see `StatusSegBinder`'s doc. `null` (every call site that
        /// doesn't explicitly set it) makes a `weft.statusSegment` decl a
        /// logged no-op, never a crash.
        ui_bind: ?StatusSegBinder = null,
    };

    /// Apply this manifest FRESH — every declaration is applied as if for
    /// the first time (the initial config load). For a RELOAD against a
    /// previously-applied manifest, use `reconcile` instead. Grants still
    /// mint correctly here (`reconcileGrants(gpa, null, self, actx)`, below)
    /// — but this does NOT log the approval-diff PRESENTATION
    /// (`grantDiffSummary`); that is `reconcile`'s doc, not this function's.
    /// Harmless in practice: every PRODUCTION caller (`System.applyManifest`,
    /// `config_load.ConfigSession.reload`) always calls `reconcile`, passing
    /// `old = null` for the first load — `apply` itself is a test/embedder
    /// convenience for callers that don't want reconcile's diffing at all.
    pub fn apply(self: *const Manifest, gpa: Allocator, actx: *ApplyCtx) !void {
        var known: std.StringHashMapUnmanaged(void) = .empty;
        defer known.deinit(gpa);
        try self.populateKnownPlugins(gpa, &known);
        try self.applyDecls(gpa, actx, &known);
        // Grants mint BEFORE plugins load (`reconcileGrants(gpa, null, ...)`
        // degenerates to "mint every declared grant, revoke nothing" — the
        // fresh-load case) — see `reconcileGrants`'s doc for why this
        // ordering is what makes the composition rule (a config-authored
        // grant narrows/replaces a plugin's own describe() ask) work at all:
        // `wasm_host/plugin.zig`'s `mintGrantHandles` must find this row
        // ALREADY live when a plugin's `describe()` handshake runs.
        try reconcileGrants(gpa, null, self, actx);
        try self.loadPlugins(actx);
        try self.runCommands(actx);
    }

    fn populateKnownPlugins(self: *const Manifest, gpa: Allocator, out: *std.StringHashMapUnmanaged(void)) !void {
        for (self.imports.items) |imp| try imp.populateKnownPlugins(gpa, out);
        for (self.plugins.items) |d| {
            try out.put(gpa, d.name, {});
            // A path-form / `.js` plugin's VALUE-STORE identity is its
            // `pluginNamespace` — NOT the raw declared name.
            // `weft.plugin("acp.js")` reads its config as plugin "acp"
            // (`weft.config(key)` keys on `JsPlugin.name`, which IS
            // `pluginNamespace`'s result). Without this, `weft.set("acp",
            // "cmd", …)` — the documented ACP setup — silently dropped as an
            // unknown owner (R1: a real pre-M3-working config broken by the
            // ownership check). The namespace is a substring of `d.name`'s
            // own backing memory (no allocation), valid for the same
            // lifetime.
            const ns = pluginNamespace(d.name);
            if (!std.mem.eql(u8, ns, d.name)) try out.put(gpa, ns, {});
        }
    }

    fn collectPluginNames(self: *const Manifest, gpa: Allocator, out: *std.ArrayList([]const u8)) !void {
        for (self.imports.items) |imp| try imp.collectPluginNames(gpa, out);
        for (self.plugins.items) |d| try out.append(gpa, d.name);
    }

    fn appendRunKeyPart(gpa: Allocator, out: *std.ArrayList(u8), bytes: []const u8) !void {
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, @intCast(bytes.len), .little);
        try out.appendSlice(gpa, &len);
        try out.appendSlice(gpa, bytes);
    }

    /// A length-framed identity for add-only run reconciliation. Arguments are
    /// part of identity: changing `grammar-add`'s package or symbol must run the
    /// new invocation even though its command name is unchanged.
    fn runKey(gpa: Allocator, d: RunDecl) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try appendRunKeyPart(gpa, &out, d.command);
        for (d.args) |a| try appendRunKeyPart(gpa, &out, a.value);
        return out.toOwnedSlice(gpa);
    }

    fn runOne(actx: *ApplyCtx, d: RunDecl) void {
        var values: [maxRunArgs]command.Value = undefined;
        for (d.args, 0..) |a, i| values[i] = .{ .string = a.value };
        _ = command.run(actx.ctx.commands, actx.ctx, d.command, values[0..d.args.len]) catch {};
    }

    fn collectRunCommands(self: *const Manifest, gpa: Allocator, out: *std.ArrayList([]const u8)) !void {
        for (self.imports.items) |imp| try imp.collectRunCommands(gpa, out);
        for (self.runs.items) |d| try out.append(gpa, try runKey(gpa, d));
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
        // Fallback lists bind their FIRST entry; the rest ride inertly on the
        // decl until the intention catalog resolves them.
        for (self.binds.items) |d| actx.ctx.keymap.bind(gpa, d.mode, d.key, d.commands[0], prio, self.owner) catch {};
        for (self.menus.items) |d| applyMenu(actx.ctx, gpa, d.name, prio);
        for (self.actions.items) |d| command.registerAction(gpa, actx.ctx.commands, actx.ctx.actions, d.name, .pick) catch {};
        if (actx.ctx.semantic) |services| for (self.semantic_actions.items) |d|
            builtins.registerSemanticAction(gpa, actx.ctx.commands, services, d.name) catch {};
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
            actx.ctx.head.echo.clearRetainingCapacity();
            actx.ctx.head.echo.appendSlice(gpa, d.message) catch {};
        }
        for (self.logs.items) |d| std.log.info("config: {s}", .{d.message});
        // D2's `weft.slot` (§2.2 form 3): unlike `status_segments`, no opaque
        // binder seam is needed — `Container.declareSlot` is already
        // core-layer (see `SlotDeclDecl`'s doc for why). The schema pointer
        // is BORROWED by Container (matches every other slot declarer); it
        // stays alive because this `Manifest` owns it for its own lifetime,
        // which is guaranteed to outlive the `System`/`Container` it applies
        // into (a config reload destroys the OLD manifest only after the new
        // one has applied — see `reconcile`).
        for (self.slots.items) |d| {
            actx.ctx.actions.container.declareSlot(.{
                .name = d.name,
                .shape = d.shape,
                .composition = d.composition,
                .schema = d.schema,
            }) catch {};
        }
        for (self.status_segments.items) |*d| {
            if (actx.ui_bind) |binder| {
                // `@constCast`: sound here — see `StatusSegBinder.bind`'s
                // doc for why a binder mutating `d.resolved_role` in place
                // is safe (this manifest's decls are otherwise immutable
                // for the duration of this `apply`/`reconcile` call, and
                // nothing reads `resolved_role` before `bind` returns).
                binder.bind(binder.ctx, actx.ctx, self.owner, self.tier, @constCast(d)) catch |e|
                    std.log.warn("config: weft.statusSegment('{s}') failed to bind: {t}", .{ d.text, e });
            } else {
                std.log.warn("config: weft.statusSegment('{s}') declared but no UI-mesh binder is wired for this apply; dropped", .{d.text});
            }
        }
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
        for (self.runs.items) |d| runOne(actx, d);
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
    /// drift). `weft.grant` decls join a THIRD family (`reconcileGrants`):
    /// add/remove-DIFFED, unlike plugins/runs (add-only) but ALSO unlike
    /// binds/provides (blind teardown+reapply) — see that function's doc for
    /// why a grant needs its own middle ground. Every call also logs the
    /// approval-diff PRESENTATION (`grantDiffSummary`) before applying
    /// anything.
    pub fn reconcile(gpa: Allocator, old: ?*const Manifest, new: *const Manifest, actx: *ApplyCtx) !void {
        if (old) |o| {
            if (o.hash() == new.hash()) {
                std.log.info("config: reload — manifest unchanged (0x{x}), no-op", .{new.hash()});
                return;
            }
            std.log.info("config: reload — manifest changed (0x{x} -> 0x{x}), reconciling", .{ o.hash(), new.hash() });
            try o.teardownOwned(gpa, actx);
        }

        // The approval-diff PRESENTATION (§2.4/§6 W4's residual: "the
        // approval surface shows the manifest DIFF, not raw tuples") — every
        // load logs it, including the first (`old == null`: everything
        // reads as added). The hash check above already returned early on a
        // true no-op reload, so every path reaching here has SOMETHING to
        // show.
        if (grantDiffSummary(gpa, old, new)) |summary| {
            defer gpa.free(summary);
            std.log.info("{s}", .{summary});
        } else |e| std.log.warn("config: grant diff summary failed: {t}", .{e});

        var known: std.StringHashMapUnmanaged(void) = .empty;
        defer known.deinit(gpa);
        try new.populateKnownPlugins(gpa, &known);
        try new.applyDecls(gpa, actx, &known);

        // Grants mint/revoke BEFORE plugin loading (`loadPluginsDiffed`
        // below): a config-authored row must already be LIVE when a newly-
        // loading plugin's `describe()` handshake runs, for the composition
        // rule (`wasm_host/plugin.zig`'s `mintGrantHandles`) to find it.
        try reconcileGrants(gpa, old, new, actx);

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
            defer for (old_run_list.items) |c| gpa.free(c);
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
            const key = runKey(actx.ctx.gpa, d) catch continue;
            defer actx.ctx.gpa.free(key);
            if (old_runs.contains(key)) continue; // already ran on a prior load
            runOne(actx, d);
        }
    }

    // ── Grants (doc/contextual-workspace-architecture.md §13.5: `weft.grant` — the
    // deferred verb `grants.zig`'s module doc named) ───────────────────────

    fn collectGrants(self: *const Manifest, gpa: Allocator, out: *std.ArrayList(ManifestGrantDecl)) !void {
        for (self.imports.items) |imp| try imp.collectGrants(gpa, out);
        for (self.grants.items) |d| try out.append(gpa, d);
    }

    fn containsGrant(list: []const ManifestGrantDecl, d: ManifestGrantDecl) bool {
        for (list) |x| {
            if (std.mem.eql(u8, x.plugin, d.plugin) and std.mem.eql(u8, x.capability, d.capability) and std.mem.eql(u8, x.root, d.root))
                return true;
        }
        return false;
    }

    /// Grants: an ADD/REMOVE-diffed pass, joining the same family as
    /// plugins/runs (`loadPluginsDiffed`/`runCommandsDiffed`) — its OWN
    /// pass, deliberately not folded into `applyDecls`/`teardownOwned`'s
    /// per-owner "unbind everything owned, then reapply everything" pattern.
    /// That pattern is safe for binds/provides/values (nothing outside the
    /// manifest holds a standing reference into them), but a `weft.grant`
    /// decl mints a table row a loaded plugin may already POSSESS as a
    /// `CapHandle` (`WasmPlugin.grant_handles`) — `HandleTable.grant` always
    /// mints a FRESH row, never updates one in place, so blindly
    /// revoke-then-remint on every reconcile (which runs whenever the
    /// manifest's hash differs, for ANY reason — not necessarily a grant
    /// change) would silently orphan that plugin's already-held handle even
    /// when ITS grant never changed. So: only a decl truly ABSENT from `new`
    /// (by full plugin+capability+root identity — a changed `root` is
    /// "old removed, new added", exactly right, since the LIMIT changed) is
    /// revoked; only a decl truly ABSENT from `old` is minted; an UNCHANGED
    /// decl (present, byte-identical, in both) is left completely alone, so
    /// whatever already holds its handle keeps holding a LIVE one.
    ///
    /// **The composition-rule round trip
    /// (doc/contextual-workspace-architecture.md §13.5, the honest
    /// answer)**: when a `weft.grant` decl is REMOVED, `revoke` invalidates
    /// every live row for that (principal, capability) — normally exactly
    /// ONE row, since `wasm_host/plugin.zig`'s `mintGrantHandles` never
    /// separately mints a describe()-boolean row when a config-authored one
    /// already exists (see that function's doc). There is therefore no
    /// "baseline" row left to fall back to: the plugin loses that capability
    /// entirely until a fresh load re-establishes it — the same honesty
    /// `manifest.zig` already states for a removed `weft.plugin` (unload
    /// isn't wired; restart to fully remove it).
    ///
    /// **The mirror case, equally honest — ADDING a narrowing grant for an
    /// ALREADY-RUNNING plugin (review nit 3)**: this pass DOES mint a fresh
    /// row for a `weft.grant` decl newly added on reload, even naming a
    /// plugin that's already loaded — but `loadPluginsDiffed` (the plugin-
    /// loading pass right after this one) skips a plugin already present
    /// (`manifest.zig`'s own "add-only, unload isn't wired" limitation), so
    /// `wasm_host/plugin.zig`'s `mintGrantHandles`/composition check — the
    /// ONLY place a plugin's OWN `grant_handles[i]` gets (re)pointed at a
    /// row — never runs again for it. The freshly-minted, narrower row
    /// exists in the table, live and correct for `grants-show`/future
    /// principals, but the ALREADY-RUNNING plugin keeps possessing its
    /// original, BROADER describe()-boolean handle (minted at ITS load,
    /// before this grant existed) until a fresh load re-runs
    /// `mintGrantHandles` and finds the new row via `findLive`. Not a
    /// silent security hole — the narrower row is real and independently
    /// revocable/inspectable — but a config author who ADDS a narrowing
    /// grant expecting it to immediately confine an already-running plugin
    /// will be surprised: reload/restart is what makes it take hold, same
    /// as removing a `weft.plugin` line doesn't unload it. (An EXPLICIT
    /// `revoke <plugin> <capability>` command, by contrast, invalidates the
    /// plugin's held handle immediately — that path doesn't go through
    /// reload at all.)
    ///
    /// `old == null` (the fresh-load case — `apply`'s caller) degenerates to
    /// "mint everything declared, revoke nothing".
    fn reconcileGrants(gpa: Allocator, old: ?*const Manifest, new: *const Manifest, actx: *ApplyCtx) !void {
        var new_grants: std.ArrayList(ManifestGrantDecl) = .empty;
        defer new_grants.deinit(gpa);
        try new.collectGrants(gpa, &new_grants);

        var old_grants: std.ArrayList(ManifestGrantDecl) = .empty;
        defer old_grants.deinit(gpa);
        if (old) |o| try o.collectGrants(gpa, &old_grants);

        for (old_grants.items) |od| {
            if (containsGrant(new_grants.items, od)) continue; // unchanged — leave its row alone
            if (actx.ctx.grant_table) |table| {
                const n = table.revoke(od.plugin, od.capability);
                std.log.info("config: weft.grant('{s}', '{s}') removed — {d} row(s) revoked", .{ od.plugin, od.capability, n });
            }
        }
        for (new_grants.items) |nd| {
            if (containsGrant(old_grants.items, nd)) continue; // unchanged — already minted, already possessed
            const table = actx.ctx.grant_table orelse {
                std.log.warn("config: weft.grant('{s}', '{s}') declared but no grant table is wired for this apply; dropped", .{ nd.plugin, nd.capability });
                continue;
            };
            const limit: grants_mod.Limit = if (nd.root.len > 0) .{ .fs_root = nd.root } else .none;
            _ = table.grant(.{ .capability = nd.capability, .limit = limit }, nd.plugin, null) catch |e|
                std.log.warn("config: weft.grant('{s}', '{s}') failed to mint ({t})", .{ nd.plugin, nd.capability, e });
        }
    }

    // ── The approval-diff PRESENTATION (§2.4/§6 W4's residual: "the
    // approval surface shows the manifest DIFF, not raw tuples") ──────────

    fn containsStr(list: []const []const u8, s: []const u8) bool {
        for (list) |x| if (std.mem.eql(u8, x, s)) return true;
        return false;
    }

    /// One grant's display token: `capability`, or `capability@root=X` when
    /// limited. Caller-owned.
    fn grantToken(gpa: Allocator, d: ManifestGrantDecl) ![]u8 {
        if (d.root.len == 0) return gpa.dupe(u8, d.capability);
        return std.fmt.allocPrint(gpa, "{s}@root={s}", .{ d.capability, d.root });
    }

    /// Every grant token declared FOR `plugin` in `list`, comma-joined, in
    /// decl order. Caller-owned.
    fn grantTokensFor(gpa: Allocator, list: []const ManifestGrantDecl, plugin: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        var first = true;
        for (list) |d| {
            if (!std.mem.eql(u8, d.plugin, plugin)) continue;
            if (!first) try out.append(gpa, ',');
            first = false;
            const tok = try grantToken(gpa, d);
            defer gpa.free(tok);
            try out.appendSlice(gpa, tok);
        }
        return out.toOwnedSlice(gpa);
    }

    /// `plugin`'s grant tokens present in `to` but absent from `from` (by
    /// `containsGrant`'s full-tuple identity) — the set-difference
    /// `grantDiffSummary`'s "~name[+a,-b]" shape needs in BOTH directions
    /// (swap `from`/`to`, and the sign, for the removed half). Each token is
    /// PREFIXED with `sign` ('+' or '-'). Caller-owned.
    fn grantChangedFor(gpa: Allocator, plugin: []const u8, from: []const ManifestGrantDecl, to: []const ManifestGrantDecl, sign: u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        var first = true;
        for (to) |d| {
            if (!std.mem.eql(u8, d.plugin, plugin)) continue;
            if (containsGrant(from, d)) continue;
            if (!first) try out.append(gpa, ',');
            first = false;
            try out.append(gpa, sign);
            const tok = try grantToken(gpa, d);
            defer gpa.free(tok);
            try out.appendSlice(gpa, tok);
        }
        return out.toOwnedSlice(gpa);
    }

    fn appendDiffEntry(gpa: Allocator, out: *std.ArrayList(u8), sign: u8, name: []const u8, toks: []const u8) !void {
        try out.append(gpa, ' ');
        try out.append(gpa, sign);
        try out.appendSlice(gpa, name);
        if (toks.len > 0) {
            try out.append(gpa, '[');
            try out.appendSlice(gpa, toks);
            try out.append(gpa, ']');
        }
    }

    /// The diff PRESENTATION itself (v1 — INSPECTION, never a gate; §6 W4:
    /// "a blocking approve/deny prompt is explicitly NOT v1 — the diff
    /// PRESENTATION is the gate"): one summary line in the
    /// `+git[proc,fs_write@root=repo] -notes[fs_write] ~vim[+doc.edit]` shape
    /// — a `+name[...]` entry per plugin newly present in `new` (bracket
    /// lists ITS `weft.grant` decls in `new`, omitted if it declared none), a
    /// `-name[...]` entry per plugin present in `old` but absent from `new`
    /// (bracket lists what it held), and a `~name[+cap,-cap2]` entry for a
    /// plugin present in BOTH whose `weft.grant` set changed. `old == null`
    /// (the first load) reads every plugin as added. `(no change)` when
    /// nothing in either dimension differs.
    ///
    /// **The catalog-trust-root framing (§5 "Trust root — DECIDED")**: a
    /// bare catalog plugin name's OWN `describe()`-declared perms are the
    /// bundled catalog's IMPLICIT, curated grant bundle — deliberately NOT
    /// enumerable here. This diff is computed PRE-load (`reconcile` calls it
    /// before `applyDecls`/plugin loading run at all) — it's what a user
    /// would approve BEFORE trusting the load, never a post-hoc report of
    /// what a plugin's `describe()` already asked for (which hasn't run
    /// yet). Only EXPLICIT `weft.grant` decls are data this function CAN
    /// see, so only they appear in the brackets; a bare `+name` with no
    /// bracket is exactly "this plugin loads under the catalog's own,
    /// curated trust — nothing further was explicitly declared for it".
    /// Caller-owned.
    pub fn grantDiffSummary(gpa: Allocator, old: ?*const Manifest, new: *const Manifest) ![]u8 {
        var new_plugins: std.ArrayList([]const u8) = .empty;
        defer new_plugins.deinit(gpa);
        try new.collectPluginNames(gpa, &new_plugins);
        var new_grants: std.ArrayList(ManifestGrantDecl) = .empty;
        defer new_grants.deinit(gpa);
        try new.collectGrants(gpa, &new_grants);

        var old_plugins: std.ArrayList([]const u8) = .empty;
        defer old_plugins.deinit(gpa);
        var old_grants: std.ArrayList(ManifestGrantDecl) = .empty;
        defer old_grants.deinit(gpa);
        if (old) |o| {
            try o.collectPluginNames(gpa, &old_plugins);
            try o.collectGrants(gpa, &old_grants);
        }

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        try out.appendSlice(gpa, "config grants:");
        var any = false;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(gpa);

        for (new_plugins.items) |name| {
            if ((try seen.getOrPut(gpa, name)).found_existing) continue;
            if (!containsStr(old_plugins.items, name)) {
                const toks = try grantTokensFor(gpa, new_grants.items, name);
                defer gpa.free(toks);
                try appendDiffEntry(gpa, &out, '+', name, toks);
                any = true;
            } else {
                const added = try grantChangedFor(gpa, name, old_grants.items, new_grants.items, '+');
                defer gpa.free(added);
                const removed = try grantChangedFor(gpa, name, new_grants.items, old_grants.items, '-');
                defer gpa.free(removed);
                if (added.len > 0 or removed.len > 0) {
                    try out.append(gpa, ' ');
                    try out.append(gpa, '~');
                    try out.appendSlice(gpa, name);
                    try out.append(gpa, '[');
                    try out.appendSlice(gpa, added);
                    if (added.len > 0 and removed.len > 0) try out.append(gpa, ',');
                    try out.appendSlice(gpa, removed);
                    try out.append(gpa, ']');
                    any = true;
                }
            }
        }
        for (old_plugins.items) |name| {
            if ((try seen.getOrPut(gpa, name)).found_existing) continue;
            const toks = try grantTokensFor(gpa, old_grants.items, name);
            defer gpa.free(toks);
            try appendDiffEntry(gpa, &out, '-', name, toks);
            any = true;
        }

        if (!any) {
            out.clearRetainingCapacity();
            try out.appendSlice(gpa, "config grants: (no change)");
        }
        return out.toOwnedSlice(gpa);
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
        // `weft.statusSegment` bindings share the SAME Container `actions`
        // adapts onto (task #19's shared-Container fold-in) — unbind them
        // by the identical owner-exact convention `provides` uses just
        // above (a raw Container call, not routed through the `actions`
        // domain wrapper: these are `ui/*` bindings, not action provides).
        // Domain-SCOPED (review send-back): `.ui`, not the container-wide
        // form the pre-fix code used — this call and the `unregisterByOwner`
        // just above are NOT redundant even when `self.owner` is the same
        // string for both (e.g. the root config manifest's `"config"`):
        // each now removes ONLY its own domain's bindings, precisely.
        // MUST run before `Manifest.destroy()` frees `d.text`/`d.role` —
        // `StatusSegBinder.bind`'s `ctx` pointer borrows straight into
        // `self.status_segments.items`; see that type's doc. `reconcile`
        // guarantees this ordering (`teardownOwned` always precedes
        // `destroy` for the OLD manifest — see its doc).
        if (self.status_segments.items.len > 0) actx.ctx.actions.container.unbindOwnerExact(.ui, self.owner);
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
    ctx.head.echo.clearRetainingCapacity();
    ctx.head.echo.appendSlice(gpa, msg) catch {};
}

/// Surface a dropped `weft.set` to the config author (nit a: the closed-
/// namespace drop must not be stderr-only — a GUI user never sees stderr).
fn echoValueDropped(ctx: *command.Context, gpa: Allocator, owner: []const u8, key: []const u8) void {
    const msg = std.fmt.allocPrint(gpa, "config: weft.set(\"{s}\", \"{s}\", ...) dropped — '{s}' is not a loaded plugin or a declared value namespace", .{ owner, key, owner }) catch return;
    defer gpa.free(msg);
    ctx.head.echo.clearRetainingCapacity();
    ctx.head.echo.appendSlice(gpa, msg) catch {};
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "manifest: staging + hash — two identical manifests hash identically" {
    const gpa = t.allocator;
    const a = try Manifest.create(gpa, "config", .config);
    defer a.destroy();
    try a.addBind("normal", "j", &.{"cursor-down"});
    try a.addValue("theme", "accent", "#8ec07c");
    try a.addPlugin("vim");

    const b = try Manifest.create(gpa, "config", .config);
    defer b.destroy();
    try b.addBind("normal", "j", &.{"cursor-down"});
    try b.addValue("theme", "accent", "#8ec07c");
    try b.addPlugin("vim");

    try t.expectEqual(a.hash(), b.hash());

    // A changed manifest hashes differently.
    try b.addBind("normal", "k", &.{"cursor-up"});
    try t.expect(a.hash() != b.hash());
}

test "manifest: argument-bearing runs are owned and hash-sensitive" {
    const gpa = t.allocator;
    const args = [_]command.Value{
        .{ .string = ".foo" },
        .{ .string = "/tmp/grammar" },
        .{ .string = "tree_sitter_fixture" },
    };
    const a = try Manifest.create(gpa, "config", .config);
    defer a.destroy();
    try a.addRun("grammar-add", &args);

    const b = try Manifest.create(gpa, "config", .config);
    defer b.destroy();
    try b.addRun("grammar-add", &args);
    try t.expectEqual(a.hash(), b.hash());
    try t.expectEqualStrings("/tmp/grammar", a.runs.items[0].args[1].value);

    const changed = [_]command.Value{
        .{ .string = ".foo" },
        .{ .string = "/tmp/grammar" },
        .{ .string = "other_symbol" },
    };
    try b.addRun("grammar-add", &changed);
    try t.expect(a.hash() != b.hash());
}

test "manifest: pluginTrust classifies bare catalog names vs path-form" {
    try t.expectEqual(PluginTrust.catalog, pluginTrust("vim"));
    try t.expectEqual(PluginTrust.path_form, pluginTrust("dap.js"));
    try t.expectEqual(PluginTrust.path_form, pluginTrust("./local/x.wasm"));
    try t.expectEqual(PluginTrust.path_form, pluginTrust("/abs/x.wasm"));
}

test "manifest: pluginNamespace + pluginTrust agree across name forms — pinned against config_load.zig's callers" {
    const Case = struct { name: []const u8, namespace: []const u8, trust: PluginTrust };
    const cases = [_]Case{
        .{ .name = "git", .namespace = "git", .trust = .catalog },
        .{ .name = "dap.js", .namespace = "dap", .trust = .path_form },
        .{ .name = "/x/y/acp.js", .namespace = "acp", .trust = .path_form },
        .{ .name = "foo.wasm", .namespace = "foo", .trust = .path_form },
    };
    for (cases) |c| {
        try t.expectEqualStrings(c.namespace, pluginNamespace(c.name));
        try t.expectEqual(c.trust, pluginTrust(c.name));
    }
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
    try a.addBind("a", "b", &.{"c"});

    const b = try Manifest.create(gpa, "config", .config);
    defer b.destroy();
    try b.addBind("ab", "", &.{"c"});

    try t.expect(a.hash() != b.hash());
}

test "manifest: staging — weft.grant lands as a ManifestGrantDecl, hash-sensitive to its root" {
    const gpa = t.allocator;
    const a = try Manifest.create(gpa, "config", .config);
    defer a.destroy();
    try a.addGrant("git", "fs_write", "repo");

    try t.expectEqual(@as(usize, 1), a.grants.items.len);
    try t.expectEqualStrings("git", a.grants.items[0].plugin);
    try t.expectEqualStrings("fs_write", a.grants.items[0].capability);
    try t.expectEqualStrings("repo", a.grants.items[0].root);

    const b = try Manifest.create(gpa, "config", .config);
    defer b.destroy();
    try b.addGrant("git", "fs_write", "repo");
    try t.expectEqual(a.hash(), b.hash());

    const c = try Manifest.create(gpa, "config", .config);
    defer c.destroy();
    try c.addGrant("git", "fs_write", "other-repo");
    try t.expect(a.hash() != c.hash());

    const d = try Manifest.create(gpa, "config", .config);
    defer d.destroy();
    try d.addGrant("git", "fs_write", ""); // unrestricted — a different decl than a limited one
    try t.expect(a.hash() != d.hash());
}

test "manifest: staging — weft.slot lands as a SlotDeclDecl, hash-sensitive to its schema (D2 §2.2 form 3)" {
    const gpa = t.allocator;
    const str_ty: schema_mod.Schema = .str;
    const u32_ty: schema_mod.Schema = .{ .scalar = .u32 };
    const fields_v1 = [_]schema_mod.Schema.Field{.{ .name = "text", .ty = &str_ty }};
    const schema_v1: schema_mod.Schema = .{ .@"struct" = &fields_v1 };

    const a = try Manifest.create(gpa, "config", .config);
    defer a.destroy();
    try a.addSlot("ui/badge", .query, .ordered_union, &schema_v1);

    try t.expectEqual(@as(usize, 1), a.slots.items.len);
    try t.expectEqualStrings("ui/badge", a.slots.items[0].name);
    try t.expectEqual(container_mod.Shape.query, a.slots.items[0].shape);
    // The staged schema is a DEEP, independent clone — proven by mutating
    // the source `schema_v1` after staging and confirming the manifest's
    // own copy is unaffected (it is a distinct heap tree; `schemaEql`
    // structural-compares it against the ORIGINAL shape below instead).
    try t.expect(schema_mod.schemaEql(&schema_v1, a.slots.items[0].schema));

    const b = try Manifest.create(gpa, "config", .config);
    defer b.destroy();
    try b.addSlot("ui/badge", .query, .ordered_union, &schema_v1);
    try t.expectEqual(a.hash(), b.hash());

    // A DIFFERENT schema (an added field — §2.3's only legal evolution, but
    // still a hash-visible change: "changing a slot's schema changes the
    // approved artifact, exactly as changing a grant does") hashes
    // differently, even though the SLOT NAME is identical.
    const fields_v2 = [_]schema_mod.Schema.Field{
        .{ .name = "text", .ty = &str_ty },
        .{ .name = "count", .ty = &u32_ty },
    };
    const schema_v2: schema_mod.Schema = .{ .@"struct" = &fields_v2 };
    const c = try Manifest.create(gpa, "config", .config);
    defer c.destroy();
    try c.addSlot("ui/badge", .query, .ordered_union, &schema_v2);
    try t.expect(a.hash() != c.hash());

    // A different composition, same name+schema, also hash-visible.
    const d = try Manifest.create(gpa, "config", .config);
    defer d.destroy();
    try d.addSlot("ui/badge", .query, .merge_ranked, &schema_v1);
    try t.expect(a.hash() != d.hash());
}

// NOTE (D2 slice report): `applyDecls`'s `weft.slot` loop (above, in
// `applyDecls` itself) has no FILE-LOCAL end-to-end test against a real
// `command.Context` — consistent with every OTHER `applyDecls` loop in this
// file (`binds`/`provides`/`values`/…), none of which has one either: this
// file's tests exercise staging + hashing directly (see the test above);
// `apply`/`reconcile` against a live `System` are covered at the
// `System`/`config_load.zig` integration level, which this slice does not
// add new coverage to (unchanged surface — the new loop calls the same
// already-tested `Container.declareSlot` every other slot declarer calls).

test "manifest: grantDiffSummary — the first load reads every plugin as added, grants bracketed" {
    const gpa = t.allocator;
    const new = try Manifest.create(gpa, "config", .config);
    defer new.destroy();
    try new.addPlugin("git");
    try new.addGrant("git", "proc", "");
    try new.addGrant("git", "fs_write", "repo");
    try new.addPlugin("vim");

    const summary = try Manifest.grantDiffSummary(gpa, null, new);
    defer gpa.free(summary);
    try t.expectEqualStrings("config grants: +git[proc,fs_write@root=repo] +vim", summary);
}

test "manifest: grantDiffSummary — add/remove/change across a reload; an unchanged plugin stays silent" {
    const gpa = t.allocator;
    const old = try Manifest.create(gpa, "config", .config);
    defer old.destroy();
    try old.addPlugin("git");
    try old.addGrant("git", "fs_write", "repo");
    try old.addPlugin("notes");
    try old.addGrant("notes", "fs_write", "");
    try old.addPlugin("vim");

    const new = try Manifest.create(gpa, "config", .config);
    defer new.destroy();
    try new.addPlugin("git");
    try new.addGrant("git", "fs_write", "other-repo"); // root CHANGED
    try new.addPlugin("vim"); // unchanged, no grants either side
    try new.addPlugin("helix"); // newly added

    const summary = try Manifest.grantDiffSummary(gpa, old, new);
    defer gpa.free(summary);
    try t.expect(std.mem.indexOf(u8, summary, "~git[+fs_write@root=other-repo,-fs_write@root=repo]") != null);
    try t.expect(std.mem.indexOf(u8, summary, "+helix") != null);
    try t.expect(std.mem.indexOf(u8, summary, "-notes[fs_write]") != null);
    try t.expect(std.mem.indexOf(u8, summary, "vim") == null); // silent — nothing changed for it
}

test "manifest: grantDiffSummary — a true no-op reload reports '(no change)'" {
    const gpa = t.allocator;
    const old = try Manifest.create(gpa, "config", .config);
    defer old.destroy();
    try old.addPlugin("vim");
    try old.addGrant("vim", "fs_read", "");

    const new = try Manifest.create(gpa, "config", .config);
    defer new.destroy();
    try new.addPlugin("vim");
    try new.addGrant("vim", "fs_read", "");

    const summary = try Manifest.grantDiffSummary(gpa, old, new);
    defer gpa.free(summary);
    try t.expectEqualStrings("config grants: (no change)", summary);
}

test {
    std.testing.refAllDecls(@This());
}

test "manifest: a bind fallback list is owned, hash-sensitive to content AND order (configuration.md §5.2)" {
    const gpa = t.allocator;
    const a = try Manifest.create(gpa, "config", .config);
    defer a.destroy();
    try a.addBind("normal", "Return", &.{ "target.activate", "editing.insert-line-break" });
    try t.expectEqual(@as(usize, 2), a.binds.items[0].commands.len);

    const b = try Manifest.create(gpa, "config", .config);
    defer b.destroy();
    try b.addBind("normal", "Return", &.{ "target.activate", "editing.insert-line-break" });
    try t.expectEqual(a.hash(), b.hash());

    // Fallback order is authored data, not a set.
    const c = try Manifest.create(gpa, "config", .config);
    defer c.destroy();
    try c.addBind("normal", "Return", &.{ "editing.insert-line-break", "target.activate" });
    try t.expect(a.hash() != c.hash());

    // The string form is the same representation — a ONE-entry list, and a
    // different decl than the two-entry one that starts with it.
    const d = try Manifest.create(gpa, "config", .config);
    defer d.destroy();
    try d.addBind("normal", "Return", &.{"target.activate"});
    try t.expectEqual(@as(usize, 1), d.binds.items[0].commands.len);
    try t.expect(a.hash() != d.hash());

    // Per-entry length framing: ["a","b"] never collides with ["ab"].
    const e2 = try Manifest.create(gpa, "config", .config);
    defer e2.destroy();
    try e2.addBind("normal", "Return", &.{ "a", "b" });
    const f = try Manifest.create(gpa, "config", .config);
    defer f.destroy();
    try f.addBind("normal", "Return", &.{"ab"});
    try t.expect(e2.hash() != f.hash());
}

test "manifest: degenerate bind lists are rejected at the door, so apply always has a first entry" {
    const gpa = t.allocator;
    const m = try Manifest.create(gpa, "config", .config);
    defer m.destroy();
    try t.expectError(error.BindListEmpty, m.addBind("normal", "Return", &.{}));
    const too_long = [_][]const u8{"x"} ** (maxBindCommands + 1);
    try t.expectError(error.BindListTooLong, m.addBind("normal", "Return", &too_long));
    try t.expectEqual(@as(usize, 0), m.binds.items.len);
}
