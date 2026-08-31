//! The quickjs plane's test suite — the config plane (`weft.bind`/`run`/`use`),
//! the persistent JS-plugin plane, the proc-stream membrane, the grant gate,
//! and doc/place.md §4.1a's "a JS plugin is not a different KIND of plugin".
//!
//! Split out of quickjs.zig, which was 3750 lines of which 1900 were these
//! tests — the same shape every other large subsystem here already has
//! (`core/session/tests.zig`, `core/wasm_abi/tests.zig`, `core/tests.zig`).
//! quickjs.zig was the outlier that kept them inline.

const std = @import("std");
const Allocator = std.mem.Allocator;

const quickjs = @import("../quickjs.zig");
const JsPlugin = quickjs.JsPlugin;
const evalConfig = quickjs.evalConfig;
const evalToManifest = quickjs.evalToManifest;
const EvalError = quickjs.EvalError;
const PluginLoader = quickjs.PluginLoader;
const jsDoor = quickjs.jsDoor;
const plugin_handlers = quickjs.plugin_handlers;
const quickjs_wasm = quickjs.quickjs_wasm;
// Exposed by quickjs.zig for this suite — see the note at each declaration.
const cAgentWrite = quickjs.cAgentWrite;
const cFileRead = quickjs.cFileRead;
const cGrant = quickjs.cGrant;
const firstFramedRecord = @import("../framed.zig").first;
const transcriptAppend = quickjs.transcriptAppend;
const transcriptEntry = quickjs.transcriptEntry;

const wasm = @import("../wasm.zig");
const command = @import("../command.zig");
const task = @import("../task.zig");
const kv = @import("../kv.zig");
const Buffers = @import("../Buffers.zig");
const subbuffer = @import("../subbuffer.zig");
const pick_mod = @import("../pick.zig");
const grants_mod = @import("../grants.zig");
const manifest_mod = @import("../manifest.zig");
const TranscriptDoc = @import("../transcript.zig");
const qjs_contract = @import("../membrane/qjs_contract.zig");
const semantic_model = @import("weft_semantic");
const view_runtime = @import("weft_view_runtime");
const t = std.testing;

const Env = struct {
    pool: *@import("../task.zig").Pool,
    buffers: @import("../Buffers.zig"),
    commands: command.Commands,
    keymap: @import("../Keymap.zig"),
    head: @import("../Head.zig"),
    /// The ONE shared Container `caps`/`actions` bind into (task #19).
    container: @import("../container.zig").Container,
    caps: @import("../capability.zig").Caps,
    actions: @import("../action.zig"),
    semantic: @import("../semantic.zig").Services,
    quit: bool,
    /// A real grant table, as `System.create` wires one — so a JS plugin
    /// loaded here adopts its authority exactly the way production does
    /// (`grant` below stands in for the config plane's `weft.grant`).
    grants: grants_mod.HandleTable,
    ctx: command.Context,

    fn init(gpa: Allocator, self: *Env) !void {
        self.pool = try task.Pool.init(gpa, .{ .threads = 1 });
        self.buffers = try @import("../Buffers.zig").init(gpa, self.pool, "user");
        self.commands = .empty;
        self.keymap = .empty;
        self.head = .empty;
        self.container = @import("../container.zig").Container.init(gpa);
        self.caps = @import("../capability.zig").Caps.init(gpa, task.nowNs, &self.container);
        self.actions = @import("../action.zig").init(gpa, &self.container);
        self.semantic = @import("../semantic.zig").Services.init(.here);
        self.quit = false;
        self.grants = grants_mod.HandleTable.init(gpa);
        self.ctx = .{
            .gpa = gpa,
            .buffers = &self.buffers,
            .commands = &self.commands,
            .keymap = &self.keymap,
            .actions = &self.actions,
            .semantic = &self.semantic,
            .caps = &self.caps,
            .quit = &self.quit,
            .head = &self.head,
            .grant_table = &self.grants,
        };
    }

    /// Mint what `weft.grant(plugin, capability)` would mint — call BEFORE
    /// `JsPlugin.load`, which is when a plugin adopts its rows. `plugin`
    /// and `capability` are borrowed by the table (string literals here).
    fn grant(self: *Env, plugin: []const u8, capability: []const u8) !void {
        _ = try self.grants.grant(.{ .capability = capability }, plugin, null);
    }

    fn deinit(self: *Env, gpa: Allocator) void {
        self.grants.deinit();
        self.actions.deinit();
        self.semantic.deinit(gpa);
        self.caps.deinit();
        self.container.deinit();
        self.head.deinit(gpa);
        self.keymap.deinit(gpa);
        self.commands.deinit(gpa);
        self.buffers.deinit(gpa);
        self.pool.deinit();
    }
};

fn bindRunArgsFixture(gpa: Allocator, env: *Env) !void {
    const H = struct {
        fn invoke(ctx: *command.Context, data: ?*anyopaque, args: []const command.Value) anyerror!command.Value {
            _ = data;
            if (args.len != 3) return error.FixtureArity;
            if (args[0] != .string or args[1] != .string or args[2] != .string) return error.FixtureType;
            if (!std.mem.eql(u8, args[0].string, ".foo") or
                !std.mem.eql(u8, args[1].string, "/tmp/grammar") or
                !std.mem.eql(u8, args[2].string, "tree_sitter_fixture")) return error.FixtureValue;
            ctx.head.echo.clearRetainingCapacity();
            try ctx.head.echo.appendSlice(ctx.gpa, "run-args-ok");
            return .nil;
        }
    };
    _ = try env.commands.bind(gpa, "fixture-run-args", .{
        .name = "fixture-run-args",
        .summary = "argument-bearing config fixture",
        .args = &.{
            .{ .name = "ext", .type = .string },
            .{ .name = "dir", .type = .string },
            .{ .name = "symbol", .type = .string },
        },
        .handler = H.invoke,
        .data = null,
    });
}

test "quickjs: config.js drives the weft ABI — binds a key and echoes" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    const cfg =
        \\weft.bind("normal", "j", "cursor-down");
        \\weft.bind("normal", "k", "cursor-up");
        \\weft.echo("config loaded (" + (1 + 1) + " keys)");
    ;
    try evalConfig(&engine, &env.ctx, null, null, null, cfg);

    // The JS ran real logic (string concat + arithmetic) and reached the host:
    try env.head.setModeRaw(gpa, "normal");
    try t.expectEqualStrings("cursor-down", env.keymap.lookup(env.head.currentMode(), "j").?);
    try t.expectEqualStrings("cursor-up", env.keymap.lookup(env.head.currentMode(), "k").?);
    try t.expectEqualStrings("config loaded (2 keys)", env.head.echo.items);
}

test "quickjs: weft.use includes a shared bindings module from the config dir" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    // A shared defaults file the config pulls in with `weft.use`. It binds a
    // pick key (which now lives in config data, not core).
    const dir = ".zig-cache/tmp/weft-use-test";
    const defaults_path = dir ++ "/shared.js";
    try @import("../file.zig").writeBytesMakingDirs(gpa, dir, defaults_path,
        \\weft.bind("pick", "Down", "pick-next");
        \\weft.bind("pick", "Return", "pick-accept");
    );
    defer @import("../file.zig").deleteFile(gpa, defaults_path);

    // The config includes it, then OVERRIDES one bind (last-wins) to prove the
    // including config wins over the shared defaults.
    const cfg =
        \\weft.use("shared");
        \\weft.bind("pick", "Down", "pick-prev");
    ;
    try evalConfig(&engine, &env.ctx, null, null, dir, cfg);

    try env.head.setModeRaw(gpa, "pick");
    try t.expectEqualStrings("pick-accept", env.keymap.lookup(env.head.currentMode(), "Return").?); // from the include
    try t.expectEqualStrings("pick-prev", env.keymap.lookup(env.head.currentMode(), "Down").?); // config override won
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
            try ctx.head.echo.appendSlice(ctx.gpa, "ran!");
            return .nil;
        }
    };
    _ = try env.commands.bind(gpa, "mark", .{ .name = "mark", .summary = "", .args = &.{}, .handler = H.mark, .data = null });

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    try evalConfig(&engine, &env.ctx, null, null, null, "weft.run(\"mark\");");
    try t.expectEqualStrings("ran!", env.head.echo.items);
}

test "quickjs: config weft.run carries bounded string args through the generic command door" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    try bindRunArgsFixture(gpa, &env);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    try evalConfig(&engine, &env.ctx, null, null, null, "weft.run('fixture-run-args', '.foo', '/tmp/grammar', 'tree_sitter_fixture');");
    try t.expectEqualStrings("run-args-ok", env.head.echo.items);
}

test "quickjs: manifest run declarations retain args until apply" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    try bindRunArgsFixture(gpa, &env);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    const m = try evalToManifest(&engine, &env.ctx, null, null, null, "weft.run('fixture-run-args', '.foo', '/tmp/grammar', 'tree_sitter_fixture');", .config, "config");
    defer m.destroy();
    try t.expectEqual(@as(usize, 1), m.runs.items.len);
    try t.expectEqualStrings("/tmp/grammar", m.runs.items[0].args[1].value);
    var actx: manifest_mod.Manifest.ApplyCtx = .{ .ctx = &env.ctx, .loader = null, .config = null };
    try m.apply(gpa, &actx);
    try t.expectEqualStrings("run-args-ok", env.head.echo.items);
}

test "quickjs: argument-bearing weft.run rejects invalid shape before staging" {
    const gpa = t.allocator;
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const cases = [_][]const u8{
        "weft.run('fixture', 1);",
        "weft.run('fixture', '1','2','3','4','5','6','7','8','9');",
        "weft.run('fixture', new Array(1025).fill('x').join(''));",
    };
    for (cases) |source| {
        var env: Env = undefined;
        try Env.init(gpa, &env);
        defer env.deinit(gpa);
        try t.expectError(error.ConfigException, evalToManifest(&engine, &env.ctx, null, null, null, source, .config, "config"));
    }
}

