//! The `Pick` state machine + its interaction layer: the live pick state
//! (prompt, query, filtered items, selection, frecency, sticky narrowing),
//! the open/close lifecycle with "pick" mode save-restore, the async source
//! driver (`tick`), and the pick commands bound in the "pick" keymap mode.
//! Filtering/ranking delegates to the pure matcher in `match.zig`; the
//! configuration value types come from `types.zig`.
//!
//! `buildSurface` (rendering P2 — doc/rendering.md) is Pick's OWN scene
//! builder: the caret-anchored completion list (item + dimmed kind/detail
//! note columns, the selected row's docs as a linked info panel) and the
//! window-bottom dock (query line + item rows) used to be assembled by the
//! render layer (`gfx/view/popup.zig`'s `pickSurface`/`drawPickInto`) reading
//! `Pick`'s fields directly. Pick is "the consumer" now — it knows its own
//! shape; the render layer (`popup.zig`'s `drawCaretSurface`/
//! `drawDockSurface`) only knows `core.surface.Surface`, the same generic
//! scene which-key/dired/magit already draw through.

const std = @import("std");
const Allocator = std.mem.Allocator;

const command = @import("../command.zig");
const task = @import("../task.zig");
const Value = command.Value;
const surface = @import("../surface.zig");

const match = @import("match.zig");
const Match = match.Match;
const matchScore = match.matchScore;
const orderlessMatch = match.orderlessMatch;
const Style = match.Style;

const types = @import("types.zig");
const Acceptor = types.Acceptor;
const Outcome = types.Outcome;
const Source = types.Source;
const Options = types.Options;
const Entry = types.Entry;

const Pick = @This();

active: bool = false,
/// Set only while the owning head is being torn down. Cancellation handlers
/// may normally open a replacement picker; termination closes that door so no
/// callback can be installed after its plugin/context has begun to die.
terminating: bool = false,
prompt: []u8 = &.{},
items: std.ArrayList([]u8) = .empty,
/// Parallel to `items`: display-only docstrings ("" when none).
docs: std.ArrayList([]u8) = .empty,
/// Parallel to `items`: the full info body (completion documentation) shown in a
/// side popup for the selected row ("" when none).
infos: std.ArrayList([]u8) = .empty,
query: std.ArrayList(u8) = .empty,
/// Indices into `items`, filtered by `query`, rank order.
filtered: std.ArrayList(u32) = .empty,
selected: usize = 0,
acceptor: ?Acceptor = null,
prev_mode: []u8 = &.{},
/// Accept the typed query, not only a candidate (see `Options`).
allow_free_text: bool = false,
/// Async candidate producer for this pick (null = static list).
source: ?Source = null,
/// Bumped on every query mutation; the source acts when it lags.
query_epoch: u64 = 0,
source_epoch: u64 = 0,
/// `task.nowNs()` of the last query mutation (debounce baseline).
last_query_ns: u64 = 0,
/// "prompt\x00text" → use record; survives across opens (session
/// scope). Keys owned.
frecency: std.StringHashMapUnmanaged(Frec) = .empty,
use_counter: u64 = 0,
/// Completion style for the live query (default orderless).
style: Style = .orderless,
/// A byte offset to anchor the popup AT (completion): the view draws the
/// list just below that caret line instead of the window-bottom dock. Null =
/// the ordinary bottom dock (command palette, buffer switch, file find).
caret_anchor: ?usize = null,
/// Sticky narrowing filter (space-joined tokens): a candidate must
/// match it (orderless) IN ADDITION to the live query. `pick-narrow`
/// promotes the current query into it and clears the query; a further
/// `pick-narrow` ANDs another facet; `pick-widen` clears it.
narrow: std.ArrayList(u8) = .empty,

const Frec = struct { uses: u32, last: u64 };

pub const empty: Pick = .{};

pub fn deinit(self: *Pick, gpa: Allocator) void {
    // A live acceptor needs a command.Context so it can observe cancellation.
    // Owners must call terminate before destroying that context;
    // silently clearing it here would violate the terminal-event contract.
    std.debug.assert(self.acceptor == null);
    self.clear(gpa);
    var it = self.frecency.keyIterator();
    while (it.next()) |k| gpa.free(k.*);
    self.frecency.deinit(gpa);
    self.* = .{};
}

/// Cancel an active pick WITHOUT the ordinary `close()`'s mode-restore side
/// effect (`ctx.head.setModeRaw(prev_mode)`/menu-return popping) and WITHOUT
/// wiping learned frecency (unlike `deinit`). A no-op when nothing is
/// active. This is `clear`'s exact cleanup, made reachable without a
/// `command.Context` — for a caller that is about to determine the head's
/// resting mode some OTHER way (`core.System.Host.swap`,
/// doc/contextual-workspace-architecture.md §7: a pick's items/acceptor are
/// minted against the system a head is LEAVING, so a live pick cannot be
/// carried across a system re-bind; the swap cancels it here, then lands the
/// mode via the target system's own resting rule, not via this pick's
/// `prev_mode`, which named a mode in the system being left).
pub fn cancelActive(self: *Pick, ctx: *command.Context) void {
    if (!self.active) return;
    const acceptor = self.acceptor.?;
    self.acceptor = null;
    self.clear(ctx.gpa);
    defer if (acceptor.cleanup) |cleanup| cleanup(acceptor.data, ctx.gpa);
    acceptor.handler(ctx, acceptor.data, .cancelled) catch |err| {
        std.log.warn("pick: cancellation handler failed: {t}", .{err});
    };
}

/// Permanently end picker interaction for an owning head that is about to be
/// destroyed. Unlike ordinary cancellation, this rejects a replacement opened
/// reentrantly by the cancellation handler. Idempotent so layered owners may
/// each establish the invariant before releasing their own callback targets.
pub fn terminate(self: *Pick, ctx: *command.Context) void {
    self.terminating = true;
    self.cancelActive(ctx);
    std.debug.assert(!self.active and self.acceptor == null);
}

