//! fmt — format + external filters (design §6.2), a `.wasm` plugin over the
//! native `proc` FILTER surface. `format-buffer` picks a formatter by file
//! extension and rewrites the buffer through it; `filter` runs any command over
//! the selection (vim `!`). Both land as async, CRDT-anchored, plugin-authored edits
//! that merge like a concurrent editor. perms `{proc, timer}`.

const std = @import("std");
const weft = @import("weft");

/// `params` is the command's argument shape, written the way a person reads
/// it back (`describeCommand`): the palette shows it beside the row, the `:`
/// line hints it while you type, and it is what gets ASKED for when a call
/// arrives short.
const Cmd = struct {
    name: []const u8,
    handler: *const fn () void,
    params: []const u8 = "",
    summary: []const u8 = "",
};
const cmds = [_]Cmd{
    .{ .name = "format-buffer", .handler = formatBuffer, .summary = "Format the buffer with the formatter configured for its language." },
    .{ .name = "filter", .handler = filter, .params = "command", .summary = "Pipe the selection (or buffer) through a shell command." },
};

export fn describe() void {
    for (cmds) |c| weft.describeCommand(c.name, c.params, c.summary);
    weft.requestPerm(.proc);
    weft.requestPerm(.timer);
}
export fn init() void {
    for (cmds) |c| _ = weft.register(c.name);
}
export fn on_command(id: u32) void {
    if (id < cmds.len) cmds[id].handler();
}

/// (extension, in-place formatter with a `{}` for the file). First match wins.
const formatters = [_]struct { ext: []const u8, cmd: []const u8 }{
    .{ .ext = ".zig", .cmd = "zig fmt {}" },
    .{ .ext = ".rs", .cmd = "rustfmt {}" },
    .{ .ext = ".go", .cmd = "gofmt -w {}" },
    .{ .ext = ".py", .cmd = "black -q {}" },
    .{ .ext = ".nix", .cmd = "nixfmt {}" },
    .{ .ext = ".js", .cmd = "prettier --write {}" },
    .{ .ext = ".ts", .cmd = "prettier --write {}" },
    .{ .ext = ".jsx", .cmd = "prettier --write {}" },
    .{ .ext = ".tsx", .cmd = "prettier --write {}" },
    .{ .ext = ".json", .cmd = "prettier --write {}" },
    .{ .ext = ".css", .cmd = "prettier --write {}" },
    .{ .ext = ".html", .cmd = "prettier --write {}" },
    .{ .ext = ".md", .cmd = "prettier --write {}" },
};

/// Format the whole buffer with the formatter matching its file extension.
fn formatBuffer() void {
    const path = weft.path() orelse return;
    inline for (formatters) |f| {
        if (std.mem.endsWith(u8, path, f.ext))
            return weft.procFilter(f.cmd, .{ .start = 0, .end = weft.byteLen() });
    }
}

/// Filter the selection (or the whole buffer) through arg0 as a shell command.
fn filter() void {
    const cmd = weft.argStr(0) orelse return;
    const r = weft.selection() orelse weft.Range{ .start = 0, .end = weft.byteLen() };
    weft.procFilter(cmd, r);
}
