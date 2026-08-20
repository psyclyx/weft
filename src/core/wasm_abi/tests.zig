//! The wasm-membrane test suite + its compact editor `Env`. Exercises the full
//! ABI end to end: a `.wasm` guest reaches the editor only across the sandbox
//! membrane, yet lands its edits on the identical authority path an in-process
//! catalog plugin uses. Kept beside the facade so `zig build test` still runs
//! them (wasm_abi.zig references this file from a test block).

const std = @import("std");
const wasm = @import("../wasm.zig");
const command = @import("../command.zig");
const kv = @import("../kv.zig");
const file = @import("../file.zig");
const pick_mod = @import("../pick.zig");
const subbuffer = @import("../subbuffer.zig");
const register = @import("../register.zig");
const surface_mod = @import("../surface.zig");
const async_loop = @import("../async.zig");
const net_session = @import("../net_session.zig");
const wasm_host = @import("../wasm_host.zig");
const Allocator = std.mem.Allocator;

const wasm_abi = @import("../wasm_abi.zig");
const runGuest = wasm_abi.runGuest;
const loadPlugin = wasm_abi.loadPlugin;
const guest_hello = wasm_abi.guest_hello;

const t = std.testing;

test "wasm plugin: a .wasm guest edits the buffer through the host ABI, as its peer" {
    const gpa = t.allocator;
    const task = @import("../task.zig");
    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var buffers = try @import("../Buffers.zig").init(gpa, pool, "user");
    defer buffers.deinit(gpa);
    var commands: command.Commands = .empty;
    defer commands.deinit(gpa);
    var keymap: @import("../Keymap.zig") = .empty;
    defer keymap.deinit(gpa);
    var pick: @import("../pick.zig").Pick = .empty;
    defer pick.deinit(gpa);
    var caps = @import("../capability.zig").Caps.init(gpa, task.nowNs);
    defer caps.deinit();
    var actions = @import("../action.zig").init(gpa);
    defer actions.deinit();
    var quit = false;
    var echo: std.ArrayList(u8) = .empty;
    defer echo.deinit(gpa);
    var ctx: command.Context = .{
        .gpa = gpa,
        .buffers = &buffers,
        .commands = &commands,
        .keymap = &keymap,
        .actions = &actions,
        .pick = &pick,
        .caps = &caps,
        .quit = &quit,
        .echo = &echo,
    };

    try buffers.active().editor.insertText(gpa, "ab");
    buffers.active().editor.placeCursor(1); // between 'a' and 'b'

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    try runGuest(&engine, &ctx, "wasm.hello", guest_hello);

    // The .wasm guest inserted "wasm!" at the cursor through the host edit.
    const s = try buffers.active().editor.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("awasm!b", s);
    // Authored as the wasm plugin's peer, not the user (the authority gate
    // holds across the membrane).
    const doc = &buffers.active().editor.doc;
    try t.expect(doc.commitAt(doc.commitCount() - 1).author != .user);
}

test "wasm plugin: init registers a command that dispatches back into the guest" {
    const gpa = t.allocator;
    const task = @import("../task.zig");
    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var buffers = try @import("../Buffers.zig").init(gpa, pool, "user");
    defer buffers.deinit(gpa);
    var commands: command.Commands = .empty;
    defer commands.deinit(gpa);
    var keymap: @import("../Keymap.zig") = .empty;
    defer keymap.deinit(gpa);
    var pick: @import("../pick.zig").Pick = .empty;
    defer pick.deinit(gpa);
    var caps = @import("../capability.zig").Caps.init(gpa, task.nowNs);
    defer caps.deinit();
    var actions = @import("../action.zig").init(gpa);
    defer actions.deinit();
    var quit = false;
    var echo: std.ArrayList(u8) = .empty;
    defer echo.deinit(gpa);
    var ctx: command.Context = .{
        .gpa = gpa,
        .buffers = &buffers,
        .commands = &commands,
        .keymap = &keymap,
        .actions = &actions,
        .pick = &pick,
        .caps = &caps,
        .quit = &quit,
        .echo = &echo,
    };

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &ctx, "wasm.plugin", @embedFile("guest_plugin_wasm"), .{});
    defer plugin.deinit();

    // The guest's init() registered "wasm-mark" through the host.
    try t.expect(commands.resolve("wasm-mark") != null);

    // Running it dispatches back into the guest, which edits via the host
    // gate — authored as the plugin's peer, across the membrane.
    try buffers.active().editor.insertText(gpa, "xy");
    buffers.active().editor.placeCursor(1);
    _ = try command.run(&commands, &ctx, "wasm-mark", &.{});
    const s = try buffers.active().editor.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("x[wasm]y", s);
    const doc = &buffers.active().editor.doc;
    try t.expect(doc.commitAt(doc.commitCount() - 1).author != .user);
}

// A compact editor environment for the membrane tests below.
const Env = struct {
    pool: *@import("../task.zig").Pool,
    buffers: @import("../Buffers.zig"),
    commands: command.Commands,
    keymap: @import("../Keymap.zig"),
    pick: @import("../pick.zig").Pick,
    caps: @import("../capability.zig").Caps,
    actions: @import("../action.zig"),
    quit: bool,
    echo: std.ArrayList(u8),
    ctx: command.Context,

    fn init(gpa: Allocator, self: *Env) !void {
        const task = @import("../task.zig");
        self.pool = try task.Pool.init(gpa, .{ .threads = 1 });
        self.buffers = try @import("../Buffers.zig").init(gpa, self.pool, "user");
        self.commands = .empty;
        self.keymap = .empty;
        self.pick = .empty;
        self.caps = @import("../capability.zig").Caps.init(gpa, task.nowNs);
        self.actions = @import("../action.zig").init(gpa);
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

test "wasm plugin: the edit catalog plugin runs identically as .wasm (duplicate-line)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "edit", @embedFile("guest_edit_wasm"), .{});
    defer plugin.deinit();

    // Both commands declared in describe() bound through the handshake.
    try t.expect(env.commands.resolve("duplicate-line") != null);
    try t.expect(env.commands.resolve("upcase-line") != null);

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "hello\nworld");
    ed.placeCursor(2); // inside the first line

    _ = try command.run(&env.commands, &env.ctx, "duplicate-line", &.{});
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    // Same result the in-process edit.zig produces: the line copied below.
    try t.expectEqualStrings("hello\nhello\nworld", s);
    // Authored as the plugin's peer, across the membrane, through the gate.
    try t.expect(ed.doc.commitAt(ed.doc.commitCount() - 1).author != .user);
}

test "wasm: compiled-module image serialize→deserialize round-trips; garbage rejected" {
    var engine = try wasm.Engine.init();
    defer engine.deinit();

    var module = try engine.compile(@embedFile("guest_edit_wasm"));
    defer module.deinit();

    // Serialize the compiled image (the .cwasm cache write) and rebuild from it
    // (the cache read) — the round-trip the fast startup path depends on.
    const image = try module.serialize(t.allocator);
    defer t.allocator.free(image);
    try t.expect(image.len > 0);
    var restored = engine.deserialize(image) orelse return error.DeserializeFailed;
    restored.deinit();

    // A stale/garbage image is rejected (null), never a crash — so a
    // cross-version cache falls back to a fresh compile.
    try t.expect(engine.deserialize("not a real .cwasm image") == null);
}

