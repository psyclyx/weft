//! offers — the one reading of what a context offers, for everything that
//! shows it (doc/model.md §2.4): the offers projection's strip, list and menu,
//! and the palette's offer rows.
//!
//! "What can I do here" used to be read four ways — the toolbar, the context
//! menu and the palette each walked the offer doors themselves, with their
//! own idea of which offers count, what a pinned entry is and what a disabled
//! one looks like. Here it is read once:
//!
//!   · pinned entries first, in the config's order — an intention (whose
//!     availability is the offer's, and which shows as offered nowhere when
//!     nobody offers it here) or a command (always there), as `name` or
//!     `name\tLabel`;
//!   · then every offer of the context, minus the grammar's own key words
//!     (`std.*`, unless a caller keeps them) and whatever name prefixes the
//!     caller hides, arranged by the offers' own presentation (`group`,
//!     `order`) through `affordances` — the one arrangement, so two
//!     presentations of the same context never teach two maps of it;
//!   · a disabled offer either kept, carrying its reason (a strip greys it, a
//!     palette row says why), or left out (a menu lists what can run).
//!
//! Strings are copied into the caller's allocator: the SDK's offer scratch
//! is reused by the next read.

const std = @import("std");
const weft = @import("weft");
const affordances = @import("weft_affordances");

pub const Kind = enum { intention, command };

/// One entry, as every presentation reads it.
pub const Item = struct {
    kind: Kind = .intention,
    /// The intention (`std.history.undo`, `plugin.git.stage`) or command.
    name: []const u8,
    label: []const u8,
    /// The presentation group; pinned entries have their own (empty) one.
    group: []const u8 = "",
    /// Who wins the offer here — what a tooltip or a palette row names.
    provider: []const u8 = "",
    /// The stable reason code when it cannot run; empty when it can.
    reason: []const u8 = "",
    pinned: bool = false,

    pub fn enabled(self: Item) bool {
        return self.reason.len == 0;
    }
};

/// What happens to an offer that cannot run here.
pub const Disabled = enum {
    /// Kept, with its reason: a fixed strip greys it (and a click says why),
    /// a palette row names why.
    keep,
    /// Left out: a menu lists what can be done here.
    omit,
};

pub const Options = struct {
    where: weft.OfferContext,
    /// Pinned records (`name` or `name\tLabel`), placed first in order.
    pinned: ?weft.ConfigIter = null,
    /// Keep the grammar's own key vocabulary (`std.*`) among the rest. A
    /// strip leaves them to be pinned; a palette lists them.
    grammar_words: bool = false,
    /// Name prefixes to leave out (checked after pinning).
    hide: []const []const u8 = &.{},
    disabled: Disabled = .keep,
};

fn isIntention(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "std.") or std.mem.startsWith(u8, name, "plugin.");
}

fn lastSegment(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    return name[dot + 1 ..];
}

fn hidden(name: []const u8, hide: []const []const u8) bool {
    for (hide) |prefix| if (prefix.len > 0 and std.mem.startsWith(u8, name, prefix)) return true;
    return false;
}

fn fromOffer(a: std.mem.Allocator, o: weft.Offer) !Item {
    return .{
        .name = try a.dupe(u8, o.intention),
        .label = try a.dupe(u8, o.label),
        .group = try a.dupe(u8, o.group),
        .provider = try a.dupe(u8, o.provider),
        .reason = switch (o.availability) {
            .enabled => "",
            else => try a.dupe(u8, if (o.reason.len > 0) o.reason else "unavailable"),
        },
    };
}

/// Everything `opts.where` offers right now, pinned entries first and the
/// rest arranged, into `a`.
pub fn collect(a: std.mem.Allocator, opts: Options) ![]Item {
    var found: std.ArrayList(struct { item: Item, order: ?i32, taken: bool = false }) = .empty;
    var offers = weft.offersIn(opts.where);
    while (offers.next()) |o| try found.append(a, .{ .item = try fromOffer(a, o), .order = o.order });

    var out: std.ArrayList(Item) = .empty;
    if (opts.pinned) |list| {
        var it = list;
        while (it.next()) |raw| {
            const rec = try a.dupe(u8, raw);
            var parts = std.mem.splitScalar(u8, rec, '\t');
            const name = parts.next() orelse continue;
            if (name.len == 0) continue;
            const label = parts.next() orelse "";
            if (!isIntention(name)) {
                try out.append(a, .{ .kind = .command, .name = name, .label = if (label.len > 0) label else name, .pinned = true });
                continue;
            }
            const hit = for (found.items) |*f| {
                if (std.mem.eql(u8, f.item.name, name)) break f;
            } else null;
            if (hit) |f| {
                f.taken = true;
                var item = f.item;
                item.group = "";
                item.pinned = true;
                if (label.len > 0) item.label = label;
                if (opts.disabled == .omit and !item.enabled()) continue;
                try out.append(a, item);
            } else if (opts.disabled == .keep) {
                // Pinned but offered nowhere here: shown, and says so.
                try out.append(a, .{ .name = name, .label = if (label.len > 0) label else lastSegment(name), .reason = "not-offered-here", .pinned = true });
            }
        }
    }

    var rest: std.ArrayList(Item) = .empty;
    var arrange: std.ArrayList(affordances.Item) = .empty;
    for (found.items) |f| {
        if (f.taken) continue;
        if (!opts.grammar_words and std.mem.startsWith(u8, f.item.name, "std.")) continue;
        if (hidden(f.item.name, opts.hide)) continue;
        if (opts.disabled == .omit and !f.item.enabled()) continue;
        if (rest.items.len >= affordances.max_items) break;
        const seq: u32 = @intCast(rest.items.len);
        try rest.append(a, f.item);
        try arrange.append(a, .{ .group = f.item.group, .order = f.order, .seq = seq });
    }
    affordances.arrange(arrange.items);
    for (arrange.items) |it| try out.append(a, rest.items[it.seq]);
    return out.toOwnedSlice(a);
}

/// Whether a separator belongs before `items[i]`: where the group changes.
pub fn separatorBefore(items: []const Item, i: usize) bool {
    return i > 0 and !std.mem.eql(u8, items[i - 1].group, items[i].group);
}

/// Run `item` in `where`, echoing a refusal with its reason. A command runs
/// as itself; an intention resolves again NOW, in that context — the list a
/// person clicked was built earlier and is never a stored decision.
pub fn run(item: Item, where: weft.OfferContext) void {
    switch (item.kind) {
        .command => weft.run(item.name),
        .intention => switch (weft.invokeIntentionIn(where, item.name)) {
            .invoked => {},
            // A refusal already says what refused and why.
            .refused => |why| weft.echo(why),
            .unknown => {
                var buf: [256]u8 = undefined;
                weft.echo(std.fmt.bufPrint(&buf, "{s}: not-offered-here", .{item.label}) catch return);
            },
        },
    }
}