test "quickjs: weft.action + weft.provide wire the pick dispatch layer" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
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
    try evalConfig(&engine, &env.ctx, null, null, null, cfg);

    // The action registered its trampoline command (a key can bind to it), and
    // the key resolves to the action name through the normal keymap door.
    try t.expect(env.commands.resolve("eval") != null);
    try t.expect(env.ctx.actions.isAction("eval"));
    try env.head.setModeRaw(gpa, "normal");
    try t.expectEqualStrings("eval", env.keymap.lookup(env.head.currentMode(), "space").?);

    // The `when` predicates crossed the JS→host membrane intact: eval resolves
    // per language, and the unconstrained default covers everything else.
    try t.expectEqualStrings("zig-eval", env.ctx.actions.resolve("eval", .{ .mode = "normal", .lang = "zig" }).?);
    try t.expectEqualStrings("python-repl", env.ctx.actions.resolve("eval", .{ .mode = "normal", .lang = "py" }).?);
    try t.expectEqualStrings("eval-line", env.ctx.actions.resolve("eval", .{ .mode = "normal", .lang = "md" }).?);
}

test "quickjs: semanticAction binds and invokes an open plugin view action" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    try evalConfig(&engine, &env.ctx, null, null, null, "weft.semanticAction('fixture.plugin-action'); weft.bind('normal', 'm', 'fixture.plugin-action');");
    try t.expect(env.commands.resolve("fixture.plugin-action") != null);
    try env.head.setModeRaw(gpa, "normal");
    try t.expectEqualStrings("fixture.plugin-action", env.keymap.lookup("normal", "m").?);

    const ActionProvider = struct {
        calls: usize = 0,

        pub fn invoke(self: *@This(), request: semantic_model.action.Request) view_runtime.action.ProviderError!semantic_model.action.Outcome {
            if (!std.mem.eql(u8, request.action, "fixture.plugin-action")) return .declined;
            self.calls += 1;
            return .handled;
        }
    };
    const owner = try env.semantic.acquireOwner();
    const actions = [_]semantic_model.scene.Action{.{ .id = "fixture.plugin-action" }};
    const view = try env.semantic.publishView(gpa, owner, null, 1, .{
        .id = @enumFromInt(1),
        .focusable = true,
        .actions = &actions,
        .content = .{ .label = "fixture" },
    });
    var provider: ActionProvider = .{};
    try env.semantic.registerActionProvider(gpa, owner, .init(&provider));
    _ = try env.semantic.focusView(&env.head, gpa, view, null);

    _ = try command.run(&env.commands, &env.ctx, "fixture.plugin-action", &.{});
    try t.expectEqual(@as(usize, 1), provider.calls);
}

test "quickjs: a JS plugin registers a command dispatched back into JS" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    // The plugin plane: a PERSISTENT quickjs instance that registers a command
    // and receives its dispatch back — the JS-plugin reactor, proving the
    // describe/init/on_command lifecycle works one layer up under the engine.
    const src =
        \\weft.command("greet", () => weft.echo("hi from js"));
    ;
    var plugin = try JsPlugin.load(gpa, &engine, &env.ctx, env.pool, .empty, "test", null, src);
    defer plugin.deinit();

    try t.expect(env.commands.resolve("greet") != null);
    _ = try command.run(&env.commands, &env.ctx, "greet", &.{});
    try t.expectEqualStrings("hi from js", env.head.echo.items);
}

test "quickjs: weft.pick delivers structured acceptance and cancellation" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    try pick_mod.install(gpa, &env.commands, &env.keymap);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    // Empty options are intentional: the accepted index must remain the
    // caller's original line ordinal (beta is index 2, not normalized index 1).
    const src =
        \\weft.onPick((o) => {
        \\  if (o.kind === "candidate")
        \\    weft.echo(o.kind + "|" + o.index + "|" + o.text + "|" + o.query + "|" + o.match.start + "|" + o.match.span);
        \\  else weft.echo(o.kind);
        \\});
        \\weft.command("open-pick", () => weft.pick("choose", "alpha\n\nbeta"));
    ;
    var plugin = try JsPlugin.load(gpa, &engine, &env.ctx, env.pool, .empty, "test", null, src);
    defer plugin.deinit();

    _ = try command.run(&env.commands, &env.ctx, "open-pick", &.{});
    try t.expect(env.head.pick.active);
    _ = try command.run(&env.commands, &env.ctx, "pick-input", &.{.{ .string = "beta" }});
    _ = try command.run(&env.commands, &env.ctx, "pick-accept", &.{});
    try t.expectEqualStrings("candidate|2|beta|beta|0|4", env.head.echo.items);

    // The live query is not bounded by the original option payload. Preserve
    // it exactly without sizing guest memory from that unrelated input.
    const long_query = "                    beta";
    _ = try command.run(&env.commands, &env.ctx, "open-pick", &.{});
    _ = try command.run(&env.commands, &env.ctx, "pick-input", &.{.{ .string = long_query }});
    _ = try command.run(&env.commands, &env.ctx, "pick-accept", &.{});
    try t.expectEqualStrings("candidate|2|beta|                    beta|0|4", env.head.echo.items);

    _ = try command.run(&env.commands, &env.ctx, "open-pick", &.{});
    try t.expect(env.head.pick.active);
    _ = try command.run(&env.commands, &env.ctx, "pick-cancel", &.{});
    try t.expectEqualStrings("cancelled", env.head.echo.items);
}

test "quickjs: a JS plugin drives a duplex subprocess and reads its output" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    // The plugin spawns a child (sh builtins, hermetic .empty env), sends it a
    // line, and its onOutput handler reads the echoed reply — the whole
    // agent-transport shape (spawn + stdin + streamed stdout) in JS.
    // `weft.onOutput` is BACKGROUND (`weft_on_output`, fired by `tick`);
    // `weft.echo` is head-gated (task #19 item 4), so the reply defers
    // through a self-registered command — a nested `weft.run` from a
    // background entry IS a dispatching entry for its duration (same door
    // `config/plugins/acp.js`'s real onOutput→weft.pick path uses).
    const src =
        \\let reply = "";
        \\weft.onOutput((h) => { reply = weft.procRead(h); weft.run("deliver"); });
        \\weft.command("deliver", () => { weft.echo("got:" + reply); });
        \\weft.command("go", () => {
        \\  let h = weft.procSpawn("read x; printf '%s\n' \"$x\"");
        \\  weft.procSend(h, "ping\n");
        \\});
    ;
    try env.grant("test", "proc");
    var plugin = try JsPlugin.load(gpa, &engine, &env.ctx, env.pool, .empty, "test", null, src);
    defer plugin.deinit();

    _ = try command.run(&env.commands, &env.ctx, "go", &.{});
    // Pump the frame-boundary output dispatch until the reply arrives.
    const deadline = task.nowNs() + 2 * std.time.ns_per_s;
    while (std.mem.indexOf(u8, env.head.echo.items, "ping") == null and task.nowNs() < deadline) {
        _ = plugin.tick();
        std.Thread.yield() catch {};
    }
    try t.expect(std.mem.indexOf(u8, env.head.echo.items, "ping") != null);
}

// SCOPE NOTE (added alongside the incremental-append/decoration-path
// rework below, so a future reader doesn't have to reconstruct this from
// git blame): this test predates `weft.transcriptEntry`/`transcriptAppend`
// and was written against the OLD raw `weft.bufferAppend` path — it never
// names the transcript seam and never asserts role tagging or model state,
// only a plain substring in the rendered buffer. It still exercises the
// REAL `config/plugins/acp.js` end to end (a real mock-agent subprocess,
// the real JSON-RPC parse, the real `weft.transcriptEntry` call
// `acp.js`'s `trAppend` now makes), so it is NOT vacuous — but it is
// coincidental coverage of the new seam, not a test written FOR it. The
// test below is: a direct handler-level test, driving `weft.
// transcriptEntry`/`transcriptAppend` through the real JS runtime, that
// asserts what this one does not (role tagging, streamed-body accumulation,
// the model AND the projected buffer, and that the FAST incremental path —
// not a full-`fill` fallback — is what actually ran).
test "quickjs: the ACP plugin drives a mock agent's message into the transcript" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    // A fire-and-forget mock ACP agent (sh builtins only — printf): emits the
    // initialize + session/new results, a session/update carrying an agent
    // message, and the prompt result. This is the client-side round-trip the
    // plugin parses: JSON-RPC in, agent_message_chunk → transcript.
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const mock_path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/mock.sh", .{tmp.sub_path});
    defer gpa.free(mock_path);
    const mock =
        \\printf '{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1,"agentCapabilities":{}}}\n'
        \\printf '{"jsonrpc":"2.0","id":1,"result":{"sessionId":"s1"}}\n'
        \\printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hello from agent"}}}}\n'
        \\printf '{"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}\n'
    ;
    try @import("../file.zig").writeBytes(gpa, mock_path, mock);

    // The real ACP client plugin (read from the repo) + a start line pointing
    // at the mock. `/bin/sh <path>` needs no PATH (hermetic .empty env).
    const acp = try @import("../file.zig").readAlloc(gpa, "config/plugins/acp.js");
    defer gpa.free(acp);
    const src = try std.fmt.allocPrint(gpa, "{s}\nstartAgent(\"/bin/sh {s}\", \"hi\");\n", .{ acp, mock_path });
    defer gpa.free(src);

    try env.grant("test", "proc"); // what config/config.js's weft.grant("acp", "proc") mints
    var plugin = try JsPlugin.load(gpa, &engine, &env.ctx, env.pool, .empty, "test", null, src);
    defer plugin.deinit();

    // Pump the frame-boundary output dispatch until the agent's message lands
    // in the transcript buffer.
    const deadline = task.nowNs() + 3 * std.time.ns_per_s;
    var found = false;
    while (!found and task.nowNs() < deadline) {
        _ = plugin.tick();
        var it = env.buffers.iterator();
        while (it.next()) |b| {
            if (!std.mem.eql(u8, b.name, "*agent*")) continue;
            const txt = try b.textEditor().?.text().toOwnedSlice(gpa);
            defer gpa.free(txt);
            if (std.mem.indexOf(u8, txt, "hello from agent") != null) found = true;
        }
        std.Thread.yield() catch {};
    }
    try t.expect(found);
}

