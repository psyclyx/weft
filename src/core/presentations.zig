//! What a person reads about a name — a command, an action, an intention —
//! here (doc/chrome.md §1.2), and the config tier that may rewrite it.
//!
//! A command carries its own presentation (`Command.meta`), declared by
//! whoever registered it. Config describes any command it likes with
//! `weft.command(id, {label, menu, …})`; each call is a ROW in
//! `Presentations`, keyed by name, that sets only the fields it names — so a
//! config can relabel a plugin's verb, or file it under another menu, without
//! the plugin knowing, and relabelling a command keeps the place another row
//! (menus.js) gave it. Late-bound like the registry: a description may name a
//! command no plugin has registered yet.
//!
//! Precedence, lowest first: what the command declared; a resident plugin's
//! rows (it describes only its own commands); config rows, in the order the
//! manifest applies them (a fragment's before the config that uses it, each
//! file's in call order). A later row wins only the fields it names.
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

/// The description tier: name → its rows, lowest precedence first, every
/// string owned (the text form each decoded from is kept, and the fields
/// borrow it).
pub const Presentations = struct {
    map: std.StringArrayHashMapUnmanaged(std.ArrayList(Row)) = .empty,
    /// Moves whenever a description is made or dropped — what a person may
    /// call a command, and whether it is offered at all, changed.
    revision: u64 = 0,

    /// Who wrote a row: a resident plugin describing its own command, or the
    /// user's config. Every config row outranks every plugin row, whichever
    /// arrived first.
    pub const Tier = enum { plugin, config };

    const Row = struct {
        text: []u8,
        owner: []u8,
        tier: Tier,
        description: codec.Description,

        fn free(self: Row, gpa: Allocator) void {
            gpa.free(self.text);
            gpa.free(self.owner);
        }
    };

    pub fn deinit(self: *Presentations, gpa: Allocator) void {
        for (self.map.keys(), self.map.values()) |k, *rows| {
            gpa.free(k);
            for (rows.items) |r| r.free(gpa);
            rows.deinit(gpa);
        }
        self.map.deinit(gpa);
        self.* = .{};
    }

    /// Add a row describing `name`, in the shared text form, on behalf of
    /// `owner` (a config manifest, or a plugin). It sets the fields `text`
    /// names over every row beneath it and leaves the rest alone.
    pub fn put(self: *Presentations, gpa: Allocator, name: []const u8, text: []const u8, owner: []const u8, tier: Tier) !void {
        const owned_text = try gpa.dupe(u8, text);
        errdefer gpa.free(owned_text);
        const owned_owner = try gpa.dupe(u8, owner);
        errdefer gpa.free(owned_owner);
        const gop = try self.map.getOrPut(gpa, name);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
            gop.key_ptr.* = gpa.dupe(u8, name) catch |err| {
                _ = self.map.pop();
                return err;
            };
        }
        const rows = gop.value_ptr;
        // Above every row of its tier and below every row of a higher one.
        var at = rows.items.len;
        while (at > 0 and @intFromEnum(rows.items[at - 1].tier) > @intFromEnum(tier)) at -= 1;
        try rows.insert(gpa, at, .{
            .text = owned_text,
            .owner = owned_owner,
            .tier = tier,
            .description = codec.describe(owned_text),
        });
        self.revision +%= 1;
    }

    /// Forget every row `owner` made (a config reload, a plugin unloading).
    pub fn dropOwner(self: *Presentations, gpa: Allocator, owner: []const u8) void {
        var i: usize = 0;
        while (i < self.map.count()) {
            const rows = &self.map.values()[i];
            var j: usize = 0;
            while (j < rows.items.len) {
                if (std.mem.eql(u8, rows.items[j].owner, owner)) {
                    rows.orderedRemove(j).free(gpa);
                    self.revision +%= 1;
                } else j += 1;
            }
            if (rows.items.len == 0) {
                const k = self.map.keys()[i];
                rows.deinit(gpa);
                self.map.swapRemoveAt(i);
                gpa.free(k);
            } else i += 1;
        }
    }

    /// `base` (what the name declared) with every row describing `name`
    /// applied over it, lowest first.
    pub fn over(self: *const Presentations, name: []const u8, base: Presentation) Presentation {
        const rows = self.map.get(name) orelse return base;
        var out = base;
        for (rows.items) |r| out = r.description.over(out);
        return out;
    }

    /// What the rows alone say of `name`; null when none describes it.
    pub fn get(self: *const Presentations, name: []const u8) ?Presentation {
        if (!self.map.contains(name)) return null;
        return self.over(name, .{});
    }
};

