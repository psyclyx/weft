//! Unsaved work across every entry — what quitting would lose — and the doors
//! around it: quitting, saving all of it, and running a command once the
//! saves in flight have landed.
//!
//! Quitting is an ACTION (`app.quit`), for the reason `save` and `close` are:
//! what to do about the work a quit would lose is a question a plugin may
//! answer — by asking (the `buffers` plugin offers save-all, discard and
//! cancel). Core's own provider is the floor a config without one gets: it
//! quits when nothing would be lost and otherwise refuses, naming what.
//! `app.quit-force` quits regardless.
//!
//! What counts is one census (`collect`), read by the floor's refusal, by the
//! `app.unsaved` data source an asking provider names things from, and by
//! `file.save-all`: a file's unsaved edits (`file` — save-all writes them), a
//! listing's unapplied draft (`draft` — saved where it is), and text with no
//! file behind it, open or parked (`text` — only Save As keeps it).
//!
//! A save is a fallible REQUEST (`Editor.requestSave`): it lands, or fails,
//! frames later. So "save, then quit" cannot be two commands in a row — the
//! quit would still see the file unsaved. `file.when-saved <command>` holds the
//! command until every save it was armed behind has settled (the frame folds
//! saves, then calls `settle`), runs it if they all landed, and drops it —
//! naming what failed — if any did not.

const std = @import("std");
const Allocator = std.mem.Allocator;
const command = @import("command.zig");
const Buffers = @import("Buffers.zig");
const Actions = @import("action.zig");
const builtins = @import("builtins.zig");

const Context = command.Context;
const Value = command.Value;
const ok: Value = .nil;

/// What an entry would lose to a quit.
pub const Kind = enum {
    /// Edits its file never received; `file.save-all` writes them.
    file,
    /// A draft one of its views holds that its provider has not applied.
    draft,
    /// Text with no file behind it — a scratch, or one parked on close.
    text,
};

pub const Item = struct {
    kind: Kind,
    /// What a person calls it: the file's base name, else the entry's name.
    /// Borrowed from the entry.
    name: []const u8,
};

/// What `b` would lose to a quit, or null when nothing.
pub fn kindOf(ctx: *Context, b: *Buffers.Buffer) ?Kind {
    if (b.hasUnsavedFile(ctx.gpa) catch true) return .file;
    if (builtins.holdsUnsavedWork(ctx, b)) return .draft;
    if (b.keepsDocument()) return .text;
    return null;
}

fn shownName(b: *Buffers.Buffer) []const u8 {
    const ed = b.textEditor() orelse return b.name;
    return std.fs.path.basename(ed.backingPath() orelse b.name);
}

/// The census: every entry, open or parked, holding work a quit would lose.
pub fn collect(ctx: *Context, out: *std.ArrayList(Item)) Allocator.Error!void {
    var it = ctx.buffers.iterator();
    while (it.next()) |b| {
        const kind = kindOf(ctx, b) orelse continue;
        try out.append(ctx.gpa, .{ .kind = kind, .name = shownName(b) });
    }
    for (ctx.buffers.parked.items) |b| try out.append(ctx.gpa, .{ .kind = .text, .name = b.name });
}

/// `a.txt, b.txt, *scratch* and 2 more` — the first few names, for one line.
fn writeNames(w: *std.Io.Writer, items: []const Item) void {
    const shown = 4;
    for (items[0..@min(items.len, shown)], 0..) |item, i| {
        w.print("{s}{s}", .{ if (i == 0) "" else ", ", item.name }) catch return;
    }
    if (items.len > shown) w.print(" and {d} more", .{items.len - shown}) catch return;
}

// ── Quitting ────────────────────────────────────────────────────────────

/// The floor `app.quit` provider: quit when nothing would be lost, else
/// refuse and say what — and how to quit anyway.
fn cQuitUnlessUnsaved(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    var items: std.ArrayList(Item) = .empty;
    defer items.deinit(ctx.gpa);
    try collect(ctx, &items);
    if (items.items.len == 0) {
        ctx.quit.* = true;
        return ok;
    }
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print("not quitting: {d} unsaved (", .{items.items.len}) catch {};
    writeNames(&w, items.items);
    w.writeAll(") — save, or Quit Without Saving") catch {};
    try ctx.head.echo.say(ctx.gpa, w.buffered());
    // Refused, said already: a string here would be echoed over the reason.
    return .{ .boolean = false };
}

fn cQuitForce(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    ctx.quit.* = true;
    return ok;
}

/// `app.unsaved`: the census as a data source, one `kind<TAB>name` line per
/// entry (`file`, `draft`, `text`), empty when a quit would lose nothing.
/// Borrowed until the next call.
fn cUnsaved(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    var items: std.ArrayList(Item) = .empty;
    defer items.deinit(ctx.gpa);
    try collect(ctx, &items);
    const listing = &ctx.buffers.unsaved_listing;
    listing.clearRetainingCapacity();
    for (items.items) |item| {
        try listing.appendSlice(ctx.gpa, @tagName(item.kind));
        try listing.append(ctx.gpa, '\t');
        try listing.appendSlice(ctx.gpa, item.name);
        try listing.append(ctx.gpa, '\n');
    }
    return .{ .string = listing.items };
}

// ── Saving all ──────────────────────────────────────────────────────────