test "quickjs: transcriptEntry/transcriptAppend — role tagging, streamed-body accumulation, model+buffer agreement, and the INCREMENTAL (not full-refill) fast path" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    // Four commands, one per step, so the Zig side can peek host state
    // BETWEEN individual `weft.transcriptEntry`/`transcriptAppend` calls —
    // a single top-level `weft_plugin_init` eval (like the mock-agent test
    // above uses) runs its whole body in one uninterruptible JS_Eval, which
    // can't be inspected mid-script.
    const src =
        \\weft.command("open", () => weft.transcriptEntry("*t*", "user", "hi"));
        \\weft.command("chunk", () => weft.transcriptAppend("*t*", "!"));
        \\weft.command("open2", () => weft.transcriptEntry("*t*", "agent", "yo"));
    ;
    var plugin = try JsPlugin.load(gpa, &engine, &env.ctx, env.pool, .empty, "test", null, src);
    defer plugin.deinit();

    const bufText = struct {
        fn get(e: *Env, gpa2: Allocator) ![]u8 {
            var it = e.buffers.iterator();
            while (it.next()) |b| {
                if (std.mem.eql(u8, b.name, "*t*")) return b.textEditor().?.text().toOwnedSlice(gpa2);
            }
            return error.NoBuffer;
        }
    }.get;

    // "open": the model gets its first (role, text) entry; the FULL `fill`
    // path runs (a structural change — new row), which mints entry 0's
    // subbuffer claim — cached as `live_sub`.
    _ = try command.run(&env.commands, &env.ctx, "open", &.{});
    try t.expectEqual(@as(usize, 1), plugin.conversation("*t*").?.transcript.count());
    try t.expectEqualStrings("user", plugin.conversation("*t*").?.transcript.at(0).role());
    {
        const b0 = try plugin.conversation("*t*").?.transcript.at(0).text(gpa);
        defer gpa.free(b0);
        try t.expectEqualStrings("hi", b0);
    }
    {
        const got = try bufText(&env, gpa);
        defer gpa.free(got);
        try t.expectEqualStrings("user: hi", got);
    }
    try t.expectEqual(@as(usize, 1), plugin.conversation("*t*").?.subs.list.items.len);
    const sub_a = plugin.conversation("*t*").?.live_sub.?;

    // "chunk" ×2: streamed onto the SAME row. The claim object's IDENTITY
    // (not just its resolved range) stays the SAME pointer across both —
    // the precise signature of the INCREMENTAL path (`SubBuffer.extendEnd`
    // mutates the existing claim in place); a full-`fill` fallback would
    // `dropDoc` + re-`claim`, minting a BRAND NEW object each time, which
    // this asserts did NOT happen.
    _ = try command.run(&env.commands, &env.ctx, "chunk", &.{});
    const sub_b = plugin.conversation("*t*").?.live_sub.?;
    try t.expectEqual(@as(usize, 1), plugin.conversation("*t*").?.subs.list.items.len); // no new/leaked claim
    try t.expect(sub_a == sub_b);

    _ = try command.run(&env.commands, &env.ctx, "chunk", &.{});
    const sub_c = plugin.conversation("*t*").?.live_sub.?;
    try t.expectEqual(@as(usize, 1), plugin.conversation("*t*").?.subs.list.items.len);
    try t.expect(sub_b == sub_c);

    // The MODEL accumulated both chunks (replication's source of truth)...
    {
        const b0 = try plugin.conversation("*t*").?.transcript.at(0).text(gpa);
        defer gpa.free(b0);
        try t.expectEqualStrings("hi!!", b0);
    }
    // ...and the PROJECTED BUFFER agrees, byte for byte, with what a full
    // `fill` of this same model would have produced — the incremental path
    // is a performance shortcut, never a divergent rendering.
    {
        const got = try bufText(&env, gpa);
        defer gpa.free(got);
        try t.expectEqualStrings("user: hi!!", got);

        const DocumentMod = @import("../Document.zig");
        var doc_check = try DocumentMod.init(gpa, "check");
        defer doc_check.deinit(gpa);
        var subs_check: subbuffer.SubBuffers = .empty;
        defer subs_check.deinit(gpa);
        try TranscriptDoc.fill(gpa, &plugin.conversation("*t*").?.transcript, &doc_check, &subs_check);
        const full = try doc_check.text().toOwnedSlice(gpa);
        defer gpa.free(full);
        try t.expectEqualStrings(full, got);
    }

    // "open2": a NEW row — role tagging carries through per entry, not just
    // per plugin — and its claim is a genuinely DIFFERENT object (the full
    // `fill` this triggers re-mints every row's claim, entry 0's included).
    _ = try command.run(&env.commands, &env.ctx, "open2", &.{});
    try t.expectEqual(@as(usize, 2), plugin.conversation("*t*").?.transcript.count());
    try t.expectEqualStrings("agent", plugin.conversation("*t*").?.transcript.at(1).role());
    const sub_d = plugin.conversation("*t*").?.live_sub.?;
    try t.expect(sub_d != sub_c);
    try t.expectEqual(@as(usize, 2), plugin.conversation("*t*").?.subs.list.items.len);
    {
        const got = try bufText(&env, gpa);
        defer gpa.free(got);
        try t.expectEqualStrings("user: hi!!\nagent: yo", got);
    }
}

test "quickjs: a JS plugin reads a file through weft.fileRead" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const fpath = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/read.txt", .{tmp.sub_path});
    defer gpa.free(fpath);
    try @import("../file.zig").writeBytes(gpa, fpath, "file contents here");

    // fs/read is answered from disk (no open buffer here) — the harness reading
    // a file for the agent.
    const src = try std.fmt.allocPrint(gpa, "weft.command(\"r\", () => weft.echo(weft.fileRead(\"{s}\")));", .{fpath});
    defer gpa.free(src);
    try env.grant("test", "fs_read");
    var plugin = try JsPlugin.load(gpa, &engine, &env.ctx, env.pool, .empty, "test", null, src);
    defer plugin.deinit();

    _ = try command.run(&env.commands, &env.ctx, "r", &.{});
    try t.expectEqualStrings("file contents here", env.head.echo.items);
}

// ── The JS plane's grant gate (`guest/deny.zig`'s twin, one layer up under
// the JS engine): a resident `.js` plugin declares nothing about itself, so a
// config `weft.grant` is the ONLY thing that can give it an effect. The
// fixture is the plugin source itself — each command wraps its effect in
// try/catch and echoes which arm ran, so the test can tell a THROWN denial
// apart from a value the plugin could have silently ignored. ──

/// A plugin that reports, through the echo line, whether its effect ran or
/// was denied. `weft.echo` is head-gated, so both arms defer nothing — they
/// run inside the dispatching command that called them.
const grant_gate_js =
    \\weft.command("spawn", () => {
    \\  try { weft.procSpawn("true"); weft.echo("spawned"); }
    \\  catch (e) { weft.echo("threw: " + e.message); }
    \\});
    \\weft.command("read", () => {
    \\  try { weft.echo("read:" + weft.fileRead("/etc/hostname")); }
    \\  catch (e) { weft.echo("threw: " + e.message); }
    \\});
;

test "quickjs: a JS plugin with NO declared grants gets NO effect capability — the call throws" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    // Nothing granted: fail closed on every effect door, and loudly.
    var plugin = try JsPlugin.load(gpa, &engine, &env.ctx, env.pool, .empty, "ungranted", null, grant_gate_js);
    defer plugin.deinit();

    _ = try command.run(&env.commands, &env.ctx, "spawn", &.{});
    try t.expect(std.mem.startsWith(u8, env.head.echo.items, "threw: "));
    try t.expect(std.mem.indexOf(u8, env.head.echo.items, "permission denied") != null);
    // Denial is not a spawn that merely failed — no child was ever started.
    try t.expectEqual(@as(usize, 0), plugin.streams.items.len);

    _ = try command.run(&env.commands, &env.ctx, "read", &.{});
    try t.expect(std.mem.startsWith(u8, env.head.echo.items, "threw: "));
}

test "quickjs: a granted JS plugin spawns — and revoking `proc` stops it on the very next call" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    try env.grant("gated", "proc");
    var plugin = try JsPlugin.load(gpa, &engine, &env.ctx, env.pool, .empty, "gated", null, grant_gate_js);
    defer plugin.deinit();

    _ = try command.run(&env.commands, &env.ctx, "spawn", &.{});
    try t.expectEqualStrings("spawned", env.head.echo.items);
    // `fs_read` was never granted — one capability is not the others.
    _ = try command.run(&env.commands, &env.ctx, "read", &.{});
    try t.expect(std.mem.startsWith(u8, env.head.echo.items, "threw: "));

    // Possession, not a cached boolean: the plugin re-checks the SAME row.
    try t.expectEqual(@as(usize, 1), env.grants.revoke("gated", "proc"));
    _ = try command.run(&env.commands, &env.ctx, "spawn", &.{});
    try t.expect(std.mem.startsWith(u8, env.head.echo.items, "threw: "));
}

test "quickjs: an fs_read grant narrowed to a root confines a JS plugin (guest/fs_limit.zig's twin)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const file = @import("../file.zig");
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/root", .{tmp.sub_path});
    defer gpa.free(root);
    const inside = try std.fmt.allocPrint(gpa, "{s}/ok.txt", .{root});
    defer gpa.free(inside);
    const outside = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/secret.txt", .{tmp.sub_path});
    defer gpa.free(outside);
    const traversal = try std.fmt.allocPrint(gpa, "{s}/../secret.txt", .{root});
    defer gpa.free(traversal);
    try file.writeBytesMakingDirs(gpa, root, inside, "in root");
    try file.writeBytes(gpa, outside, "out of root");

    const src = try std.fmt.allocPrint(gpa,
        \\function reader(name, path) {{
        \\  weft.command(name, () => {{
        \\    try {{ weft.echo("read:" + weft.fileRead(path)); }}
        \\    catch (e) {{ weft.echo("threw"); }}
        \\  }});
        \\}}
        \\reader("in", "{s}");
        \\reader("out", "{s}");
        \\reader("up", "{s}");
    , .{ inside, outside, traversal });
    defer gpa.free(src);

    _ = try env.grants.grant(.{ .capability = "fs_read", .limit = .{ .fs_root = root } }, "confined", null);
    var plugin = try JsPlugin.load(gpa, &engine, &env.ctx, env.pool, .empty, "confined", null, src);
    defer plugin.deinit();

    _ = try command.run(&env.commands, &env.ctx, "in", &.{});
    try t.expectEqualStrings("read:in root", env.head.echo.items);
    // Possessed, but out of the granted root — a denial, not an empty read.
    _ = try command.run(&env.commands, &env.ctx, "out", &.{});
    try t.expectEqualStrings("threw", env.head.echo.items);
    _ = try command.run(&env.commands, &env.ctx, "up", &.{});
    try t.expectEqualStrings("threw", env.head.echo.items);
}

