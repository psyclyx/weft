//! Typed commands over a portable value ABI. A command is a name, a
//! typed argument schema, and a handler; invocation goes value-ABI in,
//! value-ABI out, so every caller — keymaps, the M5 Lua/Fennel VMs, other
//! commands — uses the same door. The schema is *derived* from a typed
//! Zig function at comptime (`define`), so built-in commands are ordinary
//! functions and the validation layer cannot drift from the signature.

const std = @import("std");
const Allocator = std.mem.Allocator;

const registry = @import("registry.zig");
const Document = @import("Document.zig");
const Editor = @import("Editor.zig");
const Buffers = @import("Buffers.zig");
const Keymap = @import("Keymap.zig");
const Actions = @import("action.zig");
const capability = @import("capability.zig");
const authority = @import("authority.zig");
const position = @import("position.zig");

pub const Principal = authority.Principal;
pub const Grade = authority.Grade;

/// The portable argument/result ABI. Mirrors what a Lua boundary can
/// carry; strings are borrowed for the duration of the call.
pub const Value = union(enum) {
    nil,
    boolean: bool,
    integer: i64,
    number: f64,
    string: []const u8,
    /// A version-stamped position ([FIX 1]): the honest way a position
    /// crosses the ABI. It rebases through the commit log to a current
    /// offset or to null — never a bare offset that silently breaks under
    /// concurrent edits. Backed by position.zig; borrowed for the call
    /// (its version token, like `string`). The prerequisite for
    /// motions-that-return-ranges and the pick pool's anchor column.
    anchor: position.StampedOffset,
    /// A version-stamped range — a stamped `(start, end)`.
    range: position.StampedRange,
};

pub const Type = std.meta.Tag(Value);

pub const ArgSpec = struct {
    name: []const u8,
    type: Type,
};

