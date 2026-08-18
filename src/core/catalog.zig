//! catalog — the reference plugins (design §6), each a Zig module written
//! against `abi.zig` with NO core privilege: exactly what a user could
//! write against the same door (the manifesto's test). The host loads
//! `all()` at startup (plan 03 P5 wires this into main.zig alongside — and
//! eventually instead of — the Lua config path).
//!
//! Domains land as the ABI grows to cover them. Present: `project`
//! (recent files, kv) and `edit` (line operators, edit door). The proc/
//! net/async-driven domains (repl, agent, lang-fmt) need the async-delivery
//! -to-editor wiring (a completion sink that edits on the frame thread)
//! before they can be shipped WITHOUT a frame-blocking poll — that wiring
//! is the next integration step, not a core gap.

const std = @import("std");
const abi = @import("abi.zig");

pub const project = @import("catalog/project.zig");
pub const edit = @import("catalog/edit.zig");
pub const shell = @import("catalog/shell.zig");
pub const region = @import("catalog/region.zig");
pub const complete = @import("catalog/complete.zig");
pub const structural = @import("catalog/structural.zig");
pub const demo_config = @import("catalog/demo_config.zig");
pub const palette = @import("catalog/palette.zig");
pub const vim = @import("catalog/vim.zig");

/// The complete Zig config (plan 06C: this REPLACES the Lua `bundled.fnl` +
/// `init.fnl`). `vim` is the modal keymap, `std` (palette.zig) the UI policy
/// (palette/buffers/status), and the rest add commands/providers. `edit`
/// before `vim`/`std` so their composed targets exist (late binding tolerates
/// any order anyway). `demo_config` is excluded — it is a demo, not config.
/// Copies into `out` (`>= count`) and returns the filled slice.
pub fn all(out: []abi.Plugin) []abi.Plugin {
    const list = [_]abi.Plugin{
        edit.plugin(),    project.plugin(),  shell.plugin(),
        region.plugin(),  complete.plugin(), structural.plugin(),
        palette.plugin(), vim.plugin(),
    };
    @memcpy(out[0..list.len], &list);
    return out[0..list.len];
}

pub const count = 8;

// ── Tests: drive each catalog plugin through a real Host ─────────────

const t = std.testing;
const command = @import("command.zig");
const kv = @import("kv.zig");

const Env = struct {
    gpa: std.mem.Allocator,
    pool: *@import("task.zig").Pool,
    buffers: @import("Buffers.zig"),
    commands: command.Commands,
    keymap: @import("Keymap.zig"),
    pick: @import("pick.zig").Pick,
    caps: @import("capability.zig").Caps,
    quit: bool,
    echo: std.ArrayList(u8),
    ctx: command.Context,

    fn init(gpa: std.mem.Allocator, self: *Env) !void {
        self.pool = try @import("task.zig").Pool.init(gpa, .{ .threads = 1 });
        self.buffers = try @import("Buffers.zig").init(gpa, self.pool, "user");
        self.commands = .empty;
        self.keymap = .empty;
        self.pick = .empty;
        self.caps = @import("capability.zig").Caps.init(gpa, @import("task.zig").nowNs);
        self.quit = false;
        self.echo = .empty;
        self.ctx = .{
            .gpa = gpa,
            .buffers = &self.buffers,
            .commands = &self.commands,
            .keymap = &self.keymap,
            .pick = &self.pick,
            .caps = &self.caps,
            .quit = &self.quit,
            .echo = &self.echo,
        };
    }
    fn deinit(self: *Env, gpa: std.mem.Allocator) void {
        self.caps.deinit();
        self.pick.deinit(gpa);
        self.keymap.deinit(gpa);
        self.commands.deinit(gpa);
        self.echo.deinit(gpa);
        self.buffers.deinit(gpa);
        self.pool.deinit();
    }
    fn editor(self: *Env) *@import("Editor.zig") {
        return &self.buffers.active().editor;
    }
};

test "catalog/project: remember + recent track visited files, deduped" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var store: kv.Store = .empty;
    defer store.deinit(gpa);

    var host = abi.Host.init(&env.ctx, .{ .kv = &store });
    defer host.deinit();
    try host.load(project.plugin());

    // A buffer with no path can't be remembered.
    try t.expectEqual(command.Value{ .integer = -1 }, try command.run(&env.commands, &env.ctx, "project-remember", &.{}));

    // Give it a path, remember it twice + another: deduped, most-recent-first.
    try env.editor().adoptPath(gpa, "/tmp/a.zig");
    try t.expectEqual(command.Value{ .integer = 1 }, try command.run(&env.commands, &env.ctx, "project-remember", &.{}));
    try t.expectEqual(command.Value{ .integer = 1 }, try command.run(&env.commands, &env.ctx, "project-remember", &.{})); // dup → still 1

    const list = try command.run(&env.commands, &env.ctx, "project-recent", &.{});
    try t.expectEqualStrings("/tmp/a.zig", list.string);
}