// ── doc/place.md §4.1a: a JS plugin is not a different KIND of plugin ─────
// The wasm-plane gate for this lives in `wasm_abi/tests.zig`. Its twin here
// is the point: both planes go through `wasm_host/fs.zig`'s ONE gate, so the
// carve-out cannot hold on one surface and not the other — which is exactly
// how `cAgentWrite` came to have no perm check at all while `wl_fs_write`
// had two.

test "quickjs: no grant, however broad, reaches the editor's own machinery (guest gate's JS twin)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    const machinery = @import("../machinery.zig");
    const cache = wasm.Engine.cacheDir(gpa).?;
    defer gpa.free(cache);
    const cached = try std.fmt.allocPrint(gpa, "{s}/deadbeef.cwasm", .{cache});
    defer gpa.free(cached);
    const kv_dir = @import("../kv_file.zig").stateDir(gpa).?;
    defer gpa.free(kv_dir);
    const kv_blob = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ kv_dir, @import("../kv_file.zig").store_file });
    defer gpa.free(kv_blob);
    var ibuf: [512]u8 = undefined;
    const id_path = @import("../identity.zig").configPath(&ibuf, machinery.Posix{});
    var kbuf: [512]u8 = undefined;
    const peers_path = @import("../known_peers.zig").configPath(&kbuf, machinery.Posix{});

    // Ordinary content the unconfined grant DOES reach, so the refusals below
    // are about the carve-out and not about a broken door.
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(dir);
    const content = try std.fmt.allocPrint(gpa, "{s}/user-content.txt", .{dir});
    defer gpa.free(content);
    try @import("../file.zig").writeBytesMakingDirs(gpa, dir, content, "ordinary");

    const src = try std.fmt.allocPrint(gpa,
        \\function reader(name, path) {{
        \\  weft.command(name, () => {{
        \\    try {{ weft.echo("read:" + weft.fileRead(path)); }}
        \\    catch (e) {{ weft.echo("threw"); }}
        \\  }});
        \\}}
        \\reader("content", "{s}");
        \\reader("cache", "{s}");
        \\reader("kv", "{s}");
        \\reader("identity", "{s}");
        \\reader("peers", "{s}");
    , .{ content, cached, kv_blob, id_path orelse content, peers_path orelse content });
    defer gpa.free(src);

    // The BROADEST grant the config plane can spell: no root, no scope.
    try env.grant("broad", "fs_read");
    var plugin = try JsPlugin.load(gpa, &engine, &env.ctx, env.pool, .empty, "broad", null, src);
    defer plugin.deinit();

    _ = try command.run(&env.commands, &env.ctx, "content", &.{});
    try t.expectEqualStrings("read:ordinary", env.head.echo.items);

    _ = try command.run(&env.commands, &env.ctx, "cache", &.{});
    try t.expectEqualStrings("threw", env.head.echo.items);
    _ = try command.run(&env.commands, &env.ctx, "kv", &.{});
    try t.expectEqualStrings("threw", env.head.echo.items);
    if (id_path != null) {
        _ = try command.run(&env.commands, &env.ctx, "identity", &.{});
        try t.expectEqualStrings("threw", env.head.echo.items);
    }
    if (peers_path != null) {
        _ = try command.run(&env.commands, &env.ctx, "peers", &.{});
        try t.expectEqualStrings("threw", env.head.echo.items);
    }
}

test "quickjs: an OPEN buffer doesn't launder the machinery carve-out either" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    // `cFileRead`'s LIVE-BUFFER half — the branch with no descriptor to root
    // against, and the one that used to be gated only by the limit. Opening
    // a machinery file (which the HOST may legitimately do) must not make it
    // readable by a plugin holding an unconfined grant.
    const cache = wasm.Engine.cacheDir(gpa).?;
    defer gpa.free(cache);
    const cached = try std.fmt.allocPrint(gpa, "{s}/opened.cwasm", .{cache});
    defer gpa.free(cached);
    try @import("../file.zig").writeBytesMakingDirs(gpa, cache, cached, "compiled image bytes");
    defer @import("../file.zig").deleteFile(gpa, cached);

    const bid = try env.buffers.create(gpa, "opened.cwasm");
    try env.buffers.get(bid).?.textEditor().?.openFile(gpa, cached);

    const src = try std.fmt.allocPrint(gpa,
        \\weft.command("go", () => {{
        \\  try {{ weft.echo("read:" + weft.fileRead("{s}")); }}
        \\  catch (e) {{ weft.echo("threw"); }}
        \\}});
    , .{cached});
    defer gpa.free(src);

    try env.grant("broad", "fs_read");
    var plugin = try JsPlugin.load(gpa, &engine, &env.ctx, env.pool, .empty, "broad", null, src);
    defer plugin.deinit();

    _ = try command.run(&env.commands, &env.ctx, "go", &.{});
    try t.expectEqualStrings("threw", env.head.echo.items);
}

test "quickjs: an agent's fileWrite cannot bind a buffer onto the editor's machinery" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    // `cAgentWrite` never touches the filesystem — it binds a buffer the USER
    // later saves. That is still a write to machinery, one save away, so the
    // same carve-out has to hold here: refused, and NO buffer bound.
    const kv_dir = @import("../kv_file.zig").stateDir(gpa).?;
    defer gpa.free(kv_dir);
    const blob = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ kv_dir, @import("../kv_file.zig").store_file });
    defer gpa.free(blob);

    const src = try std.fmt.allocPrint(gpa,
        \\weft.command("w", () => {{
        \\  try {{ weft.fileWrite("{s}", "clobbered", "a1"); weft.echo("wrote"); }}
        \\  catch (e) {{ weft.echo("threw"); }}
        \\}});
    , .{blob});
    defer gpa.free(src);

    try env.grant("broad", "fs_write");
    var plugin = try JsPlugin.load(gpa, &engine, &env.ctx, env.pool, .empty, "broad", null, src);
    defer plugin.deinit();

    _ = try command.run(&env.commands, &env.ctx, "w", &.{});
    try t.expectEqualStrings("threw", env.head.echo.items);
    try t.expect(env.buffers.findByPath(blob) == null);
}

test "quickjs: an OPEN buffer doesn't launder a narrowed fs_read grant" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    // The live-buffer branch of `cFileRead` — the one with no descriptor to
    // root against. Opening a file must not make it readable past the limit.
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(dir);
    const outside = try std.fmt.allocPrint(gpa, "{s}/secret.txt", .{dir});
    defer gpa.free(outside);
    try @import("../file.zig").writeBytesMakingDirs(gpa, dir, outside, "top secret");

    const id = try env.buffers.create(gpa, "secret.txt");
    try env.buffers.get(id).?.textEditor().?.openFile(gpa, outside);

    const src = try std.fmt.allocPrint(gpa,
        \\weft.command("go", () => {{
        \\  try {{ weft.echo("read:" + weft.fileRead("{s}")); }}
        \\  catch (e) {{ weft.echo("threw"); }}
        \\}});
    , .{outside});
    defer gpa.free(src);

    const root = try std.fmt.allocPrint(gpa, "{s}/notes", .{dir});
    defer gpa.free(root);
    _ = try env.grants.grant(.{ .capability = "fs_read", .limit = .{ .fs_root = root } }, "confined", null);
    var plugin = try JsPlugin.load(gpa, &engine, &env.ctx, env.pool, .empty, "confined", null, src);
    defer plugin.deinit();

    _ = try command.run(&env.commands, &env.ctx, "go", &.{});
    try t.expectEqualStrings("threw", env.head.echo.items);
}

test "quickjs: a JS plugin writes a file as an attributed agent peer edit" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    // fs/write to a path that isn't open → weft binds a buffer to it and applies
    // the content as the agent peer (gated + attributed), not a raw disk write.
    const src =
        \\weft.command("w", () => weft.fileWrite("/tmp/weft-agent-out.zig", "const x = 1;"));
    ;
    // `fs_write`, declared: this door is possession-gated like every other
    // effect door (it was not always — see the confinement test below), so
    // the fixture has to hold the capability it exercises.
    try env.grant("test", "fs_write");
    var plugin = try JsPlugin.load(gpa, &engine, &env.ctx, env.pool, .empty, "test", null, src);
    defer plugin.deinit();
    _ = try command.run(&env.commands, &env.ctx, "w", &.{});

    const id = env.buffers.findByPath("/tmp/weft-agent-out.zig") orelse return error.NoAgentBuffer;
    const b = env.buffers.get(id).?;
    const txt = try b.textEditor().?.text().toOwnedSlice(gpa);
    defer gpa.free(txt);
    try t.expectEqualStrings("const x = 1;", txt);
    // Authored by a non-user peer — the agent, not the user's undo history.
    const doc = &b.textEditor().?.doc;
    try t.expect(doc.commitAt(doc.commitCount() - 1).author != .user);
}

