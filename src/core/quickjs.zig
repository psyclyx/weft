//! quickjs — user config as JavaScript, run in `quickjs.wasm` (QuickJS-ng
//! compiled to a wasm32-wasi reactor; see build.zig `addQuickjs`). This is
//! plan 06B: the sample config, reborn from Fennel as `config.js`, evaluated
//! inside the sandbox and driving weft ONLY through the `weft.*` host imports
//! the shim (src/quickjs/weft_qjs.c) installs as a JS global. The same
//! membrane discipline as a `.wasm` plugin — strings cross through the guest's
//! linear memory, no host pointer leaks — one layer down, under the JS engine.
//!
//! The config plane is deliberately small: `weft.bind`/`run`/`echo`/`log`.
//! It is declaration, not a general JS host (no quickjs-libc, no fs/net from
//! JS) — powers a config wants come through weft's own gated ABI, not Node's.

const std = @import("std");
const Allocator = std.mem.Allocator;
const wasm = @import("wasm.zig");
const command = @import("command.zig");

/// The embedded engine+shim (built from quickjs-ng + weft_qjs.c by build.zig).
pub const quickjs_wasm: []const u8 = @embedFile("quickjs_wasm");

pub const EvalError = error{ConfigException} || wasm.Error;

/// How `weft.plugin(name)` reaches the host's plugin loader. Kept as an
/// opaque callback so this file stays free of the wasm-plugin lifecycle
/// (main.zig owns the resident engine + plugin list + name resolution).
pub const PluginLoader = struct {
    ctx: *anyopaque,
    load: *const fn (ctx: *anyopaque, name: []const u8) void,
};

/// Host state behind the `weft.*` config imports: the editor the config wires,
/// the plugin loader, the config-data store `weft.set` writes into, and the
/// deferred work lists. Plugin loads and `weft.run`s are RECORDED during eval
/// and replayed after it — so `weft.set` for a plugin always lands before that
/// plugin is instantiated (its `init` reads config), regardless of line order,
/// even across plugins.
const Bridge = struct {
    ctx: *command.Context,
    loader: ?PluginLoader,
    config: ?*kv.Store,
    pending_plugins: std.ArrayList([]u8) = .empty,
    pending_runs: std.ArrayList([]u8) = .empty,
};

const kv = @import("kv.zig");

/// Evaluate `src` as the user config: instantiate `quickjs.wasm` under WASI
/// with the `weft.*` config surface bound over `ctx`, run its reactor init,
/// marshal the source into the guest, and eval it. A JS exception surfaces as
/// `error.ConfigException` (the shim logs its message) — never a partial,
/// silent half-applied config. Each call is a fresh JS runtime.
pub fn evalConfig(engine: *wasm.Engine, ctx: *command.Context, loader: ?PluginLoader, config: ?*kv.Store, src: []const u8) EvalError!void {
    var bridge: Bridge = .{ .ctx = ctx, .loader = loader, .config = config };
    defer {
        for (bridge.pending_plugins.items) |s| ctx.gpa.free(s);
        bridge.pending_plugins.deinit(ctx.gpa);
        for (bridge.pending_runs.items) |s| ctx.gpa.free(s);
        bridge.pending_runs.deinit(ctx.gpa);
    }

    var module = try engine.compile(quickjs_wasm);
    defer module.deinit();
    var linker = try wasm.Linker.init(engine);
    defer linker.deinit();
    try linker.defineWasi();
    try linker.defineFn("weft", "qjs_bind_key", 6, 0, cBindKey, &bridge);
    try linker.defineFn("weft", "qjs_run", 2, 0, cRun, &bridge);
    try linker.defineFn("weft", "qjs_echo", 2, 0, cEcho, &bridge);
    try linker.defineFn("weft", "qjs_log", 2, 0, cLog, &bridge);
    try linker.defineFn("weft", "qjs_plugin", 2, 0, cPlugin, &bridge);
    try linker.defineFn("weft", "qjs_set", 6, 0, cSet, &bridge);
    try linker.defineFn("weft", "qjs_menu", 2, 0, cMenu, &bridge);
    try linker.defineFn("weft", "qjs_action", 2, 0, cAction, &bridge);
    try linker.defineFn("weft", "qjs_provide", 9, 0, cProvide, &bridge);

    var instance = try linker.instantiateWasi(&module);
    defer instance.deinit();
    // Reactor: run the WASI init once before any export call.
    instance.callVoid("_initialize", &.{}) catch |e| {
        if (e != error.MissingExport) return e;
    };

    // Marshal the source into the guest (null-terminated — QuickJS' parser
    // reads a C string), eval, free.
    const size: i32 = @intCast(src.len + 1);
    const ptr = try instance.callI32("malloc", &.{size});
    if (ptr == 0) return error.OutOfMemory;
    defer instance.callVoid("free", &.{ptr}) catch {};
    const at: usize = @intCast(ptr);
    try instance.writeGuest(at, src);
    try instance.writeGuest(at + src.len, &.{0});

    const rc = try instance.callI32("weft_eval", &.{ ptr, @intCast(src.len) });
    if (rc != 0) return error.ConfigException;

    // Deferred phase: config eval fully populated the config store and the
    // load/run lists. Now instantiate plugins (each reads its config at init),
    // then run the queued startup actions (FIFO) — after every plugin exists.
    if (bridge.loader) |ld| for (bridge.pending_plugins.items) |name| ld.load(ld.ctx, name);
    for (bridge.pending_runs.items) |cmd| _ = command.run(ctx.commands, ctx, cmd, &.{}) catch {};
}