/// Everything a handler may touch — the whole editor surface, because
/// commands ARE the editor's features. Commands only ever see this,
/// never core internals. `editor()`/`document()` always mean the
/// ACTIVE buffer — a buffer switch mid-command redirects the rest of
/// the command, which is the honest semantics.
pub const Context = struct {
    gpa: Allocator,
    buffers: *Buffers,
    commands: *Commands,
    keymap: *Keymap,
    actions: *Actions,
    pick: *@import("pick.zig").Pick,
    caps: *@import("capability.zig").Caps,
    quit: *bool,
    /// Transient status-line message (`echo` writes it, the view shows
    /// it) — the generic report-back surface for commands and plugins.
    echo: *std.ArrayList(u8),
    /// Who is invoking right now (default: the interactive user). Plugins
    /// swap this in around their trampolines so their edits GRADE-gate as the
    /// plugin peer — see `plugin.zig`.
    principal: Principal = Principal.user,
    /// Set for the synchronous handling of a user keystroke/command. A helper
    /// plugin (dw, autopair, comment) editing under this flag is the USER's
    /// edit — it joins the user's single undo history (still grade-gated as the
    /// plugin). Cleared for AUTONOMOUS plugin/agent activity (async ticks,
    /// streaming), whose edits stay their own peer — the per-principal
    /// selective-undo property we keep for collaborators and agents.
    user_initiated: bool = false,

    pub fn buffer(self: *Context) *Buffers.Buffer {
        return self.buffers.active();
    }

    /// Snapshot the ambient facts an action's `when` predicate resolves
    /// against: the active keymap mode + the active buffer's language (its
    /// name's extension). Borrowed for the duration of the call.
    pub fn actionCtx(self: *Context) Actions.Ctx {
        return .{
            .mode = self.keymap.currentMode(),
            .lang = Actions.langOfName(self.buffers.active().name),
        };
    }

    /// Fire a `race`-policy intent (completion/hover/definition/…): the capability
    /// system's async fan-out. This is the seam the capability call sites route
    /// through instead of touching `caps` directly — it records the kind as a
    /// race action in the registry (so every intent, pick and race, is
    /// enumerable in one place) and then drives `Caps`, returning the session id
    /// to poll (or null when no provider matches). The consumer UIs own the
    /// session/poll lifecycle; this owns the dispatch entry.
    pub fn fireRace(
        self: *Context,
        kind: capability.Kind,
        doc: *Document,
        path: ?[]const u8,
        opts: capability.Caps.FireOptions,
    ) !?u64 {
        self.actions.noteRace(kind.actionName());
        return self.caps.fire(kind, doc, path, opts);
    }

    pub fn editor(self: *Context) *Editor {
        return &self.buffers.active().editor;
    }

    pub fn document(self: *Context) *Document {
        return &self.buffers.active().editor.doc;
    }

    pub const EditError = Document.AddPeerError || error{Unauthorized};

    /// The invoking principal's grade on `doc`. The user inherits the
    /// document's own grade; a plugin/agent may not exceed `.edit` (nor the
    /// user's grade), per the design's `min(owner_grant, manifest_max)`
    /// until per-plugin manifests bound it more tightly.
    pub fn gradeOn(self: *Context, doc: *Document) Grade {
        const local = doc.my_grant;
        return switch (self.principal.role) {
            .user, .remote => local,
            .plugin, .agent => authority.gradeMin(local, .edit),
        };
    }

    /// The one door a command mutates text through: delete `r` and insert
    /// `bytes` on the ACTIVE document, authored by the invoking principal
    /// and gated by its grade. The user path is one undoable unit; a plugin
    /// peer path syncs the plugin's shadow to head, applies at head-valid
    /// offsets, and commits as that peer (its own selective-undo unit).
    /// Cursor/selection are the caller's concern (they are local UI, not
    /// edits). Refuses with `error.Unauthorized` when the principal's grade
    /// cannot edit — the replica is left untouched, so no ghost can form.
    pub fn edit(self: *Context, r: Document.Range, bytes: []const u8) EditError!void {
        const doc = self.document();
        if (!self.gradeOn(doc).canEdit()) return error.Unauthorized;
        // The user typing, OR a helper plugin (dw/autopair/comment) executing
        // the user's keystroke, is the USER's edit → one undo history. The
        // grade was still checked as the plugin above, so an over-grade plugin
        // is refused. A plugin/agent editing AUTONOMOUSLY (not `user_initiated`)
        // commits as its own peer — its own selective-undo unit.
        if (self.principal.role == .user or self.user_initiated) {
            try self.editor().applyUserEdit(self.gpa, r, bytes);
            return;
        }
        const pid = try self.principal.peerOn(doc);
        // Sync the peer's shadow to head so `r` (in head coordinates) is
        // valid against it, then delete-then-insert and merge as one commit.
        var snap = try doc.peerSnapshot(self.gpa, pid);
        snap.deinit(self.gpa);
        if (!r.isEmpty()) try doc.peerDelete(self.gpa, pid, r);
        if (bytes.len > 0) try doc.peerInsert(self.gpa, pid, r.start, bytes);
        _ = try doc.peerCommit(self.gpa, pid);
    }
};

pub const Command = struct {
    name: []const u8,
    summary: []const u8,
    args: []const ArgSpec,
    /// `data` is the command's closure payload (null for comptime-typed
    /// commands; a VM trampoline for scripted ones).
    handler: *const fn (ctx: *Context, data: ?*anyopaque, args: []const Value) anyerror!Value,
    data: ?*anyopaque = null,
};

pub const Commands = registry.Registry(Command);

pub const RunError = error{UnknownCommand} || anyerror;

/// Invoke by name — resolution happens *now* (late binding), then the
/// schema-checking wrapper validates `args` before the typed handler
/// runs.
pub fn run(commands: *const Commands, ctx: *Context, name: []const u8, args: []const Value) RunError!Value {
    const cmd = commands.resolve(name) orelse return error.UnknownCommand;
    return cmd.handler(ctx, cmd.data, args);
}

