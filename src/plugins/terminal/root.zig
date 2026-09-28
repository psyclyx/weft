//! terminal — shells on real terminals: each shell runs on a pseudo-terminal
//! (`weft.ptySpawn`, core's door), and its output is emulated HERE, by
//! libghostty-vt linked into this plugin (`vt.zig`), into a grid of styled
//! cells a pane draws (`weft.gridPublish`). Colours, cursor shapes,
//! full-screen programs (`less`, `vim`, `top`), line editing, job control —
//! all of it is the shell's and the emulator's, as in any terminal
//! (doc/terminal.md).
//!
//! There may be any number of terminals. Each is an ordinary entry —
//! `*terminal*`, `*terminal:2*`, … designated `weft://here/proc/terminal.N` —
//! with its own emulator and pty, so it can be shown in the panel, in an
//! editor pane as a tab, or in a split. `terminal.open` shows the one used
//! last (starting one when there is none); `terminal.new` always starts
//! another. Either puts it in the viewport named by `viewport` (default
//! `panel`, `none` for the editor) through core's generic `viewport.take`,
//! focused there. `shell` names what runs (see `invocation`; default
//! `$SHELL`); `scrollback` how many lines are kept (default 10000).
//!
//! KEYS. A terminal's entry CAPTURES input (`weft.declareCapture`,
//! architecture §10.4): every key reaches `terminal.input` raw — C-c, C-d,
//! C-z, Tab, Escape, the arrows, function keys, every M- chord — and
//! libghostty-vt's encoder turns it into the bytes the child reads, in the
//! modes the child set (application cursor keys, the kitty keyboard
//! protocol). The one sequence it never sees is the grammar's break-out
//! chord (C-\ under vim, helix and ide; C-c C-\ under emacs), which hands
//! keys back to the editor; a click in its pane, vim/helix `i`
//! (`std.input.resume`), or C-` captures them again. Of the keys, the
//! terminal keeps three for itself, as terminals do: S-Prior/S-Next page
//! through the scrollback, and C-S-v / S-Insert paste the clipboard
//! (bracketed when the child asked). The wheel scrolls the scrollback — or,
//! when the child asked for the mouse, reaches it as wheel reports.
//!
//! The pane's size is the terminal's: when layout gives an entry new room
//! (`weft.entryExtent`, told through `on_poll`), its emulator and pty are
//! resized and the child hears SIGWINCH.
//!
//! A shell that exits (`exit`, C-d, a crash) says `[process exited N]` on
//! its screen; the next key or `terminal.open` starts a fresh one below it —
//! input never goes to a dead child. Closing a terminal's entry hangs its
//! shell up.
//!
//! While a shell runs, context key `terminal.session` holds a live
//! terminal's designation on the place it runs in (doc/model.md §2.5), so a
//! config can offer an action only where there is a live shell to take it.
//! It is retracted on that place, named, when the last one there ends.

const std = @import("std");
const weft = @import("weft");
const Vt = @import("vt.zig").Vt;
const keys = @import("keys.zig");
const prompt = @import("prompt.zig");

const session_key = "terminal.session";

/// Output digested per wake, per terminal: a flood (`yes`) is drawn as it
/// goes, frame by frame, instead of the frame waiting on all of it. What is
/// left wakes the plugin again.
const read_budget = 256 * 1024;

