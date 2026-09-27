//! The plugin MANIFEST — one declaration of a plugin's commands, from which
//! `describe`, `init`, and `on_command` are generated.
//!
//! Before this, every plugin in the tree wrote the same three exports over the
//! same hand-maintained table, declared once to `declareCommand`, once to
//! `register`, and once to an integer-indexed switch:
//!
//! ```zig
//! export fn describe() void { for (cmds) |c| weft.declareCommand(c.name); }
//! export fn init()     void { for (cmds) |c| _ = weft.register(c.name); }
//! export fn on_command(id: u32) void { if (id < cmds.len) cmds[id].handler(); }
//! ```
//!
//! Forty-one plugins, three passes each, and the third one is wrong: `register`
//! RETURNS the id the host chose, and indexing the table with it is only
//! correct while the host happens to hand them out in registration order. The
//! generated dispatch records what `register` actually returned, so the
//! assumption cannot rot.
//!
//! The other half is `thunk`: a command's handler may take TYPED PARAMETERS,
//! and the generated wrapper reads them. That retires `weft.argStr(0) orelse
//! return` and — because `argStr` returns a slice into one shared shim scratch
//! that the NEXT `argStr` overwrites — the copy-or-corrupt hazard three plugins
//! had already discovered the hard way (`snippets`, `net`, `llm` each carry a
//! "copy — a second argStr reuses the scratch" comment). A thunk owns its
//! arguments for the duration of the call; a handler cannot observe the seam.

const std = @import("std");
const weft = @import("root.zig");
const contract = @import("weft_membrane");

pub fn exportCallback(comptime logical_name: []const u8, comptime function: anytype) void {
    const entry = comptime blk: {
        for (contract.exports) |candidate| {
            if (candidate.transport == .full_plugin and std.mem.eql(u8, candidate.name, logical_name))
                break :blk candidate;
        }
        @compileError("unknown full-plugin callback: " ++ logical_name);
    };
    const function_type = @typeInfo(@TypeOf(function)).pointer.child;
    const function_info = @typeInfo(function_type).@"fn";
    if (function_info.params.len != entry.params.len)
        @compileError("callback arity does not match membrane contract: " ++ logical_name);
    @export(function, .{ .name = contract.export_prefix ++ logical_name });
}

/// One command. `call` is the erased entry point — write `weft.thunk(handler)`
/// rather than a bare function pointer whenever the handler takes arguments.
pub const Entry = struct {
    name: []const u8,
    call: *const fn () void,
    /// Space-separated parameter list, bare (required) or `[bracketed]`
    /// (optional), exactly as a person reads it back: `"host:port"`, `"[preset]"`.
    /// Non-empty here (or a non-empty `summary`) declares through
    /// `describeCommand`, so the palette can ask for the arguments.
    params: []const u8 = "",
    summary: []const u8 = "",
    /// How it maps over several selections — REQUIRED, so no command reaches
    /// the host without its author having looked at it. There is no
    /// table-wide default: a default is a guess about commands nobody looked
    /// at, and every plugin that had one ran some of them on the primary
    /// alone.
    arity: Arity,
};

/// How a command maps over a selection of several extents (doc/model.md
/// §2.6; core's `selection.Arity`, which dispatch maps by):
///
///   - `.one` — acts on one selection: refused on several, which is how the
///     host reads a command that declares nothing. A command that reads THE
///     caret or row once and has no per-extent reading — an interactive
///     search, a row's own action, a jump to a picked place — says this.
///   - `.each` — once per extent, last first, one undo unit; each run sees
///     its extent as THE selection, so the handler is a one-selection program.
///     `.over` names a range command that maps each extent to its target
///     first (identical targets run once); the handler then gets the target
///     as its range argument (`argRange(0)`). `.merge` unions overlapping
///     targets (lines) instead of refusing them.
///   - `.whole` — once; the handler reads the whole set, or its subject is
///     not the selection at all (a picker, a window, a process, its own
///     argument). A command that only runs another says `.whole`: the one it
///     runs maps, or refuses, by its own declaration.
///   - `.homogeneous` — once, refused when the extents differ in kind.
pub const Arity = union(enum) {
    one,
    each: Each,
    whole,
    homogeneous,

    pub const Each = struct { over: ?[]const u8 = null, merge: bool = false };
    /// The plain per-extent mapping.
    pub const each_extent: Arity = .{ .each = .{} };

    /// The wire code `declare_arity` carries; null for `.one`, which is
    /// declared by declaring nothing.
    pub fn code(self: Arity) ?u32 {
        return switch (self) {
            .one => null,
            .each => |e| if (e.over == null) 0 else if (e.merge) 4 else 3,
            .whole => 1,
            .homogeneous => 2,
        };
    }

    pub fn over(self: Arity) []const u8 {
        return switch (self) {
            .each => |e| e.over orelse "",
            .one, .whole, .homogeneous => "",
        };
    }
};

