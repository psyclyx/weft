//! terminal — a shell in the panel, on a real terminal: the shell runs on a
//! pseudo-terminal (`weft.ptySpawn`, core's door), and its output is
//! emulated HERE, by libghostty-vt linked into this plugin (`vt.zig`), into
//! a grid of styled cells the panel draws (`weft.gridPublish`). Colours,
//! cursor shapes, full-screen programs (`less`, `vim`, `top`), line editing,
//! job control — all of it is the shell's and the emulator's, as in any
//! terminal (doc/terminal.md).
//!
//! `terminal` opens it — starting the shell the first time — and puts its
//! entry in the viewport named by `viewport` (default `panel`) through core's
//! generic `viewport.take`, focused there. `shell` names what runs (see
//! `invocation`; default `$SHELL`); `scrollback` how many lines are kept
//! (default 10000).
//!
//! KEYS. The entry CAPTURES input (`weft.declareCapture`, architecture
//! §10.4): every key reaches `terminal.input` raw — C-c, C-d, C-z, Tab,
//! Escape, the arrows, function keys, every M- chord — and libghostty-vt's
//! encoder turns it into the bytes the child reads, in the modes the child
//! set (application cursor keys, the kitty keyboard protocol). The one
//! sequence it never sees is the grammar's break-out chord (C-\ under vim,
//! helix and ide; C-c C-\ under emacs), which hands keys back to the editor;
//! a click in its pane, vim/helix `i` (`std.input.resume`), or C-` captures
//! them again. Of the keys, the
//! terminal keeps three for itself, as terminals do: S-Prior/S-Next page
//! through the scrollback, and C-S-v / S-Insert paste the clipboard
//! (bracketed when the child asked). The wheel scrolls the scrollback — or,
//! when the child asked for the mouse, reaches it as wheel reports.
//!
//! The pane's size is the terminal's: when layout gives the entry new room
//! (`weft.entryExtent`, told through `on_poll`), the emulator and the pty are
//! resized and the child hears SIGWINCH.
//!
//! A shell that exits (`exit`, C-d, a crash) says `[process exited N]` on the
//! screen; the next key or C-` starts a fresh one below it — input never goes
//! to a dead child.
//!
//! While a shell runs, context key `terminal.session` holds the terminal's
//! designation, `weft://here/proc/terminal`, on the place it runs in
//! (doc/model.md §2.5), so a config can offer an action only where there is
//! a live shell to take it. It is retracted on that place, named, wherever
//! the shell ends.

const std = @import("std");
const weft = @import("weft");
const Vt = @import("vt.zig").Vt;
const keys = @import("keys.zig");

const buffer_name = "*terminal*";
const session_key = "terminal.session";

/// The emulator, once the terminal has been opened.
var vt: Vt = undefined;
var vt_live = false;
/// The shell's pty, while one runs.
var pty: ?u32 = null;
/// Where a publish is built; kept between publishes.
var msg: std.ArrayList(u8) = .empty;

/// Output digested per wake: a flood (`yes`) is drawn as it goes, frame by
/// frame, instead of the frame waiting on all of it. What is left wakes the
/// plugin again.
const read_budget = 256 * 1024;

fn orDefault(key: []const u8, default: []const u8) []const u8 {
    const v = weft.config(key);
    return if (v.len > 0) v else default;
}

fn describeExtra() void {
    weft.requestPerm(.proc);
}

fn init() void {
    // `weft://here/proc/terminal` is this plugin's: opening it with no entry
    // showing it brings the terminal back (and a shell with it).
    _ = weft.designationOpener("proc.terminal", "terminal.open");
}

var command_buf: [1024]u8 = undefined;

/// What runs, under `/bin/sh -c`: the `shell` setting — a whole command line
/// (anything with a space) as written, a bare program (`bash`, `/bin/zsh`) or
/// by default `$SHELL`, exec'd. It gets a terminal's environment: TERM names
/// an xterm-compatible terminal with 256 colours and COLORTERM says truecolor,
/// which is what the emulator speaks.
fn invocation() []const u8 {
    const v = weft.config("shell");
    const env = "export TERM=xterm-256color COLORTERM=truecolor TERM_PROGRAM=weft; ";
    if (std.mem.indexOfAny(u8, v, " \t") != null)
        return std.fmt.bufPrint(&command_buf, "{s}{s}", .{ env, v }) catch v;
    const program = if (v.len > 0) v else "${SHELL:-/bin/sh}";
    return std.fmt.bufPrint(&command_buf, "{s}exec \"{s}\"", .{ env, program }) catch "exec /bin/sh";
}