/// One terminal: its entry, its emulator, its shell.
const Term = struct {
    /// The N of `weft://here/proc/terminal.N` — never reused, so a
    /// designation names one terminal for the whole run.
    id: u32,
    name_buf: [48]u8 = undefined,
    name_len: usize = 0,
    designation_buf: [64]u8 = undefined,
    designation_len: usize = 0,
    vt: Vt = undefined,
    /// The shell's pty, while one runs.
    pty: ?u32 = null,
    /// Where a publish is built; kept between publishes.
    msg: std.ArrayList(u8) = .empty,
    /// The entry has been published (it exists, or existed and was closed).
    shown: bool = false,
    /// The place `terminal.session` was published on for this terminal.
    place_buf: [1024]u8 = undefined,
    place_len: usize = 0,
    /// When it was last used, for `terminal.open`.
    used: u64 = 0,
    /// What the shell's integration says about its turns (doc/terminal.md
    /// §8) — the state this terminal DECLARES to core, which routes keys by it.
    shell: Shell = .{},

    fn name(self: *const Term) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    fn designation(self: *const Term) []const u8 {
        return self.designation_buf[0..self.designation_len];
    }

    fn place(self: *const Term) []const u8 {
        return self.place_buf[0..self.place_len];
    }

    fn repaint(self: *Term) void {
        const reading = if (weft.entryExtent(self.name())) |e| e.reading else false;
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(weft.allocator);
        const section = self.inputSection(&payload) catch null;
        self.vt.publish(self.name(), &self.msg, reading, section);
        self.shown = true;
    }

    /// Whether the program owns every key, by what it DECLARED: no
    /// integration that syncs the command line (then nothing tells a prompt
    /// from a program), a command running (OSC 133 C..D), the alternate
    /// screen, the kitty keyboard protocol, or mouse tracking. Never a guess
    /// at what a key would do.
    fn ownsKeys(self: *Term) bool {
        const s = &self.shell;
        if (!(s.line_sync and s.at_prompt and s.line_known) or s.running) return true;
        return self.vt.altScreen() or self.vt.kittyFlags() != 0 or self.vt.mouseTracking();
    }

    /// The input section for this publish into `out`, when what the program
    /// declares changed since the last one (or its line is to be taken up);
    /// null when nothing did.
    fn inputSection(self: *Term, out: *std.ArrayList(u8)) !?[]const u8 {
        const H = weft.grid.InputHead;
        const s = &self.shell;
        var head: H = .{ .row = s.line_row, .col = s.line_col };
        if (self.ownsKeys()) head.flags |= H.owns_keys else head.flags |= H.line;
        const at_prompt = head.flags & H.line != 0;
        if (at_prompt and s.fresh) head.flags |= H.fresh;
        if (at_prompt and s.authoritative) head.flags |= H.authoritative;
        const speaks = head.flags & (H.fresh | H.authoritative) != 0;
        if (!speaks and s.declared != null and std.meta.eql(s.declared.?, Shell.Declared{ .flags = head.flags, .row = head.row, .col = head.col })) return null;
        if (s.declared == null and head.flags == H.owns_keys) {
            // What core assumes of a program that never said: nothing to say.
            s.declared = .{ .flags = head.flags, .row = head.row, .col = head.col };
            return null;
        }
        s.declared = .{ .flags = head.flags & ~(H.fresh | H.authoritative), .row = head.row, .col = head.col };
        // The cursor goes with the line, which goes only when it is the
        // program's word.
        if (speaks) head.cursor = @intCast(@min(s.line_cursor, s.line.items.len));
        try weft.grid.Input.encode(out, weft.allocator, head, if (speaks) s.line.items else "", if (at_prompt) claimed else "");
        // Said: a new prompt, or the shell's own line, is declared once —
        // with the line, not before it is there to declare.
        if (speaks) {
            s.fresh = false;
            s.authoritative = false;
        }
        return out.items;
    }

    /// Feed the shell's output to the emulator, watching for its integration
    /// (`prompt.Scanner`): where a command line starts is where the cursor
    /// is when OSC 133 B arrives, so the output is fed up to it first.
    fn feed(self: *Term, bytes: []const u8) void {
        const s = &self.shell;
        var from: usize = 0;
        for (bytes, 0..) |b, i| {
            const ev = s.scan.step(b) orelse continue;
            switch (ev) {
                .prompt_start => {
                    // The same prompt drawn again (the line editor redisplays
                    // it after its line was set) is not a new one.
                    s.redrawing = s.at_prompt;
                    s.running = false;
                },
                .line_start => {
                    self.vt.write(bytes[from .. i + 1]);
                    from = i + 1;
                    const at = self.vt.cursorCell();
                    s.line_row = at.row;
                    s.line_col = at.col;
                    if (s.redrawing) {
                        s.redrawing = false;
                        continue;
                    }
                    s.running = false;
                    s.at_prompt = true;
                    s.fresh = true;
                    // A new line editor starts empty — unless keys typed
                    // ahead reach it, which only its report can tell.
                    s.line.clearRetainingCapacity();
                    s.line_cursor = 0;
                    s.pushed.clearRetainingCapacity();
                    s.pushed_cursor = 0;
                    s.line_known = true;
                },
                .command_start => {
                    s.running = true;
                    s.at_prompt = false;
                },
                .command_end => s.running = false,
                .hello => s.line_sync = true,
                .line => |payload| s.takeReport(payload),
            }
        }
        self.vt.write(bytes[from..]);
    }

    /// Tell the shell its command line is `line`, with the cursor at byte
    /// `cursor`: the key its integration binds sets the buffer directly, in
    /// whatever keymap it is in.
    fn sendLine(self: *Term, h: u32, line: []const u8, cursor: usize) void {
        const s = &self.shell;
        s.push_seq += 1;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(weft.allocator);
        buf.print(weft.allocator, "\x1b[7780~{d};{d};", .{ s.push_seq, cursor }) catch return;
        prompt.hexEncode(&buf, weft.allocator, line) catch return;
        buf.append(weft.allocator, 0x07) catch return;
        weft.ptyWrite(h, buf.items);
        s.pushed.resize(weft.allocator, line.len) catch return;
        @memcpy(s.pushed.items, line);
        s.pushed_cursor = cursor;
    }
};

