//! repl_session — a persistent interactive subprocess behind a comint buffer
//! (design §6.3). Unlike one-shot `proc`, the child stays alive: `send` writes a
//! line to its stdin, and a reader task streams its stdout/stderr incrementally
//! into a mutex-guarded accumulator that the frame thread drains into the
//! buffer (authored as the owning plugin's peer). Concurrency is standard and
//! bounded: one blocking reader task per session; `deinit` kills the child so
//! the reader hits EOF, then JOINS it before freeing — never a use-after-free.

const std = @import("std");
const Allocator = std.mem.Allocator;
const command = @import("command.zig");
const Buffers = @import("Buffers.zig");
const task = @import("task.zig");

/// The terminal-control filter's state between chunks.
pub const Controls = enum { text, escape, csi, osc, osc_escape };

/// Append `in` to `out` without its terminal controls. The buffer a session
/// streams into is plain text with no terminal behind it, so an interactive
/// shell's colors, cursor moves and window titles would land as literal
/// bytes: CSI (`ESC [ … final`) and OSC (`ESC ] … BEL | ESC \`) sequences,
/// other two-byte escapes, carriage returns and bells are dropped. Newlines,
/// tabs and printable text pass. Returns the state to resume from, since a
/// sequence may straddle two reads.
pub fn stripControls(gpa: Allocator, from: Controls, in: []const u8, out: *std.ArrayList(u8)) !Controls {
    var state = from;
    for (in) |b| {
        switch (state) {
            .text => switch (b) {
                0x1b => state = .escape,
                '\r', 0x07, 0x08 => {},
                else => try out.append(gpa, b),
            },
            .escape => state = switch (b) {
                '[' => .csi,
                ']' => .osc,
                else => .text, // a two-byte escape: drop both
            },
            .csi => if (b >= 0x40 and b <= 0x7e) {
                state = .text;
            },
            .osc => switch (b) {
                0x07 => state = .text,
                0x1b => state = .osc_escape,
                else => {},
            },
            .osc_escape => state = if (b == '\\') .text else .osc,
        }
    }
    return state;
}

test "repl_session: terminal controls are stripped, even split across reads" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var st = try stripControls(gpa, .text, "\x1b[1;32mgreen\x1b[0m\r\n\x1b]0;title\x07$ ", &out);
    try std.testing.expectEqualStrings("green\n$ ", out.items);
    try std.testing.expectEqual(Controls.text, st);
    out.clearRetainingCapacity();
    st = try stripControls(gpa, st, "a\x1b[3", &out);
    try std.testing.expectEqual(Controls.csi, st);
    st = try stripControls(gpa, st, "1mb\x1b]2;t\x1b", &out);
    st = try stripControls(gpa, st, "\\c\x1b=d", &out);
    try std.testing.expectEqualStrings("abcd", out.items);
    try std.testing.expectEqual(Controls.text, st);
}