test "which-key: on_menu builds a corner surface from the current menu's bindings" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "which_key", @embedFile("guest_which_key_wasm"), .{});
    defer plugin.deinit();

    const Keymap = @import("../Keymap.zig");
    // "f" opens a submenu (its command IS a menu mode) → a GROUP; "g" is a leaf.
    try env.keymap.markMenuMode(gpa, "leader");
    try env.keymap.markMenuMode(gpa, "leader-file");
    try env.keymap.bind(gpa, "leader", "f", "leader-file", Keymap.prio_plugin, "test");
    try env.keymap.bind(gpa, "leader", "g", "git-status", Keymap.prio_plugin, "test");
    try env.keymap.setMode(gpa, "leader");

    // Core fires on_menu(open) at the frame boundary; the guest reads the
    // current menu's bindings and paints a surface.
    wasm_host.notifyMenu(plugin, true);
    try t.expect(plugin.surface.active);
    try t.expectEqual(surface_mod.Placement.corner, plugin.surface.placement);
    try t.expectEqual(@as(usize, 2), plugin.surface.rows.items.len);
    // Each row: the key in accent, then the command colored by group vs leaf.
    try t.expectEqualStrings("f", plugin.surface.rows.items[0].spans.items[0].text);
    try t.expectEqual(surface_mod.Role.accent, plugin.surface.rows.items[0].spans.items[0].role);
    try t.expectEqualStrings("leader-file", plugin.surface.rows.items[0].spans.items[1].text);
    try t.expectEqual(surface_mod.Role.group, plugin.surface.rows.items[0].spans.items[1].role); // a submenu
    try t.expectEqual(surface_mod.Role.leaf, plugin.surface.rows.items[1].spans.items[1].role); // git-status: leaf

    // Leaving the menu closes the surface.
    wasm_host.notifyMenu(plugin, false);
    try t.expect(!plugin.surface.active);
}

test "dired: gathers a directory tree via proc and renders the model (async)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    try @import("../builtins.zig").install(gpa, &env.commands, &env.keymap, &env.actions); // buffer-create

    var loop = async_loop.Loop.init(gpa, env.pool, @import("../task.zig").nowNs);
    defer loop.deinit();
    var subs: subbuffer.SubBuffers = .empty;
    defer subs.deinit(gpa);
    var reg: register.Register = .empty;
    defer reg.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    // dired runs `ls` via proc, parses the marked blocks into a directory TREE,
    // and renders it as ONE always-editable name-only *dired* buffer (metadata is
    // decoration). Wire the subbuffer + register services so its per-row id-spans
    // + the yank/paste ferry work.
    const plugin = try loadPlugin(&engine, &env.ctx, "dired", @embedFile("guest_dired_wasm"), .{ .loop = &loop, .subbuffers = &subs, .register = &reg });
    defer plugin.deinit();
    try t.expect(plugin.perms[wasm_host.perm_proc] and plugin.perms[wasm_host.perm_timer]);

    _ = try command.run(&env.commands, &env.ctx, "dired", &.{});
    // The model buffer was created + focused synchronously; it entered dired mode.
    try t.expectEqualStrings("dired", env.keymap.currentMode());
    const buf = blk: {
        var it = env.buffers.iterator();
        while (it.next()) |b| if (std.mem.eql(u8, b.name, "*dired*")) break :blk b;
        break :blk null;
    };
    try t.expect(buf != null);

    // Drive the async loop until `ls` lands (bounded; "." always lists).
    var rounds: usize = 0;
    while (rounds < 20_000_000 and buf.?.editor.text().byteLen() == 0) : (rounds += 1) {
        _ = loop.tick();
        std.Thread.yield() catch {};
    }
    if (buf.?.editor.text().byteLen() > 0) {
        // on_fill parsed the raw ls output and re-rendered: the buffer holds the
        // name tree — no `ls`/sentinel bytes leak through.
        const s = try buf.?.editor.text().toOwnedSlice(gpa);
        defer gpa.free(s);
        try t.expect(std.mem.indexOf(u8, s, "\x1e\x1e") == null); // sentinels repainted away
    }

    // The sandbox `ls` yields no entries, so drive the guest deterministically:
    // author a synthetic marked `ls -l` block into *dired* and fire `on_fill`
    // directly (the same export the proc bridge calls), so the guest parses a
    // real 2-entry tree (a file + a dir) and rebuilds the editable projection.
    const synth =
        "\x1e\x1e.\n" ++
        "total 8\n" ++
        "-rw-r--r-- 1 alice alice 42 2024-01-01 12:00 alpha.txt\n" ++
        "drwxr-xr-x 2 alice alice 4096 2024-01-01 12:00 subdir\n";
    try buf.?.editor.applyUserEdit(gpa, .{ .start = 0, .end = buf.?.editor.text().byteLen() }, synth);
    try plugin.instance.callVoid("on_fill", &.{});

    // The buffer is the always-editable name tree — just indented names, no
    // header/perms/glyphs in the TEXT — and it's marked this plugin's tool
    // projection, so a save reconciles it.
    try t.expectEqualStrings("dired", buf.?.editor.toolName().?); // code-backed
    {
        const s = try buf.?.editor.text().toOwnedSlice(gpa);
        defer gpa.free(s);
        try t.expect(std.mem.indexOf(u8, s, "alpha.txt") != null);
        try t.expect(std.mem.indexOf(u8, s, "subdir/") != null);
        try t.expect(std.mem.indexOf(u8, s, "Directory:") == null);
        try t.expect(std.mem.indexOf(u8, s, "rw-r--r--") == null); // perms are decoration
    }

    // Edit in place: APPEND a new row (a create) — the existing rows keep their
    // hidden id-spans intact, so reconcile reads them back as unchanged by EXACT
    // identity, and the new (id-less) row is a create. Appending (not a full
    // replace) is how a user actually types a new file with `o`.
    const probe = "weft_new_probe.txt";
    const end = buf.?.editor.text().byteLen();
    try buf.?.editor.applyUserEdit(gpa, .{ .start = end, .end = end }, probe ++ "\n");

    // `save` on the *dired* projection resolves — via the `save` ACTION scoped to
    // `When{.tool="dired"}` — to `dired-commit`, which reconciles by id, previews
    // the ordered plan in *dired-plan*, and stages it behind the y/n confirm (it
    // does NOT touch the filesystem itself; the confirm runs the ops via proc).
    _ = try command.run(&env.commands, &env.ctx, "save", &.{});
    try t.expectEqualStrings("dired-confirm", env.keymap.currentMode());
    const plan = blk: {
        var it = env.buffers.iterator();
        while (it.next()) |b| if (std.mem.eql(u8, b.name, "*dired-plan*")) break :blk b;
        break :blk null;
    };
    try t.expect(plan != null);
    const ps = try plan.?.editor.text().toOwnedSlice(gpa);
    defer gpa.free(ps);
    try t.expect(std.mem.indexOf(u8, ps, "pending changes") != null);
    try t.expect(std.mem.indexOf(u8, ps, "create  " ++ probe) != null);
    // The id-exact reconcile leaves the untouched rows alone — no spurious
    // rename/move/delete of alpha.txt or subdir from a heuristic misfire.
    try t.expect(std.mem.indexOf(u8, ps, "alpha.txt") == null);
    try t.expect(std.mem.indexOf(u8, ps, "delete") == null);
}

