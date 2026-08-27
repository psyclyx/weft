//! The command-output surface shared by `run`, `make`, and `grep`: create the
//! tool buffer, capture each row's typed location when the output lands, and
//! visit the focused row from that table (architecture §14.6 — locations are
//! carried as values, never recovered by parsing rendered text). A consumer
//! plugin binds its own mode + visit command to these; nothing here reaches
//! into another plugin's state.

const std = @import("std");
const weft = @import("weft");
const targets = @import("output_targets.zig");

pub const Target = targets.Target;

/// One output buffer's captured rows. A plugin owns a handful of output
/// buffers (`*output*`, `*build*`, `*test*`, `*grep*`), each with its own
/// table — a per-buffer value, not one singleton for whichever fill was last.
const Slot = struct {
    name: []u8,
    table: targets.Table = .{},
};

/// A slot index + 1 is that buffer's FILL TOKEN: the host hands it back at
/// delivery, so a landing fill finds its own table without asking what is
/// focused. Token 0 means "no fill to run" (the host's convention).
var slots: [4]Slot = undefined;
var slot_count: usize = 0;

/// Install the navigation shape every output buffer shares: Return visits the
/// focused row through `visit_cmd`, j/k walk, q goes back. The mode falls back
/// to `normal` (not LOCKED) so a visit leaves cleanly into the file's own mode,
/// and rests in itself so the shell never forces normal on a tool buffer.
pub fn installMode(mode: []const u8, visit_cmd: []const u8) void {
    weft.setFallback(mode, "normal");
    weft.restingMode(mode);
    weft.bindKey(mode, "Return", visit_cmd);
    weft.bindKey(mode, "j", "cursor-down");
    weft.bindKey(mode, "k", "cursor-up");
    weft.bindKey(mode, "Down", "cursor-down");
    weft.bindKey(mode, "Up", "cursor-up");
    weft.bindKey(mode, "q", "buffer-back");
}

/// Focus the `name` tool buffer (reused across runs — `buffer-create` does NOT
/// dedupe by name, so re-creating would pile up duplicates), put it in `mode`,
/// and fill it with `cmd`'s output asynchronously under its own fill token.
pub fn show(cmd: []const u8, name: []const u8, mode: []const u8) void {
    const token = tokenFor(name) orelse return;
    if (!focus(name)) weft.runStr("buffer-create", name);
    weft.setMode(mode);
    weft.procToBuffer(cmd, name, token);
}

/// `on_fill_token`: read the raw output that just landed and record each row's
/// location, painting the location spans as we go. The host has BOUND the entry
/// this fill captured, so the ambient read/style doors mean it whatever is
/// focused — and `token` says which of our tables it is. This is the ONE moment
/// the text is authoritative; from here on it is display. `row_style` paints
/// whatever else a producer knows about a row (grep's match emphasis) while the
/// raw text is in hand.
pub fn fill(token: u32, row_style: ?*const fn (base: usize, line: []const u8, at: ?Target) void) void {
    const slot = slotAt(token) orelse return;
    slot.table.clear(weft.allocator);
    weft.styleClear();

    const total = weft.byteLen();
    var base: usize = 0;
    while (base < total) {
        const chunk = weft.slice(base, total);
        if (chunk.len == 0) break;
        const tail = base + chunk.len == total;
        // Whole lines only, so a row is never split across two reads. A single
        // line longer than the read scratch is captured from its head.
        const last_break = std.mem.lastIndexOfScalar(u8, chunk, '\n');
        const usable = if (tail) chunk.len else (if (last_break) |b| b + 1 else chunk.len);
        var i: usize = 0;
        while (i < usable) {
            var e = i;
            while (e < usable and chunk[e] != '\n') e += 1;
            const at = captureRow(slot, base + i, chunk[i..e]);
            if (row_style) |paint| paint(base + i, chunk[i..e], at);
            i = e + 1;
        }
        base += usable;
    }
}

/// Record the row's location and light it; the location it captured, if any.
fn captureRow(slot: *Slot, base: usize, line: []const u8) ?Target {
    slot.table.push(weft.allocator, line) catch return null;
    const target = slot.table.get(slot.table.len() - 1) orelse return null;
    weft.style(base + target.span_start, base + target.span_end, .location);
    return target;
}

/// Return in an output buffer: open the location the FOCUSED ROW carries. The
/// rendered line is never re-read — a row restyled or reformatted after the
/// fill still visits where its output pointed.
pub fn visit() void {
    const name = activeName() orelse return;
    defer weft.allocator.free(name);
    const slot = find(name) orelse return;
    const target = slot.table.get(cursorRow()) orelse return;
    // The path is the table's; `open` reuses the read scratch, not this.
    weft.runStr("open", target.path);
    var at = lineStartOffset(target.line);
    if (target.col > 1) at = @min(at + target.col - 1, weft.lineAt(at).end);
    weft.jump(at);
}

/// The 0-based row the cursor is on, counting newlines before it.
fn cursorRow() usize {
    const cur = weft.cursor();
    var row: usize = 0;
    var pos: usize = 0;
    while (pos < cur) {
        const chunk = weft.slice(pos, cur);
        if (chunk.len == 0) break;
        row += std.mem.count(u8, chunk, "\n");
        pos += chunk.len;
    }
    return row;
}

/// Byte offset of the start of 1-based line `n` in the active buffer (clamped
/// to EOF), scanning in scratch-sized chunks so a long file still resolves.
fn lineStartOffset(n: usize) usize {
    if (n <= 1) return 0;
    var line: usize = 1;
    var pos: usize = 0;
    const total = weft.byteLen();
    while (pos < total) {
        const chunk = weft.slice(pos, total);
        if (chunk.len == 0) break;
        for (chunk, 0..) |ch, k| {
            if (ch == '\n') {
                line += 1;
                if (line == n) return pos + k + 1;
            }
        }
        pos += chunk.len;
    }
    return pos;
}

/// The active buffer's name, copied out of the read scratch (a name outgrows
/// any fixed buffer). Caller frees.
fn activeName() ?[]u8 {
    const count = weft.bufferCount();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (!weft.bufferActive(i)) continue;
        const name = weft.bufferName(i) orelse return null;
        return weft.allocator.dupe(u8, name) catch null;
    }
    return null;
}

/// `name`'s fill token, minting its slot on first use; null when this plugin
/// already tracks its full complement of output buffers.
fn tokenFor(name: []const u8) ?u32 {
    for (slots[0..slot_count], 0..) |*slot, i| {
        if (std.mem.eql(u8, slot.name, name)) return @intCast(i + 1);
    }
    if (slot_count == slots.len) return null;
    slots[slot_count] = .{ .name = weft.allocator.dupe(u8, name) catch return null };
    slot_count += 1;
    return @intCast(slot_count);
}

fn slotAt(token: u32) ?*Slot {
    if (token == 0 or token > slot_count) return null;
    return &slots[token - 1];
}

/// Focus the buffer named `name`, if one is open.
fn focus(name: []const u8) bool {
    const count = weft.bufferCount();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const other = weft.bufferName(i) orelse continue;
        if (!std.mem.eql(u8, other, name)) continue;
        const id = weft.bufferId(i) orelse return false;
        weft.runInt("buffer-switch", id);
        return true;
    }
    return false;
}

fn find(name: []const u8) ?*Slot {
    for (slots[0..slot_count]) |*slot| {
        if (std.mem.eql(u8, slot.name, name)) return slot;
    }
    return null;
}