pub const Session = struct {
    gpa: Allocator,
    ctx: *command.Context,
    plugin: []u8, // authors the comint output
    buf: []u8, // the comint buffer name (found-or-created)
    entry: ?Buffers.Ref = null, // the sink, captured by identity on first delivery
    io_threaded: std.Io.Threaded, // frame-thread io (stdin writes)
    /// The child's environment, retained because `io_threaded` uses it for the
    /// child's whole life -- a merged per-place environment cannot be a borrow
    /// that dies with the spawning call.
    environ: std.process.Environ,
    /// Whether `environ` is OURS to free. False for the borrowed process
    /// environment; true once `adoptEnviron` takes a merged one over.
    environ_owned: bool = false,
    child: std.process.Child,
    out_mutex: task.Mutex = .{},
    out_buf: std.ArrayList(u8) = .empty,
    /// Where the terminal-control filter stands between two chunks: an
    /// escape sequence may be split across reads.
    controls: Controls = .text,
    reader: task.Handle(void),

    /// Spawn `argv` as a persistent child with piped stdio and start its reader.
    pub fn start(
        gpa: Allocator,
        pool: *task.Pool,
        ctx: *command.Context,
        plugin: []const u8,
        buf: []const u8,
        argv: []const []const u8,
        environ: std.process.Environ,
        cwd: ?[]const u8,
    ) !*Session {
        const s = try gpa.create(Session);
        errdefer gpa.destroy(s);
        s.* = .{
            .gpa = gpa,
            .ctx = ctx,
            .plugin = try gpa.dupe(u8, plugin),
            .buf = try gpa.dupe(u8, buf),
            .io_threaded = .init(gpa, .{ .environ = environ }),
            .environ = environ,
            .child = undefined,
            .reader = undefined,
        };
        errdefer {
            gpa.free(s.plugin);
            gpa.free(s.buf);
            s.io_threaded.deinit();
        }
        s.child = std.process.spawn(s.io_threaded.io(), .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .cwd = if (cwd) |p| .{ .path = p } else .inherit,
        }) catch return error.ProcessSpawnFailed;
        s.reader = try pool.spawnResident(
            .{ .name = "repl_session reader", .stop = .of(s, killChild) },
            readLoop,
            .{s},
        );
        return s;
    }

    /// Shutdown's reach into this reader: killing the child is what makes its
    /// blocking read return, so a pool torn down while a REPL is still live
    /// unblocks the reader instead of freeing state it still holds.
    fn killChild(s: *Session) void {
        if (s.child.id) |id| std.posix.kill(id, std.posix.SIG.KILL) catch {};
    }

    /// Reader task: block on the child's stdout/stderr, appending each chunk to
    /// the accumulator until EOF (the child exited or was killed).
    fn readLoop(s: *Session) void {
        var threaded: std.Io.Threaded = .init(s.gpa, .{});
        defer threaded.deinit();
        const io = threaded.io();
        var mr_buf: std.Io.File.MultiReader.Buffer(2) = undefined;
        var mr: std.Io.File.MultiReader = undefined;
        mr.init(s.gpa, io, mr_buf.toStreams(), &.{ s.child.stdout.?, s.child.stderr.? });
        defer mr.deinit();
        while (mr.fill(256, .none)) |_| {
            inline for (.{ 0, 1 }) |idx| {
                const r = mr.reader(idx);
                const chunk = r.buffered();
                if (chunk.len > 0) {
                    s.out_mutex.lock();
                    s.controls = stripControls(s.gpa, s.controls, chunk, &s.out_buf) catch s.controls;
                    s.out_mutex.unlock();
                    r.toss(chunk.len);
                }
            }
        } else |_| {} // EndOfStream / read failure — the child is gone.
    }

    /// Frame thread: move any streamed output into the comint buffer (append,
    /// authored as the plugin peer). Returns true if it wrote something.
    pub fn drain(s: *Session) bool {
        s.out_mutex.lock();
        defer s.out_mutex.unlock();
        if (s.out_buf.items.len == 0) return false;
        const bufs = s.ctx.buffers;
        // Generation-checked identity, captured on first delivery — never a name
        // scan per tick, so a rename or a second same-named buffer cannot
        // misroute the stream. A closed sink is re-created once, under the name.
        const b = bufs.resolveSink(s.gpa, &s.entry, s.buf) orelse return false;
        const ed = b.textEditor() orelse return false;
        const doc = &ed.doc;
        const end = ed.text().byteLen();
        command.renderInto(s.gpa, doc, .plugin, s.plugin, &.{.{ .range = .{ .start = end, .end = end }, .bytes = s.out_buf.items }}) catch {
            s.out_buf.clearRetainingCapacity();
            return false;
        };
        s.out_buf.clearRetainingCapacity();
        return true;
    }

    /// Frame thread: write `line` (a newline is appended if absent) to stdin.
    pub fn send(s: *Session, line: []const u8) void {
        const stdin = s.child.stdin orelse return;
        const io = s.io_threaded.io();
        stdin.writeStreamingAll(io, line) catch return;
        if (line.len == 0 or line[line.len - 1] != '\n') stdin.writeStreamingAll(io, "\n") catch {};
    }

    /// Kill the child, JOIN the reader (so it can't touch freed state), reap,
    /// and free. The single owner of teardown.
    /// Take ownership of the environment this session was started with (see
    /// `proc_stream.ProcStream.adoptEnviron` for why a merged one cannot be a
    /// borrow). Called only after a SUCCESSFUL `start`.
    pub fn adoptEnviron(s: *Session) void {
        s.environ_owned = true;
    }

    pub fn deinit(s: *Session) void {
        const gpa = s.gpa;
        killChild(s);
        while (!s.reader.residentExited()) std.Thread.yield() catch {}; // join the reader
        _ = s.reader.poll();
        _ = s.child.wait(s.io_threaded.io()) catch {};
        s.out_buf.deinit(gpa);
        s.io_threaded.deinit();
        if (s.environ_owned) s.environ.block.deinit(gpa);
        gpa.free(s.plugin);
        gpa.free(s.buf);
        gpa.destroy(s);
    }
};