/// What a plugin still says for itself. Everything here is optional; a plugin
/// with none of it is exactly its command table.
pub const Hooks = struct {
    /// Requested at describe time, before any authority exists.
    perms: []const weft.Perm = &.{},
    /// Capabilities this plugin provides, cross-checked host-side at init.
    capabilities: []const []const u8 = &.{},
    /// Extra describe-phase work (declarations only — no authority yet).
    describe: ?*const fn () void = null,
    /// Extra init-phase work: keymaps, modes, `provide`, slot declarations.
    init: ?*const fn () void = null,
    /// The dispatch prologue. Runs before command `index` with the table's own
    /// index (NOT the host's id), and refuses the dispatch by returning false —
    /// which is how a plugin that routes or revalidates before every verb (git's
    /// session routing and snapshot check) keeps one funnel instead of a
    /// prologue pasted into sixty handlers.
    before: ?*const fn (index: usize) bool = null,
    /// The dispatch epilogue, run after a command that was not refused — the
    /// other end of the same funnel (vim clears its pending count and selected
    /// register after every verb that does not preserve them).
    after: ?*const fn (index: usize) void = null,
    /// A pick this plugin opened through the RAW doors, with an id of its own
    /// choosing. `weft.ask`'s continuations are routed first and never reach
    /// here; ids with the top bit set are the SDK's.
    pick: ?*const fn (pick_id: u32) void = null,
};

/// Generate the three exports for `cmds`. Call `exportAll` from a `comptime`
/// block at container scope:
///
/// ```zig
/// const P = weft.plugin(&cmds, .{ .perms = &.{.proc} });
/// comptime { P.exportAll(); }
/// ```
pub fn plugin(comptime cmds: []const Entry, comptime hooks: Hooks) type {
    comptime {
        // The duplicate check is quadratic in the table, and vim's is ~200
        // entries — the biggest in the tree, and the one whose ids a stale
        // hand-maintained switch would have silently mismatched.
        @setEvalBranchQuota(16 * cmds.len * cmds.len + 4000);
        var seen: []const []const u8 = &.{};
        for (cmds) |c| {
            if (c.name.len == 0) @compileError("a command with no name");
            for (seen) |prior| {
                if (std.mem.eql(u8, prior, c.name))
                    @compileError("duplicate command name: " ++ c.name);
            }
            seen = seen ++ [_][]const u8{c.name};
        }
    }

    return struct {
        /// The id the host assigned each command, in table order. Recorded
        /// rather than assumed: `register` is what says which id a name got.
        var ids: [cmds.len]u32 = @splat(std.math.maxInt(u32));

        fn describeFn() callconv(.c) void {
            inline for (cmds) |c| {
                if (c.params.len > 0 or c.summary.len > 0)
                    weft.describeCommand(c.name, c.params, c.summary)
                else
                    weft.declareCommand(c.name);
                weft.declareArity(c.name, c.arity);
            }
            inline for (hooks.capabilities) |cap| weft.declareCapability(cap);
            inline for (hooks.perms) |perm| weft.requestPerm(perm);
            if (hooks.describe) |f| f();
        }

        fn initFn() callconv(.c) void {
            inline for (cmds, 0..) |c, i| ids[i] = weft.register(c.name);
            if (hooks.init) |f| f();
        }

        /// How deep in this plugin's own dispatches the current one is: a
        /// command that runs another of this plugin's commands re-enters here.
        var depth: u32 = 0;

        fn onCommand(id: u32) callconv(.c) void {
            const index = indexOf(id) orelse return;
            if (hooks.before) |f| {
                if (!f(index)) return;
            }
            depth += 1;
            cmds[index].call();
            depth -= 1;
            // The epilogue ends the COMMAND, so it runs once: not after a
            // command this one ran, and not before a mapping's last run — a
            // typed count read by the first run is still due to the rest.
            if (hooks.after) |f| if (depth == 0 and (weft.visitsLeft() orelse 0) == 0) f(index);
        }

        /// The table index for a host id. Linear over a table this small, and
        /// it degrades to the identity the old code assumed when the host does
        /// hand ids out in order.
        fn indexOf(id: u32) ?usize {
            if (id < ids.len and ids[id] == id) return id;
            for (ids, 0..) |registered, i| {
                if (registered == id) return i;
            }
            return null;
        }

        /// The host's `exec` delivery, routed to the continuation that asked
        /// for it. Exported unconditionally: a plugin that never calls `exec`
        /// pays one unused export, and one that does never writes a demux.
        fn onExec(token: u32) callconv(.c) void {
            @import("exec.zig").deliver(token);
        }

        /// A pick was accepted (or cancelled). `weft.ask`'s own questions are
        /// answered here; anything else is this plugin's raw pick and goes to
        /// the `pick` hook.
        fn onPickAccept(pick_id: u32) callconv(.c) void {
            if (@import("ask.zig").deliver(pick_id)) return;
            if (hooks.pick) |f| f(pick_id);
        }

        pub fn exportAll() void {
            exportCallback("describe", &describeFn);
            exportCallback("init", &initFn);
            exportCallback("on_command", &onCommand);
            exportCallback("on_exec", &onExec);
            exportCallback("on_pick_accept", &onPickAccept);
        }

        /// The host id for a command this plugin declared, by name — for the
        /// rare caller that needs to speak an id rather than a name.
        pub fn idOf(comptime name: []const u8) u32 {
            const index = comptime blk: {
                for (cmds, 0..) |c, i| {
                    if (std.mem.eql(u8, c.name, name)) break :blk i;
                }
                @compileError("no such command: " ++ name);
            };
            return ids[index];
        }
    };
}