fn clear(self: *Pick, gpa: Allocator) void {
    // Stop the async source first: it hands off ownership (refcount)
    // and never blocks, so this is legal inside the input hot
    // section. Then run the acceptor's cleanup.
    if (self.source) |s| {
        if (s.close) |f| f(s.data, gpa);
    }
    self.source = null;
    self.allow_free_text = false;
    self.caret_anchor = null;
    self.query_epoch = 0;
    self.source_epoch = 0;
    self.last_query_ns = 0;
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
    for (self.infos.items) |d| gpa.free(d);
    self.infos.deinit(gpa);
    self.infos = .empty;
    self.query.deinit(gpa);
    self.query = .empty;
    self.filtered.deinit(gpa);
    self.filtered = .empty;
    self.selected = 0;
    self.style = .orderless;
    self.narrow.deinit(gpa);
    self.narrow = .empty;
    gpa.free(self.prev_mode);
    self.prev_mode = &.{};
    self.active = false;
}

/// Open a static pick session: copies `entries`, switches to "pick"
/// mode. The common case; `openWith` adds free-text/async options.
pub fn open(
    self: *Pick,
    ctx: *command.Context,
    prompt: []const u8,
    entries: []const Entry,
    acceptor: Acceptor,
) !void {
    return self.openWith(ctx, prompt, entries, acceptor, .{});
}

/// Open a pick session with options (free-text accept, an async
/// candidate source). On error the source's `close` is invoked so a
/// producer created by the caller is never leaked.
pub fn openWith(
    self: *Pick,
    ctx: *command.Context,
    prompt: []const u8,
    entries: []const Entry,
    acceptor: Acceptor,
    opts: Options,
) !void {
    const gpa = ctx.gpa;
    // On any failure the source is closed (never leaked) and the
    // acceptor is left UNSET — so a caller that owns a callback
    // handle (the plugin's LuaPick) can clean it up without risking
    // a later `clear()` running cleanup on a freed handle.
    errdefer if (opts.source) |s| {
        if (s.close) |f| f(s.data, gpa);
    };
    if (self.terminating) return error.PickTerminating;
    if (self.active) {
        try self.finish(ctx, .cancelled);
        // The displaced pick's callback is arbitrary plugin code. It may have
        // begun head termination even when it did not leave a replacement
        // active, so re-check the lifetime gate before this older open commits.
        if (self.terminating) return error.PickTerminating;
        // A cancellation handler may legitimately open a replacement of its
        // own. Do not silently trample that new session with this older open.
        if (self.active) return error.PickOpenedDuringCancellation;
    }
    self.prompt = try gpa.dupe(u8, prompt);
    for (entries) |e| {
        const owned = try gpa.dupe(u8, e.text);
        errdefer gpa.free(owned);
        try self.items.append(gpa, owned);
        const doc = try gpa.dupe(u8, e.doc);
        errdefer gpa.free(doc);
        try self.docs.append(gpa, doc);
        try self.infos.append(gpa, try gpa.dupe(u8, "")); // static picks carry no info
    }
    try self.refilter(gpa);
    const prev = try gpa.dupe(u8, ctx.head.currentMode());
    errdefer gpa.free(prev);
    // mechanism-not-policy (task #19 item 3): Pick bypasses the keymap
    // dispatch site (this file's module doc, and `close`'s own comment
    // below) — `setModeRaw` here is a raw overwrite, not a
    // `Head.popTransientMode` pop. Same reasoning as `Buffers.switchTo`
    // (task #19 item 2): any transient/menu frame still open named a return
    // target in the mode we're leaving for "pick", which `close` will
    // restore from `prev` (a plain string) rather than by popping — so drop
    // the stack now instead of leaving it to outlive its scope.
    ctx.head.dropAllTransients(gpa);
    try ctx.head.setModeRaw(gpa, "pick");
    // Commit — infallible from here, so the acceptor/source become
    // live only once the pick is fully open.
    self.acceptor = acceptor;
    self.allow_free_text = opts.allow_free_text;
    self.style = opts.style;
    self.source = opts.source;
    self.query_epoch = 0;
    self.source_epoch = 0;
    self.last_query_ns = 0;
    self.prev_mode = prev;
    self.active = true;
}

/// Per-frame driver for the async source: (re)generate on a settled
/// query change, then fold whatever is ready into the live pick.
/// Returns whether the UI changed (→ repaint). No-op without a
/// source, so it is cheap to call every frame.
pub fn tick(self: *Pick, ctx: *command.Context) anyerror!bool {
    if (!self.active) return false;
    const src = if (self.source) |*s| s else return false;
    var changed = false;
    if (self.source_epoch != self.query_epoch and
        self.query.items.len >= src.min_query and
        task.nowNs() - self.last_query_ns >= src.debounce_ns)
    {
        self.source_epoch = self.query_epoch;
        if (src.onQuery) |f| try f(src.data, ctx, self.query.items, self.query_epoch);
    }
    if (src.poll) |f| changed = (try f(src.data, ctx)) or changed;
    return changed;
}

/// Note a query mutation (drives debounce + source regeneration).
fn queryChanged(self: *Pick) void {
    self.query_epoch +%= 1;
    self.last_query_ns = task.nowNs();
}