/// The trampoline a declared action is registered under (see `registerAction`):
/// resolve the action name against the live context and tail-call the winning
/// provider's command with the same args. A `pick` action with no applicable
/// provider is a graceful no-op with feedback (never an error — pressing an
/// action key in the wrong buffer should explain, not fail). A `race` action's
/// synchronous trampoline resolves nothing (its providers answer over time
/// through `Caps`); it's a no-op here by design, surfaced as such.
pub fn actionTrampoline(ctx: *Context, data: ?*anyopaque, args: []const Value) anyerror!Value {
    const tr: *Actions.Trampoline = @ptrCast(@alignCast(data.?));
    if (ctx.actions.resolve(tr.name, ctx.actionCtx())) |cmd| {
        return run(ctx.commands, ctx, cmd, args);
    }
    ctx.echo.clearRetainingCapacity();
    const lang = Actions.langOfName(ctx.buffers.active().name);
    var buf: [128]u8 = undefined;
    const msg = if (lang.len > 0)
        std.fmt.bufPrint(&buf, "no {s} provider for .{s}", .{ tr.name, lang }) catch tr.name
    else
        std.fmt.bufPrint(&buf, "no {s} provider here", .{tr.name}) catch tr.name;
    ctx.echo.appendSlice(ctx.gpa, msg) catch {};
    return .nil;
}

/// Declare an action and bind its same-named trampoline `Command`, so the
/// keymap, ex, palette, and `command.run` all dispatch it uniformly. Idempotent
/// per the underlying `Actions.declare`; a re-declare just binds another
/// trampoline for the same name (they resolve identically).
pub fn registerAction(
    gpa: Allocator,
    commands: *Commands,
    actions: *Actions,
    name: []const u8,
    policy: Actions.Policy,
) !void {
    const tr = try actions.declare(name, policy);
    _ = try commands.bind(gpa, name, .{
        .name = name,
        .summary = "action",
        .args = &.{},
        .handler = actionTrampoline,
        .data = tr,
    });
}

/// Derive a `Command` from a typed function at comptime. `f` must be
/// `fn (*Context, Args) anyerror!Value` where `Args` is a struct whose
/// fields are `bool`, `i64`, `f64`, `[]const u8`, or `Value` (untyped
/// passthrough). Field order is the positional argument order; the
/// generated wrapper checks arity and types against the schema.
pub fn define(
    comptime name: []const u8,
    comptime summary: []const u8,
    comptime f: anytype,
) Command {
    const Args = ArgsStructOf(f);
    const fields = @typeInfo(Args).@"struct".fields;

    const specs = comptime blk: {
        var s: [fields.len]ArgSpec = undefined;
        for (fields, 0..) |fld, i| {
            s[i] = .{ .name = fld.name, .type = typeOf(fld.type) };
        }
        const frozen = s;
        break :blk frozen;
    };

    const Wrap = struct {
        fn call(ctx: *Context, data: ?*anyopaque, args: []const Value) anyerror!Value {
            _ = data;
            if (args.len != fields.len) return error.ArityMismatch;
            var typed: Args = undefined;
            inline for (fields, 0..) |fld, i| {
                @field(typed, fld.name) = try unpack(fld.type, args[i]);
            }
            return f(ctx, typed);
        }
    };

    return .{
        .name = name,
        .summary = summary,
        .args = &specs,
        .handler = Wrap.call,
    };
}

fn ArgsStructOf(comptime f: anytype) type {
    const params = @typeInfo(@TypeOf(f)).@"fn".params;
    if (params.len != 2 or params[0].type != *Context) {
        @compileError("command fn must be fn (*Context, Args) anyerror!Value");
    }
    return params[1].type.?;
}

fn typeOf(comptime T: type) Type {
    return switch (T) {
        bool => .boolean,
        i64 => .integer,
        f64 => .number,
        []const u8 => .string,
        position.StampedOffset => .anchor,
        position.StampedRange => .range,
        Value => .nil, // untyped: schema says nil-able, wrapper passes through
        else => @compileError("unsupported command arg type " ++ @typeName(T)),
    };
}

