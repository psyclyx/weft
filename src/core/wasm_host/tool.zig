//! Tool-backed buffers: a plugin marks a buffer as its projection
//! (`weft.toolBacking(name)`), so its content is understood to be plugin-
//! regenerated (git/files) rather than a file. This is purely the entry's
//! IDENTITY — it does NOT special-case dispatch. `save` (and any other context
//! intent) resolves through the ACTION system: the entry's tool name is an
//! ambient fact (`action.Ctx.tool`, from `Buffers.Buffer.tool`), and a
//! projection provides `save` scoped to `When{ .tool = "<name>" }`, winning
//! over the core file-write provider by specificity. So the core stays
//! projection-agnostic.

const std = @import("std");
const wasm = @import("../wasm.zig");

const shared = @import("plugin.zig");
const Door = @import("../plugin_resources.zig").Door;

/// `toolBacking(name)`: mark the entry this call is about as this plugin's
/// tool projection — only an entry this plugin made (`madeBy`).
pub fn toolBackingBody(d: Door, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const gpa = d.ctx.gpa;
    const entry = d.ctx.entry() orelse return;
    if (!madeBy(entry, d.resources.name)) return;
    const name = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(name);
    entry.setTool(gpa, name) catch return;
}
pub const hToolBacking = shared.wasmDoor(toolBackingBody, null);

/// Whether plugin `owner` made `entry` (`Buffer.creator`). What an entry IS —
/// its tool, its designation — is its maker's to say, so no plugin can
/// re-declare the user's scratch (and make its close destroy text) or another
/// plugin's entry (and strip `*repl*` of its process). Compared by name: a
/// reloaded plugin is still the maker of what it made.
fn madeBy(entry: *const @import("../Buffers.zig").Buffer, owner: []const u8) bool {
    return entry.creator.len != 0 and std.mem.eql(u8, entry.creator, owner);
}

// ── Designations (doc/model.md §2.1–2.2) ─────────────────────────────
//
// Three doors, because three parties hold three halves of one fact. The
// entry's designation is core's to answer (`designation.of`); what a
// projection's designation MEANS is its producer's, who claims the kind and
// names the command that re-runs it; and which designation a produced entry
// represents is, again, the producer's to declare — but only in kinds it may
// speak for. A plugin cannot declare that its entry is a file, a document, or
// another producer's projection: those are either derived by core from what
// the entry really holds, or owned by someone else. That rule is the door's,
// so no plugin has to be trusted to keep it.
//
// Each door is ONE body (`Door`: the plugin's resources and the context of
// the call), run by both planes — `wl_*` through `wasmDoor`, `qjs_*` through
// the JS plane's `jsDoor` — so a `.js` producer claims, declares and reads
// under exactly the rules a `.wasm` one does (`e2e/demolition_test.zig`).

const designation = @import("../designation.zig");
const durable = designation.durable;

/// `designation(out, cap) -> len`: the designation of the entry this call is
/// about, or -1 when it has none (a transient surface nobody declared). The
/// full length, so a short buffer can grow.
pub fn designationBody(d: Door, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    results[0] = -1;
    const entry = d.ctx.entry() orelse return;
    var buf: [designation.max_len]u8 = undefined;
    const text = designation.of(entry, &buf) orelse return;
    const cap: usize = @intCast(@max(args[1], 0));
    _ = caller.writeMemory(@intCast(args[0]), cap, text) catch return;
    results[0] = @intCast(text.len);
}
pub const hEntryDesignation = shared.wasmDoor(designationBody, null);

/// Why `wl_entry_designate` refused, as its (negative) result.
pub const DesignateRefusal = enum(i32) {
    /// Not `weft://…`, or not a kind a producer may declare.
    malformed = -1,
    /// A projection kind this plugin has not claimed (`wl_designation_opener`).
    not_owner = -2,
    /// The entry is named by what it holds — a file — and nothing overrides that.
    derived = -3,
    /// There is no entry this call is about (a closed bound entry).
    no_entry = -4,
    /// Another plugin made the entry, or the user did: only its maker says
    /// what it is — clearing included.
    not_maker = -5,
};

