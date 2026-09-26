//! `weft.provide(action, when, cmd, prio | opts)` — the config plane's half of
//! the provider door, parsed HERE into the same `facts.Predicate` the wasm
//! door (`wl_provide`) decodes. The shim hands `when` and the options across
//! as JSON text (`weft_qjs.c`'s `js_provide`), so the vocabulary lives in one
//! place on this side of the membrane instead of as a C struct per axis.
//!
//! Until this existed a config provider could key on `mode` and `lang` only:
//! the shim read those two properties and dropped the rest. So ide.js keyed
//! its row rename on the mode a text-less entry rests in, which is a grammar
//! detail standing in for the fact it meant. Every axis a config can name is
//! now a real fact, and a key the vocabulary does not have is REFUSED rather
//! than silently widening the provider to everywhere.

const std = @import("std");
const Allocator = std.mem.Allocator;
const facts = @import("weft_facts");
const Affordance = @import("../catalog.zig").Affordance;

pub const Error = error{
    /// `when` was not an object of facts.
    BadWhen,
    /// A `when` key no fact answers (a misspelling, or an axis not yet
    /// sayable from config).
    UnknownFact,
    /// `locality` was not one of `local`, `remote`, `tool`, `none`.
    BadLocality,
    /// The fourth argument was neither a number nor an options object.
    BadOptions,
} || Allocator.Error;

/// A parsed provide: the predicate (children owned — release with `deinit`),
/// the priority, and how its offer is presented (strings owned).
pub const Parsed = struct {
    predicate: facts.Predicate = .{ .all = &.{} },
    priority: i32 = 0,
    affordance: Affordance = .{},

    pub fn deinit(self: *Parsed, gpa: Allocator) void {
        facts.free(gpa, self.predicate);
        gpa.free(self.affordance.label);
        gpa.free(self.affordance.group);
        self.* = undefined;
    }
};

/// Parse the two JSON texts the shim sends. Empty text is "absent": no
/// narrowing, priority 0, no presentation.
pub fn parse(gpa: Allocator, when_json: []const u8, opts_json: []const u8) Error!Parsed {
    var out: Parsed = .{};
    errdefer out.deinit(gpa);
    out.predicate = try parseWhen(gpa, when_json);
    try parseOptions(gpa, opts_json, &out);
    return out;
}

fn parseWhen(gpa: Allocator, text: []const u8) Error!facts.Predicate {
    if (text.len == 0) return .{ .all = &.{} };
    var doc = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch return error.BadWhen;
    defer doc.deinit();
    const obj = switch (doc.value) {
        .object => |o| o,
        else => return error.BadWhen,
    };
    var leaves: std.ArrayList(facts.Predicate) = .empty;
    defer leaves.deinit(gpa);
    var it = obj.iterator();
    while (it.next()) |kv| {
        const key = kv.key_ptr.*;
        // `null`/absent is "don't care", the same as leaving the key out.
        if (kv.value_ptr.* == .null) continue;
        if (std.mem.eql(u8, key, "locality")) {
            const name = switch (kv.value_ptr.*) {
                .string => |s| s,
                else => return error.BadLocality,
            };
            const l = std.meta.stringToEnum(facts.Locality, name) orelse return error.BadLocality;
            try leaves.append(gpa, .{ .locus = l });
            continue;
        }
        const s = switch (kv.value_ptr.*) {
            .string => |s| s,
            else => return error.BadWhen,
        };
        const leaf: facts.Predicate = if (std.mem.eql(u8, key, "mode"))
            .{ .mode = s }
        else if (std.mem.eql(u8, key, "lang"))
            .{ .lang = s }
        else if (std.mem.eql(u8, key, "tool"))
            .{ .tool = s }
        else if (std.mem.eql(u8, key, "role"))
            .{ .role = s }
        else
            return error.UnknownFact;
        try leaves.append(gpa, leaf);
    }
    // `dupe` copies the leaves' strings out of the JSON document, which dies
    // with this call.
    return facts.dupe(gpa, .{ .all = leaves.items });
}