/// Stream more candidates into a live pick, preserving the query and
/// the current selection (matched back by text). Unlike `refresh`,
/// this APPENDS — the streaming counterpart for async producers.
pub fn appendItems(
    p: *Pick,
    gpa: Allocator,
    texts: []const []const u8,
    docs: ?[]const []const u8,
) !void {
    if (!p.active or texts.len == 0) return;
    const keep = p.selection();
    const keep_owned = if (keep) |k| try gpa.dupe(u8, k) else null;
    defer if (keep_owned) |k| gpa.free(k);
    for (texts, 0..) |it, i| {
        const owned = try gpa.dupe(u8, it);
        errdefer gpa.free(owned);
        try p.items.append(gpa, owned);
        const d = if (docs) |ds| ds[i] else "";
        const doc = try gpa.dupe(u8, d);
        errdefer gpa.free(doc);
        try p.docs.append(gpa, doc);
        try p.infos.append(gpa, try gpa.dupe(u8, ""));
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

fn prepareClose(self: *Pick, ctx: *command.Context) ![]u8 {
    // mechanism-not-policy (task #19 item 3): Pick's own save/restore — see
    // `openWith`'s comment above for why this bypasses the door.
    // If the pick was opened from a menu (e.g. the palette from leader),
    // restoring prev_mode would leave the user stuck in the menu. Pop to the
    // menu's one-shot return target instead — the pick bypasses the keymap
    // dispatch site, so this is where that class of stickiness is fixed.
    const restore = if (ctx.keymap.isMenuMode(self.prev_mode))
        ctx.head.menuReturn(self.prev_mode) orelse self.prev_mode
    else
        self.prev_mode;
    // Prepare the whole fallible transition before clearing the live picker.
    // Once clear commits, mode restore is an owned-pointer swap and cannot
    // strand a vanished picker in "pick" mode or lose its terminal event.
    return ctx.gpa.dupe(u8, restore);
}

fn commitClose(self: *Pick, ctx: *command.Context, owned_restore: []u8) void {
    self.clear(ctx.gpa);
    ctx.head.setModeRawOwned(ctx.gpa, owned_restore);
}

/// Dismiss a live picker through its ordinary lifecycle: close its source and
/// acceptor, then restore the mode it displaced. Consumers use this when the
/// target which made a picker meaningful becomes stale (for example, an async
/// completion after a buffer switch). This is UI lifecycle, not input policy;
/// key bindings still invoke the same operation through `pick-cancel`.
pub fn dismiss(self: *Pick, ctx: *command.Context) !void {
    if (self.active) try self.finish(ctx, .cancelled);
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
    const Scored = struct { index: u32, m: Match, frec: Frec };
    var scored: std.ArrayList(Scored) = .empty;
    defer scored.deinit(gpa);
    const narrowing = self.narrow.items.len > 0;
    for (self.items.items, 0..) |it, i| {
        // Narrowing is a sticky pre-filter (orderless over text or doc);
        // the live query then ranks within the narrowed set.
        if (narrowing and orderlessMatch(self.narrow.items, it) == null and
            orderlessMatch(self.narrow.items, self.docs.items[i]) == null) continue;
        if (matchScore(self.style, self.query.items, it)) |m| {
            try scored.append(gpa, .{
                .index = @intCast(i),
                .m = m,
                .frec = self.frecOf(it),
            });
        }
    }
    std.mem.sort(Scored, scored.items, {}, struct {
        fn lt(_: void, a: Scored, b: Scored) bool {
            // Word-boundary hits first (acronyms / word starts), then a
            // tighter span, then an earlier first match, then frecency.
            if (a.m.boundaries != b.m.boundaries) return a.m.boundaries > b.m.boundaries;
            if (a.m.span != b.m.span) return a.m.span < b.m.span;
            if (a.m.start != b.m.start) return a.m.start < b.m.start;
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

/// The info body (documentation) of the currently-selected row, or "" — what the
/// side info popup shows next to a completion list.
pub fn selectedInfo(self: *const Pick) []const u8 {
    if (self.filtered.items.len == 0 or self.selected >= self.filtered.items.len) return "";
    const idx = self.filtered.items[self.selected];
    if (idx >= self.infos.items.len) return "";
    return self.infos.items[idx];
}

/// Build this pick's scene as a `core.surface.Surface` (rendering P2 — see
/// this file's module doc): a `caret`-placed completion list when
/// `caret_anchor` is set, else the window-bottom `bottom` dock. `max_rows`
/// caps how many candidates show (the view's `Hud.max_pick_rows`, passed in
/// rather than imported — `core/pick` doesn't depend on `gfx/view`).
/// `scratch`-owned (an arena) — rebuilt fresh every frame/caller, never
/// retained past it, same discipline the old render-layer `pickSurface`
/// used. Null when inactive, or (caret only) when there's nothing filtered
/// — the dock still shows even empty (the query line always renders, the
/// same behavior the old `drawPickInto` had).
pub fn buildSurface(self: *const Pick, scratch: Allocator, max_rows: usize) ?surface.Surface {
    if (!self.active) return null;
    if (self.caret_anchor) |off| return self.buildCaretSurface(scratch, off, max_rows);
    return self.buildDockSurface(scratch, max_rows);
}

/// The caret-anchored completion list: column 0 = the candidate text,
/// column 1 = its dimmed kind/detail note (`.annotation` role — when
/// present; empty rows skip it, matching notes still align because the
/// renderer sizes column 1 from whichever rows DO carry one). The selected
/// row's full doc becomes the linked `info` panel. Null when nothing is
/// filtered.
fn buildCaretSurface(self: *const Pick, scratch: Allocator, off: usize, max_rows: usize) ?surface.Surface {
    const total = self.filtered.items.len;
    if (total == 0) return null;
    const shown = @min(total, max_rows);
    const start = if (self.selected >= shown) self.selected + 1 - shown else 0;

    var surf: surface.Surface = .{};
    surf.begin(scratch, .caret);
    for (0..shown) |i| {
        const idx = self.filtered.items[start + i];
        surf.addRow(scratch);
        surf.addSpanCol(scratch, self.items.items[idx], .normal, 0);
        if (idx < self.docs.items.len) {
            const note = self.docs.items[idx];
            if (note.len > 0) surf.addSpanCol(scratch, note, .annotation, 1);
        }
    }
    surf.end(scratch, self.selected - start);
    surf.anchor = off;
    surf.setInfo(scratch, self.selectedInfo());
    return surf;
}

/// The window-bottom dock: a header row (prompt + narrow chip + query +
/// count + style, one `.normal`-role span — always shown, even with zero
/// candidates) then one `.muted`-role row per shown candidate (item + its
/// doc joined into a single string, matching the old `drawPickInto`'s
/// layout exactly — the dock never column-aligns the note like the caret
/// popup does). `surf.selected` marks the highlighted item row (offset by
/// the header), or null when nothing is shown.
fn buildDockSurface(self: *const Pick, scratch: Allocator, max_rows: usize) ?surface.Surface {
    const total = self.filtered.items.len;
    const shown = @min(total, max_rows);

    var surf: surface.Surface = .{};
    surf.begin(scratch, .bottom);
    surf.addRow(scratch);
    const narrow_chip = if (self.narrow.items.len > 0)
        std.fmt.allocPrint(scratch, "[{s}]", .{self.narrow.items}) catch ""
    else
        "";
    const query = std.fmt.allocPrint(scratch, "  {s}{s}> {s}_   [{d}/{d}] ·{s}", .{
        self.prompt,                              narrow_chip, self.query.items,
        if (total == 0) 0 else self.selected + 1, total,       @tagName(self.style),
    }) catch return null;
    surf.addSpan(scratch, query, .normal);

    const start = if (self.selected >= shown) self.selected + 1 - shown else 0;
    for (0..shown) |i| {
        const fi = start + i;
        const item = self.items.items[self.filtered.items[fi]];
        const doc = self.docOf(fi);
        const l = (if (doc.len > 0)
            std.fmt.allocPrint(scratch, "  {s}  · {s}", .{ item, doc })
        else
            std.fmt.allocPrint(scratch, "  {s}", .{item})) catch continue;
        surf.addRow(scratch);
        surf.addSpan(scratch, l, .muted);
    }
    const selected: ?usize = if (shown > 0) 1 + (self.selected - start) else null;
    surf.end(scratch, selected);
    return surf;
}

// ── Commands ────────────────────────────────────────────────────────

fn pickOf(ctx: *command.Context) *Pick {
    return &ctx.head.pick;
}

/// Promote the current query into the sticky narrowing filter and clear
/// the query — a consult-style live narrow. Repeated calls AND facets.
fn cNarrow(ctx: *command.Context, _: struct {}) anyerror!Value {
    const p = pickOf(ctx);
    if (!p.active) return .nil;
    const q = std.mem.trim(u8, p.query.items, " ");
    if (q.len == 0) return .nil;
    if (p.narrow.items.len > 0) try p.narrow.append(ctx.gpa, ' ');
    try p.narrow.appendSlice(ctx.gpa, q);
    p.query.clearRetainingCapacity();
    try p.refilter(ctx.gpa); // local: narrowing does not re-run the source
    return .nil;
}

/// Drop the narrowing filter.
fn cWiden(ctx: *command.Context, _: struct {}) anyerror!Value {
    const p = pickOf(ctx);
    if (!p.active) return .nil;
    if (p.narrow.items.len == 0) return .nil;
    p.narrow.clearRetainingCapacity();
    try p.refilter(ctx.gpa);
    return .nil;
}

/// Cycle the completion style (orderless → flex → substring → prefix → …).
fn cStyleCycle(ctx: *command.Context, _: struct {}) anyerror!Value {
    const p = pickOf(ctx);
    if (!p.active) return .nil;
    p.style = switch (p.style) {
        .orderless => .flex,
        .flex => .substring,
        .substring => .prefix,
        .prefix => .orderless,
    };
    try p.refilter(ctx.gpa);
    return .nil;
}

fn cInput(ctx: *command.Context, args: struct { text: []const u8 }) anyerror!Value {
    const p = pickOf(ctx);
    if (!p.active) return .nil;
    try p.query.appendSlice(ctx.gpa, args.text);
    p.queryChanged();
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
    p.queryChanged();
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
    try p.dismiss(ctx);
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
    p.queryChanged();
    try p.refilter(ctx.gpa);
    return .nil;
}

/// Finish one pick with an immutable callback-scoped result. The picker is
/// closed before dispatch so a handler may open another pick safely. Unlike
/// the old accepted_* fields, no result survives on mutable `Pick` state.
fn finish(p: *Pick, ctx: *command.Context, outcome: Outcome) !void {
    var owned_text: ?[]u8 = null;
    defer if (owned_text) |text| ctx.gpa.free(text);
    var owned_query: ?[]u8 = null;
    defer if (owned_query) |query| ctx.gpa.free(query);

    const stable: Outcome = switch (outcome) {
        .cancelled => .cancelled,
        .input => |input| blk: {
            const text = try ctx.gpa.dupe(u8, input);
            owned_text = text;
            break :blk .{ .input = text };
        },
        .candidate => |candidate| blk: {
            const text = try ctx.gpa.dupe(u8, candidate.text);
            owned_text = text;
            const query = try ctx.gpa.dupe(u8, candidate.query);
            owned_query = query;
            break :blk .{ .candidate = .{
                .index = candidate.index,
                .text = text,
                .query = query,
                .match = candidate.match,
            } };
        },
    };
    const acceptor = p.acceptor.?;
    p.acceptor = null; // close() must not run cleanup before the callback
    const owned_restore = p.prepareClose(ctx) catch |err| {
        // prepareClose performs the only fallible close work, so failure
        // means this exact interaction is still live and can regain ownership.
        std.debug.assert(p.active);
        p.acceptor = acceptor;
        return err;
    };
    // All fallible close work is complete, while the originating prompt is
    // still live. Ranking can now commit under the correct prompt namespace;
    // commitClose itself is an infallible owned-pointer swap.
    if (stable.text()) |text| p.recordUse(ctx.gpa, text);
    p.commitClose(ctx, owned_restore);
    defer if (acceptor.cleanup) |cleanup| cleanup(acceptor.data, ctx.gpa);
    try acceptor.handler(ctx, acceptor.data, stable);
}

fn cAccept(ctx: *command.Context, args: struct {}) anyerror!Value {
    _ = args;
    const p = pickOf(ctx);
    if (!p.active) return .nil;
    if (p.selection()) |sel| {
        const index = p.filtered.items[p.selected];
        const matched = matchScore(p.style, p.query.items, sel).?;
        try p.finish(ctx, .{ .candidate = .{
            .index = index,
            .text = sel,
            .query = p.query.items,
            .match = .{ .start = matched.start, .span = matched.span },
        } });
    } else if (p.allow_free_text and p.query.items.len > 0) {
        try p.finish(ctx, .{ .input = p.query.items });
    } else {
        try p.finish(ctx, .cancelled);
    }
    return .nil;
}

/// Accept the typed query verbatim, even when it matches a candidate —
/// the "I mean this literal text" key (C-j / S-Return). Falls back to
/// candidate acceptance when free text is not allowed.
fn cAcceptInput(ctx: *command.Context, args: struct {}) anyerror!Value {
    _ = args;
    const p = pickOf(ctx);
    if (!p.active) return .nil;
    if (p.allow_free_text and p.query.items.len > 0) {
        try p.finish(ctx, .{ .input = p.query.items });
        return .nil;
    }
    return cAccept(ctx, .{});
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
    try ctx.head.pick.open(ctx, "command", entries.items, .{ .handler = runChoice });
    return .nil;
}

fn runChoice(ctx: *command.Context, data: ?*anyopaque, outcome: Outcome) anyerror!void {
    _ = data;
    const choice = outcome.text() orelse return;
    _ = command.run(ctx.commands, ctx, choice, &.{}) catch |err| {
        std.log.warn("palette: {s} failed: {t}", .{ choice, err });
    };
}

/// Register pick commands + the "pick" mode bindings.
pub fn install(gpa: Allocator, commands: *command.Commands, keymap: *@import("../Keymap.zig")) !void {
    const defs = [_]command.Command{
        command.define("pick-input", "Append text to the pick query.", cInput),
        command.define("pick-backspace", "Delete the last query character.", cBackspace),
        command.define("pick-next", "Select the next match.", cNext),
        command.define("pick-prev", "Select the previous match.", cPrev),
        command.define("pick-accept", "Accept the selected match (else the typed text, if free-text).", cAccept),
        command.define("pick-accept-input", "Accept the typed text verbatim (free-text picks).", cAcceptInput),
        command.define("pick-cancel", "Close the picker.", cCancel),
        command.define("pick-complete", "Complete the query (common prefix, else selection).", cComplete),
        command.define("pick-commands", "Open the command palette.", cPalette),
        command.define("pick-narrow", "Promote the query into a sticky narrowing filter.", cNarrow),
        command.define("pick-widen", "Drop the narrowing filter.", cWiden),
        command.define("pick-style-cycle", "Cycle the completion style (orderless/flex/substring/prefix).", cStyleCycle),
    };
    for (defs) |cmd| _ = try commands.bind(gpa, cmd.name, cmd);

    // The "pick" mode's KEY BINDINGS are config data, not core policy: the
    // shipped `defaults.js` (which every config `weft.use`s) binds Down→pick-next,
    // Return→pick-accept, etc. — so the picker is rebindable like everything
    // else, and core ships only the COMMANDS + the mode's text command. (The
    // text command IS mechanism — it names how typed input routes, not a key.)
    try keymap.setTextCommand(gpa, "pick", "pick-input");
    _ = try commands.bind(gpa, "palette", (comptime command.define("palette", "Open the command palette.", cPalette)));
}

/// Replace the item set of a live pick, preserving query and selection
/// (race-and-refine consumers call this as results land).
/// Replace the item set. `docs`, when non-empty, is a parallel array of
/// display-only annotations (completion detail/kind) shown dimmed beside each
/// item; `infos` likewise the full documentation body for the side popup. Pass
/// `&.{}` for either. Matching/acceptance still see `items` only.
pub fn refresh(p: *Pick, gpa: Allocator, items: []const []const u8, docs: []const []const u8, infos: []const []const u8) !void {
    if (!p.active) return;
    const keep = p.selection();
    const keep_owned = if (keep) |k| try gpa.dupe(u8, k) else null;
    defer if (keep_owned) |k| gpa.free(k);
    for (p.items.items) |it| gpa.free(it);
    p.items.clearRetainingCapacity();
    for (p.docs.items) |d| gpa.free(d);
    p.docs.clearRetainingCapacity();
    for (p.infos.items) |d| gpa.free(d);
    p.infos.clearRetainingCapacity();
    for (items, 0..) |it, i| {
        const owned = try gpa.dupe(u8, it);
        errdefer gpa.free(owned);
        try p.items.append(gpa, owned);
        const doc = try gpa.dupe(u8, if (i < docs.len) docs[i] else "");
        errdefer gpa.free(doc);
        try p.docs.append(gpa, doc);
        try p.infos.append(gpa, try gpa.dupe(u8, if (i < infos.len) infos[i] else ""));
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

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "pick refilter: boundary ranking and sticky narrowing" {
    const gpa = t.allocator;
    var p: Pick = .empty;
    defer p.deinit(gpa);
    const items = [_][]const u8{ "profile", "open-file", "file-open", "close-buffer" };
    for (items) |s| {
        try p.items.append(gpa, try gpa.dupe(u8, s));
        try p.docs.append(gpa, try gpa.dupe(u8, ""));
    }

    const H = struct {
        fn has(pk: *const Pick, s: []const u8) bool {
            for (pk.filtered.items) |fi| if (std.mem.eql(u8, pk.items.items[fi], s)) return true;
            return false;
        }
    };

    // flex "of": open-file ranks above profile (two word-boundary hits).
    p.style = .flex;
    try p.query.appendSlice(gpa, "of");
    try p.refilter(gpa);
    try t.expect(p.filtered.items.len >= 2);
    try t.expectEqualStrings("open-file", p.items.items[p.filtered.items[0]]);

    // orderless "file open" → both -file/-open words, never profile.
    p.style = .orderless;
    p.query.clearRetainingCapacity();
    try p.query.appendSlice(gpa, "file open");
    try p.refilter(gpa);
    try t.expectEqual(@as(usize, 2), p.filtered.items.len);
    try t.expect(H.has(&p, "open-file") and H.has(&p, "file-open"));

    // Narrow to "file", then query "open": the sticky filter AND the query.
    p.query.clearRetainingCapacity();
    try p.narrow.appendSlice(gpa, "file");
    try p.query.appendSlice(gpa, "open");
    try p.refilter(gpa);
    try t.expect(H.has(&p, "open-file") and H.has(&p, "file-open"));
    try t.expect(!H.has(&p, "close-buffer")); // no "file"
}

test {
    std.testing.refAllDecls(@This());
}

// A heap-stable editor context for driving the picker in tests (Context
// holds pointers into these fields, so the env must not move).
const TestEnv = struct {
    gpa: Allocator,
    pool: *task.Pool,
    buffers: @import("../Buffers.zig"),
    commands: command.Commands = .empty,
    keymap: @import("../Keymap.zig") = .empty,
    /// The ONE shared Container `caps`/`actions` bind into (task #19).
    container: @import("../container.zig").Container = undefined,
    caps: @import("../capability.zig").Caps,
    actions: @import("../action.zig"),
    quit: bool = false,
    head: @import("../Head.zig") = .empty,

    fn init(gpa: Allocator) !*TestEnv {
        const pool = try task.Pool.init(gpa, .{ .threads = 1 });
        const self = try gpa.create(TestEnv);
        self.* = .{
            .gpa = gpa,
            .pool = pool,
            .buffers = try @import("../Buffers.zig").init(gpa, pool, "user"),
            .container = @import("../container.zig").Container.init(gpa),
            .caps = undefined,
            .actions = undefined,
        };
        self.caps = @import("../capability.zig").Caps.init(gpa, task.nowNs, &self.container);
        self.actions = @import("../action.zig").init(gpa, &self.container);
        return self;
    }

    fn ctx(self: *TestEnv) command.Context {
        return .{
            .gpa = self.gpa,
            .buffers = &self.buffers,
            .commands = &self.commands,
            .keymap = &self.keymap,
            .actions = &self.actions,
            .caps = &self.caps,
            .quit = &self.quit,
            .head = &self.head,
        };
    }

    fn deinit(self: *TestEnv) void {
        const gpa = self.gpa;
        var pick_ctx = self.ctx();
        self.head.pick.terminate(&pick_ctx);
        self.head.deinit(gpa);
        self.actions.deinit();
        self.caps.deinit();
        self.container.deinit();
        self.keymap.deinit(gpa);
        self.commands.deinit(gpa);
        self.buffers.deinit(gpa);
        self.pool.deinit();
        gpa.destroy(self);
    }
};

const Sink = struct {
    got: std.ArrayList(u8) = .empty,
    called: bool = false,
    cancelled: bool = false,
    fn accept(ctx: *command.Context, data: ?*anyopaque, outcome: Outcome) anyerror!void {
        const s: *Sink = @ptrCast(@alignCast(data.?));
        s.called = true;
        if (outcome == .cancelled) {
            s.cancelled = true;
            return;
        }
        const choice = outcome.text().?;
        s.got.clearRetainingCapacity();
        try s.got.appendSlice(ctx.gpa, choice);
    }
};

test "pick: acceptance is one immutable callback value and is reentrant" {
    const gpa = t.allocator;
    const env = try TestEnv.init(gpa);
    defer env.deinit();
    var ctx = env.ctx();

    const Probe = struct {
        intact_after_nested_open: bool = false,
        cancelled: usize = 0,
        cleanups: usize = 0,

        fn handle(c: *command.Context, data: ?*anyopaque, outcome: Outcome) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            switch (outcome) {
                .cancelled => {
                    self.cancelled += 1;
                    return;
                },
                .input => return error.TestUnexpectedResult,
                .candidate => |candidate| {
                    try t.expectEqual(@as(usize, 1), candidate.index);
                    try t.expectEqualStrings("    ALICE_SLOT", candidate.text);
                    try t.expectEqualStrings("ALICE_SLOT", candidate.query);
                    try t.expectEqual(@as(usize, 4), candidate.match.start);
                    try t.expectEqual(@as(usize, 10), candidate.match.span);

                    // The old mutable-side-channel design lost these facts
                    // here: opening a nested pick reset Head.pick's accepted
                    // fields. A value argument remains the outer event.
                    try c.head.pick.open(c, "nested", &.{.{ .text = "next" }}, .{
                        .handler = handle,
                        .cleanup = cleanup,
                        .data = self,
                    });
                    self.intact_after_nested_open =
                        candidate.index == 1 and
                        std.mem.eql(u8, candidate.text, "    ALICE_SLOT") and
                        candidate.match.start == 4;
                },
            }
        }

        fn cleanup(data: ?*anyopaque, _: Allocator) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.cleanups += 1;
        }
    };

    var probe: Probe = .{};
    try env.head.pick.open(&ctx, "line", &.{
        .{ .text = "other" },
        .{ .text = "    ALICE_SLOT" },
    }, .{ .handler = Probe.handle, .cleanup = Probe.cleanup, .data = &probe });
    _ = try cInput(&ctx, .{ .text = "ALICE_SLOT" });
    _ = try cAccept(&ctx, .{});
    try t.expect(probe.intact_after_nested_open);
    try t.expectEqual(@as(usize, 1), probe.cleanups); // outer only
    try t.expect(env.head.pick.active); // nested pick opened successfully

    try env.head.pick.dismiss(&ctx);
    try t.expectEqual(@as(usize, 1), probe.cancelled);
    try t.expectEqual(@as(usize, 2), probe.cleanups);
}

test "pick: replacement explicitly cancels and cleans the displaced session" {
    const gpa = t.allocator;
    const env = try TestEnv.init(gpa);
    defer env.deinit();
    var ctx = env.ctx();

    const Probe = struct {
        cancelled: usize = 0,
        cleaned: usize = 0,
        fn handle(_: *command.Context, data: ?*anyopaque, outcome: Outcome) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            if (outcome == .cancelled) self.cancelled += 1;
        }
        fn cleanup(data: ?*anyopaque, _: Allocator) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.cleaned += 1;
        }
    };
    var first: Probe = .{};
    var second: Probe = .{};
    try env.head.pick.open(&ctx, "first", &.{.{ .text = "one" }}, .{
        .handler = Probe.handle,
        .cleanup = Probe.cleanup,
        .data = &first,
    });
    try env.head.pick.open(&ctx, "second", &.{.{ .text = "two" }}, .{
        .handler = Probe.handle,
        .cleanup = Probe.cleanup,
        .data = &second,
    });
    try t.expectEqual(@as(usize, 1), first.cancelled);
    try t.expectEqual(@as(usize, 1), first.cleaned);
    try t.expectEqualStrings("second", env.head.pick.prompt);
    try env.head.pick.dismiss(&ctx);
    try t.expectEqual(@as(usize, 1), second.cancelled);
    try t.expectEqual(@as(usize, 1), second.cleaned);
}

test "pick: termination rejects a picker reopened by cancellation" {
    const gpa = t.allocator;
    const env = try TestEnv.init(gpa);
    defer env.deinit();
    var ctx = env.ctx();

    const Probe = struct {
        cancellations: usize = 0,
        cleanups: usize = 0,
        replacement_rejected: bool = false,

        fn replacement(_: *command.Context, _: ?*anyopaque, _: Outcome) anyerror!void {}

        fn handle(ctx_: *command.Context, data: ?*anyopaque, outcome: Outcome) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            if (outcome != .cancelled) return;
            self.cancellations += 1;
            ctx_.head.pick.open(ctx_, "replacement", &.{.{ .text = "late" }}, .{
                .handler = replacement,
            }) catch |err| {
                if (err == error.PickTerminating) {
                    self.replacement_rejected = true;
                    return;
                }
                return err;
            };
        }

        fn cleanup(data: ?*anyopaque, _: Allocator) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.cleanups += 1;
        }
    };

    var probe: Probe = .{};
    try env.head.pick.open(&ctx, "leaving", &.{.{ .text = "one" }}, .{
        .handler = Probe.handle,
        .cleanup = Probe.cleanup,
        .data = &probe,
    });
    env.head.pick.terminate(&ctx);
    try t.expect(probe.replacement_rejected);
    try t.expectEqual(@as(usize, 1), probe.cancellations);
    try t.expectEqual(@as(usize, 1), probe.cleanups);
    try t.expect(!env.head.pick.active);
    try t.expect(env.head.pick.acceptor == null);
}

test "pick: replacement cannot resume after cancellation begins termination" {
    const gpa = t.allocator;
    const env = try TestEnv.init(gpa);
    defer env.deinit();
    var ctx = env.ctx();

    const Probe = struct {
        cancellations: usize = 0,
        cleanups: usize = 0,

        fn handle(ctx_: *command.Context, data: ?*anyopaque, outcome: Outcome) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            if (outcome != .cancelled) return;
            self.cancellations += 1;
            ctx_.head.pick.terminate(ctx_);
        }

        fn replacement(_: *command.Context, _: ?*anyopaque, _: Outcome) anyerror!void {}

        fn cleanup(data: ?*anyopaque, _: Allocator) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.cleanups += 1;
        }
    };

    var probe: Probe = .{};
    try env.head.pick.open(&ctx, "first", &.{.{ .text = "one" }}, .{
        .handler = Probe.handle,
        .cleanup = Probe.cleanup,
        .data = &probe,
    });
    try t.expectError(error.PickTerminating, env.head.pick.open(
        &ctx,
        "too late",
        &.{.{ .text = "two" }},
        .{ .handler = Probe.replacement },
    ));
    try t.expectEqual(@as(usize, 1), probe.cancellations);
    try t.expectEqual(@as(usize, 1), probe.cleanups);
    try t.expect(!env.head.pick.active);
    try t.expect(env.head.pick.acceptor == null);
}