test "quickjs: an agent's fileWrite outside a narrowed fs_write root is refused — and binds no buffer" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    // `cFileRead`'s confinement, on the WRITE door. `command.renderInto`'s
    // grade gate is not this check: it caps `.agent` at `gradeMin(doc.my_grant,
    // .edit)`, and `Document.my_grant` defaults to `.own`, so it passes for
    // every local buffer. Only `fs_write`'s own limit says where an agent may
    // write.
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(dir);
    const root = try std.fmt.allocPrint(gpa, "{s}/allowed", .{dir});
    defer gpa.free(root);
    const inside = try std.fmt.allocPrint(gpa, "{s}/note.txt", .{root});
    defer gpa.free(inside);
    const outside = try std.fmt.allocPrint(gpa, "{s}/secret.txt", .{dir});
    defer gpa.free(outside);
    try @import("../file.zig").writeBytesMakingDirs(gpa, root, inside, "");

    const src = try std.fmt.allocPrint(gpa,
        \\function writer(name, path) {{
        \\  weft.command(name, () => {{
        \\    try {{ weft.fileWrite(path, "written", "a1"); weft.echo("wrote"); }}
        \\    catch (e) {{ weft.echo("threw"); }}
        \\  }});
        \\}}
        \\writer("in", "{s}");
        \\writer("out", "{s}");
        \\writer("abs", "/tmp/weft-agent-escape.zig");
    , .{ inside, outside });
    defer gpa.free(src);

    _ = try env.grants.grant(.{ .capability = "fs_write", .limit = .{ .fs_root = root } }, "confined", null);
    var plugin = try JsPlugin.load(gpa, &engine, &env.ctx, env.pool, .empty, "confined", null, src);
    defer plugin.deinit();

    // In root: the agent edit lands, exactly as before the gate.
    _ = try command.run(&env.commands, &env.ctx, "in", &.{});
    try t.expectEqualStrings("wrote", env.head.echo.items);
    try t.expect(env.buffers.findByPath(inside) != null);

    // Out of root, and an absolute path with nothing to do with the grant:
    // both REFUSED — a thrown denial, never a write the agent thinks landed.
    _ = try command.run(&env.commands, &env.ctx, "out", &.{});
    try t.expectEqualStrings("threw", env.head.echo.items);
    _ = try command.run(&env.commands, &env.ctx, "abs", &.{});
    try t.expectEqualStrings("threw", env.head.echo.items);

    // And refusal means NO buffer was bound to either path — the door's own
    // side effect (create + adoptPath) must not run ahead of its gate.
    try t.expect(env.buffers.findByPath(outside) == null);
    try t.expect(env.buffers.findByPath("/tmp/weft-agent-escape.zig") == null);
}

test "quickjs: an ungranted JS plugin cannot fileWrite at all — possession, not just its limit" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    const src =
        \\weft.command("w", () => {
        \\  try { weft.fileWrite("/tmp/weft-agent-ungranted.zig", "x"); weft.echo("wrote"); }
        \\  catch (e) { weft.echo("threw"); }
        \\});
    ;
    var plugin = try JsPlugin.load(gpa, &engine, &env.ctx, env.pool, .empty, "ungranted", null, src);
    defer plugin.deinit();

    _ = try command.run(&env.commands, &env.ctx, "w", &.{});
    try t.expectEqualStrings("threw", env.head.echo.items);
    try t.expect(env.buffers.findByPath("/tmp/weft-agent-ungranted.zig") == null);
}

test "quickjs: a refused agent write is ANSWERED, not swallowed — the rest of the batch still streams" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    // Gating `weft.fileWrite` made refusal REACHABLE from the shipped ACP
    // reactor, which parses a whole `procRead` batch in one loop: a throw
    // escaping `onMessage` would drop every line after it, and those lines
    // are already out of the plugin's inbox — gone for good. So a narrowed
    // `fs_write` grant could silently swallow whatever the agent said next,
    // up to and including a permission request. The refusal has to be an
    // ANSWER to that one request and nothing more.
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(dir);
    const root = try std.fmt.allocPrint(gpa, "{s}/allowed", .{dir});
    defer gpa.free(root);
    const keep = try std.fmt.allocPrint(gpa, "{s}/keep.txt", .{root});
    defer gpa.free(keep);
    try @import("../file.zig").writeBytesMakingDirs(gpa, root, keep, "");
    const outside = try std.fmt.allocPrint(gpa, "{s}/secret.txt", .{dir});
    defer gpa.free(outside);

    // One batch: handshake, a write the grant cannot reach, then a message.
    const mock_path = try std.fmt.allocPrint(gpa, "{s}/mock.sh", .{dir});
    defer gpa.free(mock_path);
    const mock = try std.fmt.allocPrint(gpa,
        \\printf '{{"jsonrpc":"2.0","id":0,"result":{{"protocolVersion":1}}}}\n'
        \\printf '{{"jsonrpc":"2.0","id":1,"result":{{"sessionId":"s1"}}}}\n'
        \\printf '{{"jsonrpc":"2.0","id":8,"method":"fs/write_text_file","params":{{"path":"{s}","content":"escaped"}}}}\n'
        \\printf '{{"jsonrpc":"2.0","method":"session/update","params":{{"update":{{"sessionUpdate":"agent_message_chunk","content":{{"type":"text","text":"after the refusal"}}}}}}}}\n'
    , .{outside});
    defer gpa.free(mock);
    try @import("../file.zig").writeBytes(gpa, mock_path, mock);

    const acp = try @import("../file.zig").readAlloc(gpa, "config/plugins/acp.js");
    defer gpa.free(acp);
    const src = try std.fmt.allocPrint(gpa, "{s}\nstartAgent(\"/bin/sh {s}\", \"hi\");\n", .{ acp, mock_path });
    defer gpa.free(src);

    try env.grant("test", "proc");
    _ = try env.grants.grant(.{ .capability = "fs_write", .limit = .{ .fs_root = root } }, "test", null);
    var plugin = try JsPlugin.load(gpa, &engine, &env.ctx, env.pool, .empty, "test", null, src);
    defer plugin.deinit();

    const deadline = task.nowNs() + 3 * std.time.ns_per_s;
    var streamed = false;
    while (!streamed and task.nowNs() < deadline) {
        _ = plugin.tick();
        var it = env.buffers.iterator();
        while (it.next()) |b| {
            if (!std.mem.eql(u8, b.name, "*agent*")) continue;
            const txt = try b.textEditor().?.text().toOwnedSlice(gpa);
            defer gpa.free(txt);
            if (std.mem.indexOf(u8, txt, "after the refusal") != null) streamed = true;
        }
        std.Thread.yield() catch {};
    }
    // The message AFTER the refused write arrived: one denial, one dropped
    // request, and the stream carried on.
    try t.expect(streamed);
    // ...and the write really was refused — no buffer bound out of root.
    try t.expect(env.buffers.findByPath(outside) == null);
}

test "quickjs: a config syntax error surfaces as ConfigException, not silent" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    // Malformed JS: the eval must fail loudly, and nothing was bound.
    try t.expectError(error.ConfigException, evalConfig(&engine, &env.ctx, null, null, null, "this is (not valid javascript"));
    try t.expectEqual(@as(usize, 0), env.head.echo.items.len);
}

test "quickjs: weft.plugin loads a real .wasm, then its command runs" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    // A minimal loader over the resident engine: resolve the guest "edit"
    // plugin from its embedded bytes and load it under the perm handshake —
    // the same shape main.zig's PluginHost has, minus disk/name resolution.
    const wasm_abi = @import("../wasm_abi.zig");
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
    try evalConfig(&engine, &env.ctx, .{ .ctx = &loader, .load = Loader.load }, null, null, cfg);

    // The plugin loaded and registered its command; the config's bind took.
    try t.expect(loader.held != null);
    try t.expect(env.commands.find("duplicate-line") != null);
    try env.head.setModeRaw(gpa, "normal");
    try t.expectEqualStrings("duplicate-line", env.keymap.lookup(env.head.currentMode(), "D").?);

    // And the command actually runs through the membrane: duplicate a line.
    try env.buffers.active().textEditor().?.insertText(gpa, "hi");
    env.buffers.active().textEditor().?.placeCursor(0);
    _ = try command.run(&env.commands, &env.ctx, "duplicate-line", &.{});
    const s = try env.buffers.active().textEditor().?.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("hi\nhi", s);
}

test "quickjs: R1 regression — weft.set for a .js plugin's STEM identity is not dropped as unowned" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    var cfgstore: kv.Store = .empty;
    defer cfgstore.deinit(gpa);

    // The DOCUMENTED ACP setup (config.js's commented block): weft.set
    // BEFORE weft.plugin, a path-form name ("acp.js") whose config-store
    // identity is its STEM ("acp" — config_load.zig's loadJs registers a
    // JsPlugin under `stem(basename(name))`, and `weft.config(key)` keys on
    // that stem). Pre-M3 this worked unconditionally (no ownership check
    // existed); the value-ownership closed-namespace check must not
    // silently drop it.
    const cfg =
        \\weft.set("acp", "cmd", "codex-acp");
        \\weft.plugin("acp.js");
    ;
    try evalConfig(&engine, &env.ctx, null, &cfgstore, null, cfg);

    const blob = cfgstore.get("acp", "cmd") orelse return error.ValueWronglyDropped;
    const value = firstFramedRecord(blob) orelse return error.BadFrame;
    try t.expectEqualStrings("codex-acp", value);
}

test "quickjs: deferred load — weft.set before the plugin line reaches its init" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    var config: kv.Store = .empty;
    defer config.deinit(gpa);

    const wasm_abi = @import("../wasm_abi.zig");
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
    try evalConfig(&engine, &env.ctx, .{ .ctx = &loader, .load = Loader.load }, &config, null, cfg);

    // The plugin read its config at init: it registered the CONFIG pair command,
    // not the shipped defaults.
    try t.expect(loader.held != null);
    try t.expect(env.commands.find("pair-tick") != null);
    try t.expect(env.commands.find("pair-paren") == null);
    try env.head.setModeRaw(gpa, "insert");
    try t.expectEqualStrings("pair-tick", env.keymap.lookup(env.head.currentMode(), "grave").?);

    // And it runs through the membrane: inserts the configured backtick pair.
    _ = try command.run(&env.commands, &env.ctx, "pair-tick", &.{});
    const s = try env.buffers.active().textEditor().?.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("``", s);
}

test "quickjs: weft.menu declares a submenu the leader tree enters (doom-style)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    const cfg =
        \\weft.menu("leader-file");
        \\weft.bind("leader", "f", "leader-file");
        \\weft.bind("leader-file", "s", "save");
    ;
    try evalConfig(&engine, &env.ctx, null, null, null, cfg);

    // The submenu is a menu mode: which-key shows it, and the dispatch enters it
    // when a leader key's command names it (that's why "f" → "leader-file" is a
    // group, not a leaf).
    try t.expect(env.keymap.isMenuMode("leader-file"));

    // In the leader menu, "f" resolves to the submenu name (a group entry).
    try env.head.setModeRaw(gpa, "leader");
    try t.expectEqualStrings("leader-file", env.keymap.lookup(env.head.currentMode(), "f").?);

    // Inside the submenu: its own keys bind, and Escape/C-g leave via menu-escape.
    try env.head.setModeRaw(gpa, "leader-file");
    try t.expectEqualStrings("save", env.keymap.lookup(env.head.currentMode(), "s").?);
    try t.expectEqualStrings("menu-escape", env.keymap.lookup(env.head.currentMode(), "Escape").?);
    try t.expectEqualStrings("menu-escape", env.keymap.lookup(env.head.currentMode(), "C-g").?);
}