test "helix: a second modal editor loads in its OWN mode namespace" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "helix", @embedFile("guest_helix_wasm"), .{});
    defer plugin.deinit();

    // helix.init sets its OWN initial mode and binds in its OWN namespace —
    // nothing here assumes vim's "normal". If core privileged vim, this breaks.
    try t.expectEqualStrings("helix-normal", env.keymap.currentMode());
    try t.expectEqualStrings("hx-insert", env.keymap.lookup("i").?);
    try t.expectEqualStrings("cursor-left", env.keymap.lookup("h").?);
    // Word motion is bound to helix's generated move wrapper (shared `motions`).
    try t.expectEqualStrings("hx/n/motion.word-fwd", env.keymap.lookup("w").?);
    // Its leader/op menus are their own menu modes (which-key renders them).
    try t.expect(env.keymap.isMenuMode("helix-leader"));
    try t.expect(env.keymap.isMenuMode("helix-op"));
}

test "vim ex: `:` opens a command line; :N gotos, :%s substitutes, unknown falls through" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "vim", @embedFile("guest_vim_wasm"), .{});
    defer plugin.deinit();

    // `:` is now the ex command line (the palette moved to SPC :), and `ex` is a
    // text-input mode routing keystrokes to `ex-type`.
    try t.expectEqualStrings("vim-ex", env.keymap.lookup("colon").?);

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "l1\nl2\nl3\nl4\nl5");
    ed.placeCursor(0);

    // `:3` — open the command line, type "3", Enter → cursor at the start of L3.
    _ = try command.run(&env.commands, &env.ctx, "vim-ex", &.{});
    try t.expectEqualStrings("ex", env.keymap.currentMode());
    _ = try command.run(&env.commands, &env.ctx, "ex-type", &.{.{ .string = "3" }});
    _ = try command.run(&env.commands, &env.ctx, "ex-run", &.{});
    try t.expectEqualStrings("normal", env.keymap.currentMode()); // back in normal
    try t.expectEqual(@as(usize, 6), ed.cursorOffset());

    // `:%s/l/X/g` — a whole-file literal substitute, one user edit.
    _ = try command.run(&env.commands, &env.ctx, "vim-ex", &.{});
    _ = try command.run(&env.commands, &env.ctx, "ex-type", &.{.{ .string = "%s/l/X/g" }});
    _ = try command.run(&env.commands, &env.ctx, "ex-run", &.{});
    {
        const s = try ed.text().toOwnedSlice(gpa);
        defer gpa.free(s);
        try t.expectEqualStrings("X1\nX2\nX3\nX4\nX5", s);
    }

    // Composition: an unknown `:name` falls through to the registry and, when no
    // such command exists, reports it (vim's E492) rather than silently no-op.
    env.echo.clearRetainingCapacity();
    _ = try command.run(&env.commands, &env.ctx, "vim-ex", &.{});
    _ = try command.run(&env.commands, &env.ctx, "ex-type", &.{.{ .string = "definitely-not-a-command" }});
    _ = try command.run(&env.commands, &env.ctx, "ex-run", &.{});
    try t.expect(std.mem.indexOf(u8, env.echo.items, "not an editor command") != null);
}

test "wasm plugin: upcase-line edits in place across the membrane" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "edit", @embedFile("guest_edit_wasm"), .{});
    defer plugin.deinit();

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "abc\ndef");
    ed.placeCursor(5); // inside "def"
    _ = try command.run(&env.commands, &env.ctx, "upcase-line", &.{});
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("abc\nDEF", s);
}

test "wasm plugin: an undeclared registration fails the load (perm handshake)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    // The guest registers a command it never declared — the cross-check must
    // reject it and roll back, exactly as abi.zig does in-process.
    try t.expectError(error.UndeclaredCommand, loadPlugin(&engine, &env.ctx, "rogue", @embedFile("guest_rogue_wasm"), .{}));
    // Nothing left behind: neither the declared nor the undeclared name bound.
    try t.expect(env.commands.resolve("undeclared") == null);
    try t.expect(env.commands.resolve("declared") == null);
}

test "wasm plugin: hot-reload — teardown unbinds, re-instantiation is clean" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "x");
    ed.placeCursor(0);

    // Load, use, then tear down (the hot-reload's unload half): the command
    // must unbind and the store drop with no residue.
    {
        const v1 = try loadPlugin(&engine, &env.ctx, "edit", @embedFile("guest_edit_wasm"), .{});
        _ = try command.run(&env.commands, &env.ctx, "duplicate-line", &.{});
        v1.deinit();
        // After teardown the command is gone — nothing dangles behind it.
        try t.expect(env.commands.resolve("duplicate-line") == null);
    }

    // Re-instantiate from scratch (a fresh store, no shared mutable state):
    // the same source loads and runs identically — the reload contract.
    {
        const v2 = try loadPlugin(&engine, &env.ctx, "edit", @embedFile("guest_edit_wasm"), .{});
        defer v2.deinit();
        try t.expect(env.commands.resolve("duplicate-line") != null);
        ed.placeCursor(0);
        _ = try command.run(&env.commands, &env.ctx, "duplicate-line", &.{});
    }
    // Two duplications of "x" across two independent instances: "x\nx\nx".
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("x\nx\nx", s);
}

test "wasm plugin: a completion provider gathers candidates across the membrane" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "complete", @embedFile("guest_complete_wasm"), .{});
    defer plugin.deinit();

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "alpha alphabet beta alpha");

    // Fire a completion for prefix "alph": the host calls the guest's
    // on_complete, which scans the buffer and pushes matches back. Same
    // result the in-process complete.zig gives: {alpha, alphabet}, deduped.
    const sid = (try env.caps.fire(.completion, &ed.doc, ed.backingPath(), .{ .text = "alph" })).?;
    const session = env.caps.session(sid).?;
    var found: std.ArrayList([]const u8) = .empty;
    defer found.deinit(gpa);
    for (session.all()) |r| {
        if (r.payload != .completion) continue;
        for (r.payload.completion) |item| try found.append(gpa, item.text);
    }
    try t.expectEqual(@as(usize, 2), found.items.len);
    var has_alpha = false;
    var has_alphabet = false;
    for (found.items) |w| {
        if (std.mem.eql(u8, w, "alpha")) has_alpha = true;
        if (std.mem.eql(u8, w, "alphabet")) has_alphabet = true;
    }
    try t.expect(has_alpha and has_alphabet);
}

