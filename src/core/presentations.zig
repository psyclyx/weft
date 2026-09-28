//! What a person reads about a name — a command, an action, an intention —
//! here (doc/chrome.md §1.2), and the config tier that may rewrite it.
//!
//! A command carries its own presentation (`Command.meta`), declared by
//! whoever registered it. Config describes any command it likes with
//! `weft.command(id, {label, menu, …})`; those land in `Presentations`, keyed
//! by name, and win field by field over the command's own — so a config can
//! relabel a plugin's verb, or file it under another menu, without the plugin
//! knowing. Late-bound like the registry: a description may name a command no
//! plugin has registered yet.
//!
//! `of` is the one reading: every UI (the palette, which-key, the offers
//! strip, a tooltip) asks it, so they cannot disagree about what a verb is
//! called.

const std = @import("std");
const Allocator = std.mem.Allocator;
const command = @import("command.zig");
const catalog = @import("catalog.zig");
const intentions = @import("intentions.zig");
const intent = @import("intent.zig");

pub const Presentation = command.Presentation;
const codec = @import("weft_membrane").presentation;

/// The config tier: name → presentation, every string owned (the text form
/// each decoded from is kept, and the fields borrow it).
pub const Presentations = struct {
    map: std.StringArrayHashMapUnmanaged(Entry) = .empty,
    /// Moves whenever a description is made or dropped — what a person may
    /// call a command, and whether it is offered at all, changed.
    revision: u64 = 0,

    const Entry = struct {
        text: []u8,
        owner: []u8,
        value: Presentation,
    };

    pub fn deinit(self: *Presentations, gpa: Allocator) void {
        for (self.map.keys(), self.map.values()) |k, v| {
            gpa.free(k);
            gpa.free(v.text);
            gpa.free(v.owner);
        }
        self.map.deinit(gpa);
        self.* = .{};
    }

    /// Describe `name` as `p`, on behalf of `owner` (a config manifest). A
    /// second description of one name replaces the first.
    pub fn put(self: *Presentations, gpa: Allocator, name: []const u8, p: Presentation, owner: []const u8) !void {
        var buf: [1024]u8 = undefined;
        const text = try gpa.dupe(u8, try codec.encode(&buf, p));
        errdefer gpa.free(text);
        const owned_owner = try gpa.dupe(u8, owner);
        errdefer gpa.free(owned_owner);
        const gop = try self.map.getOrPut(gpa, name);
        if (gop.found_existing) {
            gpa.free(gop.value_ptr.text);
            gpa.free(gop.value_ptr.owner);
        } else {
            gop.key_ptr.* = gpa.dupe(u8, name) catch |err| {
                _ = self.map.pop();
                return err;
            };
        }
        gop.value_ptr.* = .{ .text = text, .owner = owned_owner, .value = codec.decode(text) };
        self.revision +%= 1;
    }

    /// Forget every description `owner` made (a config reload).
    pub fn dropOwner(self: *Presentations, gpa: Allocator, owner: []const u8) void {
        var i: usize = 0;
        while (i < self.map.count()) {
            const v = self.map.values()[i];
            if (std.mem.eql(u8, v.owner, owner)) {
                const k = self.map.keys()[i];
                gpa.free(v.text);
                gpa.free(v.owner);
                self.map.swapRemoveAt(i);
                gpa.free(k);
                self.revision +%= 1;
            } else i += 1;
        }
    }

    pub fn get(self: *const Presentations, name: []const u8) ?Presentation {
        const e = self.map.get(name) orelse return null;
        return e.value;
    }
};

/// How `name` is presented to a person HERE:
///
///   - a registered command (an action's trampoline included): what it
///     declared, with the config tier over it;
///   - an intention: what the provider that would answer it here presents —
///     its offer's affordance, else its command's presentation — and failing
///     that the standard vocabulary's label;
///   - a name nothing answers but config described: that description.
///
/// Null when nothing by that name exists here at all.
pub fn of(ctx: *command.Context, name: []const u8) ?Presentation {
    const over: Presentation = if (ctx.presentations) |table| table.get(name) orelse .{} else .{};
    if (ctx.commands.resolve(name)) |cmd| {
        var own = cmd.meta;
        if (own.summary.len == 0) own.summary = cmd.summary;
        return own.overlaid(over);
    }
    if (catalog.isIntentionName(name)) {
        var p: Presentation = .{};
        if (intent.providerCommand(ctx, name)) |provider| {
            if (!std.mem.eql(u8, provider, name)) if (ctx.commands.resolve(provider)) |cmd| {
                p = cmd.meta;
                if (p.summary.len == 0) p.summary = cmd.summary;
            };
        }
        if (intentions.find(name)) |known| {
            if (p.label.len == 0) p.label = known.intention.label;
            if (p.summary.len == 0) p.summary = known.intention.doc;
        }
        return p.overlaid(over);
    }
    if (ctx.presentations) |table| if (table.get(name)) |described| return described;
    return null;
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "presentations: config describes a command field by field over what it declared" {
    const gpa = t.allocator;
    var table: Presentations = .{};
    defer table.deinit(gpa);
    try table.put(gpa, "files.find", .{ .label = "Datei öffnen", .order = 3 }, "config");
    try table.put(gpa, "not.yet-registered", .{ .label = "Later" }, "config");
    const declared: Presentation = .{ .label = "Find File", .menu = "File", .prompts = true };
    const shown = declared.overlaid(table.get("files.find").?);
    try t.expectEqualStrings("Datei öffnen", shown.label);
    try t.expectEqualStrings("File", shown.menu);
    try t.expect(shown.prompts);
    try t.expectEqualStrings("Later", table.get("not.yet-registered").?.label);

    // A second description replaces the first; a reload drops the owner's.
    try table.put(gpa, "files.find", .{ .label = "Open" }, "config");
    try t.expectEqualStrings("Open", table.get("files.find").?.label);
    try t.expectEqual(@as(?i32, null), table.get("files.find").?.order);
    table.dropOwner(gpa, "config");
    try t.expect(table.get("files.find") == null);
}
