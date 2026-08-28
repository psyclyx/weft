//! Test fixture ONLY (not installed — see build.zig's `guests` table): the
//! synthetic third-party input grammar of the Files conformance gate
//! (doc/contextual-workspace-architecture.md §18, §14.2). It knows no domain
//! plugin: no command name, no mode of anyone else's, no semantic ABI call —
//! one structural mode whose keys name `std.*` protocol intentions
//! (src/core/intentions.zig, doc/configuration.md §5.1) that whatever holds
//! the focus resolves.
//!
//! The mode is STRUCTURAL by construction: it declares no commit command, so
//! a key it leaves unbound stays unhandled and can never become text (§10.1).

const weft = @import("weft");

/// The one mode this grammar owns. A grammar-owned scope name, not a global.
const mode = "gramtest";

/// A key and the first-applicable intention list it resolves through
/// (§10.2). The string form is a one-entry list — one representation.
const Binding = struct { key: []const u8, intentions: []const []const u8 };

const bindings = [_]Binding{
    .{ .key = "Tab", .intentions = &.{"std.hierarchy.toggle-expanded"} },
    .{ .key = "Return", .intentions = &.{ "std.target.activate", "std.editing.insert-line-break" } },
    .{ .key = "q", .intentions = &.{"std.navigation.back"} },
    .{ .key = "u", .intentions = &.{"std.history.undo"} },
    .{ .key = "h", .intentions = &.{"std.navigation.left"} },
    .{ .key = "j", .intentions = &.{"std.navigation.down"} },
    .{ .key = "k", .intentions = &.{"std.navigation.up"} },
    .{ .key = "l", .intentions = &.{"std.navigation.right"} },
    .{ .key = "minus", .intentions = &.{"std.hierarchy.step-out"} },
    .{ .key = "y", .intentions = &.{"std.transfer.yank"} },
    .{ .key = "d", .intentions = &.{"std.transfer.delete-to-register"} },
    .{ .key = "p", .intentions = &.{"std.transfer.paste"} },
    // The break-out a `capture` presentation can never take away (§10.4) —
    // bound in this grammar's one mode, so it is retained everywhere.
    .{ .key = "C-backslash", .intentions = &.{"std.input.break-out"} },
};

export fn describe() void {}

export fn init() void {
    // §10.4: this grammar has ONE state, and it commits nothing — so it is
    // the honest answer for every posture (and a mode a buffer rests in).
    // Declared rather than defaulted: core stamps the pairing on entry
    // switch, and a grammar that never declared would silently inherit
    // whatever the base editing mode was.
    weft.restingPosture(.text, mode);
    weft.restingPosture(.structural, mode);
    for (bindings) |b| weft.bindKeys(mode, b.key, b.intentions);
    weft.setMode(mode);
}