/// `designate(text) -> 0 | refusal`: declare the designation the entry this
/// call is about represents. Admits exactly `weft://here/proc/…` (a live
/// resource the plugin runs, in a namespace no other plugin reattaches —
/// `designation.procKind`) and `weft://here/<kind>/…` for a projection kind
/// this plugin claimed; empty clears the declaration. Only on an entry this
/// plugin made (`madeBy`), whatever the text — clearing included; and a
/// file-backed entry is refused: it is named by its file.
pub fn designateBody(d: Door, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    results[0] = if (designate(d, caller, args)) |refusal| @intFromEnum(refusal) else 0;
}
pub const hEntryDesignate = shared.wasmDoor(designateBody, null);

/// The refusal, or null once the declaration stands.
fn designate(d: Door, caller: *wasm.Caller, args: []const i32) ?DesignateRefusal {
    const gpa = d.ctx.gpa;
    const owner = d.resources.name;
    const entry = d.ctx.entry() orelse return .no_entry;
    if (!madeBy(entry, owner)) return .not_maker;
    if (entry.textEditor()) |ed| if (ed.backing != .none) return .derived;
    const text = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return .malformed;
    defer gpa.free(text);
    if (text.len != 0) {
        const named = durable.parse(text) orelse return .malformed;
        if (named.authority != .here) return .malformed;
        switch (named.kind) {
            // A process in the plugin's OWN namespace (`proc.<name>`, or one
            // its manifest declares — `designation.procKind`), whoever has
            // or has not claimed it yet: the namespace is the name's, not
            // the first declarer's.
            .proc => {
                var kind_buf: [64]u8 = undefined;
                const kind = designation.procKind(named.ref, &kind_buf) orelse return .malformed;
                if (!mayClaim(d, kind)) return .not_owner;
            },
            .projection => |kind| {
                const openers = d.ctx.designations orelse return .not_owner;
                const claimed = openers.find(kind) orelse return .not_owner;
                if (!std.mem.eql(u8, claimed.owner, owner)) return .not_owner;
            },
            .file, .directory, .doc => return .malformed,
        }
    }
    entry.setDesignation(gpa, text) catch return .malformed;
    return null;
}

/// Whether the plugin may claim (and declare entries of) `kind`: it is in the
/// plugin's own namespace (`Openers.inNamespace`), or its describe manifest
/// declared it as the capability `designation/<kind>` — a kind named for
/// what it shows (`diagnostics`) rather than for who shows it. A `.js`
/// plugin declares no capabilities, so its namespace is all it may claim.
fn mayClaim(d: Door, kind: []const u8) bool {
    if (designation.Openers.inNamespace(d.resources.name, kind)) return true;
    var buf: [128]u8 = undefined;
    const cap = std.fmt.bufPrint(&buf, "designation/{s}", .{kind}) catch return false;
    return d.resources.declaresCapability(cap);
}

/// `designationOpener(kind, command) -> 0 | -1 | -2 | -3`: claim projection
/// `kind` for this plugin, answered by `command` (which receives the
/// designation as its one argument). -1: not a projection kind (a grammar
/// kind, or not a kind name at all); -2: another plugin claimed it; -3: not
/// this plugin's to claim (`mayClaim`). A refused claim is also recorded as
/// the plugin's `load_refusal`, so a claim refused while it LOADS fails the
/// load, loudly: a producer that cannot own its kind would otherwise load
/// and silently answer nothing.
pub fn openerBody(d: Door, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    // A host with no registry (a bare fixture) has nothing to claim into:
    // refused, but no fault of the plugin's.
    if (d.ctx.designations == null) {
        results[0] = -1;
        return;
    }
    results[0] = claimOpener(d, caller, args);
    if (results[0] != 0) {
        std.log.warn("plugin {s}: its designation opener was refused ({d}): a kind must be the plugin's name, under it, or declared as designation/<kind>", .{ d.resources.name, results[0] });
        if (d.resources.load_refusal == null) d.resources.load_refusal = error.DesignationKindRefused;
    }
}
pub const hDesignationOpener = shared.wasmDoor(openerBody, null);

fn claimOpener(d: Door, caller: *wasm.Caller, args: []const i32) i32 {
    const gpa = d.ctx.gpa;
    const openers = d.ctx.designations orelse return -1;
    const kind = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return -1;
    defer gpa.free(kind);
    const command_name = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch return -1;
    defer gpa.free(command_name);
    if (!durable.Kind.isProjectionName(kind)) return -1;
    if (!mayClaim(d, kind)) return -3;
    openers.claim(gpa, kind, command_name, d.resources.name) catch |err| return switch (err) {
        error.ClaimedByAnother => -2,
        else => -1,
    };
    return 0;
}