fn parseOptions(gpa: Allocator, text: []const u8, out: *Parsed) Error!void {
    if (text.len == 0) return;
    var doc = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch return error.BadOptions;
    defer doc.deinit();
    switch (doc.value) {
        // The historical form: a bare priority.
        .integer => |n| out.priority = std.math.cast(i32, n) orelse return error.BadOptions,
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |kv| {
                const key = kv.key_ptr.*;
                const v = kv.value_ptr.*;
                if (std.mem.eql(u8, key, "priority")) {
                    out.priority = intOf(v) orelse return error.BadOptions;
                } else if (std.mem.eql(u8, key, "order")) {
                    out.affordance.order = intOf(v) orelse return error.BadOptions;
                } else if (std.mem.eql(u8, key, "label")) {
                    gpa.free(out.affordance.label);
                    out.affordance.label = try gpa.dupe(u8, strOf(v) orelse return error.BadOptions);
                } else if (std.mem.eql(u8, key, "group")) {
                    gpa.free(out.affordance.group);
                    out.affordance.group = try gpa.dupe(u8, strOf(v) orelse return error.BadOptions);
                } else return error.BadOptions;
            }
        },
        else => return error.BadOptions,
    }
}

fn intOf(v: std.json.Value) ?i32 {
    return switch (v) {
        .integer => |n| std.math.cast(i32, n),
        else => null,
    };
}

fn strOf(v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// What a refused provide says, for the echo line.
pub fn describe(err: Error) []const u8 {
    return switch (err) {
        error.BadWhen => "`when` must be an object of facts {mode, lang, tool, role, locality}",
        error.UnknownFact => "`when` names a fact config cannot match (use mode, lang, tool, role, locality)",
        error.BadLocality => "`locality` is one of local, remote, tool, none",
        error.BadOptions => "the fourth argument is a priority or {priority, label, group, order}",
        error.OutOfMemory => "out of memory",
    };
}

const t = std.testing;

test "provide: every config axis parses into the predicate the wasm door builds" {
    const gpa = t.allocator;
    var p = try parse(gpa, "{\"role\":\"fs.file\",\"tool\":\"files\",\"locality\":\"tool\"}", "");
    defer p.deinit(gpa);
    try t.expect(p.predicate.matches(.{ .role = "fs.file", .tool = "files", .locality = .tool }));
    try t.expect(!p.predicate.matches(.{ .role = "fs.file", .tool = "files", .locality = .local }));
    try t.expect(!p.predicate.matches(.{ .role = "git.file.unstaged", .tool = "files", .locality = .tool }));
    // Three facts named, three conjuncts: specificity is earned by saying more.
    try t.expectEqual(@as(u32, 3), p.predicate.specificity());
    // The same bytes the SDK's `provide` would put on the wire.
    const ours = try facts.encode(gpa, p.predicate);
    defer gpa.free(ours);
    const decoded = try facts.decode(gpa, ours);
    defer facts.free(gpa, decoded);
    try t.expect(decoded.matches(.{ .role = "fs.file", .tool = "files", .locality = .tool }));
}

test "provide: empty when is unconstrained, a bare number is the priority" {
    const gpa = t.allocator;
    var p = try parse(gpa, "{}", "7");
    defer p.deinit(gpa);
    try t.expect(p.predicate.matches(.{}));
    try t.expectEqual(@as(i32, 7), p.priority);
    try t.expectEqualStrings("", p.affordance.label);
}

test "provide: an options object carries priority and presentation" {
    const gpa = t.allocator;
    var p = try parse(gpa, "{\"mode\":\"ide\"}", "{\"priority\":3,\"label\":\"Rename\",\"group\":\"edit\",\"order\":2}");
    defer p.deinit(gpa);
    try t.expectEqual(@as(i32, 3), p.priority);
    try t.expectEqualStrings("Rename", p.affordance.label);
    try t.expectEqualStrings("edit", p.affordance.group);
    try t.expectEqual(@as(?i32, 2), p.affordance.order);
}

test "provide: a fact config cannot name is refused, never widened" {
    const gpa = t.allocator;
    try t.expectError(error.UnknownFact, parse(gpa, "{\"posture\":\"text\"}", ""));
    try t.expectError(error.BadLocality, parse(gpa, "{\"locality\":\"moon\"}", ""));
    try t.expectError(error.BadWhen, parse(gpa, "[1]", ""));
    try t.expectError(error.BadOptions, parse(gpa, "{}", "{\"colour\":1}"));
}