/// What a shell's integration has said, for one terminal.
const Shell = struct {
    scan: prompt.Scanner = .{},
    /// The integration syncs its command line (OSC 7780 hello).
    line_sync: bool = false,
    /// Between OSC 133 C and D.
    running: bool = false,
    /// After OSC 133 B, before C.
    at_prompt: bool = false,
    /// An A arrived at a prompt already declared: its B is a redraw.
    redrawing: bool = false,
    /// What the line editor holds is known: empty at a new prompt, or as
    /// it last reported. A key typed raw at the prompt before it was
    /// declared makes it unknown until the next report.
    line_known: bool = false,
    /// Where the command line starts (the cursor at B), on the screen.
    line_row: u16 = 0,
    line_col: u16 = 0,
    /// The shell's line as it last reported it, and its cursor (bytes).
    line: std.ArrayList(u8) = .empty,
    line_cursor: usize = 0,
    /// A new prompt, not yet declared.
    fresh: bool = false,
    /// The shell changed its line itself (completion, history), not yet
    /// declared: its word replaces the editor's field.
    authoritative: bool = false,
    /// The last line weft set, by sequence, and what it was.
    push_seq: u64 = 0,
    pushed: std.ArrayList(u8) = .empty,
    pushed_cursor: usize = 0,
    /// What was last declared to core.
    declared: ?Declared = null,

    const Declared = struct { flags: u32, row: u32, col: u32 };

    fn deinit(self: *Shell) void {
        self.scan.deinit();
        self.line.deinit(weft.allocator);
        self.pushed.deinit(weft.allocator);
    }

    /// A line report: an older state than weft's last word is a stale echo;
    /// one that differs from what weft set is the shell's own change.
    fn takeReport(self: *Shell, payload: []const u8) void {
        const r = prompt.parseReport(payload) orelse return;
        if (r.seq < self.push_seq) return;
        prompt.hexDecode(&self.line, weft.allocator, r.hex) catch return;
        self.line_cursor = @min(r.cursor, self.line.items.len);
        self.line_known = true;
        if (!std.mem.eql(u8, self.line.items, self.pushed.items) or self.line_cursor != self.pushed_cursor) {
            self.authoritative = true;
            self.pushed.resize(weft.allocator, self.line.items.len) catch return;
            @memcpy(self.pushed.items, self.line.items);
            self.pushed_cursor = self.line_cursor;
        }
    }
};

/// The keys a shell keeps at its prompt whatever the grammar binds them to:
/// completion, and accepting the line.
const claimed = "Tab\nS-Tab\nISO_Left_Tab\nS-ISO_Left_Tab\nReturn\nKP_Enter";
/// What asks the integration to report its line (bash has no redraw hook).
const report_request = "\x1b[7781~";

/// Every terminal, heap-allocated so a `*Term` (and the emulator's
/// userdata pointer into it) survives the list growing.
var terms: std.ArrayList(*Term) = .empty;
var next_id: u32 = 1;
var clock: u64 = 0;

fn orDefault(key: []const u8, default: []const u8) []const u8 {
    const v = weft.config(key);
    return if (v.len > 0) v else default;
}

fn describeExtra() void {
    weft.requestPerm(.proc);
}

fn init() void {
    // `weft://here/proc/terminal.N` is this plugin's: opening one with no
    // entry showing it brings that terminal back while its shell lives.
    _ = weft.designationOpener("proc.terminal", "terminal.open");
}

var command_buf: [1024]u8 = undefined;