test "catalog/edit: duplicate-line and upcase-line operate through the ABI" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var host = abi.Host.init(&env.ctx, .{});
    defer host.deinit();
    try host.load(edit.plugin());

    try env.editor().insertText(gpa, "hello world");
    env.editor().placeCursor(3); // somewhere on the line

    _ = try command.run(&env.commands, &env.ctx, "duplicate-line", &.{});
    {
        const s = try env.editor().text().toOwnedSlice(gpa);
        defer gpa.free(s);
        try t.expectEqualStrings("hello world\nhello world", s);
    }
    // The edit authored as the "edit" plugin peer, not the user.
    const doc = &env.buffers.active().editor.doc;
    try t.expect(doc.commitAt(doc.commitCount() - 1).author != .user);

    // Upper-case the first line.
    env.editor().placeCursor(0);
    _ = try command.run(&env.commands, &env.ctx, "upcase-line", &.{});
    {
        const s = try env.editor().text().toOwnedSlice(gpa);
        defer gpa.free(s);
        try t.expectEqualStrings("HELLO WORLD\nhello world", s);
    }
}

test "catalog/shell: insert-shell runs a command and inserts its output" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var loop = @import("async.zig").Loop.init(gpa, env.pool, @import("task.zig").nowNs);
    defer loop.deinit();

    var host = abi.Host.init(&env.ctx, .{ .loop = &loop });
    defer host.deinit();
    try host.load(shell.plugin());

    _ = try command.run(&env.commands, &env.ctx, "insert-shell", &.{.{ .string = "printf weft" }});
    // Drive the loop until the async output lands (bounded).
    var rounds: usize = 0;
    while (env.editor().text().byteLen() == 0 and rounds < 20_000_000) : (rounds += 1) {
        _ = loop.tick();
        std.Thread.yield() catch {};
    }
    const s = try env.editor().text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("weft", s);
    // Authored as the shell plugin peer, not the user.
    const doc = &env.buffers.active().editor.doc;
    try t.expect(doc.commitAt(doc.commitCount() - 1).author != .user);
}

test "catalog/region: mark-region claims a subbuffer with a language fact" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var subs = @import("subbuffer.zig").SubBuffers.empty;
    defer subs.deinit(gpa);

    var host = abi.Host.init(&env.ctx, .{ .subbuffers = &subs });
    defer host.deinit();
    try host.load(region.plugin());

    try env.editor().insertText(gpa, "let x = 1\nlet y = 2");
    env.editor().placeCursor(2); // on the first line

    const r = try command.run(&env.commands, &env.ctx, "mark-region", &.{.{ .string = "javascript" }});
    try t.expectEqual(command.Value{ .integer = 9 }, r); // "let x = 1" is 9 bytes
    const sub = subs.at(&env.buffers.active().editor.doc, 4).?;
    try t.expectEqualStrings("javascript", sub.fact("language").?);
    // It rebases: insert two chars at the head, the claim moves with the text.
    env.editor().placeCursor(0);
    try env.editor().insertText(gpa, "//");
    try t.expectEqual(@as(usize, 2), sub.resolve().start);
}

test "catalog/complete: provides matching buffer words through the caps race" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var host = abi.Host.init(&env.ctx, .{});
    defer host.deinit();
    try host.load(complete.plugin());

    try env.editor().insertText(gpa, "foobar foobaz foo qux");
    // Fire the completion race; the plugin's instant provider answers now.
    const id = (try env.caps.fire(.completion, &env.editor().doc, null, .{ .text = "foo" })).?;
    defer env.caps.finish(id);
    const merged = try env.caps.mergedCompletion(gpa, id);
    defer gpa.free(merged);

    // "foobar"/"foobaz" match "foo"; "foo" itself is excluded (not longer).
    try t.expectEqual(@as(usize, 2), merged.len);
    var saw_bar = false;
    var saw_baz = false;
    for (merged) |it| {
        if (std.mem.eql(u8, it.text, "foobar")) saw_bar = true;
        if (std.mem.eql(u8, it.text, "foobaz")) saw_baz = true;
    }
    try t.expect(saw_bar and saw_baz);
}

fn testSyntaxOf(buf: *@import("Buffers.zig").Buffer) ?*@import("syntax.zig").Syntax {
    return @ptrCast(@alignCast(buf.frontend orelse return null));
}