/// The terminal's size: the room its pane had last frame, or a conventional
/// one before any pane has shown it (the first frame corrects it).
fn size() struct { cols: u16, rows: u16, cell_w: u16, cell_h: u16 } {
    if (weft.entryExtent(buffer_name)) |e| return .{ .cols = @max(e.cols, 2), .rows = @max(e.rows, 1), .cell_w = e.cell_w, .cell_h = e.cell_h };
    return .{ .cols = 80, .rows = 24, .cell_w = 0, .cell_h = 0 };
}

/// The emulator, made on first use.
fn emulator() ?*Vt {
    if (vt_live) return &vt;
    const s = size();
    const lines = std.fmt.parseInt(usize, orDefault("scrollback", "10000"), 10) catch 10000;
    vt.init(s.cols, s.rows, lines) catch {
        weft.echo("terminal: the emulator could not start");
        return null;
    };
    vt.resize(s.cols, s.rows, s.cell_w, s.cell_h);
    vt_live = true;
    return &vt;
}

/// The running shell: the one there is, or a fresh one. Null when none will
/// start (said so).
fn shell() ?u32 {
    if (pty) |h| return h;
    const t = emulator() orelse return null;
    const h = weft.ptySpawn(invocation(), t.cols, t.rows) orelse {
        weft.echo("terminal: could not start the shell");
        return null;
    };
    t.resize(t.cols, t.rows, t.cell_w, t.cell_h);
    weft.ptyResize(h, t.cols, t.rows, t.cols *| t.cell_w, t.rows *| t.cell_h);
    t.pty = h;
    pty = h;
    return h;
}

/// Draw whatever changed.
fn repaint() void {
    if (vt_live) vt.publish(buffer_name, &msg);
}

/// `on_poll`: something of ours is ready — the shell printed, the shell
/// ended, or the panel changed size.
fn onPoll() callconv(.c) void {
    if (!vt_live) return;
    if (pty) |h| {
        var buf: [64 * 1024]u8 = undefined;
        var taken: usize = 0;
        while (taken < read_budget) {
            const got = weft.ptyRead(h, &buf) orelse break;
            if (got.len == 0) break;
            vt.write(got);
            taken += got.len;
        }
        if (weft.ptyExited(h)) |code| ended(h, code);
    }
    fitToPane();
    repaint();
}

/// The shell is gone: say so on its screen, and let the next key start
/// another.
fn ended(h: u32, code: u8) void {
    var note: [48]u8 = undefined;
    vt.write(std.fmt.bufPrint(&note, "\r\n[process exited {d}]\r\n", .{code}) catch "\r\n[process exited]\r\n");
    weft.ptyClose(h);
    pty = null;
    vt.pty = null;
    publish("");
}

/// Size the emulator and the pty to the pane.
fn fitToPane() void {
    const e = weft.entryExtent(buffer_name) orelse return;
    const cols = @max(e.cols, 2);
    const rows = @max(e.rows, 1);
    if (cols == vt.cols and rows == vt.rows and e.cell_w == vt.cell_w and e.cell_h == vt.cell_h) return;
    vt.resize(cols, rows, e.cell_w, e.cell_h);
    if (pty) |h| weft.ptyResize(h, cols, rows, cols *| e.cell_w, rows *| e.cell_h);
}

/// What the terminal's entry is.
const designation = "weft://here/proc/terminal";

/// The place `terminal.session` was last published on, by its designation —
/// where it is retracted, wherever the user is when the shell ends.
var published_buf: [1024]u8 = undefined;
var published_len: usize = 0;

/// Say whether a shell is live (`value`), or that none is (empty). A shell
/// is published on the place it starts in; its end is said on that same
/// place, named, so quitting from another project cannot strand the key.
fn publish(value: []const u8) void {
    if (value.len != 0) {
        var here_buf: [1024]u8 = undefined;
        const place = weft.placeDesignation(&here_buf) orelse return;
        const was = published_buf[0..published_len];
        // Moved: what was said about the old place is no longer true there.
        if (was.len != 0 and !std.mem.eql(u8, was, place)) weft.contextSetAt(session_key, "", was) catch {};
        @memcpy(published_buf[0..place.len], place);
        published_len = place.len;
    }
    if (published_len == 0) return;
    weft.contextSetAt(session_key, value, published_buf[0..published_len]) catch |err| {
        var buf: [96]u8 = undefined;
        weft.echo(std.fmt.bufPrint(&buf, "terminal: could not publish {s}: {t}", .{ session_key, err }) catch session_key);
    };
    if (value.len == 0) published_len = 0;
}

