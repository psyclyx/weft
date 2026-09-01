//! `exec` — run a command as an ARGV and get back what it said.
//!
//! What this replaces, and why it is a different thing rather than a nicer
//! spelling of the same thing. The fill doors (`procToBuffer`, `procSpool`)
//! take a SHELL STRING and a buffer name. Everything a plugin actually wants
//! from a subprocess had to be reconstructed around that:
//!
//!   - **The exit status** did not cross at all, so git makes each command
//!     print its own — `printf '\036\036C%d\n' "$s"` — and scans the sentinel
//!     back out of the output stream, splicing it away before parsing the rest.
//!   - **stderr** did not cross either, so it gets folded into stdout with
//!     `2>&1` and is then indistinguishable from the output.
//!   - **Quoting** is the plugin's problem: seventy-two `bufPrint` sites in the
//!     tree build command lines, and every interpolated path is wrapped in
//!     `'{s}'` and hopes. A path containing an apostrophe is a broken command
//!     at best.
//!   - **The output** arrives as a DOCUMENT. `git` reads it straight back out
//!     with `slice` in 64 KiB windows into a fixed 256 KiB array, and truncates
//!     past that. The buffer was never wanted; it was the only transport.
//!   - **Sequencing** had to be fused into one shell line (`mutation && gather`)
//!     to avoid an async read/write race, which is why git has four
//!     near-identical `gatherAfter*` wrappers.
//!
//! `exec` crosses the three facts a command produces. There is no shell, so
//! there is no quoting layer to get wrong; there is no buffer, so there is no
//! document to read the answer out of; and the callback runs where a plugin is
//! allowed to speak, so a background result no longer has to re-enter through a
//! self-registered command to say a sentence.
//!
//! It grants nothing new. The same `.proc` + `.timer` gate, the same place, and
//! the same host-named spool for the one thing a child needs on disk: a bare
//! `{}` ARGUMENT is replaced with a temp the host names, fills, and deletes —
//! so `git apply {}` and `git commit -F {}` still need no `fs_write`.

const std = @import("std");
const weft = @import("root.zig");
const e = @import("externs.zig");

/// What to run.
pub const Spec = struct {
    /// The program and its arguments. No shell: an argument containing spaces,
    /// quotes, or newlines is one argument, and nothing interprets it.
    argv: []const []const u8,
    /// Bytes the child needs as a FILE. The host writes them to a temp it
    /// names, substitutes that path for a bare `{}` argument, and deletes it —
    /// on success, on failure, and on a command that never ran.
    input: ?[]const u8 = null,
    /// A buffer of this plugin's whose PLACE the child runs in. Empty means the
    /// entry the dispatch is in, which is what every other proc door does.
    ///
    /// This is NOT a working-directory door. A buffer's place is the host's to
    /// assign; naming one can only reach somewhere the host already put this
    /// plugin. It exists so a projection of a SECOND repository can act on that
    /// repository without prefixing every command with its own `cd` guard.
    at: []const u8 = "",
};

/// A finished command.
pub const Done = struct {
    /// The exit code, or -1 for a child that died by signal or never ran.
    status: i32,

    pub fn ok(self: Done) bool {
        return self.status == 0;
    }

    /// How many bytes the command wrote to `which` (0 stdout, 1 stderr).
    pub fn len(self: Done, which: Stream) usize {
        _ = self;
        const n = e.wl_exec_read(@intFromEnum(which), 0, 0, 0);
        return if (n < 0) 0 else @intCast(n);
    }

    /// A window on the output, from `offset`, into a buffer you own. Returns
    /// what was written — short of `out.len` means you have it all.
    pub fn read(self: Done, which: Stream, offset: usize, out: []u8) []const u8 {
        const total = self.len(which);
        if (offset >= total) return out[0..0];
        const want = @min(out.len, total - offset);
        const n = e.wl_exec_read(@intFromEnum(which), @intCast(offset), p(out.ptr), @intCast(want));
        return if (n < 0) out[0..0] else out[0..@intCast(n)];
    }

    /// The whole stream, allocated. Unbounded by anything but memory — there is
    /// no 256 KiB ceiling here, which is the other half of why a large `git
    /// status` stops being wrong.
    pub fn dupe(self: Done, gpa: std.mem.Allocator, which: Stream) ![]u8 {
        const total = self.len(which);
        const buf = try gpa.alloc(u8, total);
        errdefer gpa.free(buf);
        var got: usize = 0;
        while (got < total) {
            const n = self.read(which, got, buf[got..]).len;
            if (n == 0) break;
            got += n;
        }
        return gpa.realloc(buf, got) catch buf[0..got];
    }

    /// The first non-blank line of a stream, into a caller buffer — what an
    /// echoed refusal wants, and the shape every plugin was hand-rolling.
    pub fn firstLine(self: Done, which: Stream, out: []u8) []const u8 {
        const got = self.read(which, 0, out);
        var i: usize = 0;
        while (i < got.len) {
            var end = i;
            while (end < got.len and got[end] != '\n') end += 1;
            const line = std.mem.trim(u8, got[i..end], " \t\r");
            if (line.len > 0) return line;
            i = end + 1;
        }
        return got[0..0];
    }
};