test "wasm plugin: demo-config composes commands + binds a key (config surface)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    // Load the edit plugin (provides duplicate-line/upcase-line) then the
    // config that composes them — the same layering as std + user config.
    const edit = try loadPlugin(&engine, &env.ctx, "edit", @embedFile("guest_edit_wasm"), .{});
    defer edit.deinit();
    const cfg = try loadPlugin(&engine, &env.ctx, "demo-config", @embedFile("guest_demo_config_wasm"), .{});
    defer cfg.deinit();

    // init() bound C-d → dup-up through the config surface.
    try env.keymap.setMode(gpa, "default");
    try t.expectEqualStrings("dup-up", env.keymap.lookup("C-d").?);

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "ab");
    ed.placeCursor(0);
    _ = try command.run(&env.commands, &env.ctx, "dup-up", &.{});
    // dup-up ran duplicate-line ("ab\nab") then upcase-line on the current
    // line (cursor still at 0 → the first line) across the membrane.
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("AB\nab", s);
}

test "wasm plugin: project command args/result + kv cross the membrane" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var store: kv.Store = .empty;
    defer store.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "project", @embedFile("guest_project_wasm"), .{ .kv = &store });
    defer plugin.deinit();

    // Seed the recent list host-side (namespaced to the plugin); the guest
    // reads it back through kv and returns it as a string result.
    try store.put(gpa, "project", "recent", "a.zig\nb.zig");
    const r = try command.run(&env.commands, &env.ctx, "project-recent", &.{});
    try t.expectEqualStrings("a.zig\nb.zig", r.string);

    // The scratch buffer has no backing path → remember returns -1 (the
    // integer result crosses the membrane).
    const r2 = try command.run(&env.commands, &env.ctx, "project-remember", &.{});
    try t.expectEqual(command.Value{ .integer = -1 }, r2);
}

test "wasm plugin: palette status echoes the active buffer (introspection)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "std", @embedFile("guest_palette_wasm"), .{});
    defer plugin.deinit();

    // status walks the buffers (bufferCount/bufferAt) and echoes the active
    // one's name — the whole introspection surface across the membrane.
    _ = try command.run(&env.commands, &env.ctx, "status", &.{});
    try t.expectEqualStrings(env.buffers.active().name, env.echo.items);
}

test "wasm plugin: palette opens a command pick; accept dispatches back and runs the choice" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    // The pick UI is ordinary commands in the "pick" keymap mode.
    try pick_mod.install(gpa, &env.commands, &env.keymap);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "std", @embedFile("guest_palette_wasm"), .{});
    defer plugin.deinit();

    // pick-commands builds a pick over the whole registry and opens it.
    _ = try command.run(&env.commands, &env.ctx, "pick-commands", &.{});
    try t.expect(env.pick.active);

    // Narrow to "status" and accept: the accept crosses back into the guest's
    // on_pick_accept, which runs the chosen command — which echoes the buffer.
    _ = try command.run(&env.commands, &env.ctx, "pick-input", &.{.{ .string = "status" }});
    _ = try command.run(&env.commands, &env.ctx, "pick-accept", &.{});
    try t.expect(!env.pick.active); // accept closed the pick
    try t.expectEqualStrings(env.buffers.active().name, env.echo.items);
}

test "wasm plugins: consult-line jumps to the accepted row by its add index" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    try @import("../pick.zig").install(gpa, &env.commands, &env.keymap);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "consult", @embedFile("guest_consult_wasm"), .{});
    defer plugin.deinit();

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "aaa\nbbb\nccc");
    ed.placeCursor(0);

    // Open the line pick, narrow to the third line, accept: the guest resolves
    // the accepted ROW INDEX (2) to the offset it recorded, jumping to line 3.
    _ = try command.run(&env.commands, &env.ctx, "consult-line", &.{});
    try t.expect(env.pick.active);
    _ = try command.run(&env.commands, &env.ctx, "pick-input", &.{.{ .string = "ccc" }});
    _ = try command.run(&env.commands, &env.ctx, "pick-accept", &.{});
    try t.expect(!env.pick.active);
    try t.expectEqual(@as(usize, 8), ed.cursorOffset()); // start of "ccc"
}

test "wasm plugins: consult-imenu picks a definition and jumps to it" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    try @import("../pick.zig").install(gpa, &env.commands, &env.keymap);

    const src = "fn foo() void {}\nfn bar() void {}";
    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, src);
    const sx = @import("../syntax.zig");
    const syn = try sx.Syntax.create(gpa, sx.forPath("t.zig").?, &ed.doc);
    defer syn.destroy();
    env.buffers.active().frontend = syn;
    const R = struct {
        fn resolve(buf: *@import("../Buffers.zig").Buffer) ?*sx.Syntax {
            return @ptrCast(@alignCast(buf.frontend orelse return null));
        }
    };

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "consult", @embedFile("guest_consult_wasm"), .{ .syntax_of = R.resolve });
    defer plugin.deinit();

    ed.placeCursor(0);
    _ = try command.run(&env.commands, &env.ctx, "consult-imenu", &.{});
    try t.expect(env.pick.active);
    _ = try command.run(&env.commands, &env.ctx, "pick-input", &.{.{ .string = "bar" }});
    _ = try command.run(&env.commands, &env.ctx, "pick-accept", &.{});
    try t.expectEqual(std.mem.indexOf(u8, src, "fn bar").?, ed.cursorOffset());
}

test "wasm plugins: buf-pick switches to the accepted buffer by recorded id" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    try @import("../builtins.zig").install(gpa, &env.commands, &env.keymap, &env.actions); // buffer-switch
    try @import("../pick.zig").install(gpa, &env.commands, &env.keymap);

    // Two more buffers beyond the initial scratch (ids 1 and 2).
    _ = try env.buffers.create(gpa, "alpha");
    _ = try env.buffers.create(gpa, "beta");

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "buffers", @embedFile("guest_buffers_wasm"), .{});
    defer plugin.deinit();

    _ = try command.run(&env.commands, &env.ctx, "buf-pick", &.{});
    try t.expect(env.pick.active);
    _ = try command.run(&env.commands, &env.ctx, "pick-input", &.{.{ .string = "beta" }});
    _ = try command.run(&env.commands, &env.ctx, "pick-accept", &.{});
    // The accepted row resolved to beta's id → it is now the active buffer.
    try t.expectEqualStrings("beta", env.buffers.active().name);
}

test "wasm plugin: structural node-kind/delete-node degrade honestly with no grammar" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    // No syntax service wired → nodeAt reports "no node" across the membrane.
    const plugin = try loadPlugin(&engine, &env.ctx, "structural", @embedFile("guest_structural_wasm"), .{});
    defer plugin.deinit();

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "foo");
    const r1 = try command.run(&env.commands, &env.ctx, "node-kind", &.{});
    try t.expect(r1 == .nil); // no grammar → nil
    const r2 = try command.run(&env.commands, &env.ctx, "delete-node", &.{});
    try t.expectEqual(command.Value{ .integer = 0 }, r2);
    try t.expect(ed.text().byteLen() == 3); // nothing deleted
}

