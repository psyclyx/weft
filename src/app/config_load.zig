//! Config + plugin loading. The user's `config.js` runs in the quickjs.wasm
//! sandbox and reaches the editor only through the `weft.*` grants — the same
//! door a plugin uses. `PluginHost` is the resident wasm-plugin loader that
//! both `--plugin` and the config's `weft.plugin(name)` funnel through, so name
//! resolution and lifetime are one path.

const std = @import("std");
const core = @import("../core/core.zig");

/// Load and run the user's `config.js` in the quickjs.wasm sandbox (plan
/// 06B). Reads the file, spins a one-shot wasm engine, and evals — the config
/// wires the editor only through the `weft.*` grants. The engine is scoped to
/// the eval: config is a startup declaration, not a resident runtime.
pub fn loadJsConfig(gpa: std.mem.Allocator, ctx: *core.command.Context, path: []const u8, loader: ?core.quickjs.PluginLoader, config: *core.kv.Store) !void {
    const src = try core.file.readAlloc(gpa, path);
    defer gpa.free(src);
    var engine = try core.wasm.Engine.init(gpa);
    defer engine.deinit();
    // `weft.use(name)` resolves against the config's own directory.
    const dir = std.fs.path.dirname(path);
    try core.quickjs.evalConfig(&engine, ctx, loader, config, dir, src);
}

/// A LIVE config binding (doc/configuration.md §5): remembers the manifest
/// last applied so a `config-reload` is a `Manifest.reconcile` against it
/// (an unchanged reload is a verified no-op; a changed one tears down what
/// it owned and applies the delta) instead of a blind re-run of the whole
/// JS program against already-mutated state. `main.zig` owns one of these
/// for the session's config file and wires `config-reload` to `.reload()`.
pub const ConfigSession = struct {
    gpa: std.mem.Allocator,
    ctx: *core.command.Context,
    path: []u8,
    loader: ?core.quickjs.PluginLoader,
    config: *core.kv.Store,
    last: ?*core.manifest.Manifest = null,
    /// `weft.statusSegment` mesh-reachability seam
    /// (doc/cwa-prior-docs-audit.md §5; see
    /// `core.manifest.StatusSegBinder`'s doc) — unset (`null`) by default,
    /// so every existing caller of `init` compiles and behaves unchanged.
    /// `main.zig` sets this field directly after `init` returns
    /// (`cs.ui_bind = .{ .ctx = &session.container, .bind =
    /// view_mod.ui_mesh.bindManifestSegment }`) rather than threading it
    /// through `init`'s own parameter list, which would force every OTHER
    /// caller (tests, a headless embedder with no UI mesh at all) to pass
    /// one too.
    ui_bind: ?core.manifest.StatusSegBinder = null,

    pub fn init(gpa: std.mem.Allocator, ctx: *core.command.Context, path: []const u8, loader: ?core.quickjs.PluginLoader, config: *core.kv.Store) !ConfigSession {
        return .{ .gpa = gpa, .ctx = ctx, .path = try gpa.dupe(u8, path), .loader = loader, .config = config };
    }

    pub fn deinit(self: *ConfigSession) void {
        if (self.last) |m| m.destroy();
        self.gpa.free(self.path);
        self.* = undefined;
    }

    /// (Re)load the config file: evaluate it fresh into a NEW manifest, then
    /// reconcile against whatever was applied last (null on the first call —
    /// `reconcile` degenerates to a full apply). Absent/broken config is a
    /// logged warning, never fatal — matching `loadJsConfig`'s degrade.
    pub fn reload(self: *ConfigSession) !void {
        const src = try core.file.readAlloc(self.gpa, self.path);
        defer self.gpa.free(src);
        var engine = try core.wasm.Engine.init(self.gpa);
        defer engine.deinit();
        const dir = std.fs.path.dirname(self.path);
        const new = try core.quickjs.evalToManifest(&engine, self.ctx, self.loader, self.config, dir, src, .config, "config");
        errdefer new.destroy();
        std.log.info("config: manifest hash = 0x{x}", .{new.hash()});
        var actx: core.manifest.Manifest.ApplyCtx = .{ .ctx = self.ctx, .loader = self.loader, .config = self.config, .ui_bind = self.ui_bind };
        try core.manifest.Manifest.reconcile(self.gpa, self.last, new, &actx);
        if (self.last) |old| old.destroy();
        self.last = new;
    }
};

