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
const Door = @import("../plugin_resources.zig").Door;

/// The entry this call is about (`command.Context.entry` — the active one, or
/// the entry a background delivery captured), for the handlers that have
/// nothing to answer without an editor: a guest asking about text in an entry
/// that holds none gets the same reply it gets for an empty document.
///
/// Takes the CONTEXT, not a plugin: these bodies are shared with the resident
/// JS membrane (see `read_doors`), and "the entry this call is about" is a
/// property of the dispatch, not of which guest runtime dispatched it. The
/// non-shared handlers below pass `p.activeCtx()`; the shared ones pass
/// `d.ctx`, which is the same value arriving by the same route.
fn activeEditor(ctx: *command.Context) ?*Editor {
    return (ctx.entry() orelse return null).textEditor();
}

fn opaqueHandle(raw: i32) ?u32 {
    return if (raw < 0) null else @intCast(raw);
}

// ── The read surface, shared with the JS plane ───────────────────────
// A JS plugin runs inside quickjs.wasm, which IS a wasm plugin, so it should
// be able to read the buffer it is in. It could not: it had `qjs_line_text`,
// a narrower answer to a question `line_at` + `slice` already answer, and
// nothing else. These bodies carry no authority — no perm gate, no trap, no
// mutation — which is exactly why they were the right ones to share first.
//
// Same construction as the proc doors (doc/place.md §4.1a): the body lives
// once, `wasmDoor` and `quickjs.zig`'s `jsDoor` wrap it for their own plugin
// type, and `e2e/demolition_test.zig` proves by function pointer that neither
// plane grew a second copy.

/// Wrap a shared body as a `wl_*` handler. The read doors carry no authority,
/// so this is `plugin.zig`'s one trampoline with no gate — the same function
/// the proc doors bind through, called with `null` instead of being a second,
/// subtly different generator that happens to omit the check.
pub fn wasmDoor(comptime body: anytype) wasm.Linker.HostFn {
    return shared.wasmDoor(body, null);
}

pub fn cursorBody(d: Door, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    const ed = activeEditor(d.ctx) orelse {
        results[0] = 0;
        return;
    };
    results[0] = @intCast(ed.cursorOffset());
}
pub const hCursor = wasmDoor(cursorBody);

pub fn byteLenBody(d: Door, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    const ed = activeEditor(d.ctx) orelse {
        results[0] = 0;
        return;
    };
    results[0] = @intCast(ed.text().byteLen());
}
pub const hByteLen = wasmDoor(byteLenBody);

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

pub fn sliceBody(d: Door, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const ed = activeEditor(d.ctx) orelse {
        results[0] = 0;
        return;
    };
    const rope = ed.text();
    const len = rope.byteLen();
    const s = @min(@as(usize, @intCast(args[0])), len);
    const e = @min(@as(usize, @intCast(args[1])), len);
    if (e <= s) {
        results[0] = 0;
        return;
    }
    const buf = d.resources.gpa.alloc(u8, e - s) catch {
        results[0] = 0;
        return;
    };
    defer d.resources.gpa.free(buf);
    var sr = rope.streamReader(.{ .start = s, .end = e }, &.{});
    sr.interface.readSliceAll(buf) catch {
        results[0] = 0;
        return;
    };
    const n = caller.writeMemory(@intCast(args[2]), @intCast(args[3]), buf) catch 0;
    results[0] = @intCast(n);
}
pub const hSlice = wasmDoor(sliceBody);

pub fn lineAtBody(d: Door, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const rope = (activeEditor(d.ctx) orelse return).text();
    const row = rope.offsetToPoint(@min(@as(usize, @intCast(args[0])), rope.byteLen())).row;
    const line = rope.lineRange(row);
    const pair = [2]u32{ @intCast(line.start), @intCast(line.end) };
    _ = caller.writeMemory(@intCast(args[1]), 8, std.mem.asBytes(&pair)) catch {};
}
pub const hLineAt = wasmDoor(lineAtBody);

pub fn selectionBody(d: Door, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const ed = activeEditor(d.ctx) orelse {
        results[0] = 0;
        return;
    };
    const sel = ed.selectedRange() orelse {
        results[0] = 0;
        return;
    };
    const pair = [2]u32{ @intCast(sel.start), @intCast(sel.end) };
    _ = caller.writeMemory(@intCast(args[0]), 8, std.mem.asBytes(&pair)) catch {};
    results[0] = 1;
}
pub const hSelection = wasmDoor(selectionBody);