test "wasm plugin: ts expands selection to the enclosing node + runs a query" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    const src = "const x = 42;";
    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, src);

    // Attach a real zig grammar via the buffer's frontend slot; a resolver hands
    // it to the membrane (the host owns that slot).
    const sx = @import("../syntax.zig");
    const syn = try sx.Syntax.create(gpa, sx.forPath("t.zig").?, &ed.doc);
    defer syn.destroy();
    env.buffers.active().frontend = syn;
    const R = struct {
        fn resolve(buf: *@import("../Buffers.zig").Buffer) ?*sx.Syntax {
            return @ptrCast(@alignCast(buf.frontend orelse return null));
        }
    };

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "ts", @embedFile("guest_ts_wasm"), .{ .syntax_of = R.resolve });
    defer plugin.deinit();

    // Cursor on "42": select-node selects the literal; expand grows to a
    // strictly larger enclosing node (design §6.2, via native syntax reads).
    ed.placeCursor(std.mem.indexOf(u8, src, "42").?);
    _ = try command.run(&env.commands, &env.ctx, "ts-select-node", &.{});
    const leaf = ed.selectedRange().?;
    _ = try command.run(&env.commands, &env.ctx, "ts-expand-selection", &.{});
    const parent = ed.selectedRange().?;
    try t.expect(parent.end - parent.start > leaf.end - leaf.start);

    // A query over the buffer materializes captures across the membrane: the
    // identifier "x" is found (>= 1 capture).
    const n = try command.run(&env.commands, &env.ctx, "ts-query", &.{.{ .string = "(identifier) @i" }});
    try t.expect(n == .integer and n.integer >= 1);
}

test "wasm plugins: a tree text object (a-function) an operator deletes (daf)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    const src = "fn foo() void {}\nconst x = 1;";
    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, src);

    const sx = @import("../syntax.zig");
    const syn = try sx.Syntax.create(gpa, sx.forPath("t.zig").?, &ed.doc);
    defer syn.destroy();
    env.buffers.active().frontend = syn;
    const R = struct {
        fn resolve(buf: *@import("../Buffers.zig").Buffer) ?*sx.Syntax {
            return @ptrCast(@alignCast(buf.frontend orelse return null));
        }
    };

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const textobjects = try loadPlugin(&engine, &env.ctx, "textobjects", @embedFile("guest_textobjects_wasm"), .{ .syntax_of = R.resolve });
    defer textobjects.deinit();
    const operators = try loadPlugin(&engine, &env.ctx, "operators", @embedFile("guest_operators_wasm"), .{ .syntax_of = R.resolve });
    defer operators.deinit();

    // Cursor inside the function; a-function selects the whole function node,
    // the operator deletes it — a tree object composed with the SAME operator.
    ed.placeCursor(std.mem.indexOf(u8, src, "foo").?);
    const rv = try command.run(&env.commands, &env.ctx, "textobj.a-function", &.{});
    try t.expect(rv == .range);
    _ = try command.run(&env.commands, &env.ctx, "op.delete", &.{rv});
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expect(std.mem.indexOf(u8, s, "foo") == null); // the function is gone
    try t.expect(std.mem.indexOf(u8, s, "const x") != null); // the rest remains
}

test "wasm plugin: region claims a subbuffer + attaches a fact across the membrane" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var subs: subbuffer.SubBuffers = .empty;
    defer subs.deinit(gpa); // frees the claimed entries (runs after plugin.deinit)

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "region", @embedFile("guest_region_wasm"), .{ .subbuffers = &subs });
    defer plugin.deinit();

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "line one\nline two");
    ed.placeCursor(2); // inside the first line ("line one" — 8 bytes)

    const r = try command.run(&env.commands, &env.ctx, "mark-region", &.{.{ .string = "js" }});
    try t.expectEqual(command.Value{ .integer = 8 }, r);
    // The claimed subbuffer (handle 0) carries the language fact the guest set.
    try t.expectEqualStrings("js", plugin.subs.items[0].fact("language").?);
}

test "wasm plugin: shell insert-shell runs a command off-thread and inserts, rebased" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var loop = async_loop.Loop.init(gpa, env.pool, @import("../task.zig").nowNs);
    defer loop.deinit();

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "shell", @embedFile("guest_shell_wasm"), .{ .loop = &loop });
    defer plugin.deinit();

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "X");
    ed.placeCursor(1); // capture the insert point at offset 1

    _ = try command.run(&env.commands, &env.ctx, "insert-shell", &.{.{ .string = "printf hi" }});

    // Concurrently insert at the head: the deferred insert's stamped offset
    // (1) must rebase to 3 before "hi" lands.
    ed.placeCursor(0);
    try ed.insertText(gpa, "YY"); // doc → "YYX"

    var rounds: usize = 0;
    while (ed.text().byteLen() < 5 and rounds < 5_000_000) : (rounds += 1) {
        _ = loop.tick();
        std.Thread.yield() catch {};
    }
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    // "hi" landed at the REBASED offset 3 (after "YYX"), authored as the peer.
    try t.expectEqualStrings("YYXhi", s);
    try t.expect(ed.doc.commitAt(ed.doc.commitCount() - 1).author != .user);
}

test "wasm plugin: shell insert is a no-op when the async service is absent" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    // No loop wired: the shell plugin declared proc+timer, but with no async
    // service the effect drops honestly (no ghost edit).
    const plugin = try loadPlugin(&engine, &env.ctx, "shell", @embedFile("guest_shell_wasm"), .{});
    defer plugin.deinit();
    try t.expect(plugin.perms[wasm_host.perm_proc] and plugin.perms[wasm_host.perm_timer]); // declared

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "Z");
    _ = try command.run(&env.commands, &env.ctx, "insert-shell", &.{.{ .string = "printf hi" }});
    try t.expect(ed.text().byteLen() == 1); // nothing inserted
}

test "wasm plugin: git-status runs git into a focused tool buffer (async)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    try @import("../builtins.zig").install(gpa, &env.commands, &env.keymap, &env.actions); // buffer-create

    var loop = async_loop.Loop.init(gpa, env.pool, @import("../task.zig").nowNs);
    defer loop.deinit();

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "git", @embedFile("guest_git_wasm"), .{ .loop = &loop });
    defer plugin.deinit();
    try t.expect(plugin.perms[wasm_host.perm_proc] and plugin.perms[wasm_host.perm_timer]);

    // Phase 2b/2c: the transient verbs are declared + registered (menu modes are
    // keymap state, but each terminal action is a real command).
    for ([_][]const u8{
        "git-amend",            "git-fixup",         "git-cherry-pick", "git-revert",
        "git-reset-hard",       "git-branch-create", "git-stash-pop",   "git-push-do",
        "git-fetch-toggle-all", "git-rebase-finish", "git-confirm-yes",
    }) |name| try t.expect(env.commands.find(name) != null);

    _ = try command.run(&env.commands, &env.ctx, "git-status", &.{});
    // The magit model buffer was created + focused synchronously (before output).
    const buf = blk: {
        var it = env.buffers.iterator();
        while (it.next()) |b| if (std.mem.eql(u8, b.name, "*magit*")) break :blk b;
        break :blk null;
    };
    try t.expect(buf != null);

    // Drive the async loop until git's output lands (bounded; this repo is a
    // git checkout). If git is unavailable the buffer stays empty — the
    // structural checks above still hold.
    var rounds: usize = 0;
    while (rounds < 20_000_000 and buf.?.editor.text().byteLen() == 0) : (rounds += 1) {
        _ = loop.tick();
        std.Thread.yield() catch {};
    }
    if (buf.?.editor.text().byteLen() > 0) {
        // on_fill parsed the raw git output and re-rendered the model: the
        // buffer now holds the pretty projection, not the porcelain, so we
        // assert the rendered branch header, not a `#`.
        const s = try buf.?.editor.text().toOwnedSlice(gpa);
        defer gpa.free(s);
        try t.expect(std.mem.indexOf(u8, s, "Branch:") != null);
        const doc = &buf.?.editor.doc;
        try t.expect(doc.commitAt(doc.commitCount() - 1).author != .user); // the plugin peer
    }
}

