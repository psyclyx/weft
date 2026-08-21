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
    var engine = try core.wasm.Engine.init();
    defer engine.deinit();
    // `weft.use(name)` resolves against the config's own directory.
    const dir = std.fs.path.dirname(path);
    try core.quickjs.evalConfig(&engine, ctx, loader, config, dir, src);
}

/// A LIVE config binding (north-star-plan §2.3/§6): remembers the manifest
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
        var engine = try core.wasm.Engine.init();
        defer engine.deinit();
        const dir = std.fs.path.dirname(self.path);
        const new = try core.quickjs.evalToManifest(&engine, self.ctx, self.loader, self.config, dir, src, .config, "config");
        errdefer new.destroy();
        std.log.info("config: manifest hash = 0x{x}", .{new.hash()});
        var actx: core.manifest.Manifest.ApplyCtx = .{ .ctx = self.ctx, .loader = self.loader, .config = self.config };
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
    /// taken literally (explicit --plugin paths). Writes into `buf`.
    fn resolve(self: *PluginHost, buf: []u8, name: []const u8) ?[]const u8 {
        if (std.mem.indexOfScalar(u8, name, '/') != null or
            std.mem.endsWith(u8, name, ".wasm") or std.mem.endsWith(u8, name, ".js"))
            return name;
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
        const p = core.wasm_abi.loadPlugin(self.engine, self.ctx, std.fs.path.stem(name), bytes, self.opts) catch |e| {
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
        const p = core.quickjs.JsPlugin.load(self.gpa, self.engine, self.ctx, pool, core.wasm_host.hostEnviron(), std.fs.path.stem(std.fs.path.basename(name)), self.opts.config, src) catch |e| {
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