/// `file.save-all`: request a save for every entry with unsaved file edits,
/// and say what that leaves unsaved — a draft is saved where it is, text with
/// no file only by Save As. Answers how many saves it requested.
fn cSaveAll(ctx: *Context, args: struct {}) anyerror!Value {
    _ = args;
    var requested: i64 = 0;
    var it = ctx.buffers.iterator();
    while (it.next()) |b| {
        if (!(b.hasUnsavedFile(ctx.gpa) catch false)) continue;
        try b.textEditor().?.requestSave(ctx.gpa);
        requested += 1;
    }
    var items: std.ArrayList(Item) = .empty;
    defer items.deinit(ctx.gpa);
    try collect(ctx, &items);
    // The files just requested still read unsaved until their saves land.
    var left: usize = 0;
    for (items.items) |item| {
        if (item.kind == .file) continue;
        items.items[left] = item;
        left += 1;
    }
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    if (requested == 0 and left == 0) {
        w.writeAll("nothing to save") catch {};
    } else {
        w.print("saving {d} file{s}", .{ requested, if (requested == 1) "" else "s" }) catch {};
        if (left > 0) {
            w.writeAll("; still unsaved: ") catch {};
            writeNames(&w, items.items[0..left]);
        }
    }
    try ctx.head.echo.say(ctx.gpa, w.buffered());
    return .{ .integer = requested };
}

// ── Running something once the saves land ───────────────────────────────

/// A command held until the saves it was armed behind settle
/// (`Buffers.after_saves`).
pub const AfterSaves = struct {
    /// What to run then. Owned.
    command: []u8,
    /// The entries whose saves it waits on.
    entries: std.ArrayList(Buffers.Id) = .empty,

    pub fn deinit(self: *AfterSaves, gpa: Allocator) void {
        gpa.free(self.command);
        self.entries.deinit(gpa);
        self.* = undefined;
    }
};

/// `file.when-saved <command>`: run `command` once every save in flight has
/// landed. A save that fails — or one that failed already and still has edits
/// to lose — drops it instead, and says which. With nothing in flight it runs
/// now. Arming again replaces what was waiting.
fn cWhenSaved(ctx: *Context, args: struct { command: []const u8 }) anyerror!Value {
    if (ctx.commands.resolve(args.command) == null) return error.UnknownCommand;
    var waiting: AfterSaves = .{ .command = try ctx.gpa.dupe(u8, args.command) };
    errdefer waiting.deinit(ctx.gpa);
    var it = ctx.buffers.iterator();
    while (it.next()) |b| {
        const ed = b.textEditor() orelse continue;
        const waits = switch (ed.save_state) {
            .saving, .stale => true,
            .failed => b.hasUnsavedFile(ctx.gpa) catch true,
            .idle => false,
        };
        if (waits) try waiting.entries.append(ctx.gpa, b.id);
    }
    if (ctx.buffers.after_saves) |*prior| prior.deinit(ctx.gpa);
    ctx.buffers.after_saves = waiting;
    _ = try settle(ctx);
    return ok;
}

/// Run what `file.when-saved` holds if the saves it waits on have settled —
/// called by the frame after it folds saves, and on arming. True when it ran
/// (or was dropped), which changes what is on screen.
pub fn settle(ctx: *Context) !bool {
    const waiting = if (ctx.buffers.after_saves) |*w| w else return false;
    var failed: std.ArrayList(Item) = .empty;
    defer failed.deinit(ctx.gpa);
    var reason: ?anyerror = null;
    for (waiting.entries.items) |id| {
        // An entry closed while it saved has nothing left to wait for.
        const b = ctx.buffers.get(id) orelse continue;
        const ed = b.textEditor() orelse continue;
        switch (ed.save_state) {
            .saving, .stale => return false,
            .failed => |err| {
                try failed.append(ctx.gpa, .{ .kind = .file, .name = shownName(b) });
                reason = reason orelse err;
            },
            .idle => {},
        }
    }
    var held = waiting.*;
    ctx.buffers.after_saves = null;
    defer held.deinit(ctx.gpa);
    if (failed.items.len > 0) {
        const label = if (ctx.commands.resolve(held.command)) |c| (if (c.meta.label.len > 0) c.meta.label else held.command) else held.command;
        var buf: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        w.print("{s} cancelled: couldn't save ", .{label}) catch {};
        writeNames(&w, failed.items);
        w.print(" ({t})", .{reason.?}) catch {};
        try ctx.head.echo.say(ctx.gpa, w.buffered());
        return true;
    }
    command.invoke(ctx.commands, ctx, held.command, &.{});
    return true;
}

// ── Registration ────────────────────────────────────────────────────────

const table = [_]command.Command{
    command.define("app.quit-unless-unsaved", "Quit the editor, refusing while anything unsaved would be lost.", cQuitUnlessUnsaved).present(.{ .internal = true }),
    command.define("app.quit-force", "Quit the editor, discarding anything unsaved.", cQuitForce).present(.{ .label = "Quit Without Saving" }),
    command.define("app.unsaved", "What quitting would lose, one kind and name a line (a data source).", cUnsaved).present(.{ .internal = true }),
    command.define("file.save-all", "Save every file with unsaved edits.", cSaveAll).present(.{ .label = "Save All", .icon = "save" }),
    command.define("file.when-saved", "Run a command once the saves in flight have landed, or not at all if one fails.", cWhenSaved).present(.{ .internal = true }),
};

pub fn install(gpa: Allocator, commands: *command.Commands, actions: *Actions) !void {
    for (table) |cmd| _ = try commands.bind(gpa, cmd.name, cmd);
    // `quit` is an ACTION: C-q, `:q`, the menu, the palette and the window's
    // close button all dispatch it, and a plugin that would rather ask than
    // refuse provides it. Priority -1 keeps core's the floor any provider wins.
    try command.registerAction(gpa, commands, actions, "app.quit", .pick, "Quit the editor, letting its provider ask about anything unsaved.", .{
        .label = "Quit",
        .icon = "log-out",
    });
    try actions.provide(.{ .action = "app.quit", .command = "app.quit-unless-unsaved", .priority = -1, .owner = "core" });
}