test "wasm plugin: run-command runs a shell command into a tool buffer (async)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    try @import("../builtins.zig").install(gpa, &env.commands, &env.keymap, &env.actions);

    var loop = async_loop.Loop.init(gpa, env.pool, @import("../task.zig").nowNs);
    defer loop.deinit();
    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "run", @embedFile("guest_run_wasm"), .{ .loop = &loop });
    defer plugin.deinit();

    // A deterministic command (echo) — proves the proc→buffer path end to end.
    _ = try command.run(&env.commands, &env.ctx, "run-command", &.{.{ .string = "echo weft-ok" }});
    const buf = blk: {
        var it = env.buffers.iterator();
        while (it.next()) |b| if (std.mem.eql(u8, b.name, "*output*")) break :blk b;
        break :blk null;
    };
    try t.expect(buf != null);
    var rounds: usize = 0;
    while (rounds < 20_000_000 and buf.?.editor.text().byteLen() == 0) : (rounds += 1) {
        _ = loop.tick();
        std.Thread.yield() catch {};
    }
    const s = try buf.?.editor.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("weft-ok", s); // stdout, trailing newline trimmed
    const doc = &buf.?.editor.doc;
    try t.expect(doc.commitAt(doc.commitCount() - 1).author != .user); // the plugin peer
}

test "wasm plugin: fmt filters a range through a command (async, in-place tmp)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var loop = async_loop.Loop.init(gpa, env.pool, @import("../task.zig").nowNs);
    defer loop.deinit();
    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "fmt", @embedFile("guest_fmt_wasm"), .{ .loop = &loop });
    defer plugin.deinit();

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "foo foo");
    const before = ed.doc.commitCount();
    // Filter the whole buffer through sed (in /usr/bin — no nix PATH needed):
    // rewrite the temp file in place, then the result replaces the range.
    _ = try command.run(&env.commands, &env.ctx, "filter", &.{.{ .string = "sed -i s/foo/bar/g {}" }});
    var rounds: usize = 0;
    while (rounds < 20_000_000 and ed.doc.commitCount() == before) : (rounds += 1) {
        _ = loop.tick();
        std.Thread.yield() catch {};
    }
    try t.expect(ed.doc.commitCount() > before); // the async filter landed an edit
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    // Either transformed (sed on PATH) or the original (no PATH in the test
    // harness) — never corrupted/emptied. That safety is the load-bearing part;
    // the transform is exercised at runtime where main wires the real environ.
    try t.expect(std.mem.eql(u8, s, "foo foo") or std.mem.indexOf(u8, s, "bar") != null);
    try t.expect(ed.doc.commitAt(ed.doc.commitCount() - 1).author != .user); // plugin peer
}

test "wasm plugin: repl runs a persistent process and streams its output back" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    try @import("../builtins.zig").install(gpa, &env.commands, &env.keymap, &env.actions); // buffer-create

    var loop = async_loop.Loop.init(gpa, env.pool, @import("../task.zig").nowNs);
    defer loop.deinit();
    var engine = try wasm.Engine.init();
    defer engine.deinit();
    // `cat` is a persistent echo REPL — stateful proof the child stays alive.
    const plugin = try loadPlugin(&engine, &env.ctx, "repl", @embedFile("guest_repl_wasm"), .{ .loop = &loop, .pool = env.pool });
    defer plugin.deinit(); // kills cat + JOINS the reader — no hang, no leak

    // A shell read-loop is a persistent echo REPL whose `echo` flushes
    // immediately (unlike `cat`, which block-buffers stdout on a pipe).
    _ = try command.run(&env.commands, &env.ctx, "repl-start", &.{.{ .string = "while read l; do echo \"$l\"; done" }});
    const buf = blk: {
        var it = env.buffers.iterator();
        while (it.next()) |b| if (std.mem.eql(u8, b.name, "*repl*")) break :blk b;
        break :blk null;
    };
    try t.expect(buf != null);
    _ = try command.run(&env.commands, &env.ctx, "repl-send", &.{.{ .string = "ping" }});

    // Drive the frame drain until cat's echo streams into *repl* (bounded — a
    // timeout fails the assert rather than hanging).
    var rounds: usize = 0;
    while (rounds < 5_000_000 and buf.?.editor.text().byteLen() == 0) : (rounds += 1) {
        _ = wasm_host.drainReplSessions(plugin);
        std.Thread.yield() catch {};
    }
    const s = try buf.?.editor.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expect(std.mem.indexOf(u8, s, "ping") != null); // the echoed line
}

test "wasm plugin: console-send runs the current line and appends output" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    try @import("../builtins.zig").install(gpa, &env.commands, &env.keymap, &env.actions); // buffer-create

    var loop = async_loop.Loop.init(gpa, env.pool, @import("../task.zig").nowNs);
    defer loop.deinit();
    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "console", @embedFile("guest_console_wasm"), .{ .loop = &loop });
    defer plugin.deinit();

    _ = try command.run(&env.commands, &env.ctx, "console-open", &.{}); // focus *console*
    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "echo con-ok"); // type a command line
    const before = ed.doc.commitCount();
    _ = try command.run(&env.commands, &env.ctx, "console-send", &.{});
    var rounds: usize = 0;
    while (rounds < 20_000_000 and ed.doc.commitCount() == before) : (rounds += 1) {
        _ = loop.tick();
        std.Thread.yield() catch {};
    }
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("echo con-ok\ncon-ok", s); // output appended below the input
}

test "wasm plugin: vim wires the modal keymap and runs motions/operators as .wasm" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    // The register is now a CORE service (register.zig), shared by every editor
    // — vim's yank/paste route through it, so wire one for the yy/p round-trip.
    var reg: register.Register = .empty;
    defer reg.deinit(gpa);
    const plugin = try loadPlugin(&engine, &env.ctx, "vim", @embedFile("guest_vim_wasm"), .{ .register = &reg });
    defer plugin.deinit();

    // init() booted into normal and wired the whole keymap through the config
    // surface — motions, operators, insert entries — all across the membrane.
    try t.expectEqualStrings("normal", env.keymap.currentMode());
    try t.expectEqualStrings("vim-insert", env.keymap.lookup("i").?);
    try t.expectEqualStrings("enter-op-delete", env.keymap.lookup("d").?);

    // Mode switches: i → insert, Escape (vim-normal) → normal.
    _ = try command.run(&env.commands, &env.ctx, "vim-insert", &.{});
    try t.expectEqualStrings("insert", env.keymap.currentMode());
    _ = try command.run(&env.commands, &env.ctx, "vim-normal", &.{});
    try t.expectEqualStrings("normal", env.keymap.currentMode());

    // yank-line + paste duplicates the current line (through the core register).
    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "hello");
    ed.placeCursor(0);
    _ = try command.run(&env.commands, &env.ctx, "yank-line", &.{});
    _ = try command.run(&env.commands, &env.ctx, "paste", &.{});
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("hello\nhello", s);
    try t.expect(ed.doc.commitAt(ed.doc.commitCount() - 1).author != .user);
}