// ── The `weft.*` config imports: read the guest's strings, drive the ctx.
// Each mirrors an abi.Abi config-surface method; failures degrade quietly
// (a bad bind is dropped) — the JS side already validated arity/types. ──

fn readStr(br: *Bridge, caller: *wasm.Caller, ptr: i32, len: i32) ?[]u8 {
    return caller.readMemory(br.ctx.gpa, @intCast(ptr), @intCast(len)) catch null;
}

fn cBindKey(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const br: *Bridge = @ptrCast(@alignCast(data.?));
    const gpa = br.ctx.gpa;
    const mode = readStr(br, caller, args[0], args[1]) orelse return;
    defer gpa.free(mode);
    const key = readStr(br, caller, args[2], args[3]) orelse return;
    defer gpa.free(key);
    const cmd = readStr(br, caller, args[4], args[5]) orelse return;
    defer gpa.free(cmd);
    // User config shadows plugins and core defaults (highest tier).
    br.ctx.keymap.bind(gpa, mode, key, cmd, @import("Keymap.zig").prio_config, "config") catch {};
}

fn cRun(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const br: *Bridge = @ptrCast(@alignCast(data.?));
    const cmd = readStr(br, caller, args[0], args[1]) orelse return;
    // Queue: run after all plugins load, so a config `weft.run("<plugin cmd>")`
    // works even if written before the plugin's `weft.plugin(...)` line.
    br.pending_runs.append(br.ctx.gpa, cmd) catch br.ctx.gpa.free(cmd);
}

/// weft.set(plugin, key, blob) — stage config data for a plugin (read at its
/// init via wl_config_get). The blob is already framed by the shim; store it
/// verbatim in the DISTINCT config store, namespaced by plugin name.
fn cSet(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const br: *Bridge = @ptrCast(@alignCast(data.?));
    const store = br.config orelse return;
    const plugin = readStr(br, caller, args[0], args[1]) orelse return;
    defer br.ctx.gpa.free(plugin);
    const key = readStr(br, caller, args[2], args[3]) orelse return;
    defer br.ctx.gpa.free(key);
    const blob = readStr(br, caller, args[4], args[5]) orelse return;
    defer br.ctx.gpa.free(blob);
    store.put(br.ctx.gpa, plugin, key, blob) catch {};
}

/// weft.menu(name) — declare `name` as a prefix-menu keymap mode: a which-key
/// submenu. It swallows text (a modal menu, not typing) and Escape/C-g leave it
/// via `menu-escape`. A leader key bound to `name` enters it (the dispatch
/// treats a bound command that names a menu mode as "enter that submenu").
fn cMenu(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const br: *Bridge = @ptrCast(@alignCast(data.?));
    const gpa = br.ctx.gpa;
    const name = readStr(br, caller, args[0], args[1]) orelse return;
    defer gpa.free(name);
    const km = br.ctx.keymap;
    const Keymap = @import("Keymap.zig");
    km.markMenuMode(gpa, name) catch {};
    km.setTextCommand(gpa, name, null) catch {}; // swallow text — a menu, not typing
    km.bind(gpa, name, "Escape", "menu-escape", Keymap.prio_config, "config") catch {};
    km.bind(gpa, name, "C-g", "menu-escape", Keymap.prio_config, "config") catch {};
    km.bind(gpa, name, "F1", "which-key-now", Keymap.prio_config, "config") catch {}; // force the hint now
}