pub fn pathBody(d: Door, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const ed = activeEditor(d.ctx) orelse {
        results[0] = -1;
        return;
    };
    const path = ed.backingPath() orelse {
        results[0] = -1;
        return;
    };
    const n = caller.writeMemory(@intCast(args[0]), @intCast(args[1]), path) catch {
        results[0] = -1;
        return;
    };
    results[0] = @intCast(n);
}
pub const hPath = wasmDoor(pathBody);

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
/// (a git/files listing, a transcript) into a buffer — a DISTINCT operation
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

pub fn jumpBody(d: Door, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const ed = activeEditor(d.ctx) orelse return;
    ed.placeCursor(@min(@as(usize, @intCast(args[0])), ed.text().byteLen()));
}
pub const hJump = wasmDoor(jumpBody);

// ── The native `editor` surface + anchored-range membrane ────────────

/// `editor.step(from, dir, kind) -> offset`: the pure step primitive a motion
/// plugin composes (char boundary or byte-column line motion), no cursor move.
pub fn hEditorStep(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const from: usize = @intCast(args[0]);
    const dir: Editor.StepDir = @enumFromInt(@as(u32, @intCast(args[1])));
    const kind: Editor.StepKind = @enumFromInt(@as(u32, @intCast(args[2])));
    const ed = activeEditor(p.activeCtx()) orelse {
        results[0] = @intCast(from);
        return;
    };
    results[0] = @intCast(ed.stepOffset(from, dir, kind));
}

/// `editor.setSelection(start, end)`: select `[start, end)` (mark at start,
/// cursor at end) as THE selection — `Editor.selectRange`, so any secondaries
/// collapse; several are written only through `selections_set`.
pub fn hSetSelection(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const ed = activeEditor(p.activeCtx()) orelse return;
    const len = ed.text().byteLen();
    ed.selectRange(p.gpa, @min(@as(usize, @intCast(args[0])), len), @min(@as(usize, @intCast(args[1])), len)) catch {};
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
    results[0] = runForRange(p, cmd);
}