/// Where weft's shell integration lives (nix/shell-integration.nix), as the
/// build baked it in; `WEFT_SHELL_INTEGRATION` in the environment overrides
/// it where the shell is started.
const shell_integration = @import("terminal_build").shell_integration;

/// What runs, under `/bin/sh -c`: the `shell` setting — a whole command line
/// (anything with a space) as written, a bare program (`bash`, `/bin/zsh`) or
/// by default `$SHELL`, exec'd. It gets a terminal's environment: TERM names
/// an xterm-compatible terminal with 256 colours and COLORTERM says truecolor,
/// which is what the emulator speaks, and TERM_PROGRAM says weft, for an rc
/// file to test.
///
/// A bare program starts through the shell integration's `launch`, which
/// injects weft's integration into zsh, bash and fish as their own startup
/// files allow (doc/terminal.md §7) — unless `integration` is `off`, or the
/// integration is not where it should be. A whole command line is run as
/// written: what it starts is its own business.
fn invocation() []const u8 {
    // Asked first: `weft.config` answers in one scratch, which the next
    // question overwrites.
    const integrated = !std.mem.eql(u8, weft.config("integration"), "off");
    const v = weft.config("shell");
    const env = "export TERM=xterm-256color COLORTERM=truecolor TERM_PROGRAM=weft; ";
    if (std.mem.indexOfAny(u8, v, " \t") != null)
        return std.fmt.bufPrint(&command_buf, "{s}{s}", .{ env, v }) catch v;
    const program = if (v.len > 0) v else "${SHELL:-/bin/sh}";
    if (!integrated)
        return std.fmt.bufPrint(&command_buf, "{s}exec \"{s}\"", .{ env, program }) catch "exec /bin/sh";
    return std.fmt.bufPrint(&command_buf,
        \\{s}WEFT_SHELL_INTEGRATION="${{WEFT_SHELL_INTEGRATION:-{s}}}"; export WEFT_SHELL_INTEGRATION; if [ -x "$WEFT_SHELL_INTEGRATION/launch" ]; then exec "$WEFT_SHELL_INTEGRATION/launch" "{s}"; fi; exec "{s}"
    , .{ env, shell_integration, program, program }) catch "exec /bin/sh";
}

/// The size a terminal starts at: the room its pane had last frame, or a
/// conventional one before any pane has shown it (the first frame corrects
/// it).
fn size(name: []const u8) struct { cols: u16, rows: u16, cell_w: u16, cell_h: u16 } {
    if (weft.entryExtent(name)) |e| return .{ .cols = @max(e.cols, 2), .rows = @max(e.rows, 1), .cell_w = e.cell_w, .cell_h = e.cell_h };
    return .{ .cols = 80, .rows = 24, .cell_w = 0, .cell_h = 0 };
}

/// A new terminal, its emulator made; no shell yet. Null (said so) when it
/// cannot be.
fn make() ?*Term {
    const t = weft.allocator.create(Term) catch return null;
    t.* = .{ .id = next_id };
    const name = weft.instanceName("terminal", t.id, &t.name_buf) orelse {
        weft.allocator.destroy(t);
        return null;
    };
    t.name_len = name.len;
    const designation = std.fmt.bufPrint(&t.designation_buf, "weft://here/proc/terminal.{d}", .{t.id}) catch unreachable;
    t.designation_len = designation.len;
    const s = size(name);
    const lines = std.fmt.parseInt(usize, orDefault("scrollback", "10000"), 10) catch 10000;
    t.vt.init(s.cols, s.rows, lines) catch {
        weft.allocator.destroy(t);
        weft.echo("terminal: the emulator could not start");
        return null;
    };
    t.vt.resize(s.cols, s.rows, s.cell_w, s.cell_h);
    terms.append(weft.allocator, t) catch {
        t.vt.deinit();
        weft.allocator.destroy(t);
        return null;
    };
    next_id += 1;
    return t;
}

/// Let `t` go: its shell hung up, its emulator freed.
fn drop(t: *Term) void {
    if (t.pty) |h| {
        weft.ptyClose(h);
        t.pty = null;
    }
    retract(t);
    t.vt.deinit();
    t.msg.deinit(weft.allocator);
    t.shell.deinit();
    for (terms.items, 0..) |x, i| if (x == t) {
        _ = terms.orderedRemove(i);
        break;
    };
    weft.allocator.destroy(t);
}