/// weft.action(name) — declare a `pick` action (an abstract intent) and bind
/// its same-named trampoline command, so a config `weft.bind(mode, key, name)`
/// dispatches it. Idempotent.
fn cAction(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const br: *Bridge = @ptrCast(@alignCast(data.?));
    const gpa = br.ctx.gpa;
    const name = readStr(br, caller, args[0], args[1]) orelse return;
    defer gpa.free(name);
    command.registerAction(gpa, br.ctx.commands, br.ctx.actions, name, .pick) catch {};
}

/// weft.provide(action, mode, lang, cmd, prio) — register a provider. Empty
/// mode/lang strings mean "don't care" (an unconstrained provider). Auto-
/// declares the action if `weft.action` hasn't run yet (load order is free),
/// but does NOT bind a trampoline command — a provider alone isn't a key
/// target; declare (or another config's declare) owns the command bind.
fn cProvide(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const br: *Bridge = @ptrCast(@alignCast(data.?));
    const gpa = br.ctx.gpa;
    const action = readStr(br, caller, args[0], args[1]) orelse return;
    defer gpa.free(action);
    const mode = readStr(br, caller, args[2], args[3]) orelse return;
    defer gpa.free(mode);
    const lang = readStr(br, caller, args[4], args[5]) orelse return;
    defer gpa.free(lang);
    const cmd = readStr(br, caller, args[6], args[7]) orelse return;
    defer gpa.free(cmd);
    br.ctx.actions.provide(.{
        .action = action,
        .when = .{
            .mode = if (mode.len > 0) mode else null,
            .lang = if (lang.len > 0) lang else null,
        },
        .command = cmd,
        .priority = args[8],
        .owner = "config",
    }) catch {};
}

fn cEcho(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const br: *Bridge = @ptrCast(@alignCast(data.?));
    const msg = readStr(br, caller, args[0], args[1]) orelse return;
    defer br.ctx.gpa.free(msg);
    br.ctx.echo.clearRetainingCapacity();
    br.ctx.echo.appendSlice(br.ctx.gpa, msg) catch {};
}

fn cLog(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const br: *Bridge = @ptrCast(@alignCast(data.?));
    const msg = readStr(br, caller, args[0], args[1]) orelse return;
    defer br.ctx.gpa.free(msg);
    std.log.info("config: {s}", .{msg});
}

fn cPlugin(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const br: *Bridge = @ptrCast(@alignCast(data.?));
    if (br.loader == null) return; // no loader wired → weft.plugin is a no-op
    const name = readStr(br, caller, args[0], args[1]) orelse return;
    // Defer instantiation to after eval: config data staged by weft.set (on any
    // line) is then in place before the plugin's init reads it.
    br.pending_plugins.append(br.ctx.gpa, name) catch br.ctx.gpa.free(name);
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

const Env = struct {
    pool: *@import("task.zig").Pool,
    buffers: @import("Buffers.zig"),
    commands: command.Commands,
    keymap: @import("Keymap.zig"),
    pick: @import("pick.zig").Pick,
    caps: @import("capability.zig").Caps,
    actions: @import("action.zig"),
    quit: bool,
    echo: std.ArrayList(u8),
    ctx: command.Context,

    fn init(gpa: Allocator, self: *Env) !void {
        const task = @import("task.zig");
        self.pool = try task.Pool.init(gpa, .{ .threads = 1 });
        self.buffers = try @import("Buffers.zig").init(gpa, self.pool, "user");
        self.commands = .empty;
        self.keymap = .empty;
        self.pick = .empty;
        self.caps = @import("capability.zig").Caps.init(gpa, task.nowNs);
        self.actions = @import("action.zig").init(gpa);
        self.quit = false;
        self.echo = .empty;
        self.ctx = .{
            .gpa = gpa,
            .buffers = &self.buffers,
            .commands = &self.commands,
            .keymap = &self.keymap,
            .actions = &self.actions,
            .pick = &self.pick,
            .caps = &self.caps,
            .quit = &self.quit,
            .echo = &self.echo,
        };
    }
    fn deinit(self: *Env, gpa: Allocator) void {
        self.actions.deinit();
        self.caps.deinit();
        self.pick.deinit(gpa);
        self.keymap.deinit(gpa);
        self.commands.deinit(gpa);
        self.echo.deinit(gpa);
        self.buffers.deinit(gpa);
        self.pool.deinit();
    }
};

test "quickjs: config.js drives the weft ABI — binds a key and echoes" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();

    const cfg =
        \\weft.bind("normal", "j", "cursor-down");
        \\weft.bind("normal", "k", "cursor-up");
        \\weft.echo("config loaded (" + (1 + 1) + " keys)");
    ;
    try evalConfig(&engine, &env.ctx, null, null, cfg);

    // The JS ran real logic (string concat + arithmetic) and reached the host:
    try env.keymap.setMode(gpa, "normal");
    try t.expectEqualStrings("cursor-down", env.keymap.lookup("j").?);
    try t.expectEqualStrings("cursor-up", env.keymap.lookup("k").?);
    try t.expectEqualStrings("config loaded (2 keys)", env.echo.items);
}