/// Run `cmd` and import the live range it returns as a handle in this
/// plugin's table; -1 when it returned none. The shared body of `run_range`
/// and `run_range_each`.
fn runForRange(p: *WasmPlugin, cmd: []const u8) i32 {
    const rv = command.run(p.activeCtx().commands, p.activeCtx(), cmd, &.{}) catch return -1;
    if (rv != .range) return -1;
    const doc = p.activeCtx().document() orelse return -1;
    const cur = rv.range.resolve(doc) orelse return -1;
    const h = p.anchorRange(cur.start, cur.end) catch return -1;
    return @intCast(h);
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

/// `wl_view_range(out_ptr)` → 0, writing `[start,end)`: the byte range the
/// head's focused pane showed of the addressed entry in its last built frame
/// — what the user can SEE, after scrolling and folds. -1 when that pane
/// showed another entry, or nothing yet. Clamped to the entry's current
/// length (an edit may have landed since the frame).
pub fn hViewRange(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    results[0] = -1;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const ctx = p.activeCtx();
    const shown = ctx.head.view_range orelse return;
    const entry = ctx.buffer();
    if (shown.entry.id != entry.id or shown.entry.generation != entry.generation) return;
    const doc = ctx.document() orelse return;
    const len = doc.text().byteLen();
    const pair = [2]u32{ @intCast(@min(shown.start, len)), @intCast(@min(shown.end, len)) };
    _ = caller.writeMemory(@intCast(args[0]), 8, std.mem.asBytes(&pair)) catch return;
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
    const doc = p.activeCtx().document() orelse {
        results[0] = -1;
        return;
    };
    const cur = p.cur_args[i].range.resolve(doc) orelse {
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

// ── Multiple selections ──────────────────────────────────────────────
// A selection set crosses as ONE u32 record, both ways:
//
//     [primary, anchor0, head0, anchor1, head1, …]
//
// in document order. `get` writes it, `set` reads it back — so a guest edits
// the set it read and hands it back, and add/remove/collapse are SDK
// compositions over the pair rather than three more doors (plugin_sdk
// `addSelection`/`removeSelection`/`collapseSelections`). A caret reads
// `anchor == head`, and `anchor == head` sets one.

/// Guest words arrive as i32; every one of these is a u32 on the guest side
/// (offsets, counts, pointers). Reinterpret, never `@intCast` — a sign-bit
/// word from a hostile guest must not trap the host.
fn word(raw: i32) u32 {
    return @bitCast(raw);
}

/// A sane ceiling on one selection record, so a hostile count cannot ask the
/// host to allocate gigabytes. Far above any editing use.
const max_selections: u32 = 1 << 16;

/// `selections_get(out_ptr, cap) -> count`: write the primary index and up to
/// `cap` `{anchor, head}` pairs; return the full count (a `cap` of 0 writes
/// nothing — the count query). An entry with no text reports 0.
pub fn hSelectionsGet(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const ed = activeEditor(p.activeCtx()) orelse {
        results[0] = 0;
        return;
    };
    const n = ed.selectionCount();
    results[0] = @intCast(n);
    const cap = @min(word(args[1]), n);
    if (cap == 0) return;
    const words = p.gpa.alloc(u32, 1 + 2 * cap) catch return;
    defer p.gpa.free(words);
    words[0] = @intCast(ed.primary);
    for (0..cap) |i| {
        const e = ed.selectionEnds(i);
        words[1 + 2 * i] = @intCast(e.anchor);
        words[2 + 2 * i] = @intCast(e.head);
    }
    const bytes = std.mem.sliceAsBytes(words);
    _ = caller.writeMemory(word(args[0]), bytes.len, bytes) catch {};
}

/// `selections_set(ptr, n) -> 0 | -1`: replace every selection with the `n`
/// pairs of the record at `ptr` (n ≥ 1). Offsets clamp to the document; the
/// set is normalized (sorted, overlaps merged). -1 for no editor, n out of
/// range, or an unreadable record — the old set is then untouched.
pub fn hSelectionsSet(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = -1;
    const ed = activeEditor(p.activeCtx()) orelse return;
    const n = word(args[1]);
    if (n == 0 or n > max_selections) return;
    const raw = caller.readMemory(p.gpa, word(args[0]), (1 + 2 * @as(usize, n)) * 4) catch return;
    defer p.gpa.free(raw);
    const ends = p.gpa.alloc(Editor.Ends, n) catch return;
    defer p.gpa.free(ends);
    const primary = std.mem.readInt(u32, raw[0..4], .little);
    for (ends, 0..) |*e, i| {
        const at = 4 + 8 * i;
        e.* = .{
            .anchor = std.mem.readInt(u32, raw[at..][0..4], .little),
            .head = std.mem.readInt(u32, raw[at + 4 ..][0..4], .little),
        };
    }
    ed.setSelections(p.gpa, ends, primary) catch return;
    results[0] = 0;
}

/// `run_range_each(cmd, out_ptr, cap) -> count`: run a motion ONCE PER
/// SELECTION, each time with that selection as the primary — so the motion,
/// which reads "the cursor", reads that selection's head — and write one
/// live-range handle per selection (-1 where it returned no range), in the
/// document order the selections had when this began. The primary is restored
/// afterwards. With one selection this is `run_range`.
pub fn hRunRangeEach(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = 0;
    const cmd = caller.readMemory(p.gpa, word(args[0]), word(args[1])) catch return;
    defer p.gpa.free(cmd);
    const entry = p.activeCtx().entry() orelse return;
    const at = entry.ref();
    const ed = entry.textEditor() orelse return;
    // Iterate by HANDLE, not index: a motion is free to reshape the set, and
    // the head handle is the selection's stable identity meanwhile.
    const heads = p.gpa.alloc(SelectionHead, ed.selectionCount()) catch return;
    defer p.gpa.free(heads);
    for (heads, ed.selections.items) |*h, sel| h.* = sel.head;
    const out = p.gpa.alloc(i32, heads.len) catch return;
    defer p.gpa.free(out);
    const primary_head = ed.selections.items[ed.primary].head;
    // A VISIT: the motion speaks the single-selection API, and here that
    // means the visited selection, not a collapse of its siblings.
    ed.beginVisit();
    for (heads, out) |h, *o| {
        o.* = -1;
        // The motion may have closed or switched the entry: stop, honestly.
        if (visitedEditor(p, at) != ed) continue;
        ed.visit(selectionIndexOf(ed, h) orelse continue);
        o.* = runForRange(p, cmd);
    }
    if (p.ctx.buffers.resolve(at)) |b| if (b.textEditor()) |still| {
        still.visit(selectionIndexOf(still, primary_head) orelse @min(still.primary, still.selectionCount() - 1));
        still.endVisit();
    };
    const bytes = std.mem.sliceAsBytes(out[0..@min(word(args[3]), out.len)]);
    if (bytes.len > 0) _ = caller.writeMemory(word(args[2]), bytes.len, bytes) catch {};
    results[0] = @intCast(heads.len);
}

const SelectionHead = @FieldType(Editor.Selection, "head");

/// The editor a visit began on, found again by its entry ref — only while that
/// entry is still the one this dispatch addresses. A command run inside the
/// visit may switch or close the entry; a closed one's editor is gone (and
/// took its visit with it). The visit still ENDS on a merely switched one.
fn visitedEditor(p: *WasmPlugin, at: anytype) ?*Editor {
    const b = p.ctx.buffers.resolve(at) orelse return null;
    const ed = b.textEditor() orelse return null;
    return if (activeEditor(p.activeCtx()) == ed) ed else null;
}

fn selectionIndexOf(ed: *const Editor, head: SelectionHead) ?usize {
    for (ed.selections.items, 0..) |sel, i| {
        if (sel.head == head) return i;
    }
    return null;
}

/// `run_range_arg_each(cmd, handles_ptr, n)`: run an operator once per live
/// range handle, in REVERSE offset order (a later edit never shifts an
/// earlier range's bytes under an operator that reads them), all inside ONE
/// undo unit of the active editor — the operator's own cursor moves are
/// barriers `beginUnit` holds shut. Stale or foreign handles are skipped.
pub fn hRunRangeArgEach(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const cmd = caller.readMemory(p.gpa, word(args[0]), word(args[1])) catch return;
    defer p.gpa.free(cmd);
    const n = word(args[3]);
    if (n == 0 or n > max_selections) return;
    const raw = caller.readMemory(p.gpa, word(args[2]), @as(usize, n) * 4) catch return;
    defer p.gpa.free(raw);
    const Job = struct { handle: u32, start: usize, end: usize };
    var jobs: std.ArrayList(Job) = .empty;
    defer jobs.deinit(p.gpa);
    for (0..n) |i| {
        const h = opaqueHandle(std.mem.readInt(i32, raw[4 * i ..][0..4], .little)) orelse continue;
        const slot = p.activeRange(h) orelse continue;
        const cur = p.resolveRange(slot) orelse continue;
        jobs.append(p.gpa, .{ .handle = h, .start = cur.start, .end = cur.end }) catch return;
    }
    std.mem.sort(Job, jobs.items, {}, struct {
        fn gt(_: void, a: Job, b: Job) bool {
            return a.start > b.start or (a.start == b.start and a.end > b.end);
        }
    }.gt);
    // Close the unit (and the visit: an operator that places "the" caret
    // places its own, not a collapse of the set) on the editor this began on,
    // found again by its entry ref: an operator may switch (or close) the
    // entry meanwhile.
    const entry = p.activeCtx().entry() orelse return;
    const at = entry.ref();
    const began = entry.textEditor() orelse return;
    began.history.beginUnit();
    began.beginVisit();
    defer if (p.ctx.buffers.resolve(at)) |b| if (b.textEditor()) |ed| {
        ed.endVisit();
        ed.history.endUnit();
    };
    for (jobs.items) |job| {
        const slot = p.activeRange(job.handle) orelse continue;
        const rv = command.Value{ .range = p.borrowedRange(slot) orelse continue };
        _ = command.run(p.activeCtx().commands, p.activeCtx(), cmd, &.{rv}) catch {};
    }
}

/// `undo_unit(open) -> 0 | -1`: open (1) or close (0) an undo unit on the
/// entry this call is about — everything the user's history ingests in
/// between is ONE unit, whatever barriers fire. Units nest, and the outermost
/// owns the unit: an operator that brackets itself inside a guest's count
/// loop is part of the loop's unit. Scoped to the command dispatch that
/// opened it (a unit left open closes as that dispatch returns). -1 outside
/// a dispatch, on an entry with no text, or for a close with none open here.
pub fn hUndoUnit(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const done = if (args[0] != 0) p.openUndoUnit() else p.closeUndoUnit();
    results[0] = if (done) 0 else -1;
}

/// The read/motion doors BOTH membranes bind, named once. `quickjs.zig` walks
/// this to bind its own side, and `e2e/demolition_test.zig` walks it to prove
/// by function pointer that the two planes run the same body — the same proof
/// the proc doors get, for the same reason: a JS plugin is a wasm plugin, and
/// two bodies is how they stop being one.
///
/// `edit` itself is NOT here yet, and the reason is honest rather than
/// incidental: it authors as `p.principal()` and TRAPS on a doc-region
/// violation, and a trap tears down a resident QuickJS runtime the next
/// command still needs (`quickjs.zig`'s `jsDoor` answers `denied` instead).
/// Sharing it means deciding what a refused edit means on a plane that cannot
/// die — a real design question, not a missing extern.
pub const read_doors = .{
    .{ .name = "cursor", .body = cursorBody, .wl = hCursor },
    .{ .name = "byte_len", .body = byteLenBody, .wl = hByteLen },
    .{ .name = "slice", .body = sliceBody, .wl = hSlice },
    .{ .name = "line_at", .body = lineAtBody, .wl = hLineAt },
    .{ .name = "selection", .body = selectionBody, .wl = hSelection },
    .{ .name = "path", .body = pathBody, .wl = hPath },
    .{ .name = "jump", .body = jumpBody, .wl = hJump },
};