/// `terminal`: the shell in the panel, focused and taking the keys; started
/// on first use, and again once it has exited.
fn open() void {
    _ = shell() orelse return;
    // The first publish makes the entry the pane will show.
    vt.all_dirty = true;
    repaint();
    weft.focusOrCreateBuffer(buffer_name);
    // The entry is a live resource (doc/model.md §2.1): it designates the
    // shell while one runs here, and a jump back to it once the entry is
    // closed is refused rather than answered with a new shell. It is also
    // what the viewport holds.
    _ = weft.designate(designation);
    weft.runStr("viewport.take", orDefault("viewport", "panel"));
    publish(designation);
    weft.declareCapture("terminal.input");
    weft.exitToResting();
}

/// `terminal.input`: one captured key — its spec and the text it committed.
fn input(spec: []const u8, text: []const u8) void {
    const t = emulator() orelse return;
    // A key to a terminal whose shell has ended starts the next one; the key
    // itself was meant for the old one.
    const h = pty orelse {
        if (shell() != null) publish(designation);
        return repaint();
    };
    defer repaint();
    if (std.mem.eql(u8, spec, "S-Prior")) return t.scroll(-@as(isize, @max(1, t.rows - 1)));
    if (std.mem.eql(u8, spec, "S-Next")) return t.scroll(@as(isize, @max(1, t.rows - 1)));
    if (std.mem.eql(u8, spec, "C-S-V") or std.mem.eql(u8, spec, "C-S-v") or std.mem.eql(u8, spec, "S-Insert")) return paste();
    if (std.mem.startsWith(u8, spec, "wheel-")) return wheel(t, h, std.mem.eql(u8, spec, "wheel-up"), std.mem.eql(u8, spec, "wheel-down"));
    var text_buf: [8]u8 = undefined;
    const k = keys.parse(spec, text, &text_buf) orelse return; // a click, a bare modifier
    var out: [128]u8 = undefined;
    const bytes = t.encodeKey(k, &out);
    if (bytes.len == 0) return;
    t.scrollToBottom();
    weft.ptyWrite(h, bytes);
}

/// A wheel notch: the child's, as a wheel report, when it asked for the
/// mouse; arrow keys on the alternate screen (a pager scrolls, as in any
/// terminal); otherwise the scrollback.
fn wheel(t: *Vt, h: u32, up: bool, down: bool) void {
    if (!up and !down) return; // sideways
    if (t.mouseTracking()) {
        const at = t.cursorCell();
        var out: [64]u8 = undefined;
        const bytes = t.encodeWheel(up, at.col, at.row, &out);
        if (bytes.len > 0) weft.ptyWrite(h, bytes);
        return;
    }
    if (t.altScreen()) {
        var key_buf: [8]u8 = undefined;
        const k = keys.parse(if (up) "Up" else "Down", "", &key_buf).?;
        var out: [16]u8 = undefined;
        const bytes = t.encodeKey(k, &out);
        for (0..3) |_| weft.ptyWrite(h, bytes);
        return;
    }
    t.scroll(if (up) -3 else 3);
}

/// `terminal.paste`: the clipboard, typed into the shell — control bytes
/// that could run a command stripped, and bracketed when the child asked.
/// Needs the `clipboard` grant (config: `weft.grant("terminal", "clipboard")`).
fn paste() void {
    const t = emulator() orelse return;
    const h = pty orelse return;
    const clip = weft.clipboardGet() orelse return;
    if (clip.len == 0) return;
    const text = weft.allocator.dupe(u8, clip) catch return;
    defer weft.allocator.free(text);
    const out = weft.allocator.alloc(u8, text.len + 16) catch return;
    defer weft.allocator.free(out);
    const bytes = t.encodePaste(text, out);
    t.scrollToBottom();
    weft.ptyWrite(h, bytes);
    repaint();
}

/// `terminal.quit`: stop the shell; the screen stays with what it printed.
fn quit() void {
    const h = pty orelse return;
    ended(h, 0);
    repaint();
}

const cmds = [_]weft.CommandEntry{
    .{ .name = "terminal.open", .arity = .whole, .call = open, .summary = "Open the shell in the panel, on a terminal that takes every key.", .label = "New Terminal", .menu = "Terminal", .group = "new", .order = 1, .icon = "terminal" },
    .{ .name = "terminal.input", .arity = .whole, .call = weft.thunk(input), .params = "key text", .summary = "Send one captured key to the terminal's shell.", .internal = true },
    .{ .name = "terminal.paste", .arity = .whole, .call = paste, .summary = "Paste the clipboard into the terminal's shell.", .label = "Paste into Terminal", .menu = "Terminal", .group = "terminal", .order = 2, .icon = "clipboard-paste" },
    .{ .name = "terminal.quit", .arity = .whole, .call = quit, .summary = "Stop the terminal's shell.", .label = "Stop Terminal", .menu = "Terminal", .group = "terminal", .order = 1, .icon = "stop" },
};

comptime {
    weft.plugin(&cmds, .{ .describe = describeExtra, .init = init }).exportAll();
    weft.exportCallback("on_poll", &onPoll);
}