test "pick: acceptance records frecency under its originating prompt" {
    const gpa = t.allocator;
    const env = try TestEnv.init(gpa);
    defer env.deinit();
    var ctx = env.ctx();

    const Probe = struct {
        fn handle(_: *command.Context, _: ?*anyopaque, _: Outcome) anyerror!void {}
    };
    try env.head.pick.open(&ctx, "buffers", &.{.{ .text = "scratch" }}, .{
        .handler = Probe.handle,
    });
    _ = try cAccept(&ctx, .{});

    const namespaced = env.head.pick.frecency.get("buffers\x00scratch") orelse
        return error.TestUnexpectedResult;
    try t.expectEqual(@as(u32, 1), namespaced.uses);
    try t.expect(env.head.pick.frecency.get("\x00scratch") == null);
}

test "pick: close allocation failure keeps the live acceptor owned" {
    const gpa = t.allocator;
    const env = try TestEnv.init(gpa);
    defer env.deinit();
    var ctx = env.ctx();

    const Probe = struct {
        calls: usize = 0,
        cleanups: usize = 0,
        fn handle(_: *command.Context, data: ?*anyopaque, _: Outcome) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.calls += 1;
        }
        fn cleanup(data: ?*anyopaque, _: Allocator) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.cleanups += 1;
        }
    };
    var probe: Probe = .{};
    try env.head.setModeRaw(gpa, "normal");
    try env.head.pick.open(&ctx, "line", &.{.{ .text = "    target" }}, .{
        .handler = Probe.handle,
        .cleanup = Probe.cleanup,
        .data = &probe,
    });
    _ = try cInput(&ctx, .{ .text = "target" });

    // finish owns two stable string copies before close duplicates prev_mode;
    // fail that third allocation. The session must remain live with the same
    // acceptor instead of becoming an active picker which can never finish.
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 2 });
    var failing_ctx = ctx;
    failing_ctx.gpa = failing.allocator();
    try t.expectError(error.OutOfMemory, cAccept(&failing_ctx, .{}));
    try t.expect(env.head.pick.active);
    try t.expect(env.head.pick.acceptor != null);
    try t.expectEqual(@as(usize, 0), probe.calls);
    try t.expectEqual(@as(usize, 0), probe.cleanups);

    try env.head.pick.dismiss(&ctx);
    try t.expectEqual(@as(usize, 1), probe.calls);
    try t.expectEqual(@as(usize, 1), probe.cleanups);
}

