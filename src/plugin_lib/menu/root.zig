//! menu — how a plugin shows a menu (doc/chrome.md §2): the menubar's
//! drop-downs and the context menu are the same widget, so they are the same
//! code up to the model.
//!
//! A menu is three things, and each lives in one place:
//!
//!   · its BEHAVIOUR — which row is lit, which submenu is open, what a key or
//!     a click does — is `cascade.zig`, plain data under test;
//!   · its SCENE is `scene` below: one `menu` panel per open level, `menu-item`
//!     action nodes carrying the facts the menu widget draws from (the key
//!     hint, the icon, the check, the mnemonic, why it is greyed), and a
//!     `separator` for each rule — the vocabulary `gfx/view/menu.zig` reads;
//!   · its INPUT is one head-local interaction (`definition`) that binds the
//!     menu keys, the pointer (a click, and `hover` — the highlight follows
//!     the pointer), a letter per mnemonic, and `*`, so a key the menu does
//!     not use never falls through to the editor beneath it.
//!
//! The owner keeps a `Cascade` over its own entries, publishes `scene` into
//! the interaction's view, and turns each action back into a `Verb` through
//! its own command (semantic callbacks are not dispatching entries) —
//! `offers` for the context menu, `menu` for the menubar.

const std = @import("std");
const weft = @import("weft");
pub const cascade = @import("cascade.zig");

pub const Entry = cascade.Entry;
pub const Cascade = cascade.Cascade;
pub const Outcome = cascade.Outcome;

const Node = weft.semantic.scene.Node;
const Fact = weft.semantic.scene.Fact;
const Binding = weft.semantic.interaction.Binding;
const Action = weft.semantic.interaction.Action;

/// The action every row names; a click reaches the interaction's `mouse-1`
/// binding first, so this is only what a row IS.
pub const act_choose = "menu.choose";

/// A node of another view the root panel hangs below (a menubar title).
pub const AnchorNode = struct { view: weft.semantic.view.Ref, node: u64 };

/// The scene of `c`: its root panel, and each open submenu nested after the
/// row it opened from. Rows are `cascade.rowId(base, …)`; strings are copied
/// into `a`.
pub fn scene(a: std.mem.Allocator, c: *const Cascade, base: u64, anchor: ?AnchorNode) !Node {
    var root = try panel(a, c, base, 0);
    if (anchor) |at| {
        var facts: std.ArrayList(Fact) = .empty;
        try facts.append(a, .{ .name = "anchor-view", .value = try std.fmt.allocPrint(a, "{d}.{d}", .{ at.view.slot, at.view.generation }) });
        try facts.append(a, .{ .name = "anchor-node", .value = try std.fmt.allocPrint(a, "{d}", .{at.node}) });
        root.facts = try facts.toOwnedSlice(a);
    }
    return root;
}

fn panel(a: std.mem.Allocator, c: *const Cascade, base: u64, k: usize) !Node {
    const rows = c.level(k);
    var marks_buf: [cascade.max_panel_rows]?usize = undefined;
    const marks = cascade.mnemonics(rows, &marks_buf);
    var children: std.ArrayList(Node) = .empty;
    for (rows, 0..) |row, i| {
        if (i >= marks.len) break;
        if (row.rule and i > 0)
            try children.append(a, .{ .id = @enumFromInt(cascade.ruleId(base, k, i)), .role = "separator", .content = .{ .label = "──" } });
        var label_buf: [256]u8 = undefined;
        const shown = try a.dupe(u8, cascade.shown(row.label, &label_buf).text);
        if (row.heading) {
            try children.append(a, .{ .id = @enumFromInt(cascade.rowId(base, k, i)), .role = "menu-heading", .content = .{ .label = shown } });
            continue;
        }
        const lit = k < c.depth and c.lit[k] == i;
        var facts: std.ArrayList(Fact) = .empty;
        if (row.name.len > 0) try facts.append(a, .{ .name = "name", .value = try a.dupe(u8, row.name) });
        if (row.icon.len > 0) try facts.append(a, .{ .name = "icon", .value = try a.dupe(u8, row.icon) });
        if (row.keys.len > 0) try facts.append(a, .{ .name = "keys", .value = try a.dupe(u8, row.keys) });
        if (row.reason.len > 0) try facts.append(a, .{ .name = "reason", .value = try a.dupe(u8, row.reason) });
        if (row.checked) try facts.append(a, .{ .name = "checked", .value = "on" });
        if (row.radio) try facts.append(a, .{ .name = "radio", .value = "on" });
        if (row.opens()) try facts.append(a, .{ .name = "submenu", .value = "on" });
        if (lit) try facts.append(a, .{ .name = "lit", .value = "on" });
        if (c.keyboard) if (marks[i]) |at| try facts.append(a, .{ .name = "mnemonic", .value = try std.fmt.allocPrint(a, "{d}", .{at}) });
        try children.append(a, .{
            .id = @enumFromInt(cascade.rowId(base, k, i)),
            .role = "menu-item",
            .facts = try facts.toOwnedSlice(a),
            .content = .{ .action = .{ .action = act_choose, .label = shown, .enabled = row.enabled() } },
        });
        if (lit and k + 1 < c.depth and row.opens()) try children.append(a, try panel(a, c, base, k + 1));
    }
    return .{
        .id = @enumFromInt(cascade.panelId(base, k)),
        .role = "menu",
        .content = .{ .container = .{ .axis = .vertical, .children = try children.toOwnedSlice(a) } },
    };
}