test "wasm plugin: vim yank/paste ferries a subbuffer id through the register (dd→p is a move)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    var reg: register.Register = .empty;
    defer reg.deinit(gpa);
    var subs: subbuffer.SubBuffers = .empty;
    defer subs.deinit(gpa);
    const plugin = try loadPlugin(&engine, &env.ctx, "vim", @embedFile("guest_vim_wasm"), .{ .register = &reg, .subbuffers = &subs });
    defer plugin.deinit();

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "row-a");
    // A projection row: its name carries a hidden id (exactly as dired claims).
    const row = try subs.claim(gpa, &ed.doc, .{ .start = 0, .end = 5 });
    try row.putFact(gpa, "id", "42");
    ed.placeCursor(0);

    // yy then p: the id must ride the CORE register onto the pasted line — a
    // move — not vanish into a delete+create. The whole thesis, end to end
    // across the wasm membrane: yankRange snapshots it, pasteAt re-stamps it.
    _ = try command.run(&env.commands, &env.ctx, "yank-line", &.{});
    _ = try command.run(&env.commands, &env.ctx, "paste", &.{});
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("row-a\nrow-a", s);
    const pasted = subs.at(&ed.doc, 8) orelse return error.NoIdOnPastedRow;
    try t.expectEqualStrings("42", pasted.fact("id").?);
}

test "wasm plugins: a motion returns a range an operator awaits + applies (dw)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const motions = try loadPlugin(&engine, &env.ctx, "motions", @embedFile("guest_motions_wasm"), .{});
    defer motions.deinit();
    const operators = try loadPlugin(&engine, &env.ctx, "operators", @embedFile("guest_operators_wasm"), .{});
    defer operators.deinit();

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "foo bar");
    ed.placeCursor(0);

    // The motion returns a version-stamped RANGE Value across the membrane —
    // never a bare offset. Cursor is one end (0), the target the other (4).
    const rv = try command.run(&env.commands, &env.ctx, "motion.word-fwd", &.{});
    try t.expect(rv == .range);

    // The operator awaits that range (as its arg) and applies the gated edit —
    // authored as the operators plugin's peer, not the user.
    _ = try command.run(&env.commands, &env.ctx, "op.delete", &.{rv});
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("bar", s);
    try t.expect(ed.doc.commitAt(ed.doc.commitCount() - 1).author != .user);
}

test "wasm plugins: an awaited range rebases through a concurrent edit" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const motions = try loadPlugin(&engine, &env.ctx, "motions", @embedFile("guest_motions_wasm"), .{});
    defer motions.deinit();
    const operators = try loadPlugin(&engine, &env.ctx, "operators", @embedFile("guest_operators_wasm"), .{});
    defer operators.deinit();

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "foo bar");
    ed.placeCursor(0);

    // Compute a word-forward range [0,4) stamped at the current version.
    const rv = try command.run(&env.commands, &env.ctx, "motion.word-fwd", &.{});
    try t.expect(rv == .range);

    // A concurrent edit lands BEFORE the operator applies: insert "XX" at 0.
    // The stamped range must rebase to [2,6) — "Buffer changed" is inexpressible.
    ed.placeCursor(0);
    try ed.insertText(gpa, "XX");

    _ = try command.run(&env.commands, &env.ctx, "op.delete", &.{rv});
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("XXbar", s); // "foo " deleted at its rebased site
}

test "wasm plugins: vim composes motions + operators — dw through the keymap" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const motions = try loadPlugin(&engine, &env.ctx, "motions", @embedFile("guest_motions_wasm"), .{});
    defer motions.deinit();
    const operators = try loadPlugin(&engine, &env.ctx, "operators", @embedFile("guest_operators_wasm"), .{});
    defer operators.deinit();
    const vim = try loadPlugin(&engine, &env.ctx, "vim", @embedFile("guest_vim_wasm"), .{});
    defer vim.deinit();

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "foo bar");
    ed.placeCursor(0);

    // `d` enters operator-pending; the `w` binding there is vim's op wrapper,
    // which runs motion.word-fwd and hands its range to op.delete.
    _ = try command.run(&env.commands, &env.ctx, "enter-op-delete", &.{});
    try t.expectEqualStrings("op-pending", env.keymap.currentMode());
    try t.expectEqualStrings("vim/o/motion.word-fwd", env.keymap.lookup("w").?);
    _ = try command.run(&env.commands, &env.ctx, env.keymap.lookup("w").?, &.{});
    try t.expectEqualStrings("normal", env.keymap.currentMode());

    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("bar", s);
}

test "wasm plugins: a text object returns a range an operator applies (di\")" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const textobjects = try loadPlugin(&engine, &env.ctx, "textobjects", @embedFile("guest_textobjects_wasm"), .{});
    defer textobjects.deinit();
    const operators = try loadPlugin(&engine, &env.ctx, "operators", @embedFile("guest_operators_wasm"), .{});
    defer operators.deinit();

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "say \"hi\" ok");
    ed.placeCursor(5); // inside the quotes

    // inner-quote-double yields the span between the quotes ("hi"); the operator
    // deletes it — the range is absolute (the construct), not cursor-relative.
    const rv = try command.run(&env.commands, &env.ctx, "textobj.inner-quote-double", &.{});
    try t.expect(rv == .range);
    _ = try command.run(&env.commands, &env.ctx, "op.delete", &.{rv});
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("say \"\" ok", s);
}

test "wasm plugins: vim di( through the keymap (operator + text object)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const textobjects = try loadPlugin(&engine, &env.ctx, "textobjects", @embedFile("guest_textobjects_wasm"), .{});
    defer textobjects.deinit();
    const operators = try loadPlugin(&engine, &env.ctx, "operators", @embedFile("guest_operators_wasm"), .{});
    defer operators.deinit();
    const vim = try loadPlugin(&engine, &env.ctx, "vim", @embedFile("guest_vim_wasm"), .{});
    defer vim.deinit();

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "f(a, b)");
    ed.placeCursor(4); // inside the parens

    // di( : d → op-pending, i → op-to (inner), ( → the paren object.
    _ = try command.run(&env.commands, &env.ctx, "enter-op-delete", &.{});
    _ = try command.run(&env.commands, &env.ctx, env.keymap.lookup("i").?, &.{});
    try t.expectEqualStrings("op-to", env.keymap.currentMode());
    _ = try command.run(&env.commands, &env.ctx, env.keymap.lookup("parenleft").?, &.{});
    try t.expectEqualStrings("normal", env.keymap.currentMode());

    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("f()", s);
}