test "pick: free-text accept — typed query when nothing matches" {
    const gpa = t.allocator;
    const env = try TestEnv.init(gpa);
    defer env.deinit();
    var sink: Sink = .{};
    defer sink.got.deinit(gpa);
    var ctx = env.ctx();

    try env.head.pick.openWith(&ctx, "read", &.{.{ .text = "apple" }}, .{
        .handler = Sink.accept,
        .data = &sink,
    }, .{ .allow_free_text = true });
    _ = try cInput(&ctx, .{ .text = "zzz" }); // matches nothing
    try t.expect(env.head.pick.selection() == null);
    _ = try cAccept(&ctx, .{});
    try t.expect(sink.called);
    try t.expectEqualStrings("zzz", sink.got.items);
    try t.expect(!env.head.pick.active);
}

test "pick: free-text off — no candidate means no acceptance" {
    const gpa = t.allocator;
    const env = try TestEnv.init(gpa);
    defer env.deinit();
    var sink: Sink = .{};
    defer sink.got.deinit(gpa);
    var ctx = env.ctx();

    try env.head.pick.open(&ctx, "cmd", &.{.{ .text = "apple" }}, .{
        .handler = Sink.accept,
        .data = &sink,
    });
    _ = try cInput(&ctx, .{ .text = "zzz" });
    _ = try cAccept(&ctx, .{});
    try t.expect(sink.called);
    try t.expect(sink.cancelled);
    try t.expect(!env.head.pick.active);
}

