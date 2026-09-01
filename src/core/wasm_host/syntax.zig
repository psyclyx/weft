//! Structural reads over the buffer's tree-sitter grammar (design §4: the tree
//! stays host-side, captures/nodes cross) plus subbuffer claims + facts. Each
//! degrades honestly to -1 when no grammar/subbuffer service is wired.

const std = @import("std");
const wasm = @import("../wasm.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;

/// The editor of the entry this call is about — the active one, or the entry a
/// background delivery captured (`command.Context.entry`).
fn entryEditor(p: *WasmPlugin) ?*@import("../Editor.zig") {
    return (p.activeCtx().entry() orelse return null).textEditor();
}

pub fn hNodeAt(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const resolve = p.syntax_of orelse {
        results[0] = -1;
        return;
    };
    const syn = resolve(p.activeCtx().buffer()) orelse {
        results[0] = -1;
        return;
    };
    const node = syn.nodeAt(@intCast(args[0])) orelse {
        results[0] = -1;
        return;
    };
    const span = [2]u32{ @intCast(node.start), @intCast(node.end) };
    _ = caller.writeMemory(@intCast(args[3]), 8, std.mem.asBytes(&span)) catch {};
    results[0] = @intCast(caller.writeMemory(@intCast(args[1]), @intCast(args[2]), node.kind) catch 0);
}

/// The smallest NAMED node that STRICTLY encloses `[start, end)` — the
/// expand-selection primitive (call repeatedly to grow to the next scope).
/// Writes kind + [start,end] span; returns the kind length, or -1.
pub fn hNodeEnclosing(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const resolve = p.syntax_of orelse {
        results[0] = -1;
        return;
    };
    const syn = resolve(p.activeCtx().buffer()) orelse {
        results[0] = -1;
        return;
    };
    const start: usize = @intCast(args[0]);
    const end: usize = @intCast(args[1]);
    const anc = syn.ancestorsAt(p.gpa, start) catch {
        results[0] = -1;
        return;
    };
    defer p.gpa.free(anc);
    // Innermost first (reverse of root→leaf): the first node strictly bigger.
    var k = anc.len;
    while (k > 0) {
        k -= 1;
        const n = anc[k];
        if (n.start <= start and n.end >= end and !(n.start == start and n.end == end)) {
            const span = [2]u32{ @intCast(n.start), @intCast(n.end) };
            _ = caller.writeMemory(@intCast(args[4]), 8, std.mem.asBytes(&span)) catch {};
            results[0] = @intCast(caller.writeMemory(@intCast(args[2]), @intCast(args[3]), n.kind) catch 0);
            return;
        }
    }
    results[0] = -1;
}

/// Run a tree-sitter query (`scm`) over `[start, end)`; stash its captures on
/// the plugin (read back via `wl_query_capture`) and return the count, or -1.
pub fn hQuery(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    p.queryCapsClear();
    const resolve = p.syntax_of orelse {
        results[0] = -1;
        return;
    };
    const syn = resolve(p.activeCtx().buffer()) orelse {
        results[0] = -1;
        return;
    };
    const scm = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch {
        results[0] = -1;
        return;
    };
    defer p.gpa.free(scm);
    const caps = syn.queryCaptures(p.gpa, scm, .{ .start = @intCast(args[2]), .end = @intCast(args[3]) }) catch {
        results[0] = -1;
        return;
    };
    defer p.gpa.free(caps); // names transfer into query_caps below
    for (caps) |c| p.query_caps.append(p.gpa, .{ .name = c.name, .start = c.start, .end = c.end }) catch {
        p.gpa.free(c.name);
    };
    results[0] = @intCast(p.query_caps.items.len);
}

/// The named children of the smallest node at `off` (structural descent).
/// Materialized into the same capture buffer (kind as the "name"), read back
/// with `wl_query_capture`. Returns the child count, or -1.
pub fn hNodeChildren(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    p.queryCapsClear();
    const resolve = p.syntax_of orelse {
        results[0] = -1;
        return;
    };
    const syn = resolve(p.activeCtx().buffer()) orelse {
        results[0] = -1;
        return;
    };
    const kids = syn.childrenAt(p.gpa, @intCast(args[0])) catch {
        results[0] = -1;
        return;
    };
    defer p.gpa.free(kids);
    for (kids) |k| {
        const name = p.gpa.dupe(u8, k.kind) catch continue;
        p.query_caps.append(p.gpa, .{ .name = name, .start = k.start, .end = k.end }) catch p.gpa.free(name);
    }
    results[0] = @intCast(p.query_caps.items.len);
}

/// Read the `i`-th capture from the last `wl_query`: writes name + [start,end]
/// span, returns the name length, or -1.
pub fn hQueryCapture(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const i: usize = @intCast(args[0]);
    if (i >= p.query_caps.items.len) {
        results[0] = -1;
        return;
    }
    const q = p.query_caps.items[i];
    const span = [2]u32{ @intCast(q.start), @intCast(q.end) };
    _ = caller.writeMemory(@intCast(args[3]), 8, std.mem.asBytes(&span)) catch {};
    results[0] = @intCast(caller.writeMemory(@intCast(args[1]), @intCast(args[2]), q.name) catch 0);
}

pub fn hClaimSubbuffer(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const subs = p.subbuffers orelse {
        results[0] = -1;
        return;
    };
    const ed = entryEditor(p) orelse {
        results[0] = -1;
        return;
    };
    const sub = subs.claim(p.gpa, &ed.doc, .{ .start = @intCast(args[0]), .end = @intCast(args[1]) }) catch {
        results[0] = -1;
        return;
    };
    p.subs.append(p.gpa, sub) catch {
        results[0] = -1;
        return;
    };
    results[0] = @intCast(p.subs.items.len - 1);
}

pub fn hSubbufferPutFact(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const handle: usize = @intCast(args[0]);
    if (handle >= p.subs.items.len) return;
    const gpa = p.gpa;
    const key = caller.readMemory(gpa, @intCast(args[1]), @intCast(args[2])) catch return;
    defer gpa.free(key);
    const val = caller.readMemory(gpa, @intCast(args[3]), @intCast(args[4])) catch return;
    defer gpa.free(val);
    p.subs.items[handle].putFact(gpa, key, val) catch {};
}
