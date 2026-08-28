//! marks (architecture §11.7's worked example — non-install: exercised by the
//! wasm-membrane suite, never shipped). A third-party decorator that
//! highlights `TODO`/`FIXME` in ANY text entry it is told to decorate. The
//! text presentation has never heard of it: nothing in core, in the view, or
//! in another plugin names "marks" — it claims an annotation layer on a
//! REFERENCED entry and the presentation composites whatever feeds it finds.
//!
//! `marks-on [buffer]` decorates that entry (the active one by default) and
//! republishes; `marks-off [buffer]` takes its paint away. Each round is
//! stamped with the entry revision it was computed against, so an edit drops
//! the marks until the next `marks-on` — a decorator never guesses where its
//! spans went.

const std = @import("std");
const weft = @import("weft");

const layer_name = "marks";
const window = 4096;
/// Longest keyword minus one: the overlap that keeps a hit from being lost on
/// a window boundary.
const overlap = 4;

const Keyword = struct { text: []const u8, role: weft.StyleClass };
const keywords = [_]Keyword{
    .{ .text = "TODO", .role = .emphasis },
    .{ .text = "FIXME", .role = .removed },
};

const Target = struct { entry: u32, anno: weft.Annotations };
/// The entries this plugin decorates. Bounded on purpose: a decorator holds a
/// fixed number of targets and refuses past it, rather than growing with
/// whatever it is pointed at.
var targets: [8]?Target = @splat(null);
var buf: [window]u8 = undefined;

const Cmd = struct { name: []const u8, handler: *const fn () void };
const cmds = [_]Cmd{
    .{ .name = "marks-on", .handler = on },
    .{ .name = "marks-off", .handler = off },
};

export fn describe() void {
    for (cmds) |c| weft.declareCommand(c.name);
}
export fn init() void {
    for (cmds) |c| _ = weft.register(c.name);
}
export fn on_command(id: u32) void {
    if (id < cmds.len) cmds[id].handler();
}

/// The entry named by arg0, or the active one.
fn requested() ?u32 {
    const want = weft.argStr(0);
    var i: usize = 0;
    while (i < weft.bufferCount()) : (i += 1) {
        const hit = if (want) |name| blk: {
            const other = weft.bufferName(i) orelse break :blk false;
            break :blk std.mem.eql(u8, other, name);
        } else weft.bufferActive(i);
        if (!hit) continue;
        const id = weft.bufferId(i) orelse return null;
        return @intCast(id);
    }
    return null;
}

fn slot(entry: u32) ?*?Target {
    for (&targets) |*t| {
        if (t.*) |held| if (held.entry == entry) return t;
    }
    return null;
}

fn freeSlot() ?*?Target {
    for (&targets) |*t| {
        if (t.* == null) return t;
    }
    return null;
}

/// Claim the layer if we do not hold it yet, then republish every mark in the
/// entry against its current revision.
fn on() void {
    const entry = requested() orelse return weft.echo("marks: no such entry");
    const held = slot(entry) orelse freeSlot() orelse return weft.echo("marks: too many entries");
    if (held.* == null) {
        const anno = weft.Annotations.open(entry, layer_name) orelse return weft.echo("marks: refused");
        held.* = .{ .entry = entry, .anno = anno };
    }
    const anno = held.*.?.anno;
    if (!anno.begin()) {
        held.* = null;
        return weft.echo("marks: that entry is gone");
    }
    const len = anno.byteLen();
    var base: usize = 0;
    while (base < len) {
        const chunk = anno.read(base, @min(base + window, len), &buf);
        if (chunk.len == 0) break;
        for (keywords) |k| {
            var from: usize = 0;
            while (std.mem.indexOfPos(u8, chunk, from, k.text)) |at| : (from = at + 1) {
                if (base > 0 and at + k.text.len <= overlap) continue; // reported in the previous window
                anno.span(base + at, base + at + k.text.len, k.role, .range, "");
            }
        }
        if (chunk.len <= overlap) break;
        base += chunk.len - overlap;
    }
}

/// Take this plugin's paint off that entry. Nothing else changes.
fn off() void {
    const entry = requested() orelse return;
    const held = slot(entry) orelse return;
    held.*.?.anno.close();
    held.* = null;
}