/// The `config-reload` command handler — `main.zig` binds this over a
/// `*ConfigSession` (`.data`). A failed reload is logged, never fatal (same
/// degrade as the initial load).
pub fn configReloadHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    _ = ctx;
    _ = args;
    const cs: *ConfigSession = @ptrCast(@alignCast(data.?));
    cs.reload() catch |e| std.log.warn("config-reload: {t}", .{e});
    return .nil;
}

/// Decode the first record of a framed config blob (uvarint count, then per
/// record uvarint(len)++bytes — the encoding the config shim produces). Used to
/// read a single-value `weft.set` (e.g. a theme color) host-side.
pub fn firstConfigRecord(blob: []const u8) ?[]const u8 {
    var cur = blob;
    _ = getConfigUvarint(&cur) orelse return null; // record count
    const n = getConfigUvarint(&cur) orelse return null;
    if (n > cur.len) return null;
    return cur[0..@intCast(n)];
}
fn getConfigUvarint(cur: *[]const u8) ?u64 {
    var shift: u6 = 0;
    var v: u64 = 0;
    while (cur.len > 0) {
        const b = cur.*[0];
        cur.* = cur.*[1..];
        v |= @as(u64, b & 0x7f) << shift;
        if (b & 0x80 == 0) return v;
        if (shift >= 57) return null;
        shift += 7;
    }
    return null;
}

/// Resolve the reference-plugin directory: `$WEFT_PLUGIN_DIR` if set, else
/// `<exe>/../lib/weft/plugins` (where `zig build` installs them). Falls back to
/// a bare "plugins" if the exe path can't be found. Caller owns the result.
pub fn pluginDir(gpa: std.mem.Allocator) []const u8 {
    if (std.c.getenv("WEFT_PLUGIN_DIR")) |d| return gpa.dupe(u8, std.mem.span(d)) catch "plugins";
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const exe_dir = std.process.executableDirPathAlloc(threaded.io(), gpa) catch
        return gpa.dupe(u8, "plugins") catch "plugins";
    defer gpa.free(exe_dir);
    return std.fs.path.join(gpa, &.{ exe_dir, "..", "lib", "weft", "plugins" }) catch
        gpa.dupe(u8, "plugins") catch "plugins";
}

/// The compiled-module (`.cwasm`) cache directory: `$WEFT_CACHE_DIR`, else
/// `$XDG_CACHE_HOME/weft/modules`, else `$HOME/.cache/weft/modules`. Null when
/// no writable base can be resolved (caching disabled — the editor still runs,
/// just recompiles each start). Caller owns the result.
pub fn moduleCacheDir(gpa: std.mem.Allocator) ?[]const u8 {
    if (std.c.getenv("WEFT_CACHE_DIR")) |d| return gpa.dupe(u8, std.mem.span(d)) catch null;
    if (std.c.getenv("XDG_CACHE_HOME")) |d|
        return std.fs.path.join(gpa, &.{ std.mem.span(d), "weft", "modules" }) catch null;
    if (std.c.getenv("HOME")) |d|
        return std.fs.path.join(gpa, &.{ std.mem.span(d), ".cache", "weft", "modules" }) catch null;
    return null;
}