// ── Input ───────────────────────────────────────────────────────────

/// What an interaction action asks of the menu.
pub const Verb = union(enum) {
    up,
    down,
    left,
    right,
    home,
    end,
    choose,
    close,
    click,
    hover,
    /// Consumed and ignored: the rest of a click, a key the menu does not use.
    swallow,
    /// A letter or digit: a mnemonic, or a jump.
    letter: u8,
    /// Alt with a letter: a menubar's mnemonic.
    alt: u8,
    /// The owner's own action (`extra` in `definition`).
    other: []const u8,

    /// The verb an interaction action names, from the action ids
    /// `definition` declares.
    pub fn of(action: []const u8) ?Verb {
        if (!std.mem.startsWith(u8, action, "menu.")) return null;
        const rest = action["menu.".len..];
        if (std.mem.startsWith(u8, rest, "key-") and rest.len == 5) return .{ .letter = rest[4] };
        if (std.mem.startsWith(u8, rest, "alt-") and rest.len == 5) return .{ .alt = rest[4] };
        if (std.mem.startsWith(u8, rest, "own-")) return .{ .other = rest[4..] };
        inline for (.{ "up", "down", "left", "right", "home", "end", "choose", "close", "click", "hover", "swallow" }) |name| {
            if (std.mem.eql(u8, rest, name)) return @unionInit(Verb, name, {});
        }
        return null;
    }

    /// The verb as one word of text — what the owner hands its own command
    /// (`letter a`, `own reopen`) — and back (`parse`).
    pub fn spell(self: Verb, buf: []u8) []const u8 {
        return switch (self) {
            .letter => |ch| std.fmt.bufPrint(buf, "letter {c}", .{ch}) catch "",
            .alt => |ch| std.fmt.bufPrint(buf, "alt {c}", .{ch}) catch "",
            .other => |name| std.fmt.bufPrint(buf, "own {s}", .{name}) catch "",
            else => @tagName(self),
        };
    }

    pub fn parse(text: []const u8) ?Verb {
        if (std.mem.startsWith(u8, text, "letter ") and text.len == 8) return .{ .letter = text[7] };
        if (std.mem.startsWith(u8, text, "alt ") and text.len == 5) return .{ .alt = text[4] };
        if (std.mem.startsWith(u8, text, "own ")) return .{ .other = text[4..] };
        inline for (.{ "up", "down", "left", "right", "home", "end", "choose", "close", "click", "hover", "swallow" }) |name| {
            if (std.mem.eql(u8, text, name)) return @unionInit(Verb, name, {});
        }
        return null;
    }
};

const letters = "abcdefghijklmnopqrstuvwxyz0123456789";

const fixed = [_]struct { input: []const u8, action: []const u8 }{
    .{ .input = "Up", .action = "menu.up" },
    .{ .input = "Down", .action = "menu.down" },
    .{ .input = "Left", .action = "menu.left" },
    .{ .input = "Right", .action = "menu.right" },
    .{ .input = "Home", .action = "menu.home" },
    .{ .input = "End", .action = "menu.end" },
    .{ .input = "Return", .action = "menu.choose" },
    .{ .input = "KP_Enter", .action = "menu.choose" },
    .{ .input = "space", .action = "menu.choose" },
    .{ .input = "Escape", .action = "menu.close" },
    .{ .input = "mouse-1", .action = "menu.click" },
    .{ .input = "hover", .action = "menu.hover" },
    // The rest of a click that opened or chose: never the text's.
    .{ .input = "up-mouse-1", .action = "menu.swallow" },
    .{ .input = "up-mouse-3", .action = "menu.swallow" },
    .{ .input = "drag-mouse-1", .action = "menu.swallow" },
    .{ .input = "*", .action = "menu.swallow" },
};

const fixed_actions = [_][]const u8{ "menu.up", "menu.down", "menu.left", "menu.right", "menu.home", "menu.end", "menu.choose", "menu.close", "menu.click", "menu.hover", "menu.swallow" };