test "quickjs: config.js can run a registered command through weft.run" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    // A host command the config invokes: appends a mark to the echo line.
    const H = struct {
        fn mark(ctx: *command.Context, data: ?*anyopaque, args: []const command.Value) anyerror!command.Value {
            _ = data;
            _ = args;
            try ctx.echo.appendSlice(ctx.gpa, "ran!");
            return .nil;
        }
    };
    _ = try env.commands.bind(gpa, "mark", .{ .name = "mark", .summary = "", .args = &.{}, .handler = H.mark, .data = null });

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    try evalConfig(&engine, &env.ctx, null, null, "weft.run(\"mark\");");
    try t.expectEqualStrings("ran!", env.echo.items);
}

test "quickjs: weft.action + weft.provide wire the pick dispatch layer" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    // Declare an abstract intent, provide language-specific and default
    // implementations, and bind a key to the intent — the synthetic bind.
    const cfg =
        \\weft.action("eval");
        \\weft.provide("eval", { lang: "zig" }, "zig-eval");
        \\weft.provide("eval", { lang: "py" }, "python-repl");
        \\weft.provide("eval", {}, "eval-line", -10);
        \\weft.bind("normal", "space", "eval");
    ;
    try evalConfig(&engine, &env.ctx, null, null, cfg);

    // The action registered its trampoline command (a key can bind to it), and
    // the key resolves to the action name through the normal keymap door.
    try t.expect(env.commands.resolve("eval") != null);
    try t.expect(env.ctx.actions.isAction("eval"));
    try env.keymap.setMode(gpa, "normal");
    try t.expectEqualStrings("eval", env.keymap.lookup("space").?);

    // The `when` predicates crossed the JS→host membrane intact: eval resolves
    // per language, and the unconstrained default covers everything else.
    try t.expectEqualStrings("zig-eval", env.ctx.actions.resolve("eval", .{ .mode = "normal", .lang = "zig" }).?);
    try t.expectEqualStrings("python-repl", env.ctx.actions.resolve("eval", .{ .mode = "normal", .lang = "py" }).?);
    try t.expectEqualStrings("eval-line", env.ctx.actions.resolve("eval", .{ .mode = "normal", .lang = "md" }).?);
}

test "quickjs: a config syntax error surfaces as ConfigException, not silent" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    // Malformed JS: the eval must fail loudly, and nothing was bound.
    try t.expectError(error.ConfigException, evalConfig(&engine, &env.ctx, null, null, "this is (not valid javascript"));
    try t.expectEqual(@as(usize, 0), env.echo.items.len);
}

test "quickjs: weft.plugin loads a real .wasm, then its command runs" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();

    // A minimal loader over the resident engine: resolve the guest "edit"
    // plugin from its embedded bytes and load it under the perm handshake —
    // the same shape main.zig's PluginHost has, minus disk/name resolution.
    const wasm_abi = @import("wasm_abi.zig");
    const Loader = struct {
        engine: *wasm.Engine,
        ctx: *command.Context,
        held: ?*wasm_abi.WasmPlugin = null,
        fn load(cx: *anyopaque, name: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(cx));
            std.debug.assert(std.mem.eql(u8, name, "edit"));
            self.held = wasm_abi.loadPlugin(self.engine, self.ctx, "edit", @embedFile("guest_edit_wasm"), .{}) catch null;
        }
    };
    var loader: Loader = .{ .engine = &engine, .ctx = &env.ctx };
    defer if (loader.held) |p| p.deinit();

    // config.js loads the plugin and binds one of its commands. Load is now
    // deferred to after eval, but still completes inside evalConfig, so by the
    // time it returns the plugin is registered and the (late-bound) bind resolves.
    const cfg =
        \\weft.plugin("edit");
        \\weft.bind("normal", "D", "duplicate-line");
    ;
    try evalConfig(&engine, &env.ctx, .{ .ctx = &loader, .load = Loader.load }, null, cfg);

    // The plugin loaded and registered its command; the config's bind took.
    try t.expect(loader.held != null);
    try t.expect(env.commands.find("duplicate-line") != null);
    try env.keymap.setMode(gpa, "normal");
    try t.expectEqualStrings("duplicate-line", env.keymap.lookup("D").?);

    // And the command actually runs through the membrane: duplicate a line.
    try env.buffers.active().editor.insertText(gpa, "hi");
    env.buffers.active().editor.placeCursor(0);
    _ = try command.run(&env.commands, &env.ctx, "duplicate-line", &.{});
    const s = try env.buffers.active().editor.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("hi\nhi", s);
}