/// The resident wasm-plugin loader: holds the engine, the editor context, the
/// effect services, and the live plugin list. Both `--plugin` and the config's
/// `weft.plugin(name)` funnel through `load`, so name resolution and lifetime
/// are one path. Plugins stay resident for the session (their registered
/// commands hold pointers into the WasmPlugin); the list frees them at exit.
pub const PluginHost = struct {
    gpa: std.mem.Allocator,
    engine: *core.wasm.Engine,
    ctx: *core.command.Context,
    opts: core.wasm_abi.LoadOptions,
    list: *std.ArrayList(*core.wasm_abi.WasmPlugin),
    /// JS plugins (a `.js` name) — a distinct type from the wasm list; ticked
    /// each frame for their proc-stream output.
    js_list: *std.ArrayList(*core.quickjs.JsPlugin),
    dir: []const u8,

    /// A bare name ("vim") resolves to `<dir>/vim.wasm` (or `<dir>/acp.js` for a
    /// `.js` name); anything with a path separator or a `.wasm`/`.js` suffix is
    /// taken literally (explicit --plugin paths) — `core.manifest.pluginTrust`'s
    /// path-form test, called directly (not a parallel copy) so a plugin can
    /// never resolve differently than it was trust-classified. Writes into `buf`.
    fn resolve(self: *PluginHost, buf: []u8, name: []const u8) ?[]const u8 {
        if (core.manifest.pluginTrust(name) == .path_form) return name;
        return std.fmt.bufPrint(buf, "{s}/{s}.wasm", .{ self.dir, name }) catch null;
    }

    pub fn load(self: *PluginHost, name: []const u8) void {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        // A `.js` name (or path) loads as a JS plugin — a resident quickjs
        // instance — rather than a `.wasm` guest.
        if (std.mem.endsWith(u8, name, ".js")) return self.loadJs(&path_buf, name);
        const path = self.resolve(&path_buf, name) orelse return;
        // Compilation copies the module, so the file bytes free right after.
        const bytes = core.file.readAlloc(self.gpa, path) catch |e| {
            std.log.warn("plugin: {s} failed to read: {t}", .{ path, e });
            return;
        };
        defer self.gpa.free(bytes);
        const p = core.wasm_abi.loadPlugin(self.engine, self.ctx, core.manifest.pluginNamespace(name), bytes, self.opts) catch |e| {
            std.log.warn("plugin: {s} failed to load: {t}", .{ path, e });
            return;
        };
        self.list.append(self.gpa, p) catch p.deinit();
    }

    /// Load a JS plugin: read its source and stand up a resident quickjs
    /// instance driving weft through the `weft.*` membrane. A bare `foo.js`
    /// resolves against the plugin dir; a path is literal.
    fn loadJs(self: *PluginHost, buf: []u8, name: []const u8) void {
        const path = if (std.mem.indexOfScalar(u8, name, '/') != null)
            name
        else
            std.fmt.bufPrint(buf, "{s}/{s}", .{ self.dir, name }) catch return;
        const src = core.file.readAlloc(self.gpa, path) catch |e| {
            std.log.warn("plugin: {s} failed to read: {t}", .{ path, e });
            return;
        };
        defer self.gpa.free(src);
        const pool = self.opts.pool orelse {
            std.log.warn("plugin: {s} needs a task pool (agent subprocesses)", .{path});
            return;
        };
        const p = core.quickjs.JsPlugin.load(self.gpa, self.engine, self.ctx, pool, core.wasm_host.hostEnviron(), core.manifest.pluginNamespace(name), self.opts.config, src) catch |e| {
            std.log.warn("plugin: {s} failed to load: {t}", .{ path, e });
            return;
        };
        self.js_list.append(self.gpa, p) catch p.deinit();
    }

    pub fn loader(self: *PluginHost) core.quickjs.PluginLoader {
        return .{ .ctx = self, .load = trampoline };
    }
    fn trampoline(ctx: *anyopaque, name: []const u8) void {
        const self: *PluginHost = @ptrCast(@alignCast(ctx));
        self.load(name);
    }
};

// ── Tests ───────────────────────────────────────────────────────────
// doc/contextual-workspace-architecture.md §13.5: "this slice makes grants REAL in the
// desktop — loadPlugin's grant_table must be wired where plugins actually
// load." These drive `PluginHost.load` itself (main.zig's exact production
// entry point — a real `System`, `System.initPlugins`'s real `Plugins`
// bundle, `PluginHost` resolving a name to a real on-disk `.wasm`), not the
// wasm-membrane suite's lower-level `wasm_abi.loadPlugin` direct calls.

const t = std.testing;