const letter_actions: [letters.len][]const u8 = blk: {
    var out: [letters.len][]const u8 = undefined;
    for (letters, 0..) |ch, i| out[i] = "menu.key-" ++ [_]u8{ch};
    break :blk out;
};
const alt_actions: [26][]const u8 = blk: {
    var out: [26][]const u8 = undefined;
    for (letters[0..26], 0..) |ch, i| out[i] = "menu.alt-" ++ [_]u8{ch};
    break :blk out;
};
const letter_inputs: [letters.len][]const u8 = blk: {
    var out: [letters.len][]const u8 = undefined;
    for (letters, 0..) |ch, i| out[i] = &[_]u8{ch};
    break :blk out;
};
const alt_inputs: [26][]const u8 = blk: {
    var out: [26][]const u8 = undefined;
    for (letters[0..26], 0..) |ch, i| out[i] = "M-" ++ [_]u8{ch};
    break :blk out;
};

/// An owner's own binding: `input` runs `Verb.other(name)`.
pub const Extra = struct { input: []const u8, name: []const u8 };

/// The interaction a menu runs as: every menu key, the pointer, a letter per
/// mnemonic, Alt with a letter when `alt` (a menubar switching menus), and
/// the owner's `extra` bindings, which win over the menu's own. Strings are
/// built into `a`.
pub fn definition(a: std.mem.Allocator, view: weft.semantic.view.Ref, root: u64, presentation: []const u8, alt: bool, extra: []const Extra) !weft.semantic.interaction.Definition {
    var actions: std.ArrayList(Action) = .empty;
    var bindings: std.ArrayList(Binding) = .empty;
    for (extra, 0..) |x, i| {
        const id = try std.fmt.allocPrint(a, "menu.own-{s}", .{x.name});
        // Two inputs may name one verb: one action for both.
        const seen = for (extra[0..i]) |before| {
            if (std.mem.eql(u8, before.name, x.name)) break true;
        } else false;
        if (!seen) try actions.append(a, .{ .id = id });
        try bindings.append(a, .{ .input = x.input, .action = id });
    }
    for (fixed_actions) |id| try actions.append(a, .{ .id = id });
    for (letter_actions) |id| try actions.append(a, .{ .id = id });
    if (alt) for (alt_actions) |id| try actions.append(a, .{ .id = id });
    for (fixed) |f| if (!takenBy(extra, f.input)) try bindings.append(a, .{ .input = f.input, .action = f.action });
    for (letter_inputs, letter_actions) |input, id| if (!takenBy(extra, input)) try bindings.append(a, .{ .input = input, .action = id });
    if (alt) for (alt_inputs, alt_actions) |input, id| if (!takenBy(extra, input)) try bindings.append(a, .{ .input = input, .action = id });
    return .{
        .role = .popup,
        .view = view,
        .root = @enumFromInt(root),
        .actions = try actions.toOwnedSlice(a),
        .bindings = try bindings.toOwnedSlice(a),
        .default_action = "menu.choose",
        .cancel_action = "menu.close",
        .presentation = presentation,
    };
}

fn takenBy(extra: []const Extra, input: []const u8) bool {
    for (extra) |x| if (std.mem.eql(u8, x.input, input)) return true;
    return false;
}

/// The keyboard half of a verb, applied to `c`. Pointer verbs and the
/// owner's own are the owner's (`pointedRow`, then `cascade.hover`/`click`).
pub fn key(c: *Cascade, verb: Verb) Outcome {
    const was = c.keyboard;
    c.keyboard = true;
    const outcome: Outcome = switch (verb) {
        .up => cascade.up(c),
        .down => cascade.down(c),
        .left => cascade.left(c),
        .right => cascade.right(c),
        .home => cascade.home(c),
        .end => cascade.end(c),
        .choose => cascade.choose(c),
        .close => cascade.escape(c),
        .letter => |ch| cascade.letter(c, ch),
        else => .none,
    };
    // The first key shows the underlines, even when it moved nothing.
    return if (!was and outcome == .none) .redraw else outcome;
}

/// The row of the menu under `base` the pointer is on, if it is on one.
/// Rows live in the focused pane's floating overlay, so a node in another
/// pane with a colliding id is not taken for one.
pub fn pointedRow(base: u64) ?struct { panel: usize, row: usize } {
    const p = weft.pointer() orelse return null;
    const node = p.node orelse return null;
    if (!p.focused) return null;
    const at = cascade.rowAt(base, node) orelse return null;
    return .{ .panel = at.panel, .row = at.row };
}

/// The key hint a row shows: the shortest key `listing` (one per line) holds.
pub fn firstKey(listing: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, listing, '\n') orelse listing.len;
    return listing[0..end];
}
