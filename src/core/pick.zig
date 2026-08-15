//! Pick — the fuzzy-select primitive. One core mechanism, many uses:
//! the command palette is `pick-commands` over the registry's names, a
//! config can `scion.pick` its own items with a Fennel callback. State
//! is plain data the view renders (prompt, query, filtered items,
//! selection); interaction is ordinary commands bound in the "pick"
//! keymap mode, with `pick-input` as the mode's text command — the
//! picker adds no new input machinery at all.
//!
//! Filtering is subsequence match (case-insensitive), ranked by
//! tightness (span of the match), then by item order.

const std = @import("std");
const Allocator = std.mem.Allocator;

const command = @import("command.zig");
const Value = command.Value;

pub const Acceptor = struct {
    handler: *const fn (ctx: *command.Context, data: ?*anyopaque, choice: []const u8) anyerror!void,
    /// Called exactly once when the pick closes (accept or cancel).
    cleanup: ?*const fn (data: ?*anyopaque, gpa: Allocator) void = null,
    data: ?*anyopaque = null,
};

pub const Pick = struct {
    active: bool = false,
    prompt: []u8 = &.{},
    items: std.ArrayList([]u8) = .empty,
    query: std.ArrayList(u8) = .empty,
    /// Indices into `items`, filtered by `query`, rank order.
    filtered: std.ArrayList(u32) = .empty,
    selected: usize = 0,
    acceptor: ?Acceptor = null,
    prev_mode: []u8 = &.{},

    pub const empty: Pick = .{};

    pub fn deinit(self: *Pick, gpa: Allocator) void {
        self.clear(gpa);
        self.* = .{};
    }

    fn clear(self: *Pick, gpa: Allocator) void {
        if (self.acceptor) |a| {
            if (a.cleanup) |f| f(a.data, gpa);
        }
        self.acceptor = null;
        gpa.free(self.prompt);
        self.prompt = &.{};
        for (self.items.items) |it| gpa.free(it);
        self.items.deinit(gpa);
        self.items = .empty;
        self.query.deinit(gpa);
        self.query = .empty;
        self.filtered.deinit(gpa);
        self.filtered = .empty;
        self.selected = 0;
        gpa.free(self.prev_mode);
        self.prev_mode = &.{};
        self.active = false;
    }

    /// Open a pick session: copies `items`, switches to "pick" mode.
    pub fn open(
        self: *Pick,
        ctx: *command.Context,
        prompt: []const u8,
        items: []const []const u8,
        acceptor: Acceptor,
    ) !void {
        const gpa = ctx.gpa;
        if (self.active) self.clear(gpa);
        self.prompt = try gpa.dupe(u8, prompt);
        for (items) |it| {
            const owned = try gpa.dupe(u8, it);
            errdefer gpa.free(owned);
            try self.items.append(gpa, owned);
        }
        self.acceptor = acceptor;
        self.prev_mode = try gpa.dupe(u8, ctx.keymap.currentMode());
        self.active = true;
        try self.refilter(gpa);
        try ctx.keymap.setMode(gpa, "pick");
    }

    fn close(self: *Pick, ctx: *command.Context) !void {
        const prev = try ctx.gpa.dupe(u8, self.prev_mode);
        defer ctx.gpa.free(prev);
        self.clear(ctx.gpa);
        try ctx.keymap.setMode(ctx.gpa, prev);
    }

    fn refilter(self: *Pick, gpa: Allocator) !void {
        self.filtered.clearRetainingCapacity();
        const Scored = struct { index: u32, span: usize };
        var scored: std.ArrayList(Scored) = .empty;
        defer scored.deinit(gpa);
        for (self.items.items, 0..) |it, i| {
            if (matchSpan(self.query.items, it)) |span| {
                try scored.append(gpa, .{ .index = @intCast(i), .span = span });
            }
        }
        std.mem.sort(Scored, scored.items, {}, struct {
            fn lt(_: void, a: Scored, b: Scored) bool {
                if (a.span != b.span) return a.span < b.span;
                return a.index < b.index;
            }
        }.lt);
        for (scored.items) |s| try self.filtered.append(gpa, s.index);
        if (self.selected >= self.filtered.items.len) self.selected = 0;
    }

    /// Current choice's text, if any.
    pub fn selection(self: *const Pick) ?[]const u8 {
        if (self.filtered.items.len == 0) return null;
        return self.items.items[self.filtered.items[self.selected]];
    }
};

/// Byte span of the tightest greedy case-insensitive subsequence match,
/// or null. Empty query matches everything with span 0.
fn matchSpan(query: []const u8, item: []const u8) ?usize {
    if (query.len == 0) return 0;
    var qi: usize = 0;
    var first: ?usize = null;
    var last: usize = 0;
    for (item, 0..) |ch, i| {
        if (std.ascii.toLower(ch) == std.ascii.toLower(query[qi])) {
            if (first == null) first = i;
            last = i;
            qi += 1;
            if (qi == query.len) return last - first.? + 1;
        }
    }
    return null;
}

// ── Commands ────────────────────────────────────────────────────────

fn pickOf(ctx: *command.Context) *Pick {
    return ctx.pick;
}

