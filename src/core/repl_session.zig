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

pub const Session = struct {
    gpa: Allocator,
    ctx: *command.Context,
    plugin: []u8, // authors the comint output
    buf: []u8, // the comint buffer name (found-or-created)
    entry: ?Buffers.Ref = null, // the sink, captured by identity on first delivery
    io_threaded: std.Io.Threaded, // frame-thread io (stdin writes)
    child: std.process.Child,
    out_mutex: task.Mutex = .{},
    out_buf: std.ArrayList(u8) = .empty,
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
        s.reader = try pool.spawnResident(readLoop, .{s});
        return s;
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
                    s.out_buf.appendSlice(s.gpa, chunk) catch {};
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
    pub fn deinit(s: *Session) void {
        const gpa = s.gpa;
        if (s.child.id) |id| std.posix.kill(id, std.posix.SIG.KILL) catch {};
        while (s.reader.poll() == null) std.atomic.spinLoopHint(); // join the reader
        _ = s.child.wait(s.io_threaded.io()) catch {};
        s.out_buf.deinit(gpa);
        s.io_threaded.deinit();
        gpa.free(s.plugin);
        gpa.free(s.buf);
        gpa.destroy(s);
    }
};