test "pick: appendItems preserves query and selection" {
    const gpa = t.allocator;
    const env = try TestEnv.init(gpa);
    defer env.deinit();
    var sink: Sink = .{};
    defer sink.got.deinit(gpa);
    var ctx = env.ctx();

    try env.head.pick.open(&ctx, "p", &.{
        .{ .text = "one" }, .{ .text = "two" }, .{ .text = "three" },
    }, .{ .handler = Sink.accept, .data = &sink });
    _ = try cNext(&ctx, .{}); // select "two"
    try t.expectEqualStrings("two", env.head.pick.selection().?);
    try env.head.pick.appendItems(gpa, &.{"four"}, null);
    try t.expectEqual(@as(usize, 4), env.head.pick.items.items.len);
    try t.expectEqualStrings("two", env.head.pick.selection().?);
}

const FakeSrc = struct {
    polls: usize = 0,
    closes: usize = 0,
    query_fires: usize = 0,
    emitted: bool = false,
    fn poll(data: ?*anyopaque, ctx: *command.Context) anyerror!bool {
        const s: *FakeSrc = @ptrCast(@alignCast(data.?));
        s.polls += 1;
        if (s.emitted) return false;
        s.emitted = true;
        try ctx.head.pick.appendItems(ctx.gpa, &.{ "alpha", "beta" }, null);
        return true;
    }
    fn close(data: ?*anyopaque, gpa: Allocator) void {
        _ = gpa;
        const s: *FakeSrc = @ptrCast(@alignCast(data.?));
        s.closes += 1;
    }
    fn onQuery(data: ?*anyopaque, ctx: *command.Context, query: []const u8, epoch: u64) anyerror!void {
        _ = ctx;
        _ = query;
        _ = epoch;
        const s: *FakeSrc = @ptrCast(@alignCast(data.?));
        s.query_fires += 1;
    }
};