/// The running shell of `t`: the one there is, or a fresh one. Null when
/// none will start (said so).
fn shell(t: *Term) ?u32 {
    if (t.pty) |h| return h;
    const h = weft.ptySpawn(invocation(), t.vt.cols, t.vt.rows) orelse {
        weft.echo("terminal: could not start the shell");
        return null;
    };
    t.vt.resize(t.vt.cols, t.vt.rows, t.vt.cell_w, t.vt.cell_h);
    weft.ptyResize(h, t.vt.cols, t.vt.rows, t.vt.cols *| t.vt.cell_w, t.vt.rows *| t.vt.cell_h);
    t.vt.pty = h;
    t.pty = h;
    publish(t);
    return h;
}

/// The terminal whose entry is named `name`.
fn byName(name: []const u8) ?*Term {
    for (terms.items) |t| if (std.mem.eql(u8, t.name(), name)) return t;
    return null;
}

/// The terminal a designation names (`weft://here/proc/terminal.N`).
fn byDesignation(text: []const u8) ?*Term {
    for (terms.items) |t| if (std.mem.eql(u8, t.designation(), text)) return t;
    return null;
}

/// The terminal the active entry is.
fn active() ?*Term {
    var buf: [256]u8 = undefined;
    return byName(weft.activeBufferName(&buf) orelse return null);
}

/// The terminal used last whose entry is still open.
fn recent() ?*Term {
    var best: ?*Term = null;
    for (terms.items) |t| {
        if (!weft.bufferNamed(t.name())) continue;
        if (best == null or t.used > best.?.used) best = t;
    }
    return best;
}

fn touch(t: *Term) void {
    clock += 1;
    t.used = clock;
}

/// `on_poll`: something of ours is ready — a shell printed or ended, a pane
/// changed size, or an entry closed.
fn onPoll() callconv(.c) void {
    // A terminal whose entry was closed: its shell goes with it.
    var i: usize = terms.items.len;
    while (i > 0) {
        i -= 1;
        const t = terms.items[i];
        if (t.shown and !weft.bufferNamed(t.name())) drop(t);
    }
    for (terms.items) |t| {
        if (t.pty) |h| {
            var buf: [64 * 1024]u8 = undefined;
            var taken: usize = 0;
            while (taken < read_budget) {
                const got = weft.ptyRead(h, &buf) orelse break;
                if (got.len == 0) break;
                t.feed(got);
                taken += got.len;
            }
            if (weft.ptyExited(h)) |code| ended(t, h, code);
        }
        fitToPane(t);
        if (t.shown) t.repaint();
    }
}

/// `t`'s shell is gone: say so on its screen, and let the next key start
/// another.
fn ended(t: *Term, h: u32, code: u8) void {
    var note: [48]u8 = undefined;
    t.vt.write(std.fmt.bufPrint(&note, "\r\n[process exited {d}]\r\n", .{code}) catch "\r\n[process exited]\r\n");
    weft.ptyClose(h);
    t.pty = null;
    t.vt.pty = null;
    retract(t);
    // The next shell says its own: what core last heard stays, to compare.
    const declared = t.shell.declared;
    t.shell.deinit();
    t.shell = .{ .declared = declared };
}

/// Size `t`'s emulator and pty to its pane.
fn fitToPane(t: *Term) void {
    const e = weft.entryExtent(t.name()) orelse return;
    const cols = @max(e.cols, 2);
    const rows = @max(e.rows, 1);
    const vt = &t.vt;
    if (cols == vt.cols and rows == vt.rows and e.cell_w == vt.cell_w and e.cell_h == vt.cell_h) return;
    vt.resize(cols, rows, e.cell_w, e.cell_h);
    if (t.pty) |h| weft.ptyResize(h, cols, rows, cols *| e.cell_w, rows *| e.cell_h);
}

/// Say `t`'s shell is live on the place it starts in. A place moved from is
/// told it holds no shell of `t`'s any more.
fn publish(t: *Term) void {
    var here_buf: [1024]u8 = undefined;
    const place = weft.placeDesignation(&here_buf) orelse return;
    if (t.place_len != 0 and !std.mem.eql(u8, t.place(), place)) retract(t);
    @memcpy(t.place_buf[0..place.len], place);
    t.place_len = place.len;
    setSession(t.designation(), place);
}

/// `t`'s shell is not live any more: its place hears of another terminal
/// live there, or of none.
fn retract(t: *Term) void {
    if (t.place_len == 0) return;
    const place = t.place();
    t.place_len = 0;
    for (terms.items) |other| {
        if (other == t or other.pty == null or !std.mem.eql(u8, other.place(), place)) continue;
        return setSession(other.designation(), place);
    }
    setSession("", place);
}

