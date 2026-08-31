//! `TestHost` — the compact editor environment core's tests run against: a
//! `Buffers` with one live scratch entry, a command table, a keymap, one
//! `Head`, and the shared `Container` that `caps`/`actions`/`slot_host` all
//! bind into. Plus the `command.Context` that names them, which is what a
//! test actually wants.
//!
//! **One harness, not four.** This was three near-identical copies —
//! `core/tests.zig`'s `TestHost`, `core/wasm_abi/tests.zig`'s `Env`, and a
//! third that was about to be written for `wasm_host/buffers.zig` — with the
//! same fields, the same init order, and the same deinit order transcribed by
//! hand. The init ORDER is the part that matters and the part a copy gets
//! wrong: `caps`/`actions`/`slot_host` borrow `&self.container`, so they can
//! only be built after the struct literal has put the container at its final
//! address (the same reasoning `System.create` writes down). A fourth
//! transcription of that rule is a fourth chance to get it wrong.
//!
//! Deliberately NOT re-exported from `core.zig`: nothing in the production
//! graph should be able to reach a test fixture. Test files import this path
//! directly.
//!
//! **No builtins.** `init` installs no command table — a membrane test wants
//! to see exactly what a plugin declared, and nothing else. A test that wants
//! the built-in commands installs them itself (`core/tests.zig` does), which
//! keeps "what is bound here" a property of the test rather than of the
//! harness.

const std = @import("std");
const Allocator = std.mem.Allocator;

const task = @import("task.zig");
const Buffers = @import("Buffers.zig");
const Editor = @import("Editor.zig");
const Keymap = @import("Keymap.zig");
const Head = @import("Head.zig");
const command = @import("command.zig");
const container_mod = @import("container.zig");
const capability = @import("capability.zig");
const action = @import("action.zig");
const slot_mod = @import("slot.zig");
const grants_mod = @import("grants.zig");

const TestHost = @This();

pool: *task.Pool,
buffers: Buffers,
commands: command.Commands,
keymap: Keymap,
head: Head,
/// The ONE shared Container `caps`/`actions`/`slot_host` bind into (task #19).
container: container_mod.Container,
caps: capability.Caps,
actions: action,
/// D2's generic, schema-directed slot host (`core/slot.zig`) — `Caps`'s
/// sibling. Present in every fixture so a slot test needs no special harness.
slot_host: slot_mod.SlotHost,
/// The System's grant table. Present (rather than `null`) so a confinement
/// test can grant without rebuilding the world; an empty table grants
/// nothing, which is what every other fixture already assumed.
grants: grants_mod.HandleTable,
quit: bool,
ctx: command.Context,

pub fn init(gpa: Allocator, self: *TestHost) !void {
    self.pool = try task.Pool.init(gpa, .{ .threads = 1 });
    self.buffers = try Buffers.init(gpa, self.pool, "user");
    self.commands = .empty;
    self.keymap = .empty;
    self.head = .empty;
    self.container = container_mod.Container.init(gpa);
    self.grants = grants_mod.HandleTable.init(gpa);
    self.quit = false;
    // AFTER the fields above: these three borrow `&self.container`, which
    // must already hold its final value at its final address. See the module
    // doc — this ordering is the reason this file exists.
    self.caps = capability.Caps.init(gpa, task.nowNs, &self.container);
    self.actions = action.init(gpa, &self.container);
    self.slot_host = slot_mod.SlotHost.init(gpa, &self.container);
    self.ctx = .{
        .gpa = gpa,
        .buffers = &self.buffers,
        .commands = &self.commands,
        .keymap = &self.keymap,
        .actions = &self.actions,
        .caps = &self.caps,
        .quit = &self.quit,
        .head = &self.head,
        .slot_host = &self.slot_host,
        .grant_table = &self.grants,
    };
}

/// The active entry's editor. Every fixture starts with one scratch entry
/// that holds text, so this does not fail in practice.
pub fn editor(self: *TestHost) *Editor {
    return self.buffers.active().textEditor().?;
}

pub fn deinit(self: *TestHost, gpa: Allocator) void {
    self.slot_host.deinit();
    self.actions.deinit();
    self.caps.deinit();
    self.grants.deinit();
    self.container.deinit();
    self.head.deinit(gpa);
    self.keymap.deinit(gpa);
    self.commands.deinit(gpa);
    self.buffers.deinit(gpa);
    self.pool.deinit();
}