fn unpack(comptime T: type, v: Value) error{TypeMismatch}!T {
    if (T == Value) return v;
    return switch (T) {
        bool => if (v == .boolean) v.boolean else error.TypeMismatch,
        i64 => if (v == .integer) v.integer else error.TypeMismatch,
        f64 => if (v == .number) v.number else error.TypeMismatch,
        []const u8 => if (v == .string) v.string else error.TypeMismatch,
        position.StampedOffset => if (v == .anchor) v.anchor else error.TypeMismatch,
        position.StampedRange => if (v == .range) v.range else error.TypeMismatch,
        else => unreachable,
    };
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

fn insertText(ctx: *Context, args: struct { offset: i64, text: []const u8 }) anyerror!Value {
    try ctx.document().insert(ctx.gpa, @intCast(args.offset), args.text);
    return .{ .integer = @intCast(ctx.document().text().byteLen()) };
}

test "command Value: a stamped range rebases through a concurrent edit or nulls" {
    const gpa = t.allocator;
    var doc = try Document.init(gpa, "user");
    defer doc.deinit(gpa);
    try doc.insert(gpa, 0, "hello");
    const v0 = try doc.version(gpa);
    defer gpa.free(v0);

    // Carry a stamped range as an ABI Value; a concurrent head insert shifts
    // it, and it rebases to the current offsets (never a bare stale offset).
    const val: Value = .{ .range = position.StampedRange.at(v0, 0, 5) };
    try doc.insert(gpa, 0, "XYZ");
    const r = val.range.rebase(&doc).?;
    try t.expectEqual(@as(usize, 3), r.start);
    try t.expectEqual(@as(usize, 8), r.end);

    // An unknown version rebases to null — rebase or discard, no third result.
    const bogus: Value = .{ .range = position.StampedRange.at("nope", 0, 5) };
    try t.expectEqual(@as(?Document.Range, null), bogus.range.rebase(&doc));

    // The value survives the typed-arg door too (unpack round-trips it).
    try t.expectEqual(Type.range, comptime typeOf(position.StampedRange));
}

test "command: schema derivation, validation, late-bound run" {
    const gpa = t.allocator;
    const task = @import("task.zig");
    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var buffers = try Buffers.init(gpa, pool, "user");
    defer buffers.deinit(gpa);
    var keymap: Keymap = .empty;
    defer keymap.deinit(gpa);
    var pick: @import("pick.zig").Pick = .empty;
    defer pick.deinit(gpa);
    var caps = @import("capability.zig").Caps.init(gpa, @import("task.zig").nowNs);
    defer caps.deinit();
    var actions = Actions.init(gpa);
    defer actions.deinit();
    var quit = false;
    var echo_line: std.ArrayList(u8) = .empty;
    defer echo_line.deinit(gpa);

    var commands: Commands = .empty;
    defer commands.deinit(gpa);
    var ctx: Context = .{
        .gpa = gpa,
        .buffers = &buffers,
        .commands = &commands,
        .keymap = &keymap,
        .actions = &actions,
        .pick = &pick,
        .caps = &caps,
        .quit = &quit,
        .echo = &echo_line,
    };

    // Late binding: invoked-by-name before it exists → UnknownCommand.
    try t.expectError(error.UnknownCommand, run(&commands, &ctx, "insert-text", &.{}));

    const cmd = comptime define("insert-text", "Insert text at a byte offset.", insertText);
    try t.expectEqual(@as(usize, 2), cmd.args.len);
    try t.expectEqual(Type.integer, cmd.args[0].type);
    try t.expectEqual(Type.string, cmd.args[1].type);
    try t.expectEqualStrings("offset", cmd.args[0].name);
    _ = try commands.bind(gpa, "insert-text", cmd);

    // Wrong arity / wrong types are rejected before the handler runs.
    try t.expectError(error.ArityMismatch, run(&commands, &ctx, "insert-text", &.{.nil}));
    try t.expectError(error.TypeMismatch, run(&commands, &ctx, "insert-text", &.{
        .{ .string = "oops" }, .{ .string = "hi" },
    }));
    try t.expectEqual(@as(usize, 0), buffers.active().editor.text().byteLen());

    const res = try run(&commands, &ctx, "insert-text", &.{
        .{ .integer = 0 }, .{ .string = "graft" },
    });
    try t.expectEqual(Value{ .integer = 5 }, res);
    try t.expectEqual(@as(usize, 5), buffers.active().editor.text().byteLen());
}