fn setSession(value: []const u8, place: []const u8) void {
    weft.contextSetAt(session_key, value, place) catch |err| {
        var buf: [96]u8 = undefined;
        weft.echo(std.fmt.bufPrint(&buf, "terminal: could not publish {s}: {t}", .{ session_key, err }) catch session_key);
    };
}

/// Show `t` — its shell started if it has none — in the configured
/// viewport, focused and taking the keys.
fn show(t: *Term) void {
    _ = shell(t) orelse return;
    touch(t);
    // The first publish makes the entry the pane will show.
    t.vt.all_dirty = true;
    t.repaint();
    weft.focusOrCreateBuffer(t.name());
    // The entry is a live resource (doc/model.md §2.1): it designates the
    // shell while one runs, and a jump back to it once the entry is closed
    // is refused rather than answered with a new shell.
    _ = weft.designate(t.designation());
    const viewport = orDefault("viewport", "panel");
    if (!std.mem.eql(u8, viewport, "none")) weft.runStr("viewport.take", viewport);
    weft.declareCapture("terminal.input");
    weft.exitToResting();
}

/// `terminal.open [designation]`: the terminal a designation names, while
/// its shell lives — or, with none named, the one used last, or a new one.
fn open() void {
    if (weft.argStr(0)) |wanted| if (wanted.len > 0) {
        const t = byDesignation(wanted) orelse return weft.setResultStr("terminal: that terminal has exited");
        return show(t);
    };
    const t = recent() orelse make() orelse return;
    show(t);
}

/// `terminal.new`: another terminal, always.
fn new() void {
    const t = make() orelse return;
    show(t);
}

/// `terminal.input`: one key for the program — its spec and the text it
/// committed — for the terminal the active entry is. At the program's
/// prompt (doc/terminal.md §8) core adds the command line as the editor
/// holds it and the caret's byte in it: the shell is told the line first
/// (only when it differs from what it was last told), then gets the key.
/// An empty spec is the line alone: an edit the grammar made.
fn input(spec: []const u8, text: []const u8, line: ?[]const u8, cursor: ?[]const u8) void {
    const t = active() orelse return;
    touch(t);
    // A key to a terminal whose shell has ended starts the next one; the key
    // itself was meant for the old one.
    const h = t.pty orelse {
        _ = shell(t);
        return t.repaint();
    };
    defer t.repaint();
    if (line) |l| {
        const at = std.fmt.parseInt(usize, cursor orelse "0", 10) catch l.len;
        const s = &t.shell;
        if (!std.mem.eql(u8, l, s.pushed.items) or at != s.pushed_cursor) t.sendLine(h, l, @min(at, l.len));
        if (spec.len == 0) return;
        typeKey(t, h, spec, text);
        // A key that ends the line leaves the prompt: what comes next is a
        // command, or a new prompt — never this one redrawn. Otherwise ask
        // for the line back: the key may have changed it (completion).
        if (endsLine(spec)) s.at_prompt = false else if (s.line_sync) weft.ptyWrite(h, report_request);
        return;
    }
    const vt = &t.vt;
    if (std.mem.eql(u8, spec, "S-Prior")) return vt.scroll(-@as(isize, @max(1, vt.rows - 1)));
    if (std.mem.eql(u8, spec, "S-Next")) return vt.scroll(@as(isize, @max(1, vt.rows - 1)));
    if (std.mem.eql(u8, spec, "C-S-V") or std.mem.eql(u8, spec, "C-S-v") or std.mem.eql(u8, spec, "S-Insert")) return paste();
    if (std.mem.startsWith(u8, spec, "wheel-")) return wheel(vt, h, std.mem.eql(u8, spec, "wheel-up"), std.mem.eql(u8, spec, "wheel-down"));
    typeKey(t, h, spec, text);
    // Raw into a line editor weft had not yet declared: what it holds is
    // unknown now, so no command line is declared until it says — asked
    // for, unless the key ended the line (what follows may read the ask).
    const s = &t.shell;
    if (s.line_sync and s.at_prompt and !s.running) {
        s.line_known = false;
        if (!endsLine(spec)) weft.ptyWrite(h, report_request);
    }
}