test "pick: async source — poll folds, onQuery on change, close once" {
    const gpa = t.allocator;
    const env = try TestEnv.init(gpa);
    defer env.deinit();
    var sink: Sink = .{};
    defer sink.got.deinit(gpa);
    var fake: FakeSrc = .{};
    var ctx = env.ctx();

    try env.head.pick.openWith(&ctx, "src", &.{}, .{
        .handler = Sink.accept,
        .data = &sink,
    }, .{ .source = .{
        .data = &fake,
        .poll = FakeSrc.poll,
        .close = FakeSrc.close,
        .onQuery = FakeSrc.onQuery,
        .debounce_ns = 0,
    } });

    try t.expect(try env.head.pick.tick(&ctx)); // poll emits
    try t.expectEqual(@as(usize, 2), env.head.pick.items.items.len);
    try t.expect(!try env.head.pick.tick(&ctx)); // nothing new
    try t.expectEqual(@as(usize, 0), fake.query_fires); // no query change yet

    _ = try cInput(&ctx, .{ .text = "a" });
    _ = try env.head.pick.tick(&ctx);
    try t.expectEqual(@as(usize, 1), fake.query_fires); // fired on change

    _ = try cCancel(&ctx, .{});
    try t.expectEqual(@as(usize, 1), fake.closes);
    try t.expect(!env.head.pick.active);
}
