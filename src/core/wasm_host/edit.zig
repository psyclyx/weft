//! The read/edit/motion surface: read-only reads (cursor/byte_len/slice/line_at/
//! selection/path), the gated edit + jump, the native `editor` step/selection
//! primitives, and the anchored-range membrane — a motion anchors a range by
//! handle, an operator awaits/reads one and applies an edit through it. Live
//! positions never become version-plus-offset pairs.

const std = @import("std");
const wasm = @import("../wasm.zig");
const command = @import("../command.zig");
const Editor = @import("../Editor.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;

fn opaqueHandle(raw: i32) ?u32 {
    return if (raw < 0) null else @intCast(raw);
}

pub fn hCursor(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = @intCast(p.activeCtx().editor().cursorOffset());
}

pub fn hByteLen(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = @intCast(p.activeCtx().editor().text().byteLen());
}

/// Capture an opaque witness for the active document's current causal
/// frontier. Negative i32 is reserved for allocation/frontier failure.
pub fn hDocSnapshot(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const handle = p.docSnapshot() catch {
        results[0] = -1;
        return;
    };
    results[0] = @intCast(handle);
}

/// Equality-only witness check. Missing handles, a different active buffer,
/// and any frontier read failure all return false.
pub fn hDocSnapshotIsCurrent(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const handle = opaqueHandle(args[0]) orelse {
        results[0] = 0;
        return;
    };
    results[0] = @intFromBool(p.docSnapshotIsCurrent(handle));
}

/// Idempotently release an opaque document snapshot witness.
pub fn hDocSnapshotRelease(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    if (opaqueHandle(args[0])) |handle| p.releaseDocSnapshot(handle);
}

pub fn hSlice(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const rope = p.activeCtx().editor().text();
    const len = rope.byteLen();
    const s = @min(@as(usize, @intCast(args[0])), len);
    const e = @min(@as(usize, @intCast(args[1])), len);
    if (e <= s) {
        results[0] = 0;
        return;
    }
    const buf = p.gpa.alloc(u8, e - s) catch {
        results[0] = 0;
        return;
    };
    defer p.gpa.free(buf);
    var sr = rope.streamReader(.{ .start = s, .end = e }, &.{});
    sr.interface.readSliceAll(buf) catch {
        results[0] = 0;
        return;
    };
    const n = caller.writeMemory(@intCast(args[2]), @intCast(args[3]), buf) catch 0;
    results[0] = @intCast(n);
}

pub fn hLineAt(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const rope = p.activeCtx().editor().text();
    const row = rope.offsetToPoint(@min(@as(usize, @intCast(args[0])), rope.byteLen())).row;
    const line = rope.lineRange(row);
    const pair = [2]u32{ @intCast(line.start), @intCast(line.end) };
    _ = caller.writeMemory(@intCast(args[1]), 8, std.mem.asBytes(&pair)) catch {};
}

pub fn hSelection(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const sel = p.activeCtx().editor().selectedRange() orelse {
        results[0] = 0;
        return;
    };
    const pair = [2]u32{ @intCast(sel.start), @intCast(sel.end) };
    _ = caller.writeMemory(@intCast(args[0]), 8, std.mem.asBytes(&pair)) catch {};
    results[0] = 1;
}

pub fn hPath(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const path = p.activeCtx().editor().backingPath() orelse {
        results[0] = -1;
        return;
    };
    const n = caller.writeMemory(@intCast(args[0]), @intCast(args[1]), path) catch {
        results[0] = -1;
        return;
    };
    results[0] = @intCast(n);
}

/// The doc-region half of the deny taxonomy: a `.doc_region` grant narrowing
/// this edit (`error.OutOfLimit`), or that grant's identity anchors no longer
/// resolving (`error.Collapsed`), is a FAULT — the guest asked for authority
/// it was scoped out of, so it traps rather than drifting. A plain grade
/// refusal (`error.Unauthorized`) is not a fault: the door already echoed it,
/// and the guest simply gets no edit. Re-derives the resolved bounds via a
/// second, cheap `checkDocRegion` call for the message — the same "second
/// cheap read, not threaded through the error" convention
/// `wasm_host/plugin.zig`'s `trapOutOfLimit` uses for `.fs_root`.
fn trapDocRegion(p: *WasmPlugin, caller: *wasm.Caller, start: usize, end: usize, err: anyerror) void {
    switch (err) {
        error.OutOfLimit => switch (p.activeCtx().checkDocRegion(start, end)) {
            .out_of_limit => |b| caller.trap("plugin '{s}' doc-edit [{d},{d}) is outside its granted region [{d},{d})", .{ p.name, start, end, b.start, b.end }),
            .ok, .collapsed => caller.trap("plugin '{s}' doc-edit [{d},{d}) denied: outside its granted doc_region", .{ p.name, start, end }),
        },
        error.Collapsed => caller.trap("plugin '{s}' doc-edit grant COLLAPSED — its identity anchors no longer resolve (deleted or compacted); re-grant needed", .{p.name}),
        else => unreachable,
    }
}

// Group C: write.
pub fn hEdit(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const bytes = caller.readMemory(p.gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer p.gpa.free(bytes);
    const saved = p.activeCtx().principal;
    p.activeCtx().principal = p.principal();
    defer p.activeCtx().principal = saved;
    const start: usize = @intCast(args[0]);
    const end: usize = @intCast(args[1]);
    p.activeCtx().edit(.{ .start = start, .end = end }, bytes) catch |e| switch (e) {
        error.OutOfLimit, error.Collapsed => trapDocRegion(p, caller, start, end, e),
        else => {},
    };
}

/// `edit_as(agent, start, end, bytes)` (perm edit): the gated `ctx.edit` door,
/// but authored as the named `role=.agent` sub-peer rather than the plugin's
/// own peer — so an agent plugin's edits attribute to "claude"/"codex" and get
/// their own per-agent selective-undo unit. Single-shot: the override is set
/// only around this one edit (no persistent leak). An `.agent` author never
/// joins the user's undo history (see command.Context.edit), so this is always
/// a peer commit. An empty agent name falls back to the plugin's own peer.
pub fn hEditAs(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const agent = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer p.gpa.free(agent);
    const bytes = caller.readMemory(p.gpa, @intCast(args[4]), @intCast(args[5])) catch return;
    defer p.gpa.free(bytes);
    const saved_prin = p.activeCtx().principal;
    const saved_override = p.author_override;
    p.author_override = if (agent.len > 0) agent else null;
    p.activeCtx().principal = p.principal();
    defer {
        p.activeCtx().principal = saved_prin;
        p.author_override = saved_override;
    }
    const start: usize = @intCast(args[2]);
    const end: usize = @intCast(args[3]);
    p.activeCtx().edit(.{ .start = start, .end = end }, bytes) catch |e| switch (e) {
        error.OutOfLimit, error.Collapsed => trapDocRegion(p, caller, start, end, e),
        else => {},
    };
}

/// `render(start, end, bytes)` (perm edit): produce derived/streamed content
/// (a magit/dired listing, a transcript) into a buffer — a DISTINCT operation
/// from `edit`. Bypasses read-only (the text is output, not user-editable) and
/// authors as the plugin's own peer (never the user's undo). Grade-gated.
pub fn hRender(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const bytes = caller.readMemory(p.gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer p.gpa.free(bytes);
    const saved = p.activeCtx().principal;
    p.activeCtx().principal = p.principal();
    defer p.activeCtx().principal = saved;
    p.activeCtx().render(.{ .start = @intCast(args[0]), .end = @intCast(args[1]) }, bytes) catch {};
}

pub fn hJump(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const ed = p.activeCtx().editor();
    ed.placeCursor(@min(@as(usize, @intCast(args[0])), ed.text().byteLen()));
}

// ── The native `editor` surface + anchored-range membrane ────────────

/// `editor.step(from, dir, kind) -> offset`: the pure step primitive a motion
/// plugin composes (char boundary or byte-column line motion), no cursor move.
pub fn hEditorStep(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const from: usize = @intCast(args[0]);
    const dir: Editor.StepDir = @enumFromInt(@as(u32, @intCast(args[1])));
    const kind: Editor.StepKind = @enumFromInt(@as(u32, @intCast(args[2])));
    results[0] = @intCast(p.activeCtx().editor().stepOffset(from, dir, kind));
}

/// `editor.setSelection(start, end)`: select `[start, end)` (mark at start,
/// cursor at end). The native selection write-half, composed from placeCursor
/// + setMark.
pub fn hSetSelection(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const ed = p.activeCtx().editor();
    const len = ed.text().byteLen();
    ed.placeCursor(@min(@as(usize, @intCast(args[0])), len));
    ed.setMark(p.gpa) catch {};
    ed.placeCursor(@min(@as(usize, @intCast(args[1])), len));
}

/// Anchor `[start, end)` in the current CRDT document and return an opaque
/// handle into this plugin's per-dispatch table. The one way a guest builds a
/// live range (a motion's target, or a linewise op's line span).
pub fn hAnchorRange(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const h = p.anchorRange(@intCast(args[0]), @intCast(args[1])) catch {
        results[0] = -1;
        return;
    };
    results[0] = @intCast(h);
}

/// A motion sets its result to a borrowed live `range` Value.
pub fn hSetResultRange(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const h = opaqueHandle(args[0]) orelse return;
    const slot = p.activeRange(h) orelse return;
    const range = p.borrowedRange(slot) orelse return;
    p.result = .{ .range = range };
}

/// Run a command by name; if it returns a live `range` Value (a motion), copy
/// its current anchors into THIS plugin's range table and return the
/// handle. -1 if the command produced no range. This is how an operator (or
/// vim) "awaits a motion by name" (design §6.1). Synchronous motions only for
/// now. Asynchronous results use the capability/snapshot boundary instead.
pub fn hRunRange(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const cmd = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch {
        results[0] = -1;
        return;
    };
    defer p.gpa.free(cmd);
    const rv = command.run(p.activeCtx().commands, p.activeCtx(), cmd, &.{}) catch {
        results[0] = -1;
        return;
    };
    if (rv != .range) {
        results[0] = -1;
        return;
    }
    const cur = rv.range.resolve(p.activeCtx().document()) orelse {
        results[0] = -1;
        return;
    };
    const h = p.anchorRange(cur.start, cur.end) catch {
        results[0] = -1;
        return;
    };
    results[0] = @intCast(h);
}

/// Resolve an anchored-range handle to its current `[start, end)` (two u32
/// into the guest). -1 if its handle or buffer locus is gone.
pub fn hRangeEnds(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const h = opaqueHandle(args[0]) orelse {
        results[0] = -1;
        return;
    };
    const slot = p.activeRange(h) orelse {
        results[0] = -1;
        return;
    };
    const cur = p.resolveRange(slot) orelse {
        results[0] = -1;
        return;
    };
    const pair = [2]u32{ @intCast(cur.start), @intCast(cur.end) };
    _ = caller.writeMemory(@intCast(args[1]), 8, std.mem.asBytes(&pair)) catch {
        results[0] = -1;
        return;
    };
    results[0] = 0;
}

/// Explicitly release one anchored-range resource. Motion/operator handles are
/// also cleared at the next dispatch; asynchronous interactions release them
/// when their terminal callback runs.
pub fn hRangeRelease(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const h = opaqueHandle(args[0]) orelse return;
    p.releaseRange(h);
}

/// Retain a range across command dispatches. Interactive tools pair this with
/// an explicit release in their terminal callback; ordinary motions do not.
pub fn hRangeRetain(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const h = opaqueHandle(args[0]) orelse {
        results[0] = -1;
        return;
    };
    results[0] = if (p.retainRange(h)) 0 else -1;
}

/// Run a command passing a live range (by handle) as its single arg — how
/// vim hands a motion's range to an operator (`op.delete`, …).
pub fn hRunRangeArg(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const cmd = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer p.gpa.free(cmd);
    const h = opaqueHandle(args[2]) orelse return;
    const slot = p.activeRange(h) orelse return;
    const rv = command.Value{ .range = p.borrowedRange(slot) orelse return };
    _ = command.run(p.activeCtx().commands, p.activeCtx(), cmd, &.{rv}) catch {};
}

/// An operator reads its live `range` arg and anchors it in this
/// plugin's table, return the handle. -1 if arg `i` is not a range.
pub fn hArgRange(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const i: usize = @intCast(args[0]);
    if (i >= p.cur_args.len or p.cur_args[i] != .range) {
        results[0] = -1;
        return;
    }
    const cur = p.cur_args[i].range.resolve(p.activeCtx().document()) orelse {
        results[0] = -1;
        return;
    };
    const h = p.anchorRange(cur.start, cur.end) catch {
        results[0] = -1;
        return;
    };
    results[0] = @intCast(h);
}

/// Apply an edit over an anchored-range handle: resolve it, then use the gated
/// `ctx.edit` door authored as this plugin's peer (same gate/attribution as
/// `wl_edit`). A `view` grade fails inside `ctx.edit` — zero permission code
/// in the operator.
pub fn hEditRange(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const h = opaqueHandle(args[0]) orelse return;
    const slot = p.activeRange(h) orelse return;
    const cur = p.resolveRange(slot) orelse return;
    const bytes = caller.readMemory(p.gpa, @intCast(args[1]), @intCast(args[2])) catch return;
    defer p.gpa.free(bytes);
    const saved = p.activeCtx().principal;
    p.activeCtx().principal = p.principal();
    defer p.activeCtx().principal = saved;
    p.activeCtx().edit(.{ .start = cur.start, .end = cur.end }, bytes) catch |e| switch (e) {
        error.OutOfLimit, error.Collapsed => trapDocRegion(p, caller, cur.start, cur.end, e),
        else => {},
    };
}