/// Type key `spec` (committing `text`) into `t`'s shell, as its encoder
/// spells it in the modes the child set.
fn typeKey(t: *Term, h: u32, spec: []const u8, text: []const u8) void {
    var text_buf: [8]u8 = undefined;
    const k = keys.parse(spec, text, &text_buf) orelse return; // a click, a bare modifier
    var out: [128]u8 = undefined;
    const bytes = t.vt.encodeKey(k, &out);
    if (bytes.len == 0) return;
    t.vt.scrollToBottom();
    weft.ptyWrite(h, bytes);
}

/// Whether `spec` ends the command line — accepts it, interrupts it, ends
/// input — after which the shell's input is no longer its line editor's.
fn endsLine(spec: []const u8) bool {
    for ([_][]const u8{ "Return", "KP_Enter", "C-c", "C-d", "C-z", "C-j", "C-m" }) |k| {
        if (std.mem.eql(u8, spec, k)) return true;
    }
    return false;
}

/// A wheel notch: the child's, as a wheel report, when it asked for the
/// mouse; arrow keys on the alternate screen (a pager scrolls, as in any
/// terminal); otherwise the scrollback.
fn wheel(vt: *Vt, h: u32, up: bool, down: bool) void {
    if (!up and !down) return; // sideways
    if (vt.mouseTracking()) {
        const at = vt.cursorCell();
        var out: [64]u8 = undefined;
        const bytes = vt.encodeWheel(up, at.col, at.row, &out);
        if (bytes.len > 0) weft.ptyWrite(h, bytes);
        return;
    }
    if (vt.altScreen()) {
        var key_buf: [8]u8 = undefined;
        const k = keys.parse(if (up) "Up" else "Down", "", &key_buf).?;
        var out: [16]u8 = undefined;
        const bytes = vt.encodeKey(k, &out);
        for (0..3) |_| weft.ptyWrite(h, bytes);
        return;
    }
    vt.scroll(if (up) -3 else 3);
}

/// `terminal.paste`: the clipboard, typed into the active terminal's shell —
/// control bytes that could run a command stripped, and bracketed when the
/// child asked. Needs the `clipboard` grant (config:
/// `weft.grant("terminal", "clipboard")`).
fn paste() void {
    const t = active() orelse return;
    const h = t.pty orelse return;
    const clip = weft.clipboardGet() orelse return;
    if (clip.len == 0) return;
    const text = weft.allocator.dupe(u8, clip) catch return;
    defer weft.allocator.free(text);
    const out = weft.allocator.alloc(u8, text.len + 16) catch return;
    defer weft.allocator.free(out);
    const bytes = t.vt.encodePaste(text, out);
    t.vt.scrollToBottom();
    weft.ptyWrite(h, bytes);
    t.repaint();
}

/// `terminal.quit`: stop the active terminal's shell; the screen stays with
/// what it printed.
fn quit() void {
    const t = active() orelse return;
    const h = t.pty orelse return;
    ended(t, h, 0);
    t.repaint();
}

const cmds = [_]weft.CommandEntry{
    .{ .name = "terminal.open", .arity = .whole, .call = open, .params = "[designation]", .summary = "Show the terminal used last — starting one when there is none — taking every key.", .label = "Terminal", .menu = "Terminal", .group = "new", .order = 0, .icon = "terminal" },
    .{ .name = "terminal.new", .arity = .whole, .call = new, .summary = "Start another terminal, taking every key.", .label = "New Terminal", .menu = "Terminal", .group = "new", .order = 1, .icon = "plus" },
    .{ .name = "terminal.input", .arity = .whole, .call = weft.thunk(input), .params = "key text [line] [cursor]", .summary = "Send one key to the terminal's shell — at its prompt after the command line as the editor holds it.", .internal = true },
    .{ .name = "terminal.paste", .arity = .whole, .call = paste, .summary = "Paste the clipboard into the terminal's shell.", .label = "Paste into Terminal", .menu = "Terminal", .group = "terminal", .order = 2, .icon = "clipboard-paste" },
    .{ .name = "terminal.quit", .arity = .whole, .call = quit, .summary = "Stop the terminal's shell.", .label = "Stop Terminal", .menu = "Terminal", .group = "terminal", .order = 1, .icon = "stop" },
};

comptime {
    weft.plugin(&cmds, .{ .describe = describeExtra, .init = init }).exportAll();
    weft.exportCallback("on_poll", &onPoll);
}