test "config_load: W4 slice 4 GATE — the PRODUCTION loader wires a real, revocable grant table" {
    const gpa = t.allocator;
    const pool = try core.task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    const sys = try core.System.create(gpa, pool, "editor", "user");
    defer sys.destroy();
    try sys.initPlugins(pool);
    const plug = &sys.plugins.?;
    var c = sys.contextFor(&sys.default_head);

    const dir = ".zig-cache/tmp/weft-grant-prod-loader-test";
    const wasm_path = dir ++ "/notes.wasm";
    try core.file.writeBytesMakingDirs(gpa, dir, wasm_path, @embedFile("guest_notes_wasm"));
    defer core.file.deleteFile(gpa, wasm_path);

    const tmp_note = "weft-grant-prod-loader-note.md";
    core.file.deleteFile(gpa, tmp_note);
    defer core.file.deleteFile(gpa, tmp_note);

    // `.opts.grant_table = &sys.grants` — the EXACT wiring `main.zig` now
    // does; everything else about `PluginHost` is the real production path.
    var host: PluginHost = .{
        .gpa = gpa,
        .engine = &plug.engine,
        .ctx = &c,
        .opts = .{ .grant_table = &sys.grants },
        .list = &plug.list,
        .js_list = &plug.js_list,
        .dir = dir,
    };
    host.load("notes");
    try t.expectEqual(@as(usize, 1), plug.list.items.len);
    const plugin = plug.list.items[0];
    try t.expect(plugin.grant_table != null);
    try t.expect(plugin.perms[core.wasm_host.perm_fs_write]);
    try t.expect(sys.grants.check(plugin.grant_handles[core.wasm_host.perm_fs_write]));

    // Live and working through the production path.
    _ = try core.command.run(&sys.commands, &c, "notes-capture", &.{ .{ .string = "before" }, .{ .string = tmp_note } });

    // Revoke through the SAME table the loader wired — no reload, no
    // re-describe: the running plugin's very next matching call traps.
    const n = sys.revoke("notes", "fs_write");
    try t.expectEqual(@as(usize, 1), n);
    try t.expectError(error.Trap, core.command.run(&sys.commands, &c, "notes-capture", &.{ .{ .string = "after" }, .{ .string = tmp_note } }));
}

test "config_load: W4 slice 4 — the composition rule holds through the PRODUCTION loader: a config-authored weft.grant narrows describe()'s ask into ONE row" {
    const gpa = t.allocator;
    const pool = try core.task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    const sys = try core.System.create(gpa, pool, "editor", "user");
    defer sys.destroy();
    try sys.initPlugins(pool);
    const plug = &sys.plugins.?;
    var c = sys.contextFor(&sys.default_head);

    const dir = ".zig-cache/tmp/weft-grant-prod-composition-test";
    const wasm_path = dir ++ "/notes.wasm";
    try core.file.writeBytesMakingDirs(gpa, dir, wasm_path, @embedFile("guest_notes_wasm"));
    defer core.file.deleteFile(gpa, wasm_path);

    // The config-authored grant, minted the way `manifest.zig`'s
    // `applyGrants`/`reconcileGrants` would — strictly BEFORE the plugin
    // loads (the ordering the composition rule depends on).
    const configured = try sys.grants.grant(.{ .capability = "fs_write", .limit = .{ .fs_root = "notes-vault" } }, "notes", null);

    var host: PluginHost = .{
        .gpa = gpa,
        .engine = &plug.engine,
        .ctx = &c,
        .opts = .{ .grant_table = &sys.grants },
        .list = &plug.list,
        .js_list = &plug.js_list,
        .dir = dir,
    };
    host.load("notes");
    try t.expectEqual(@as(usize, 1), plug.list.items.len);
    const plugin = plug.list.items[0];

    // The plugin's own describe() ALSO asked for fs_write (a plain
    // boolean) — but its POSSESSED handle is the config-authored, LIMITED
    // row, not a second, unrestricted one alongside it.
    try t.expect(plugin.perms[core.wasm_host.perm_fs_write]);
    try t.expectEqual(configured.idx, plugin.grant_handles[core.wasm_host.perm_fs_write].idx);
    try t.expectEqual(configured.gen, plugin.grant_handles[core.wasm_host.perm_fs_write].gen);
}
