//! notes — capture + review over plain files (design §6.6, org-lite), a `.wasm`
//! plugin. `notes-capture` appends a line to a notes file via `fs.append`;
//! `notes-open` reads it into a tool buffer via `fs.read`. perms
//! `{fs_read, fs_write}`. Agenda/backlinks (grep over the notes) compose the
//! consult + proc plugins; capture into a shared vault is inherently
//! multiplayer once the file is a CRDT document.

const std = @import("std");
const weft = @import("weft");

const default_file = "weft-notes.md";
var line_buf: [1 << 14]u8 = undefined;

const Cmd = struct { name: []const u8, handler: *const fn () void };
const cmds = [_]Cmd{
    .{ .name = "notes-capture", .handler = capture },
    .{ .name = "notes-open", .handler = open },
};

export fn describe() void {
    for (cmds) |c| weft.declareCommand(c.name);
    weft.requestPerm(.fs_read);
    weft.requestPerm(.fs_write);
}
export fn init() void {
    for (cmds) |c| _ = weft.register(c.name);
}
export fn on_command(id: u32) void {
    if (id < cmds.len) cmds[id].handler();
}

/// Append arg0 (the entry) + newline to the notes file (arg1, or the default).
/// arg0 is copied out first — a second `argStr` reuses the shared arg scratch.
fn capture() void {
    const text = weft.argStr(0) orelse return;
    const n = @min(text.len, line_buf.len - 1);
    @memcpy(line_buf[0..n], text[0..n]);
    line_buf[n] = '\n';
    const path = weft.argStr(1) orelse default_file;
    _ = weft.fsAppend(path, line_buf[0 .. n + 1]);
}

/// Read the notes file (arg0, or the default) into the *notes* tool buffer.
fn open() void {
    const path = weft.argStr(0) orelse default_file;
    weft.runStr("buffer-create", "*notes*"); // create + focus it empty
    const content = weft.fsRead(path) orelse ""; // into shim scratch
    weft.edit(.{ .start = 0, .end = weft.byteLen() }, content);
    weft.jump(0);
}
