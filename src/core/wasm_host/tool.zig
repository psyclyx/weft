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
const WasmPlugin = shared.WasmPlugin;

/// `toolBacking(name)`: mark the entry this call is about as this plugin's
/// tool projection — only an entry this plugin made (`madeBy`).
pub fn hToolBacking(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const entry = p.activeCtx().entry() orelse return;
    if (!madeBy(entry, p)) return;
    const name = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer p.gpa.free(name);
    entry.setTool(p.gpa, name) catch return;
}

/// Whether `p` made `entry` (`Buffer.creator`). What an entry IS — its tool,
/// its designation — is its maker's to say, so no plugin can re-declare the
/// user's scratch (and make its close destroy text) or another plugin's
/// entry (and strip `*repl*` of its process). Compared by name: a reloaded
/// plugin is still the maker of what it made.
fn madeBy(entry: *const @import("../Buffers.zig").Buffer, p: *const WasmPlugin) bool {
    return entry.creator.len != 0 and std.mem.eql(u8, entry.creator, p.name);
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

const designation = @import("../designation.zig");
const durable = designation.durable;

/// `designation(out, cap) -> len`: the designation of the entry this call is
/// about, or -1 when it has none (a transient surface nobody declared).
pub fn hEntryDesignation(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const entry = p.activeCtx().entry() orelse {
        results[0] = -1;
        return;
    };
    var buf: [designation.max_len]u8 = undefined;
    const text = designation.of(entry, &buf) orelse {
        results[0] = -1;
        return;
    };
    results[0] = @intCast(caller.writeMemory(@intCast(args[0]), @intCast(args[1]), text) catch {
        results[0] = -1;
        return;
    });
}

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
pub fn hEntryDesignate(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = if (designate(p, caller, args)) |refusal| @intFromEnum(refusal) else 0;
}

/// The refusal, or null once the declaration stands.
fn designate(p: *WasmPlugin, caller: *wasm.Caller, args: []const i32) ?DesignateRefusal {
    const ctx = p.activeCtx();
    const entry = ctx.entry() orelse return .no_entry;
    if (!madeBy(entry, p)) return .not_maker;
    if (entry.textEditor()) |ed| if (ed.backing != .none) return .derived;
    const text = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return .malformed;
    defer p.gpa.free(text);
    if (text.len != 0) {
        const d = durable.parse(text) orelse return .malformed;
        if (d.authority != .here) return .malformed;
        switch (d.kind) {
            // A process in a namespace another plugin reattaches is that
            // plugin's to declare (`designation.procKind`).
            .proc => if (ctx.designations) |openers| {
                var kind_buf: [64]u8 = undefined;
                const kind = designation.procKind(d.ref, &kind_buf) orelse return .malformed;
                if (openers.find(kind)) |claimed| if (!std.mem.eql(u8, claimed.owner, p.name)) return .not_owner;
            },
            .projection => |kind| {
                const openers = ctx.designations orelse return .not_owner;
                const claimed = openers.find(kind) orelse return .not_owner;
                if (!std.mem.eql(u8, claimed.owner, p.name)) return .not_owner;
            },
            .file, .directory, .doc => return .malformed,
        }
    }
    entry.setDesignation(p.gpa, text) catch return .malformed;
    return null;
}

/// `designationOpener(kind, command) -> 0 | -1 | -2`: claim projection
/// `kind` for this plugin, answered by `command` (which receives the
/// designation as its one argument). -1: not a projection kind (a grammar
/// kind, or not a kind name at all); -2: another plugin claimed it.
pub fn hDesignationOpener(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const openers = p.activeCtx().designations orelse {
        results[0] = -1;
        return;
    };
    const kind = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch {
        results[0] = -1;
        return;
    };
    defer p.gpa.free(kind);
    const command_name = caller.readMemory(p.gpa, @intCast(args[2]), @intCast(args[3])) catch {
        results[0] = -1;
        return;
    };
    defer p.gpa.free(command_name);
    openers.claim(p.gpa, kind, command_name, p.name) catch |err| {
        results[0] = switch (err) {
            error.ClaimedByAnother => -2,
            else => -1,
        };
        return;
    };
    results[0] = 0;
}
