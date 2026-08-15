//! Pick — the fuzzy-select primitive. One core mechanism, many uses:
//! the command palette is `pick-commands` over the registry's names, a
//! config can `scion.pick` its own items with a Fennel callback. State
//! is plain data the view renders (prompt, query, filtered items,
//! selection); interaction is ordinary commands bound in the "pick"
//! keymap mode, with `pick-input` as the mode's text command — the
//! picker adds no new input machinery at all.
//!
//! Entries carry an optional docstring the view renders beside the
//! text (the palette shows command summaries). Filtering is
//! subsequence match (case-insensitive) over the text, ranked by
//! tightness (span of the match), then by FRECENCY — what you accepted
//! recently under this prompt floats up, so an empty-query palette is
//! your recent-commands list. Recency is an ordinal use counter, not a
//! clock. Tab completes the query (common prefix of the matches, else
//! the selection).

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

/// One selectable item: the text is what matching and acceptance see;
/// the doc is display-only.
pub const Entry = struct {
    text: []const u8,
    doc: []const u8 = "",
};

pub const Pick = struct {
    active: bool = false,
    prompt: []u8 = &.{},
    items: std.ArrayList([]u8) = .empty,
    /// Parallel to `items`: display-only docstrings ("" when none).
    docs: std.ArrayList([]u8) = .empty,
    query: std.ArrayList(u8) = .empty,
    /// Indices into `items`, filtered by `query`, rank order.
    filtered: std.ArrayList(u32) = .empty,
    selected: usize = 0,
    acceptor: ?Acceptor = null,
    prev_mode: []u8 = &.{},
    /// "prompt\x00text" → use record; survives across opens (session
    /// scope). Keys owned.
    frecency: std.StringHashMapUnmanaged(Frec) = .empty,
    use_counter: u64 = 0,

    const Frec = struct { uses: u32, last: u64 };

    pub const empty: Pick = .{};

    pub fn deinit(self: *Pick, gpa: Allocator) void {
        self.clear(gpa);
        var it = self.frecency.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        self.frecency.deinit(gpa);
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
        for (self.docs.items) |d| gpa.free(d);
        self.docs.deinit(gpa);
        self.docs = .empty;
        self.query.deinit(gpa);
        self.query = .empty;
        self.filtered.deinit(gpa);
        self.filtered = .empty;
        self.selected = 0;
        gpa.free(self.prev_mode);
        self.prev_mode = &.{};
        self.active = false;
    }

    /// Open a pick session: copies `entries`, switches to "pick" mode.
    pub fn open(
        self: *Pick,
        ctx: *command.Context,
        prompt: []const u8,
        entries: []const Entry,
        acceptor: Acceptor,
    ) !void {
        const gpa = ctx.gpa;
        if (self.active) self.clear(gpa);
        self.prompt = try gpa.dupe(u8, prompt);
        for (entries) |e| {
            const owned = try gpa.dupe(u8, e.text);
            errdefer gpa.free(owned);
            try self.items.append(gpa, owned);
            const doc = try gpa.dupe(u8, e.doc);
            errdefer gpa.free(doc);
            try self.docs.append(gpa, doc);
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

    fn frecOf(self: *const Pick, text: []const u8) Frec {
        var key_buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}\x00{s}", .{ self.prompt, text }) catch return .{ .uses = 0, .last = 0 };
        return self.frecency.get(key) orelse .{ .uses = 0, .last = 0 };
    }

    /// Record an acceptance for frecency ranking.
    fn recordUse(self: *Pick, gpa: Allocator, text: []const u8) void {
        var key_buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}\x00{s}", .{ self.prompt, text }) catch return;
        self.use_counter += 1;
        if (self.frecency.getPtr(key)) |f| {
            f.uses +|= 1;
            f.last = self.use_counter;
            return;
        }
        const owned = gpa.dupe(u8, key) catch return;
        self.frecency.put(gpa, owned, .{ .uses = 1, .last = self.use_counter }) catch gpa.free(owned);
    }

    fn refilter(self: *Pick, gpa: Allocator) !void {
        self.filtered.clearRetainingCapacity();
        const Scored = struct { index: u32, span: usize, frec: Frec };
        var scored: std.ArrayList(Scored) = .empty;
        defer scored.deinit(gpa);
        for (self.items.items, 0..) |it, i| {
            if (matchSpan(self.query.items, it)) |span| {
                try scored.append(gpa, .{
                    .index = @intCast(i),
                    .span = span,
                    .frec = self.frecOf(it),
                });
            }
        }
        std.mem.sort(Scored, scored.items, {}, struct {
            fn lt(_: void, a: Scored, b: Scored) bool {
                if (a.span != b.span) return a.span < b.span;
                if (a.frec.last != b.frec.last) return a.frec.last > b.frec.last;
                if (a.frec.uses != b.frec.uses) return a.frec.uses > b.frec.uses;
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

    /// The docstring of the `i`-th filtered row.
    pub fn docOf(self: *const Pick, filtered_index: usize) []const u8 {
        return self.docs.items[self.filtered.items[filtered_index]];
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

/// Tab: complete the query — to the longest common prefix of the
/// matches when that extends it, else to the selected item.
fn cComplete(ctx: *command.Context, args: struct {}) anyerror!Value {
    _ = args;
    const p = pickOf(ctx);
    if (!p.active or p.filtered.items.len == 0) return .nil;
    var lcp = p.items.items[p.filtered.items[0]];
    for (p.filtered.items[1..]) |idx| {
        const it = p.items.items[idx];
        var n: usize = 0;
        while (n < @min(lcp.len, it.len) and std.ascii.toLower(lcp[n]) == std.ascii.toLower(it[n])) n += 1;
        lcp = lcp[0..n];
    }
    const target = if (lcp.len > p.query.items.len) lcp else p.selection().?;
    p.query.clearRetainingCapacity();
    try p.query.appendSlice(ctx.gpa, target);
    try p.refilter(ctx.gpa);
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
    p.recordUse(ctx.gpa, choice_src);
    const acceptor = p.acceptor.?;
    p.acceptor = null; // close() must not run cleanup before the call
    try p.close(ctx);
    defer if (acceptor.cleanup) |f| f(acceptor.data, ctx.gpa);
    try acceptor.handler(ctx, acceptor.data, choice);
    return .nil;
}

/// The command palette: pick over every command (summary as the
/// docstring), run the choice.
fn cPalette(ctx: *command.Context, args: struct {}) anyerror!Value {
    _ = args;
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(ctx.gpa);
    for (0..ctx.commands.count()) |i| {
        const n: command.Commands.Name = @enumFromInt(i);
        if (ctx.commands.lookup(n)) |cmd| {
            try entries.append(ctx.gpa, .{ .text = ctx.commands.nameOf(n), .doc = cmd.summary });
        }
    }
    try ctx.pick.open(ctx, "command", entries.items, .{ .handler = runChoice });
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
        command.define("pick-complete", "Complete the query (common prefix, else selection).", cComplete),
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
        .{ "Tab", "pick-complete" },
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

/// Replace the item set of a live pick, preserving query and selection
/// (race-and-refine consumers call this as results land).
pub fn refresh(p: *Pick, gpa: Allocator, items: []const []const u8) !void {
    if (!p.active) return;
    const keep = p.selection();
    const keep_owned = if (keep) |k| try gpa.dupe(u8, k) else null;
    defer if (keep_owned) |k| gpa.free(k);
    for (p.items.items) |it| gpa.free(it);
    p.items.clearRetainingCapacity();
    for (p.docs.items) |d| gpa.free(d);
    p.docs.clearRetainingCapacity();
    for (items) |it| {
        const owned = try gpa.dupe(u8, it);
        errdefer gpa.free(owned);
        try p.items.append(gpa, owned);
        const doc = try gpa.dupe(u8, "");
        errdefer gpa.free(doc);
        try p.docs.append(gpa, doc);
    }
    try p.refilter(gpa);
    if (keep_owned) |k| {
        for (p.filtered.items, 0..) |idx, i| {
            if (std.mem.eql(u8, p.items.items[idx], k)) {
                p.selected = i;
                break;
            }
        }
    }
}