test "quickjs: every shipped example config evals without a JS error" {
    const gpa = t.allocator;
    // Each config's JS must parse and drive the weft.* surface cleanly. Plugins
    // no-op here (no loader), so this checks syntax + the bind/menu/set calls —
    // a typo or a bad API use surfaces as ConfigException. Read from the repo's
    // config/ (the test runs with cwd at the project root).
    const file = @import("../file.zig");
    const paths = [_][]const u8{
        "config/config.js", "config/config.northstar.js", "config/vim-minimal.js",
        "config/helix.js",  "config/dual.js",             "config/agent-ux.js",
    };
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    for (paths) |path| {
        const src = file.readAlloc(gpa, path) catch continue; // skip if run outside the repo
        defer gpa.free(src);
        var env: Env = undefined;
        try Env.init(gpa, &env);
        defer env.deinit(gpa);
        var cfgstore: kv.Store = .empty;
        defer cfgstore.deinit(gpa);
        evalConfig(&engine, &env.ctx, null, &cfgstore, null, src) catch |e| {
            std.debug.print("config {s} failed: {t}\n", .{ path, e });
            return e;
        };
    }
}

test "quickjs: sealed eval — two evals of the same config produce identical manifest hashes" {
    const gpa = t.allocator;
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    const cfg =
        \\weft.plugin("edit");
        \\weft.bind("normal", "j", "cursor-down");
        \\weft.action("eval");
        \\weft.provide("eval", { lang: "zig" }, "zig-eval");
        \\weft.set("theme", "accent", "#8ec07c");
        \\weft.echo("loaded");
    ;

    var env1: Env = undefined;
    try Env.init(gpa, &env1);
    defer env1.deinit(gpa);
    const m1 = try evalToManifest(&engine, &env1.ctx, null, null, null, cfg, .config, "config");
    defer m1.destroy();

    var env2: Env = undefined;
    try Env.init(gpa, &env2);
    defer env2.deinit(gpa);
    const m2 = try evalToManifest(&engine, &env2.ctx, null, null, null, cfg, .config, "config");
    defer m2.destroy();

    // Deterministic: staging the SAME source twice, in two entirely separate
    // JS runtimes, yields byte-identical manifests (§2.3's sealed-eval claim
    // — this is what "an eval using a sealed API is deterministic" tests
    // against; the `.config` surface has no clock/env/random of its own,
    // see qjs_contract's "no clock/env/random-shaped .config import" test).
    try t.expectEqual(m1.hash(), m2.hash());

    // And a manifest that DIFFERS (one extra decl) hashes differently — the
    // hash is sensitive to content, not a constant.
    const cfg2 = cfg ++ "\nweft.bind(\"normal\", \"k\", \"cursor-up\");\n";
    var env3: Env = undefined;
    try Env.init(gpa, &env3);
    defer env3.deinit(gpa);
    const m3 = try evalToManifest(&engine, &env3.ctx, null, null, null, cfg2, .config, "config");
    defer m3.destroy();
    try t.expect(m1.hash() != m3.hash());
}

test "quickjs: R2 — Date.now()/Math.random() are SEALED (fixed, deterministic across evals)" {
    const gpa = t.allocator;
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    // A config that FEEDS the two nondeterministic engine builtins into
    // weft.set — exactly the leak review R2 flagged (the .config `weft.*`
    // surface itself has none of these, but Date/Math.random are QuickJS
    // built-ins the qjs_contract audit can't see). `weft_eval`'s seal
    // prelude (core/quickjs/weft_qjs.c) overrides both before this source
    // ever runs; if it didn't, `Date.now()` (wall clock) or `Math.random()`
    // would differ between the two evals below and the hashes would too.
    const cfg =
        \\weft.set("theme", "accent", "clock:" + Date.now());
        \\weft.set("theme", "cursor", "rand:" + Math.random());
        \\weft.set("theme", "selection", "date:" + (new Date()).getTime());
    ;

    var env1: Env = undefined;
    try Env.init(gpa, &env1);
    defer env1.deinit(gpa);
    const m1 = try evalToManifest(&engine, &env1.ctx, null, null, null, cfg, .config, "config");
    defer m1.destroy();

    var env2: Env = undefined;
    try Env.init(gpa, &env2);
    defer env2.deinit(gpa);
    const m2 = try evalToManifest(&engine, &env2.ctx, null, null, null, cfg, .config, "config");
    defer m2.destroy();

    try t.expectEqual(m1.hash(), m2.hash());
    // Not just equal hashes by coincidence — the actual staged VALUES agree
    // (and are the fixed, sealed constants: Date.now()==0, a repeatable
    // Math.random() sequence, `new Date()` epoch 0). `.value` is the shim's
    // FRAMED blob (uvarint-prefixed), same encoding `weft.set` always
    // produces — decode with `firstFramedRecord`, as `weft.config` does.
    try t.expectEqualStrings("clock:0", firstFramedRecord(m1.values.items[0].value).?);
    try t.expectEqualStrings("clock:0", firstFramedRecord(m2.values.items[0].value).?);
    try t.expectEqualStrings(
        firstFramedRecord(m1.values.items[1].value).?,
        firstFramedRecord(m2.values.items[1].value).?,
    );
    try t.expectEqualStrings("date:0", firstFramedRecord(m1.values.items[2].value).?);
    try t.expectEqualStrings("date:0", firstFramedRecord(m2.values.items[2].value).?);
}

test "quickjs: weft.grant stages a GrantDecl onto the manifest, and the hash is sensitive to it (§6 W4 slice 4)" {
    const gpa = t.allocator;
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    const cfg =
        \\weft.grant("git", "fs_write", { root: "repo" });
        \\weft.grant("git", "proc");
    ;

    var env1: Env = undefined;
    try Env.init(gpa, &env1);
    defer env1.deinit(gpa);
    const m1 = try evalToManifest(&engine, &env1.ctx, null, null, null, cfg, .config, "config");
    defer m1.destroy();

    try t.expectEqual(@as(usize, 2), m1.grants.items.len);
    try t.expectEqualStrings("git", m1.grants.items[0].plugin);
    try t.expectEqualStrings("fs_write", m1.grants.items[0].capability);
    try t.expectEqualStrings("repo", m1.grants.items[0].root);
    try t.expectEqualStrings("git", m1.grants.items[1].plugin);
    try t.expectEqualStrings("proc", m1.grants.items[1].capability);
    try t.expectEqualStrings("", m1.grants.items[1].root); // no opts — unrestricted

    // Sealed eval, extended to grants: the SAME source, in a totally
    // separate JS runtime, hashes identically.
    var env2: Env = undefined;
    try Env.init(gpa, &env2);
    defer env2.deinit(gpa);
    const m2 = try evalToManifest(&engine, &env2.ctx, null, null, null, cfg, .config, "config");
    defer m2.destroy();
    try t.expectEqual(m1.hash(), m2.hash());

    // A CHANGED grant (a different root — the limit itself changed) changes
    // the hash: the determinism claim covers grants, not just binds/values.
    const cfg2 =
        \\weft.grant("git", "fs_write", { root: "other-repo" });
        \\weft.grant("git", "proc");
    ;
    var env3: Env = undefined;
    try Env.init(gpa, &env3);
    defer env3.deinit(gpa);
    const m3 = try evalToManifest(&engine, &env3.ctx, null, null, null, cfg2, .config, "config");
    defer m3.destroy();
    try t.expect(m1.hash() != m3.hash());
}

test "quickjs: weft.grant FAILS CLOSED — a non-string/undefined opts.root throws, eval fails loudly (review nit 1)" {
    const gpa = t.allocator;
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    // A mistyped narrowing — {root: 123} — must NEVER silently degrade to
    // unrestricted; the whole eval must fail instead (sealed eval's M3
    // precedent: fail loudly, never widen quietly).
    {
        var env: Env = undefined;
        try Env.init(gpa, &env);
        defer env.deinit(gpa);
        const cfg = "weft.grant(\"git\", \"fs_write\", { root: 123 });\n";
        try t.expectError(error.ConfigException, evalToManifest(&engine, &env.ctx, null, null, null, cfg, .config, "config"));
    }

    // Same for an explicitly `undefined` root — the exact "a typo'd
    // variable that evaluated to undefined" case the send-back named.
    {
        var env: Env = undefined;
        try Env.init(gpa, &env);
        defer env.deinit(gpa);
        const cfg = "weft.grant(\"git\", \"fs_write\", { root: undefined });\n";
        try t.expectError(error.ConfigException, evalToManifest(&engine, &env.ctx, null, null, null, cfg, .config, "config"));
    }

    // But an OMITTED opts, or an opts object with no `root` key at all, is
    // the legitimate unrestricted case — no exception, root stays "".
    {
        var env: Env = undefined;
        try Env.init(gpa, &env);
        defer env.deinit(gpa);
        const cfg = "weft.grant(\"git\", \"proc\");\n";
        const m = try evalToManifest(&engine, &env.ctx, null, null, null, cfg, .config, "config");
        defer m.destroy();
        try t.expectEqualStrings("", m.grants.items[0].root);
    }
    {
        var env: Env = undefined;
        try Env.init(gpa, &env);
        defer env.deinit(gpa);
        const cfg = "weft.grant(\"git\", \"proc\", {});\n";
        const m = try evalToManifest(&engine, &env.ctx, null, null, null, cfg, .config, "config");
        defer m.destroy();
        try t.expectEqualStrings("", m.grants.items[0].root);
    }
}

