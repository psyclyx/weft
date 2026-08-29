//! debug — breakpoints: the first slice of a debugger. Toggle a breakpoint on
//! the cursor's line and a gutter marker (●) shows it. This establishes the
//! `debug-*` command surface and the breakpoint MODEL the DAP client consumes.
//!
//! THE PLUGIN REMEMBERS NOTHING. A breakpoint is a place in a document, so the
//! host holds it as an ANCHOR on that document's breakpoint layer (per buffer,
//! dropped with it) — an edit above a mark carries it along, and the line the
//! debug adapter re-arms at is derived from the anchor when the wire needs one.
//! This plugin reads the set back (`breakpointOffsets`) every time it paints or
//! counts, so there is no second copy of a position here to drift out of step
//! with the text.
//!
//! The ● is a DECORATION republished from that set: display-only (perms `{}`),
//! never a document byte, so `yy` never yanks one and it takes no commit.

const std = @import("std");
const weft = @import("weft");

const Cmd = struct { name: []const u8, handler: *const fn () void };
const cmds = [_]Cmd{
    .{ .name = "debug-toggle-breakpoint", .handler = toggle },
    .{ .name = "debug-clear-breakpoints", .handler = clearAll },
    .{ .name = "debug-list-breakpoints", .handler = list },
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

/// The focused buffer changed: paint ITS breakpoints (the decorations layer is
/// per-buffer, so a switch would otherwise show nothing).
export fn on_activate() void {
    render();
}

/// Toggle a breakpoint on the cursor's line.
fn toggle() void {
    const off = weft.lineAt(weft.cursor()).start;
    weft.echo(if (weft.breakpointToggle(off))
        "debug: breakpoint set"
    else
        "debug: breakpoint cleared");
    render();
}

/// Clear every breakpoint in the focused buffer.
fn clearAll() void {
    weft.breakpointClear();
    weft.echo("debug: breakpoints cleared");
    render();
}

fn list() void {
    var n: usize = 0;
    var it = offsets();
    while (it.next()) |_| n += 1;
    var buf: [48]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "debug: {d} breakpoint(s)", .{n}) catch return;
    weft.echo(msg);
}

/// Repaint the focused buffer's breakpoints as gutter markers, from the
/// anchored set. `decorateClear` targets the active buffer's decorations layer.
fn render() void {
    weft.decorateClear();
    var it = offsets();
    while (it.next()) |off| weft.decorate(off, .gutter, .removed, "\u{25CF}"); // ● in red-ish (removed)
}

/// The active document's breakpoint offsets, read back from the host. Borrows
/// the read scratch, so the whole walk must finish before the next read call.
fn offsets() Offsets {
    return .{ .rest = weft.breakpointOffsets() };
}

const Offsets = struct {
    rest: []const u8,

    fn next(self: *Offsets) ?usize {
        while (self.rest.len != 0) {
            const cut = std.mem.indexOfScalar(u8, self.rest, ',') orelse self.rest.len;
            const field = self.rest[0..cut];
            self.rest = self.rest[@min(cut + 1, self.rest.len)..];
            if (std.fmt.parseInt(usize, field, 10) catch null) |off| return off;
        }
        return null;
    }
};