/// Erase a typed handler into the `fn () void` a table entry holds, reading its
/// arguments from the dispatch that invoked it.
///
/// Supported parameter types, in declaration order:
///   - `[]const u8`  — a required string; the handler is not called without it
///   - `?[]const u8` — an optional string
///   - `i32`         — a required integer (absent reads as 0, as `argInt` does)
///   - `?i32`        — an optional integer
///
/// Strings are COPIED for the duration of the call, which is the whole point:
/// `argStr` hands back a slice into a shared scratch that the next `argStr` —
/// or any other read door — overwrites underneath it.
pub fn thunk(comptime f: anytype) *const fn () void {
    const F = @TypeOf(f);
    const info = switch (@typeInfo(F)) {
        .@"fn" => |fn_info| fn_info,
        .pointer => |ptr| @typeInfo(ptr.child).@"fn",
        else => @compileError("thunk expects a function, got " ++ @typeName(F)),
    };
    if (info.return_type != void) @compileError("a command handler returns void");
    if (info.params.len == 0) return f;

    return struct {
        fn call() void {
            var args: std.meta.ArgsTuple(F) = undefined;
            var owned: [info.params.len][]u8 = undefined;
            var held: usize = 0;
            defer for (owned[0..held]) |s| weft.allocator.free(s);

            inline for (info.params, 0..) |param, i| {
                const T = param.type orelse @compileError("a command handler takes no anytype");
                switch (T) {
                    []const u8 => {
                        const raw = weft.argStr(i) orelse return;
                        args[i] = take(raw, &owned, &held) orelse return;
                    },
                    ?[]const u8 => {
                        args[i] = if (weft.argStr(i)) |raw|
                            (take(raw, &owned, &held) orelse return)
                        else
                            null;
                    },
                    i32 => args[i] = weft.argInt(i),
                    ?i32 => args[i] = if (i < weft.argCount()) weft.argInt(i) else null,
                    else => @compileError(
                        "unsupported command parameter type " ++ @typeName(T) ++
                            " (use []const u8, ?[]const u8, i32, or ?i32)",
                    ),
                }
            }
            @call(.auto, f, args);
        }

        /// Copy `raw` off the shim scratch and record it for release.
        fn take(raw: []const u8, owned: [][]u8, held: *usize) ?[]const u8 {
            const copy = weft.allocator.dupe(u8, raw) catch return null;
            owned[held.*] = copy;
            held.* += 1;
            return copy;
        }
    }.call;
}