test "quickjs: weft.grant is config-plane only — a resident JS plugin's call is a logged no-op" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    // A JS plugin registers a command that calls weft.grant from a LIVE
    // dispatch — `br.manifest == null` there, so `cGrant` must degrade to a
    // warning, never crash and never mutate anything (statusSegment's exact
    // precedent for a config-only verb reached from the plugin plane).
    const src =
        \\weft.command("try-grant", function() {
        \\  weft.grant("other", "fs_write", { root: "x" });
        \\  weft.echo("survived");
        \\});
    ;
    const plugin = try JsPlugin.load(gpa, &engine, &env.ctx, env.pool, .empty, "grantplugin", null, src);
    defer plugin.deinit();
    _ = try command.run(&env.commands, &env.ctx, "try-grant", &.{});
    try t.expectEqualStrings("survived", env.head.echo.items);
}

test "quickjs: weft.use produces a real imported sub-manifest at the imported tier" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    const dir = ".zig-cache/tmp/weft-use-manifest-test";
    const defaults_path = dir ++ "/shared.js";
    try @import("../file.zig").writeBytesMakingDirs(gpa, dir, defaults_path,
        \\weft.bind("pick", "Down", "pick-next");
    );
    defer @import("../file.zig").deleteFile(gpa, defaults_path);

    const cfg = "weft.use(\"shared\");\n";
    const m = try evalToManifest(&engine, &env.ctx, null, null, dir, cfg, .config, "config");
    defer m.destroy();

    try t.expectEqual(@as(usize, 1), m.imports.items.len);
    const sub = m.imports.items[0];
    try t.expectEqual(manifest_mod.Tier.imported, sub.tier);
    try t.expectEqualStrings("import:shared", sub.owner);
    try t.expectEqual(@as(usize, 1), sub.binds.items.len);
    try t.expectEqualStrings("pick-next", sub.binds.items[0].commands[0]);
}

test "quickjs: reconcile — reapplying the identical config is a verified no-op" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    const cfg =
        \\weft.bind("normal", "j", "cursor-down");
        \\weft.echo("hello");
    ;
    const m1 = try evalToManifest(&engine, &env.ctx, null, null, null, cfg, .config, "config");
    defer m1.destroy();
    var actx: manifest_mod.Manifest.ApplyCtx = .{ .ctx = &env.ctx, .loader = null, .config = null };
    try m1.apply(gpa, &actx);
    try env.head.setModeRaw(gpa, "normal");
    try t.expectEqualStrings("cursor-down", env.keymap.lookup(env.head.currentMode(), "j").?);
    try t.expectEqualStrings("hello", env.head.echo.items);

    // A second eval of the SAME source, reconciled against m1: same hash,
    // logged no-op, and critically the echo does NOT fire again (a echo
    // re-firing on every identical reload would be the "no-op" claim lying).
    env.head.echo.clearRetainingCapacity();
    const m2 = try evalToManifest(&engine, &env.ctx, null, null, null, cfg, .config, "config");
    defer m2.destroy();
    try manifest_mod.Manifest.reconcile(gpa, m1, m2, &actx);
    try t.expectEqualStrings("", env.head.echo.items); // no-op: nothing re-fired
    try t.expectEqualStrings("cursor-down", env.keymap.lookup(env.head.currentMode(), "j").?); // still bound

    // A CHANGED config removes the old bind and adds a new one — reconcile
    // tears down the removed decl and applies the added one.
    const cfg3 =
        \\weft.bind("normal", "k", "cursor-up");
        \\weft.echo("hello");
    ;
    const m3 = try evalToManifest(&engine, &env.ctx, null, null, null, cfg3, .config, "config");
    defer m3.destroy();
    try manifest_mod.Manifest.reconcile(gpa, m2, m3, &actx);
    try t.expectEqual(@as(?[]const u8, null), env.keymap.lookup(env.head.currentMode(), "j")); // removed
    try t.expectEqualStrings("cursor-up", env.keymap.lookup(env.head.currentMode(), "k").?); // added
}

test "quickjs: W4 slice 4 — reconcile round trip: a weft.grant removed leaves COHERENT state, no baseline fallback" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    const cfg1 = "weft.grant(\"git\", \"fs_write\", { root: \"repo\" });\n";
    const m1 = try evalToManifest(&engine, &env.ctx, null, null, null, cfg1, .config, "config");
    defer m1.destroy();
    var actx: manifest_mod.Manifest.ApplyCtx = .{ .ctx = &env.ctx, .loader = null, .config = null };
    try manifest_mod.Manifest.reconcile(gpa, null, m1, &actx);

    const h = env.grants.findLive("git", "fs_write").?;
    try t.expect(env.grants.check(h));
    switch (env.grants.limitFor(h)) {
        .fs_root => |root| try t.expectEqualStrings("repo", root),
        .none, .place, .doc_region, .graph_subtree => return error.TestUnexpectedResult,
    }

    // Reload WITHOUT the grant decl at all — reconcile tears it down.
    const m2 = try evalToManifest(&engine, &env.ctx, null, null, null, "", .config, "config");
    defer m2.destroy();
    try manifest_mod.Manifest.reconcile(gpa, m1, m2, &actx);

    try t.expect(!env.grants.check(h));
    try t.expectEqual(grants_mod.Reason.revoked, env.grants.reasonFor(h));
    // The composition rule's honest consequence (grants.zig's module doc):
    // no separate describe()-boolean baseline row was ever minted for a
    // config-narrowed pair, so there is nothing to "fall back" to — the
    // pair reads as fully ungranted now, not silently reverted to
    // unrestricted.
    try t.expectEqual(@as(?grants_mod.CapHandle, null), env.grants.findLive("git", "fs_write"));
}

test "quickjs: W4 slice 4 — an UNCHANGED weft.grant survives a reload that changes something else (no orphaned handle)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    const cfg1 =
        \\weft.grant("git", "fs_write", { root: "repo" });
        \\weft.bind("normal", "j", "cursor-down");
    ;
    const m1 = try evalToManifest(&engine, &env.ctx, null, null, null, cfg1, .config, "config");
    defer m1.destroy();
    var actx: manifest_mod.Manifest.ApplyCtx = .{ .ctx = &env.ctx, .loader = null, .config = null };
    try manifest_mod.Manifest.reconcile(gpa, null, m1, &actx);
    const h = env.grants.findLive("git", "fs_write").?;

    // Reload with the SAME grant decl but a DIFFERENT, unrelated bind — the
    // manifest's hash differs (reconcile's teardown+reapply DOES run), but
    // the grant itself must survive as the SAME live row, not a
    // revoke-then-remint (`reconcileGrants`'s whole point: an already-loaded
    // plugin's POSSESSED handle must not be silently orphaned by a reload
    // that didn't touch ITS grant).
    const cfg2 =
        \\weft.grant("git", "fs_write", { root: "repo" });
        \\weft.bind("normal", "k", "cursor-up");
    ;
    const m2 = try evalToManifest(&engine, &env.ctx, null, null, null, cfg2, .config, "config");
    defer m2.destroy();
    try manifest_mod.Manifest.reconcile(gpa, m1, m2, &actx);

    try t.expect(env.grants.check(h)); // still the SAME live handle
    const h2 = env.grants.findLive("git", "fs_write").?;
    try t.expectEqual(h.idx, h2.idx);
    try t.expectEqual(h.gen, h2.gen);
}

test {
    std.testing.refAllDecls(@This());
}

test "quickjs: weft.bind takes an intention or a fallback list — one staged representation, order-sensitive hash (configuration.md §5.2)" {
    const gpa = t.allocator;
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    const list_cfg =
        \\weft.bind("normal", "Return", ["target.activate", "editing.insert-line-break"]);
    ;
    var env1: Env = undefined;
    try Env.init(gpa, &env1);
    defer env1.deinit(gpa);
    const m1 = try evalToManifest(&engine, &env1.ctx, null, null, null, list_cfg, .config, "config");
    defer m1.destroy();
    try t.expectEqual(@as(usize, 1), m1.binds.items.len);
    try t.expectEqual(@as(usize, 2), m1.binds.items[0].commands.len);
    try t.expectEqualStrings("target.activate", m1.binds.items[0].commands[0]);
    try t.expectEqualStrings("editing.insert-line-break", m1.binds.items[0].commands[1]);

    // Sealed eval: the same source, a separate runtime, an identical hash.
    var env2: Env = undefined;
    try Env.init(gpa, &env2);
    defer env2.deinit(gpa);
    const m2 = try evalToManifest(&engine, &env2.ctx, null, null, null, list_cfg, .config, "config");
    defer m2.destroy();
    try t.expectEqual(m1.hash(), m2.hash());

    // The STRING form stages the identical shape, one entry long.
    var env3: Env = undefined;
    try Env.init(gpa, &env3);
    defer env3.deinit(gpa);
    const m3 = try evalToManifest(&engine, &env3.ctx, null, null, null,
        \\weft.bind("normal", "Return", "target.activate");
    , .config, "config");
    defer m3.destroy();
    try t.expectEqual(@as(usize, 1), m3.binds.items[0].commands.len);
    try t.expectEqualStrings("target.activate", m3.binds.items[0].commands[0]);
    try t.expect(m1.hash() != m3.hash());

    // Reordering the list is a content change the hash sees.
    var env4: Env = undefined;
    try Env.init(gpa, &env4);
    defer env4.deinit(gpa);
    const m4 = try evalToManifest(&engine, &env4.ctx, null, null, null,
        \\weft.bind("normal", "Return", ["editing.insert-line-break", "target.activate"]);
    , .config, "config");
    defer m4.destroy();
    try t.expect(m1.hash() != m4.hash());

    // Applying a multi-entry list binds the FIRST entry (the catalog that
    // resolves the rest lands later); the fallback rides on the decl.
    var actx: manifest_mod.Manifest.ApplyCtx = .{ .ctx = &env1.ctx, .loader = null, .config = null };
    try m1.apply(gpa, &actx);
    try env1.head.setModeRaw(gpa, "normal");
    try t.expectEqualStrings("target.activate", env1.keymap.lookup(env1.head.currentMode(), "Return").?);

    // Reconciling the identical config is a no-op: still the first entry.
    try manifest_mod.Manifest.reconcile(gpa, m1, m2, &actx);
    try t.expectEqualStrings("target.activate", env1.keymap.lookup(env1.head.currentMode(), "Return").?);
}

