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
const Keymap = @import("Keymap.zig");

/// The portable argument/result ABI. Mirrors what a Lua boundary can
/// carry; strings are borrowed for the duration of the call.
pub const Value = union(enum) {
    nil,
    boolean: bool,
    integer: i64,
    number: f64,
    string: []const u8,
};

pub const Type = std.meta.Tag(Value);

pub const ArgSpec = struct {
    name: []const u8,
    type: Type,
};

/// Everything a handler may touch — the whole editor surface, because
/// commands ARE the editor's features. Commands only ever see this,
/// never core internals.
pub const Context = struct {
    gpa: Allocator,
    editor: *Editor,
    commands: *Commands,
    keymap: *Keymap,
    pick: *@import("pick.zig").Pick,
    quit: *bool,

    pub fn document(self: *Context) *Document {
        return &self.editor.doc;
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
        else => unreachable,
    };
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

fn insertText(ctx: *Context, args: struct { offset: i64, text: []const u8 }) anyerror!Value {
    try ctx.document().insert(ctx.gpa, @intCast(args.offset), args.text);
    return .{ .integer = @intCast(ctx.document().text().byteLen()) };
}

test "command: schema derivation, validation, late-bound run" {
    const gpa = t.allocator;
    const task = @import("task.zig");
    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var editor = try Editor.init(gpa, pool, "user");
    defer editor.deinit(gpa);
    var keymap: Keymap = .empty;
    defer keymap.deinit(gpa);
    var pick: @import("pick.zig").Pick = .empty;
    defer pick.deinit(gpa);
    var quit = false;

    var commands: Commands = .empty;
    defer commands.deinit(gpa);
    var ctx: Context = .{
        .gpa = gpa,
        .editor = &editor,
        .commands = &commands,
        .keymap = &keymap,
        .pick = &pick,
        .quit = &quit,
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
    try t.expectEqual(@as(usize, 0), editor.text().byteLen());

    const res = try run(&commands, &ctx, "insert-text", &.{
        .{ .integer = 0 }, .{ .string = "graft" },
    });
    try t.expectEqual(Value{ .integer = 5 }, res);
    try t.expectEqual(@as(usize, 5), editor.text().byteLen());
}
