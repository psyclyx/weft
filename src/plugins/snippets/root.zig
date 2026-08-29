//! snippets — expand named templates (design §6.4 cape.snippet-flavored), a
//! `.wasm` plugin (perms `{fs_read}`). `snippets-expand` reads a snippets file
//! (arg1, or the default), finds the line whose trigger matches arg0, and
//! inserts its body at the cursor with literal `\n` turned into newlines. The
//! file is `trigger<TAB>body` per line — the simplest thing that composes the
//! `fs` read surface with the edit door.

const std = @import("std");
const weft = @import("weft");

const default_file = "weft-snippets.txt";
var trigger_buf: [256]u8 = undefined;
var body_buf: [1 << 14]u8 = undefined;

const Cmd = struct { name: []const u8, handler: *const fn () void };
const cmds = [_]Cmd{
    .{ .name = "snippets-expand", .handler = expand },
};

export fn describe() void {
    for (cmds) |c| weft.declareCommand(c.name);
    weft.requestPerm(.fs_read);
}
export fn init() void {
    for (cmds) |c| _ = weft.register(c.name);
}
export fn on_command(id: u32) void {
    if (id < cmds.len) cmds[id].handler();
}

/// Insert the body of the snippet named arg0 at the cursor.
fn expand() void {
    const trig = weft.argStr(0) orelse return;
    const tn = @min(trig.len, trigger_buf.len);
    @memcpy(trigger_buf[0..tn], trig[0..tn]); // copy — a second argStr reuses the scratch
    const path = weft.argStr(1) orelse default_file;
    const text = weft.fsRead(path) orelse return; // into shim scratch

    // Find the "trigger<TAB>body" line matching the (copied) trigger.
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        if (!std.mem.eql(u8, line[0..tab], trigger_buf[0..tn])) continue;
        // Expand literal "\n" in the body into real newlines.
        const raw = line[tab + 1 ..];
        var w: usize = 0;
        var i: usize = 0;
        while (i < raw.len and w < body_buf.len) : (i += 1) {
            if (i + 1 < raw.len and raw[i] == '\\' and raw[i + 1] == 'n') {
                body_buf[w] = '\n';
                w += 1;
                i += 1;
            } else {
                body_buf[w] = raw[i];
                w += 1;
            }
        }
        const off = weft.cursor();
        weft.edit(.{ .start = off, .end = off }, body_buf[0..w]);
        return;
    }
}