test "catalog/structural: node-kind and delete-node use the syntax tree" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    const src = "const x = 42;";
    try env.editor().insertText(gpa, src);
    // Attach a real grammar to the buffer via its frontend slot; a resolver
    // hands it to the ABI (the host owns that slot).
    const sx = @import("syntax.zig");
    const syn = try sx.Syntax.create(gpa, sx.forPath("t.zig").?, &env.editor().doc);
    defer syn.destroy();
    env.buffers.active().frontend = syn;

    var host = abi.Host.init(&env.ctx, .{ .syntax_of = testSyntaxOf });
    defer host.deinit();
    try host.load(structural.plugin());

    env.editor().placeCursor(std.mem.indexOf(u8, src, "42").?);
    const k = try command.run(&env.commands, &env.ctx, "node-kind", &.{});
    try t.expect(std.mem.indexOf(u8, k.string, "integer") != null or std.mem.indexOf(u8, k.string, "number") != null);

    // delete-node removes the "42" literal as a plugin-authored edit.
    _ = try command.run(&env.commands, &env.ctx, "delete-node", &.{});
    const s = try env.editor().text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("const x = ;", s);
    const doc = &env.buffers.active().editor.doc;
    try t.expect(doc.commitAt(doc.commitCount() - 1).author != .user);
}

test "catalog/demo-config: a Zig config plugin composes commands and binds keys" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var host = abi.Host.init(&env.ctx, .{});
    defer host.deinit();
    try host.load(edit.plugin()); // provides duplicate-line / upcase-line
    try host.load(demo_config.plugin()); // composes them + binds a key

    // The key is wired to the composed command (in the "default" mode the
    // config bound it in).
    try env.keymap.setMode(gpa, "default");
    try t.expectEqualStrings("dup-up", env.keymap.lookup("C-d").?);

    try env.editor().insertText(gpa, "hello");
    env.editor().placeCursor(0);
    _ = try command.run(&env.commands, &env.ctx, "dup-up", &.{});
    const s = try env.editor().text().toOwnedSlice(gpa);
    defer gpa.free(s);
    // duplicate → "hello\nhello", then upper-case the first line.
    try t.expectEqualStrings("HELLO\nhello", s);
}

test "catalog/std: pick-commands opens a pick over the whole registry" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    // The picker needs its "pick" mode + commands installed (the shell does
    // this at startup).
    try @import("pick.zig").install(gpa, &env.commands, &env.keymap);

    var host = abi.Host.init(&env.ctx, .{});
    defer host.deinit();
    try host.load(edit.plugin()); // some commands to list
    try host.load(palette.plugin()); // the "std" plugin (pick-commands/buffers/…)

    const before = env.commands.count();
    _ = try command.run(&env.commands, &env.ctx, "pick-commands", &.{});
    try t.expect(env.pick.active);
    // One pick entry per registered command (duplicate-line, upcase-line,
    // command-palette, the pick-* commands …). Env.deinit closes the pick,
    // whose acceptor cleanup frees the plugin's BoundPick.
    try t.expectEqual(before, env.pick.items.items.len);
}

test "catalog/vim: modal editing — modes, register/paste, operator dw" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    // The vim keymap layers over the built-in motions/edits.
    try @import("builtins.zig").install(gpa, &env.commands, &env.keymap);

    var host = abi.Host.init(&env.ctx, .{});
    defer host.deinit();
    try host.load(vim.plugin());

    // Booted into normal; keys are bound; mode compounds switch modes.
    try t.expectEqualStrings("normal", env.keymap.currentMode());
    try t.expectEqualStrings("vim-insert", env.keymap.lookup("i").?);
    _ = try command.run(&env.commands, &env.ctx, "vim-insert", &.{});
    try t.expectEqualStrings("insert", env.keymap.currentMode());
    _ = try command.run(&env.commands, &env.ctx, "vim-normal", &.{});
    try t.expectEqualStrings("normal", env.keymap.currentMode());

    // Linewise yank + paste-below.
    try env.editor().insertText(gpa, "hello");
    env.editor().placeCursor(0);
    _ = try command.run(&env.commands, &env.ctx, "yank-line", &.{});
    _ = try command.run(&env.commands, &env.ctx, "paste", &.{});
    {
        const s = try env.editor().text().toOwnedSlice(gpa);
        defer gpa.free(s);
        try t.expectEqualStrings("hello\nhello", s);
    }

    // Operator dw: on "foo bar" at col 0, delete a word → "bar".
    var b2 = try env.buffers.create(gpa, "b2");
    _ = &b2;
    try env.buffers.switchTo(gpa, b2, &env.keymap);
    try env.editor().insertText(gpa, "foo bar");
    env.editor().placeCursor(0);
    _ = try command.run(&env.commands, &env.ctx, "enter-op-delete", &.{});
    try t.expectEqualStrings("op-delete", env.keymap.currentMode());
    _ = try command.run(&env.commands, &env.ctx, "op-motion-word-forward", &.{});
    try t.expectEqualStrings("normal", env.keymap.currentMode());
    {
        const s = try env.editor().text().toOwnedSlice(gpa);
        defer gpa.free(s);
        try t.expectEqualStrings("bar", s);
    }
}

test {
    std.testing.refAllDecls(@This());
}