test "quickjs: deferred load — weft.set before the plugin line reaches its init" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();

    var config: kv.Store = .empty;
    defer config.deinit(gpa);

    const wasm_abi = @import("wasm_abi.zig");
    const Loader = struct {
        engine: *wasm.Engine,
        ctx: *command.Context,
        config: *kv.Store,
        held: ?*wasm_abi.WasmPlugin = null,
        fn load(cx: *anyopaque, name: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(cx));
            std.debug.assert(std.mem.eql(u8, name, "autopair"));
            self.held = wasm_abi.loadPlugin(self.engine, self.ctx, "autopair", @embedFile("guest_autopair_wasm"), .{ .config = self.config }) catch null;
        }
    };
    var loader: Loader = .{ .engine = &engine, .ctx = &env.ctx, .config = &config };
    defer if (loader.held) |p| p.deinit();

    // weft.set and a bind are written BEFORE the plugin line. Deferred load
    // makes both land: config is staged before the plugin instantiates (its
    // init reads `pairs`), and the late-bound key resolves after load.
    const cfg =
        \\weft.set("autopair", "pairs", ["pair-tick\t`\t`"]);
        \\weft.bind("insert", "grave", "pair-tick");
        \\weft.plugin("autopair");
    ;
    try evalConfig(&engine, &env.ctx, .{ .ctx = &loader, .load = Loader.load }, &config, cfg);

    // The plugin read its config at init: it registered the CONFIG pair command,
    // not the shipped defaults.
    try t.expect(loader.held != null);
    try t.expect(env.commands.find("pair-tick") != null);
    try t.expect(env.commands.find("pair-paren") == null);
    try env.keymap.setMode(gpa, "insert");
    try t.expectEqualStrings("pair-tick", env.keymap.lookup("grave").?);

    // And it runs through the membrane: inserts the configured backtick pair.
    _ = try command.run(&env.commands, &env.ctx, "pair-tick", &.{});
    const s = try env.buffers.active().editor.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("``", s);
}

test "quickjs: weft.menu declares a submenu the leader tree enters (doom-style)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();

    const cfg =
        \\weft.menu("leader-file");
        \\weft.bind("leader", "f", "leader-file");
        \\weft.bind("leader-file", "s", "save");
    ;
    try evalConfig(&engine, &env.ctx, null, null, cfg);

    // The submenu is a menu mode: which-key shows it, and the dispatch enters it
    // when a leader key's command names it (that's why "f" → "leader-file" is a
    // group, not a leaf).
    try t.expect(env.keymap.isMenuMode("leader-file"));

    // In the leader menu, "f" resolves to the submenu name (a group entry).
    try env.keymap.setMode(gpa, "leader");
    try t.expectEqualStrings("leader-file", env.keymap.lookup("f").?);

    // Inside the submenu: its own keys bind, and Escape/C-g leave via menu-escape.
    try env.keymap.setMode(gpa, "leader-file");
    try t.expectEqualStrings("save", env.keymap.lookup("s").?);
    try t.expectEqualStrings("menu-escape", env.keymap.lookup("Escape").?);
    try t.expectEqualStrings("menu-escape", env.keymap.lookup("C-g").?);
}

test "quickjs: every shipped example config evals without a JS error" {
    const gpa = t.allocator;
    // Each config's JS must parse and drive the weft.* surface cleanly. Plugins
    // no-op here (no loader), so this checks syntax + the bind/menu/set calls —
    // a typo or a bad API use surfaces as ConfigException. Read from the repo's
    // config/ (the test runs with cwd at the project root).
    const file = @import("file.zig");
    const paths = [_][]const u8{
        "config/config.js", "config/vim-minimal.js", "config/helix.js", "config/dual.js",
    };
    var engine = try wasm.Engine.init();
    defer engine.deinit();
    for (paths) |path| {
        const src = file.readAlloc(gpa, path) catch continue; // skip if run outside the repo
        defer gpa.free(src);
        var env: Env = undefined;
        try Env.init(gpa, &env);
        defer env.deinit(gpa);
        var cfgstore: kv.Store = .empty;
        defer cfgstore.deinit(gpa);
        evalConfig(&engine, &env.ctx, null, &cfgstore, src) catch |e| {
            std.debug.print("config {s} failed: {t}\n", .{ path, e });
            return e;
        };
    }
}

test {
    std.testing.refAllDecls(@This());
}