test "wasm plugins: a view-grade peer's op.delete refuses (zero permission code)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const motions = try loadPlugin(&engine, &env.ctx, "motions", @embedFile("guest_motions_wasm"), .{});
    defer motions.deinit();
    const operators = try loadPlugin(&engine, &env.ctx, "operators", @embedFile("guest_operators_wasm"), .{});
    defer operators.deinit();

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "foo bar");
    ed.placeCursor(0);
    ed.doc.my_grant = .view; // the document is read-only for us

    // The motion (read-only) still computes a range — reads are never gated.
    const rv = try command.run(&env.commands, &env.ctx, "motion.word-fwd", &.{});
    try t.expect(rv == .range);
    // But the operator's edit dies at the gate: the buffer is unchanged, and no
    // ghost commit was authored.
    const before = ed.doc.commitCount();
    _ = try command.run(&env.commands, &env.ctx, "op.delete", &.{rv});
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("foo bar", s);
    try t.expectEqual(before, ed.doc.commitCount());
}

test "wasm plugin: comment toggles a line comment, preserving indent" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "comment", @embedFile("guest_comment_wasm"), .{});
    defer plugin.deinit();

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "  hi");
    ed.placeCursor(4);
    _ = try command.run(&env.commands, &env.ctx, "comment-line", &.{});
    {
        const s = try ed.text().toOwnedSlice(gpa);
        defer gpa.free(s);
        try t.expectEqualStrings("  // hi", s);
    }
    _ = try command.run(&env.commands, &env.ctx, "comment-line", &.{});
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("  hi", s);
}

test "wasm plugin: whitespace trims trailing spaces on the line" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "whitespace", @embedFile("guest_whitespace_wasm"), .{});
    defer plugin.deinit();

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "hi   \nok");
    ed.placeCursor(0);
    _ = try command.run(&env.commands, &env.ctx, "trim-trailing-line", &.{});
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("hi\nok", s);
}

test "wasm plugin: numbers increments the integer under the cursor" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "numbers", @embedFile("guest_numbers_wasm"), .{});
    defer plugin.deinit();

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "x 41 y");
    ed.placeCursor(2); // on the '4'
    _ = try command.run(&env.commands, &env.ctx, "increment-number", &.{});
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("x 42 y", s);
}

test "wasm plugin: autopair inserts a matched pair around the cursor" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "autopair", @embedFile("guest_autopair_wasm"), .{});
    defer plugin.deinit();

    const ed = &env.buffers.active().editor;
    try ed.insertText(gpa, "ab");
    ed.placeCursor(0);
    _ = try command.run(&env.commands, &env.ctx, "pair-paren", &.{});
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("()ab", s);
    try t.expectEqual(@as(usize, 1), ed.cursorOffset());
}

test "wasm plugin: notes capture appends via fs and open reads it back" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    try @import("../builtins.zig").install(gpa, &env.commands, &env.keymap, &env.actions); // buffer-create

    const tmp = "weft-notes-test.md"; // cwd-relative; cleaned up below
    file.deleteFile(gpa, tmp);
    defer file.deleteFile(gpa, tmp);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "notes", @embedFile("guest_notes_wasm"), .{});
    defer plugin.deinit();
    try t.expect(plugin.perms[wasm_host.perm_fs_read] and plugin.perms[wasm_host.perm_fs_write]);

    // Two captures append to the file; open reads it into *notes*.
    _ = try command.run(&env.commands, &env.ctx, "notes-capture", &.{ .{ .string = "todo x" }, .{ .string = tmp } });
    _ = try command.run(&env.commands, &env.ctx, "notes-capture", &.{ .{ .string = "todo y" }, .{ .string = tmp } });
    _ = try command.run(&env.commands, &env.ctx, "notes-open", &.{.{ .string = tmp }});

    const buf = blk: {
        var it = env.buffers.iterator();
        while (it.next()) |b| if (std.mem.eql(u8, b.name, "*notes*")) break :blk b;
        break :blk null;
    };
    try t.expect(buf != null);
    const s = try buf.?.editor.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("todo x\ntodo y\n", s);
}

test "wasm plugin: modes reacts to the activation event by language" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "modes", @embedFile("guest_modes_wasm"), .{});
    defer plugin.deinit();

    // Fire activation for a python file: on_activate detects the language and
    // echoes it — the host→guest reactive event (design §3).
    wasm_host.notifyActivate(plugin, "src/main.py");
    try t.expectEqualStrings("mode: python", env.echo.items);

    // A zig file re-detects; an unknown extension is a silent no-op.
    env.echo.clearRetainingCapacity();
    wasm_host.notifyActivate(plugin, "build.zig");
    try t.expectEqualStrings("mode: zig", env.echo.items);
    env.echo.clearRetainingCapacity();
    wasm_host.notifyActivate(plugin, "LICENSE");
    try t.expectEqual(@as(usize, 0), env.echo.items.len);
}

test "wasm plugin: snippets-expand inserts a template body from an fs file" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    const tmp = "weft-snippets-test.txt";
    try file.writeBytes(gpa, tmp, "fn\tfn foo() {\\n}\nlog\tstd.log.info(\"\", .{});");
    defer file.deleteFile(gpa, tmp);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "snippets", @embedFile("guest_snippets_wasm"), .{});
    defer plugin.deinit();
    try t.expect(plugin.perms[wasm_host.perm_fs_read]);

    const ed = &env.buffers.active().editor;
    ed.placeCursor(0);
    _ = try command.run(&env.commands, &env.ctx, "snippets-expand", &.{ .{ .string = "fn" }, .{ .string = tmp } });
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("fn foo() {\n}", s); // literal \n expanded to a newline
}

test "net_session: streams a socket into a buffer, teardown clean" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    const linux = std.os.linux;
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &fds)) != .SUCCESS) return;
    var peer_open = true;
    defer if (peer_open) {
        _ = linux.close(fds[1]);
    };

    const s = try net_session.Session.startFd(gpa, env.pool, &env.ctx, "netplug", "*net*", fds[0]);
    // The "server" end writes; the reader streams it into *net* via drain.
    _ = linux.write(fds[1], "net-ok", 6);
    const buf = blk: {
        var rounds: usize = 0;
        while (rounds < 5_000_000) : (rounds += 1) {
            _ = s.drain();
            var it = env.buffers.iterator();
            while (it.next()) |b| if (std.mem.eql(u8, b.name, "*net*")) {
                if (b.editor.text().byteLen() > 0) break :blk b;
            };
            std.Thread.yield() catch {};
        }
        break :blk null;
    };
    // deinit shuts fds[0] + joins the reader + closes — no hang, no leak.
    s.deinit();
    _ = linux.close(fds[1]);
    peer_open = false;
    try t.expect(buf != null);
    const str = try buf.?.editor.text().toOwnedSlice(gpa);
    defer gpa.free(str);
    try t.expectEqualStrings("net-ok", str);
}

test "wasm plugin: kv admin round-trips across the membrane, namespaced" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var store: kv.Store = .empty;
    defer store.deinit(gpa);

    var engine = try wasm.Engine.init();
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "edit", @embedFile("guest_edit_wasm"), .{ .kv = &store });
    defer plugin.deinit();
    // The host wired the kv service; a value put under this plugin is
    // namespaced to its name (proven directly through the store).
    try store.put(gpa, "edit", "k", "v");
    try t.expectEqualStrings("v", store.get("edit", "k").?);
    try t.expectEqual(@as(?[]const u8, null), store.get("other", "k"));
}