fn cInput(ctx: *command.Context, args: struct { text: []const u8 }) anyerror!Value {
    const p = pickOf(ctx);
    if (!p.active) return .nil;
    try p.query.appendSlice(ctx.gpa, args.text);
    try p.refilter(ctx.gpa);
    return .nil;
}

fn cBackspace(ctx: *command.Context, args: struct {}) anyerror!Value {
    _ = args;
    const p = pickOf(ctx);
    if (!p.active) return .nil;
    while (p.query.items.len > 0) {
        const b = p.query.items[p.query.items.len - 1];
        p.query.items.len -= 1;
        if (b & 0xC0 != 0x80) break; // whole scalar removed
    }
    try p.refilter(ctx.gpa);
    return .nil;
}

fn cNext(ctx: *command.Context, args: struct {}) anyerror!Value {
    _ = args;
    const p = pickOf(ctx);
    if (p.active and p.filtered.items.len > 0) {
        p.selected = (p.selected + 1) % p.filtered.items.len;
    }
    return .nil;
}

fn cPrev(ctx: *command.Context, args: struct {}) anyerror!Value {
    _ = args;
    const p = pickOf(ctx);
    if (p.active and p.filtered.items.len > 0) {
        p.selected = (p.selected + p.filtered.items.len - 1) % p.filtered.items.len;
    }
    return .nil;
}

fn cCancel(ctx: *command.Context, args: struct {}) anyerror!Value {
    _ = args;
    const p = pickOf(ctx);
    if (p.active) try p.close(ctx);
    return .nil;
}

fn cAccept(ctx: *command.Context, args: struct {}) anyerror!Value {
    _ = args;
    const p = pickOf(ctx);
    if (!p.active) return .nil;
    const choice_src = p.selection() orelse {
        try p.close(ctx);
        return .nil;
    };
    // The acceptor may open another pick; hand it a stable copy and
    // close first.
    const choice = try ctx.gpa.dupe(u8, choice_src);
    defer ctx.gpa.free(choice);
    const acceptor = p.acceptor.?;
    p.acceptor = null; // close() must not run cleanup before the call
    try p.close(ctx);
    defer if (acceptor.cleanup) |f| f(acceptor.data, ctx.gpa);
    try acceptor.handler(ctx, acceptor.data, choice);
    return .nil;
}

/// The command palette: pick over every command name, run the choice.
fn cPalette(ctx: *command.Context, args: struct {}) anyerror!Value {
    _ = args;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(ctx.gpa);
    for (0..ctx.commands.count()) |i| {
        const n: command.Commands.Name = @enumFromInt(i);
        if (ctx.commands.lookup(n) != null) {
            try names.append(ctx.gpa, ctx.commands.nameOf(n));
        }
    }
    try ctx.pick.open(ctx, "command", names.items, .{ .handler = runChoice });
    return .nil;
}

fn runChoice(ctx: *command.Context, data: ?*anyopaque, choice: []const u8) anyerror!void {
    _ = data;
    _ = command.run(ctx.commands, ctx, choice, &.{}) catch |err| {
        std.log.warn("palette: {s} failed: {t}", .{ choice, err });
    };
}

/// Register pick commands + the "pick" mode bindings.
pub fn install(gpa: Allocator, commands: *command.Commands, keymap: *@import("Keymap.zig")) !void {
    const defs = [_]command.Command{
        command.define("pick-input", "Append text to the pick query.", cInput),
        command.define("pick-backspace", "Delete the last query character.", cBackspace),
        command.define("pick-next", "Select the next match.", cNext),
        command.define("pick-prev", "Select the previous match.", cPrev),
        command.define("pick-accept", "Accept the selected match.", cAccept),
        command.define("pick-cancel", "Close the picker.", cCancel),
        command.define("pick-commands", "Open the command palette.", cPalette),
    };
    for (defs) |cmd| _ = try commands.bind(gpa, cmd.name, cmd);

    const binds = [_][2][]const u8{
        .{ "Return", "pick-accept" },
        .{ "Escape", "pick-cancel" },
        .{ "C-g", "pick-cancel" },
        .{ "BackSpace", "pick-backspace" },
        .{ "Down", "pick-next" },
        .{ "Up", "pick-prev" },
        .{ "C-n", "pick-next" },
        .{ "C-p", "pick-prev" },
        .{ "Tab", "pick-next" },
    };
    for (binds) |b| try keymap.bind(gpa, "pick", b[0], b[1]);
    try keymap.setTextCommand(gpa, "pick", "pick-input");
    _ = try commands.bind(gpa, "palette", (comptime command.define("palette", "Open the command palette.", cPalette)));
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "matchSpan: subsequence with tightness" {
    try t.expectEqual(@as(?usize, 0), matchSpan("", "anything"));
    try t.expectEqual(@as(?usize, null), matchSpan("xyz", "cursor-left"));
    try t.expectEqual(@as(?usize, 4), matchSpan("save", "save"));
    try t.expect(matchSpan("cl", "cursor-left") != null);
    try t.expect(matchSpan("CL", "cursor-left") != null);
}

test {
    std.testing.refAllDecls(@This());
}