pub const Stream = enum(u32) { out = 0, err = 1 };

fn p(x: anytype) u32 {
    return @intCast(@intFromPtr(x));
}

// ── The pending table: a continuation, not a token to pack ────────────
// The old async shape handed the guest a `u32` it had to give meaning to, and
// every plugin gave it the same meaning by hand: git packs `(session << 8) |
// kind` and unpacks it in a demux switch far from the code that asked. The
// token still exists — it is how the host addresses a delivery — but it is the
// SDK's now, and what a caller supplies is the function to run.

const Pending = struct {
    thunk: *const fn (Done, ?*anyopaque) void,
    ctx: ?*anyopaque = null,
    release: ?*const fn (std.mem.Allocator, ?*anyopaque) void = null,
};

var pending: std.ArrayList(?Pending) = .empty;

/// Run `spec`, calling `on_done` when it finishes. False means the host refused
/// to start it — no permission, no task pool, or an argv it would not accept —
/// and `on_done` will not run.
pub fn exec(spec: Spec, on_done: *const fn (Done) void) bool {
    const Shim = struct {
        fn call(done: Done, ctx: ?*anyopaque) void {
            const f: *const fn (Done) void = @ptrCast(@alignCast(ctx.?));
            f(done);
        }
    };
    return submit(spec, .{ .thunk = Shim.call, .ctx = @ptrCast(@constCast(on_done)) });
}

/// `exec`, carrying a value of your own through to the callback. The value is
/// COPIED into the pending slot and released after delivery, so a caller never
/// packs context into a token and never keeps a global "what was I doing".
pub fn execWith(
    comptime Ctx: type,
    ctx: Ctx,
    spec: Spec,
    comptime on_done: fn (Done, Ctx) void,
) bool {
    const Shim = struct {
        fn call(done: Done, raw: ?*anyopaque) void {
            const held: *Ctx = @ptrCast(@alignCast(raw.?));
            on_done(done, held.*);
        }
        fn release(gpa: std.mem.Allocator, raw: ?*anyopaque) void {
            const held: *Ctx = @ptrCast(@alignCast(raw.?));
            gpa.destroy(held);
        }
    };
    const held = weft.allocator.create(Ctx) catch return false;
    held.* = ctx;
    if (!submit(spec, .{ .thunk = Shim.call, .ctx = held, .release = Shim.release })) {
        weft.allocator.destroy(held);
        return false;
    }
    return true;
}

fn submit(spec: Spec, cont: Pending) bool {
    if (spec.argv.len == 0) return false;
    const gpa = weft.allocator;
    // The argv block: arguments back to back, NUL-separated. Built here rather
    // than at the door because the guest owns its own memory and the host must
    // not have to walk a pointer array in it.
    var block: std.ArrayList(u8) = .empty;
    defer block.deinit(gpa);
    for (spec.argv, 0..) |arg, i| {
        if (i > 0) block.append(gpa, 0) catch return false;
        block.appendSlice(gpa, arg) catch return false;
    }
    const token = claim(cont) orelse return false;
    const input = spec.input orelse "";
    const accepted = e.wl_exec(
        p(block.items.ptr),
        @intCast(block.items.len),
        @intCast(spec.argv.len),
        p(input.ptr),
        @intCast(input.len),
        p(spec.at.ptr),
        @intCast(spec.at.len),
        token,
    ) == 0;
    if (!accepted) release(token);
    return accepted;
}

/// The lowest free slot, or a new one. The slot index IS the token: the host
/// echoes it back and nothing else ever reads it.
fn claim(cont: Pending) ?u32 {
    for (pending.items, 0..) |slot, i| {
        if (slot == null) {
            pending.items[i] = cont;
            return @intCast(i);
        }
    }
    pending.append(weft.allocator, cont) catch return null;
    return @intCast(pending.items.len - 1);
}

fn release(token: u32) void {
    if (token >= pending.items.len) return;
    if (pending.items[token]) |slot| {
        if (slot.release) |f| f(weft.allocator, slot.ctx);
    }
    pending.items[token] = null;
}

/// The host's delivery, routed to the continuation that asked for it. Exported
/// as `on_exec` by `weft.plugin`, so a plugin never writes an async demux.
pub fn deliver(token: u32) void {
    if (token >= pending.items.len) return; // a token we never issued
    const slot = pending.items[token] orelse return;
    // Freed BEFORE the callback, so a continuation that starts another exec can
    // reuse this slot and cannot be re-entered into its own.
    pending.items[token] = null;
    defer if (slot.release) |f| f(weft.allocator, slot.ctx);
    slot.thunk(.{ .status = e.wl_exec_status() }, slot.ctx);
}