test "quickjs: a degenerate weft.bind list fails the eval loudly — never a silently dropped binding" {
    const gpa = t.allocator;
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    const bad = [_][]const u8{
        "weft.bind(\"normal\", \"Return\", []);\n",
        "weft.bind(\"normal\", \"Return\", [\"target.activate\", 7]);\n",
    };
    for (bad) |cfg| {
        var env: Env = undefined;
        try Env.init(gpa, &env);
        defer env.deinit(gpa);
        try t.expectError(error.ConfigException, evalToManifest(&engine, &env.ctx, null, null, null, cfg, .config, "config"));
    }
}

// The §18 isolation gate for ACP: "Two repositories, REPLs, DAP sessions, and
// ACP conversations remain isolated." Two mock agents run CONCURRENTLY through
// the real `config/plugins/acp.js` — each mints its own transcript instance
// (`*agent*`, `*agent:2*`), its own CRDT sub-peer (`claude#1`, `codex#2`), and
// its own pending permission request. Answering one permission resolves ONLY
// its own tool call: the other agent stays blocked until its OWN answer, which
// is continuation identity (§14.7) rather than "whatever was pending".
test "quickjs: two ACP conversations stream into their own transcripts, and a permission answered for one never unblocks the other" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    try pick_mod.install(gpa, &env.commands, &env.keymap);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    // One mock ACP agent, parameterized by TAG (sh builtins only): handshake,
    // a message chunk, a file write, then a permission request — and after
    // that it BLOCKS on stdin, acking only when its own answer arrives. So
    // "TAG ack" in a transcript is proof that THAT agent was unblocked.
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const template =
        \\printf '{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1}}\n'
        \\printf '{"jsonrpc":"2.0","id":1,"result":{"sessionId":"TAG"}}\n'
        \\printf '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"TAG one"}}}}\n'
        \\printf '{"jsonrpc":"2.0","id":8,"method":"fs/write_text_file","params":{"path":"SHARED","content":"TAG wrote"}}\n'
        \\printf '{"jsonrpc":"2.0","id":9,"method":"session/request_permission","params":{"toolCall":{"toolCallId":"TAG-call","title":"TAG edit"},"options":[{"optionId":"allow","name":"Allow"},{"optionId":"deny","name":"Deny"}]}}\n'
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *outcome*) printf '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"TAG ack"}}}}\n' ;;
        \\  esac
        \\done
    ;
    const shared = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/shared.txt", .{tmp.sub_path});
    defer gpa.free(shared);
    const with_path = try std.mem.replaceOwned(u8, gpa, template, "SHARED", shared);
    defer gpa.free(with_path);
    var mocks: [2][]u8 = undefined;
    defer for (mocks) |m| gpa.free(m);
    const tags = [_][]const u8{ "alpha", "beta" };
    for (tags, 0..) |tag, i| {
        mocks[i] = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/{s}.sh", .{ tmp.sub_path, tag });
        const body = try std.mem.replaceOwned(u8, gpa, with_path, "TAG", tag);
        defer gpa.free(body);
        try @import("../file.zig").writeBytes(gpa, mocks[i], body);
    }

    // The REAL plugin, plus one start command per agent (named, so each
    // conversation's sub-peer is its own agent's — `claude#1`, `codex#2`).
    const acp = try @import("../file.zig").readAlloc(gpa, "config/plugins/acp.js");
    defer gpa.free(acp);
    const src = try std.fmt.allocPrint(gpa,
        \\{s}
        \\weft.command("start-a", () => startAgent("/bin/sh {s}", "hi", "claude"));
        \\weft.command("start-b", () => startAgent("/bin/sh {s}", "hi", "codex"));
    , .{ acp, mocks[0], mocks[1] });
    defer gpa.free(src);

    try env.grant("test", "proc");
    // …and `fs_write`, which the mocks' `fs/write_text_file` step needs: the
    // shared-file assertion below (both sub-peers authored it) is only
    // reachable through that door, and the door is possession-gated.
    try env.grant("test", "fs_write");
    // Two live agents pin two reader tasks (each mock BLOCKS on stdin waiting
    // for its own answer), so the shared fixture's single-thread pool would
    // starve the second spawn — concurrency here is the subject, not scenery.
    const pool = try task.Pool.init(gpa, .{ .threads = 4 });
    defer pool.deinit();
    var plugin = try JsPlugin.load(gpa, &engine, &env.ctx, pool, .empty, "test", null, src);
    defer plugin.deinit();
    // A bail with a request still open must not leave the head's pick session
    // live — teardown asserts every acceptor was answered.
    defer if (env.head.pick.active) {
        _ = command.run(&env.commands, &env.ctx, "pick-cancel", &.{}) catch {};
    };

    const H = struct {
        fn text(e: *Env, gpa2: Allocator, name: []const u8) ?[]u8 {
            var it = e.buffers.iterator();
            while (it.next()) |b| {
                if (!std.mem.eql(u8, b.name, name)) continue;
                const ed = b.textEditor() orelse return null;
                return ed.text().toOwnedSlice(gpa2) catch null;
            }
            return null;
        }
        /// Tick the plugin until `name`'s buffer contains `needle`.
        fn until(p: *JsPlugin, e: *Env, gpa2: Allocator, name: []const u8, needle: []const u8) bool {
            const deadline = task.nowNs() + 5 * std.time.ns_per_s;
            while (task.nowNs() < deadline) {
                _ = p.tick();
                if (text(e, gpa2, name)) |txt| {
                    defer gpa2.free(txt);
                    if (std.mem.indexOf(u8, txt, needle) != null) return true;
                }
                std.Thread.yield() catch {};
            }
            return false;
        }
        /// Tick until the head's picker opens. Bounded: a pick that never
        /// arrives is a failure, never a hung run.
        fn untilPick(p: *JsPlugin, e: *Env) bool {
            const deadline = task.nowNs() + 5 * std.time.ns_per_s;
            while (task.nowNs() < deadline) {
                if (e.head.pick.active) return true;
                _ = p.tick();
                std.Thread.yield() catch {};
            }
            return false;
        }
        /// Tick until BOTH named sub-peers have authored on `doc`. Bounded,
        /// like every other wait here.
        ///
        /// A transcript line and an edit on the shared file are two DIFFERENT
        /// events: waiting for "beta one" to appear in agent two's buffer says
        /// nothing about whether agent two's write has been applied yet. This
        /// test used to read `doc.peers` straight after the transcript wait and
        /// was therefore racing — rarely, and only under load, `codex#2` had
        /// not arrived and the run failed on a real editor that was working
        /// correctly.
        fn untilPeers(p: *JsPlugin, doc: anytype, a: []const u8, b: []const u8) bool {
            const deadline = task.nowNs() + 5 * std.time.ns_per_s;
            while (task.nowNs() < deadline) {
                var seen_a = false;
                var seen_b = false;
                for (doc.peers.items) |slot| {
                    const peer = slot orelse continue;
                    if (std.mem.eql(u8, peer.name, a)) seen_a = true;
                    if (std.mem.eql(u8, peer.name, b)) seen_b = true;
                }
                if (seen_a and seen_b) return true;
                _ = p.tick();
                std.Thread.yield() catch {};
            }
            return false;
        }
        /// Tick for a bounded stretch, asserting `needle` never shows up.
        fn absent(p: *JsPlugin, e: *Env, gpa2: Allocator, name: []const u8, needle: []const u8) bool {
            const deadline = task.nowNs() + 300 * std.time.ns_per_ms;
            while (task.nowNs() < deadline) {
                _ = p.tick();
                if (text(e, gpa2, name)) |txt| {
                    defer gpa2.free(txt);
                    if (std.mem.indexOf(u8, txt, needle) != null) return false;
                }
                std.Thread.yield() catch {};
            }
            return true;
        }
    };

    // Agent one: its own transcript instance, and its permission pick opens
    // (from the BACKGROUND output handler, through the nested-run door).
    _ = try command.run(&env.commands, &env.ctx, "start-a", &.{});
    try t.expect(H.until(plugin, &env, gpa, "*agent*", "alpha one"));
    try t.expect(H.untilPick(plugin, &env));

    // Agent two: a SECOND instance — its own buffer, its own model. Its
    // permission request queues behind agent one's open pick.
    _ = try command.run(&env.commands, &env.ctx, "start-b", &.{});
    try t.expect(H.until(plugin, &env, gpa, "*agent:2*", "beta one"));

    // Interleaved updates landed in the right transcripts, both directions.
    {
        const a = H.text(&env, gpa, "*agent*").?;
        defer gpa.free(a);
        const b = H.text(&env, gpa, "*agent:2*").?;
        defer gpa.free(b);
        try t.expect(std.mem.indexOf(u8, a, "beta") == null);
        try t.expect(std.mem.indexOf(u8, b, "alpha") == null);
    }
    // Two conversations, two models — not one doc with two views.
    try t.expectEqual(@as(usize, 2), plugin.conversations.items.len);
    try t.expect(plugin.conversation("*agent*") != plugin.conversation("*agent:2*"));

    // Each agent's edit authors as its OWN sub-peer, so selective undo can
    // separate claude#1 from codex#2 on the file they both wrote.
    {
        const id = env.buffers.findByPath(shared) orelse return error.NoAgentBuffer;
        const doc = &env.buffers.get(id).?.textEditor().?.doc;
        try t.expect(H.untilPeers(plugin, doc, "claude#1", "codex#2"));
    }

    // Answer the OPEN pick — agent one's. Only agent one unblocks: agent two
    // is still waiting for the answer to ITS own tool call.
    _ = try command.run(&env.commands, &env.ctx, "pick-accept", &.{});
    try t.expect(H.until(plugin, &env, gpa, "*agent*", "alpha ack"));
    try t.expect(H.absent(plugin, &env, gpa, "*agent:2*", "beta ack"));

    // Agent two's queued request opened on the freed head; answering IT
    // resolves ITS call, and its ack lands in ITS transcript.
    try t.expect(env.head.pick.active);
    _ = try command.run(&env.commands, &env.ctx, "pick-accept", &.{});
    try t.expect(H.until(plugin, &env, gpa, "*agent:2*", "beta ack"));
    {
        const a = H.text(&env, gpa, "*agent*").?;
        defer gpa.free(a);
        try t.expect(std.mem.indexOf(u8, a, "beta ack") == null);
    }
}