/// How `name` is presented to a person HERE:
///
///   - a registered command (an action's trampoline included): what it
///     declared, with the description rows over it;
///   - an intention: what the provider that would answer it here presents —
///     its offer's affordance, else its command's presentation — and failing
///     that the standard vocabulary's label;
///   - a name nothing answers but config described: that description.
///
/// Null when nothing by that name exists here at all.
pub fn of(ctx: *command.Context, name: []const u8) ?Presentation {
    const table = ctx.presentations;
    if (ctx.commands.resolve(name)) |cmd| {
        var own = cmd.meta;
        if (own.summary.len == 0) own.summary = cmd.summary;
        return if (table) |rows| rows.over(name, own) else own;
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
        return if (table) |rows| rows.over(name, p) else p;
    }
    if (table) |rows| return rows.get(name);
    return null;
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "presentations: each row sets only the fields it names, over what the command declared" {
    const gpa = t.allocator;
    var table: Presentations = .{};
    defer table.deinit(gpa);
    const declared: Presentation = .{ .label = "Find File", .icon = "file", .prompts = true };
    // A placement fragment, then the user's relabel: the relabel keeps the
    // placement, and what the command declared shows through both.
    try table.put(gpa, "files.find", "menu\tFile\ngroup\topen\norder\t3\n", "import:menus", .config);
    try table.put(gpa, "files.find", "label\tDatei öffnen\n", "config", .config);
    try table.put(gpa, "not.yet-registered", "label\tLater\n", "config", .config);
    var shown = table.over("files.find", declared);
    try t.expectEqualStrings("Datei öffnen", shown.label);
    try t.expectEqualStrings("File", shown.menu);
    try t.expectEqualStrings("open", shown.group);
    try t.expectEqual(@as(?i32, 3), shown.order);
    try t.expectEqualStrings("file", shown.icon);
    try t.expect(shown.prompts);
    try t.expectEqualStrings("Later", table.get("not.yet-registered").?.label);

    // Naming a field empty clears it, the placement's and the declaration's.
    try table.put(gpa, "files.find", "menu\t\nprompts\toff\n", "config", .config);
    shown = table.over("files.find", declared);
    try t.expectEqualStrings("", shown.menu);
    try t.expect(!shown.prompts);
    try t.expectEqualStrings("Datei öffnen", shown.label);

    // A plugin's row arriving later still sits beneath every config row.
    try table.put(gpa, "files.find", "label\tFind\nsummary\tFind a file.\n", "files", .plugin);
    shown = table.over("files.find", declared);
    try t.expectEqualStrings("Datei öffnen", shown.label);
    try t.expectEqualStrings("Find a file.", shown.summary);

    // A reload drops the owner's rows and only those.
    table.dropOwner(gpa, "config");
    shown = table.over("files.find", declared);
    try t.expectEqualStrings("Find", shown.label);
    try t.expectEqualStrings("File", shown.menu);
    try t.expect(table.get("not.yet-registered") == null);
    table.dropOwner(gpa, "import:menus");
    table.dropOwner(gpa, "files");
    try t.expect(table.get("files.find") == null);
    try t.expectEqualStrings("Find File", table.over("files.find", declared).label);
}
