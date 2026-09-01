//! whitespace — trailing-whitespace cleanup, a `.wasm` plugin with NO core
//! privilege beyond the edit door (perms `{}`). Both commands read a read-only
//! snapshot through `slice`/`lineAt` and mutate through the gated `edit` door,
//! authored as this plugin's peer (a view-grade doc refuses in the gate with
//! zero permission code here). `trim-trailing-line` edits just the trailing run
//! of the current line; `trim-trailing-buffer` rebuilds the whole (capped)
//! document trimmed and replaces it with one edit.

const weft = @import("weft");

/// Scratch for the rebuilt (trimmed) buffer. Trimming only ever shrinks, so a
/// buffer the size of the shim's read scratch (64 KiB) always suffices for the
/// bytes we managed to read — reads past this are clamped by the host (see the
/// cap note in `trimBuffer`).
var out: [1 << 16]u8 = undefined;

/// Registration order == the id the host hands `on_command`.
const cmds = [_]weft.CommandEntry{
    .{ .name = "trim-trailing-line", .call = trimLine },
    .{ .name = "trim-trailing-buffer", .call = trimBuffer },
};

fn isBlank(b: u8) bool {
    return b == ' ' or b == '\t';
}

/// Drop the trailing spaces/tabs of the CURRENT line. `lineAt` ends before the
/// newline, so `t` is exactly the line's content; we edit the trailing run to
/// empty (a no-op when there is none).
fn trimLine() void {
    const l = weft.lineAt(weft.cursor());
    const t = weft.slice(l.start, l.end); // borrows shim scratch
    var end = t.len;
    while (end > 0 and isBlank(t[end - 1])) end -= 1;
    if (end == t.len) return; // clean already
    weft.edit(.{ .start = l.start + end, .end = l.end }, "");
}

/// Strip trailing whitespace from EVERY line by rebuilding the document trimmed
/// and replacing it in one edit. Reads cap at the shim's 64 KiB scratch: if the
/// buffer is larger we trim only the leading `n` bytes we could read and replace
/// exactly that prefix (`edit({0, n}, ...)`), leaving the untouched tail intact
/// rather than truncating it.
fn trimBuffer() void {
    const len = weft.byteLen();
    const n = @min(len, out.len);
    const src = weft.slice(0, n); // borrows shim scratch; copied into `out` below
    if (n < len) weft.echo("trim-trailing-buffer: buffer exceeds 64KiB, trimmed the leading portion");

    var j: usize = 0; // write index into `out`
    var line_start: usize = 0; // start of the current line within `out`
    for (src) |b| {
        if (b == '\n') {
            while (j > line_start and isBlank(out[j - 1])) j -= 1; // drop this line's trailing run
            out[j] = '\n';
            j += 1;
            line_start = j;
        } else {
            out[j] = b;
            j += 1;
        }
    }
    // The final line carries no newline, so trim its trailing run here too.
    while (j > line_start and isBlank(out[j - 1])) j -= 1;

    if (j == n) return; // nothing to trim in the read portion
    weft.edit(.{ .start = 0, .end = n }, out[0..j]);
}

comptime {
    weft.plugin(&cmds, .{}).exportAll();
}
