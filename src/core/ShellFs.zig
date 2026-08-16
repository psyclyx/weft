//! ShellFs — the coreutils-tier remote filesystem: one persistent shell
//! (spawned by any command — ssh is the default spawner, not a coupling;
//! adb/serial/container-exec fit the same seam) driving ranged reads,
//! guarded atomic writes, listing, and content-hash change detection.
//! This is tramp's mechanism as a first-class provider.
//!
//! Every call may block (a full round-trip to the shell) — never on the
//! hot path; callers run these on task-pool workers. One in-flight
//! command at a time (mutex); the shell is a serial channel.
//!
//! Concurrency contract (doc/sessions-design.md rev 4): `hashToken`
//! detects external writers; `writeGuarded` is a remote test-and-set —
//! it replaces the file only if the target still hashes to the state the
//! caller's merge was based on, else `error.Stale` (merge the new disk
//! state as a backing-peer commit and retry). The check-then-rename race
//! window is vim's own; `flock` would tighten it where present (not
//! done in v1 — documented, not promised).

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const task = @import("task.zig");

const ShellFs = @This();

gpa: Allocator,
threaded: std.Io.Threaded,
child: std.process.Child,
mutex: task.Mutex = .{},
seq: u64 = 0,
/// The hash command detected on the remote (sha256sum → cksum). Hash
/// values are opaque tokens: compared for equality, never interpreted.
hash_cmd: []const u8 = "",

pub const Error = error{
    /// Transport or protocol failure — the shell died or spoke garbage.
    /// The ShellFs is unusable; spawn a new one.
    Shell,
    /// The remote command failed (missing file, permissions, …).
    Failed,
    OutOfMemory,
};

pub const WriteError = Error || error{
    /// The target no longer matches the expected content token — an
    /// external writer got there first. Merge, then retry.
    Stale,
};

pub const Kind = enum { file, dir, link, other };

pub const Entry = struct {
    name: []const u8,
    kind: Kind,
    size: u64,
};

/// Directory listing: entries + the arena they borrow from.
pub const Listing = struct {
    entries: []Entry,
    bytes: []u8,

    pub fn deinit(self: *Listing, gpa: Allocator) void {
        gpa.free(self.entries);
        gpa.free(self.bytes);
        self.* = undefined;
    }
};

/// Spawn the shell. `argv` is the spawner command — `{"ssh", host,
/// "sh"}` for the default tier, `{"/bin/sh"}` for local/tests. The
/// remote end must be a POSIX sh with coreutils (base64 required).
pub fn spawn(gpa: Allocator, argv: []const []const u8, environ: std.process.Environ) Error!ShellFs {
    var self: ShellFs = .{
        .gpa = gpa,
        .threaded = .init(gpa, .{ .environ = environ }),
        .child = undefined,
    };
    const io = self.threaded.io();
    self.child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return error.Shell;
    errdefer self.child.kill(io);
    // Deterministic parsing locale; detect the hash tool once.
    const probe = try self.run(gpa, "LC_ALL=C; export LC_ALL; command -v sha256sum >/dev/null 2>&1 && echo sha256sum || echo cksum");
    defer gpa.free(probe.out);
    if (probe.status != 0) return error.Shell;
    const tool = std.mem.trim(u8, probe.out, " \t\r\n");
    self.hash_cmd = if (std.mem.eql(u8, tool, "sha256sum")) "sha256sum" else "cksum";
    return self;
}

pub fn deinit(self: *ShellFs) void {
    const io = self.threaded.io();
    if (self.child.stdin) |stdin| stdin.writeStreamingAll(io, "exit\n") catch {};
    self.child.kill(io);
    self.threaded.deinit();
    self.* = undefined;
}

// ── Protocol ────────────────────────────────────────────────────────
// One command per round-trip; completion and exit status are delimited
// by a sentinel line the command's own output cannot contain (ASCII RS
// prefix + per-call sequence number).

const Reply = struct { out: []u8, status: u8 };

/// Run one shell command, capturing stdout until the sentinel. The
/// command must not read stdin (the channel is the command stream).
fn run(self: *ShellFs, gpa: Allocator, cmd: []const u8) Error!Reply {
    self.mutex.lock();
    defer self.mutex.unlock();
    const io = self.threaded.io();
    self.seq += 1;

    const script = try std.fmt.allocPrint(
        gpa,
        "{s}\nprintf '\\n\\036weft {d} %d\\n' \"$?\"\n",
        .{ cmd, self.seq },
    );
    defer gpa.free(script);
    const stdin = self.child.stdin orelse return error.Shell;
    stdin.writeStreamingAll(io, script) catch return error.Shell;

    const stdout = self.child.stdout orelse return error.Shell;
    var acc: std.ArrayList(u8) = .empty;
    errdefer acc.deinit(gpa);
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\n\x1eweft {d} ", .{self.seq}) catch unreachable;
    var buf: [16384]u8 = undefined;
    while (true) {
        if (std.mem.indexOf(u8, acc.items, needle)) |at| {
            // Sentinel present; the status ends at the following newline.
            const rest = acc.items[at + needle.len ..];
            const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse {
                // Status digits not complete yet; read more.
                const n = stdout.readStreaming(io, &.{&buf}) catch return error.Shell;
                if (n == 0) return error.Shell;
                try acc.appendSlice(gpa, buf[0..n]);
                continue;
            };
            const status = std.fmt.parseInt(u8, std.mem.trim(u8, rest[0..nl], " \r"), 10) catch return error.Shell;
            acc.items.len = at; // drop sentinel; keep exact output bytes
            return .{ .out = try acc.toOwnedSlice(gpa), .status = status };
        }
        const n = stdout.readStreaming(io, &.{&buf}) catch return error.Shell;
        if (n == 0) return error.Shell; // shell exited under us
        try acc.appendSlice(gpa, buf[0..n]);
    }
}

/// Heredoc upload of base64 text into `qtmp` (already quoted). Lines
/// wrapped — some base64 -d implementations dislike unbounded lines.
fn appendUpload(gpa: Allocator, script: *std.ArrayList(u8), qtmp: []const u8, b64: []const u8) Allocator.Error!void {
    const head = try std.fmt.allocPrint(gpa, "base64 -d > {s} <<'WEFT_B64'\n", .{qtmp});
    defer gpa.free(head);
    try script.appendSlice(gpa, head);
    var i: usize = 0;
    while (i < b64.len) : (i += 4096) {
        try script.appendSlice(gpa, b64[i..@min(b64.len, i + 4096)]);
        try script.append(gpa, '\n');
    }
    try script.appendSlice(gpa, "WEFT_B64\n");
}

/// Single-quote for sh: safe for every byte except NUL.
fn quote(gpa: Allocator, path: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, '\'');
    for (path) |b| {
        if (b == '\'') {
            try out.appendSlice(gpa, "'\\''");
        } else {
            try out.append(gpa, b);
        }
    }
    try out.append(gpa, '\'');
    return out.toOwnedSlice(gpa);
}

fn decodeBase64(gpa: Allocator, text: []const u8) Error![]u8 {
    // base64 output wraps; strip all whitespace first.
    var compact: std.ArrayList(u8) = .empty;
    defer compact.deinit(gpa);
    for (text) |b| {
        if (!std.ascii.isWhitespace(b)) try compact.append(gpa, b);
    }
    const dec = std.base64.standard.Decoder;
    const len = dec.calcSizeForSlice(compact.items) catch return error.Shell;
    const out = try gpa.alloc(u8, len);
    errdefer gpa.free(out);
    dec.decode(out, compact.items) catch return error.Shell;
    return out;
}

// ── Operations ──────────────────────────────────────────────────────

/// Whole-file read. Caller owns.
pub fn readAll(self: *ShellFs, gpa: Allocator, path: []const u8) Error![]u8 {
    const q = try quote(gpa, path);
    defer gpa.free(q);
    const cmd = try std.fmt.allocPrint(gpa, "base64 < {s}", .{q});
    defer gpa.free(cmd);
    const r = try self.run(gpa, cmd);
    defer gpa.free(r.out);
    if (r.status != 0) return error.Failed;
    return decodeBase64(gpa, r.out);
}

/// Ranged read (`[offset, offset+len)`), the partial-checkout feed.
/// Short reads past EOF return the available bytes.
pub fn readRange(self: *ShellFs, gpa: Allocator, path: []const u8, offset: u64, len: u64) Error![]u8 {
    const q = try quote(gpa, path);
    defer gpa.free(q);
    const cmd = try std.fmt.allocPrint(
        gpa,
        "{{ tail -c +{d} | head -c {d}; }} < {s} | base64",
        .{ offset + 1, len, q },
    );
    defer gpa.free(cmd);
    const r = try self.run(gpa, cmd);
    defer gpa.free(r.out);
    if (r.status != 0) return error.Failed;
    return decodeBase64(gpa, r.out);
}

/// File size in bytes.
pub fn size(self: *ShellFs, gpa: Allocator, path: []const u8) Error!u64 {
    const q = try quote(gpa, path);
    defer gpa.free(q);
    const cmd = try std.fmt.allocPrint(gpa, "wc -c < {s}", .{q});
    defer gpa.free(cmd);
    const r = try self.run(gpa, cmd);
    defer gpa.free(r.out);
    if (r.status != 0) return error.Failed;
    return std.fmt.parseInt(u64, std.mem.trim(u8, r.out, " \t\r\n"), 10) catch error.Shell;
}

/// Content token for change detection: opaque, equality-only (the
/// detected hash tool's output). Caller owns.
pub fn hashToken(self: *ShellFs, gpa: Allocator, path: []const u8) Error![]u8 {
    const q = try quote(gpa, path);
    defer gpa.free(q);
    const cmd = try std.fmt.allocPrint(gpa, "{s} < {s}", .{ self.hash_cmd, q });
    defer gpa.free(cmd);
    const r = try self.run(gpa, cmd);
    defer gpa.free(r.out);
    if (r.status != 0) return error.Failed;
    // Normalize exactly like the guard script's `tr -d ' \t-'` (cksum
    // tokens have internal spaces; sha256sum appends "  -").
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (std.mem.trim(u8, r.out, "\r\n")) |b| {
        if (b != ' ' and b != '\t' and b != '-' and b != '\n' and b != '\r') try out.append(gpa, b);
    }
    return out.toOwnedSlice(gpa);
}

/// Guarded atomic write: upload beside the target, then test-and-set —
/// rename only if the target still hashes to `expected` (null = the
/// file must not exist yet). `error.Stale` means an external writer got
/// there first: merge the new disk state, retry. Returns the written
/// content's token (hashed from the uploaded temp, so it is exactly our
/// bytes). Caller owns.
pub fn writeGuarded(
    self: *ShellFs,
    gpa: Allocator,
    path: []const u8,
    bytes: []const u8,
    expected: ?[]const u8,
) WriteError![]u8 {
    const q = try quote(gpa, path);
    defer gpa.free(q);
    const tmp = try std.fmt.allocPrint(gpa, "{s}.weft-tmp", .{path});
    defer gpa.free(tmp);
    const qtmp = try quote(gpa, tmp);
    defer gpa.free(qtmp);

    const b64_len = std.base64.standard.Encoder.calcSize(bytes.len);
    const b64 = try gpa.alloc(u8, b64_len);
    defer gpa.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, bytes);

    var script: std.ArrayList(u8) = .empty;
    defer script.deinit(gpa);
    try appendUpload(gpa, &script, qtmp, b64);
    const guard = if (expected) |token|
        try std.fmt.allocPrint(
            gpa,
            "tok=$({s} < {s} | tr -d ' \\t-')\nif [ \"$({s} < {s} 2>/dev/null | tr -d ' \\t-')\" = \"{s}\" ]; then mv {s} {s} && echo \"weft-ok $tok\"; else rm -f {s}; echo weft-stale; false; fi",
            .{ self.hash_cmd, qtmp, self.hash_cmd, q, token, qtmp, q, qtmp },
        )
    else
        try std.fmt.allocPrint(
            gpa,
            "tok=$({s} < {s} | tr -d ' \\t-')\nif [ -e {s} ]; then rm -f {s}; echo weft-stale; false; else mv {s} {s} && echo \"weft-ok $tok\"; fi",
            .{ self.hash_cmd, qtmp, q, qtmp, qtmp, q },
        );
    defer gpa.free(guard);
    try script.appendSlice(gpa, guard);
    const r = try self.run(gpa, script.items);
    defer gpa.free(r.out);
    if (r.status == 0) return parseOkToken(gpa, r.out);
    if (std.mem.indexOf(u8, r.out, "weft-stale") != null) return error.Stale;
    return error.Failed;
}

/// Unguarded write (save-as onto a path the caller owns the policy
/// for). Returns the written content's token; caller owns.
pub fn writeAtomic(self: *ShellFs, gpa: Allocator, path: []const u8, bytes: []const u8) WriteError![]u8 {
    const q = try quote(gpa, path);
    defer gpa.free(q);
    const tmp = try std.fmt.allocPrint(gpa, "{s}.weft-tmp", .{path});
    defer gpa.free(tmp);
    const qtmp = try quote(gpa, tmp);
    defer gpa.free(qtmp);
    const b64 = try gpa.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
    defer gpa.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, bytes);
    var script: std.ArrayList(u8) = .empty;
    defer script.deinit(gpa);
    try appendUpload(gpa, &script, qtmp, b64);
    const mv = try std.fmt.allocPrint(
        gpa,
        "tok=$({s} < {s} | tr -d ' \\t-')\nmv {s} {s} && echo \"weft-ok $tok\"",
        .{ self.hash_cmd, qtmp, qtmp, q },
    );
    defer gpa.free(mv);
    try script.appendSlice(gpa, mv);
    const r = try self.run(gpa, script.items);
    defer gpa.free(r.out);
    if (r.status != 0) return error.Failed;
    return parseOkToken(gpa, r.out);
}

fn parseOkToken(gpa: Allocator, out: []const u8) Error![]u8 {
    const at = std.mem.indexOf(u8, out, "weft-ok ") orelse return error.Shell;
    const rest = out[at + "weft-ok ".len ..];
    const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
    const tok = std.mem.trim(u8, rest[0..end], " \r");
    if (tok.len == 0) return error.Shell;
    return gpa.dupe(u8, tok);
}

/// Directory listing via `ls -la` parsing (tramp's mechanism). Names
/// with spaces survive; symlink targets are dropped (name only).
pub fn list(self: *ShellFs, gpa: Allocator, path: []const u8) Error!Listing {
    const q = try quote(gpa, path);
    defer gpa.free(q);
    const cmd = try std.fmt.allocPrint(gpa, "ls -la {s}", .{q});
    defer gpa.free(cmd);
    const r = try self.run(gpa, cmd);
    errdefer gpa.free(r.out);
    if (r.status != 0) {
        gpa.free(r.out);
        return error.Failed;
    }

    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(gpa);
    var lines = std.mem.splitScalar(u8, r.out, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or std.mem.startsWith(u8, line, "total")) continue;
        // mode links owner group size month day time name...
        var toks = std.mem.tokenizeAny(u8, line, " \t");
        const mode = toks.next() orelse continue;
        var skip: usize = 0;
        var sz: u64 = 0;
        var name_start: usize = 0;
        // size = 5th field; name starts after the 8th.
        while (toks.next()) |tok| {
            skip += 1;
            if (skip == 4) sz = std.fmt.parseInt(u64, tok, 10) catch 0;
            if (skip == 7) {
                name_start = (toks.index);
                break;
            }
        }
        if (skip < 7) continue;
        var name = std.mem.trim(u8, line[name_start..], " \t\r");
        if (mode[0] == 'l') {
            if (std.mem.indexOf(u8, name, " -> ")) |arrow| name = name[0..arrow];
        }
        if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        try entries.append(gpa, .{
            .name = name,
            .kind = switch (mode[0]) {
                '-' => .file,
                'd' => .dir,
                'l' => .link,
                else => .other,
            },
            .size = sz,
        });
    }
    return .{ .entries = try entries.toOwnedSlice(gpa), .bytes = r.out };
}

// ── Tests (local /bin/sh — the same protocol ssh would carry) ───────

const t = std.testing;

fn testEnviron() std.process.Environ {
    // Tests link libc; borrow the process environment so the local sh
    // gets a real PATH (base64 & friends live off the default path
    // under nix).
    return .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
}

test "shellfs: write/read/size/hash round-trip through a local sh" {
    const gpa = t.allocator;
    var tmp_dir = t.tmpDir(.{});
    defer tmp_dir.cleanup();
    var fs = try spawn(gpa, &.{"/bin/sh"}, testEnviron());
    defer fs.deinit();

    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/file.txt", .{tmp_dir.sub_path});
    defer gpa.free(path);

    // Create (guarded on non-existence), then read back.
    gpa.free(try fs.writeGuarded(gpa, path, "hello over the wire\n", null));
    const back = try fs.readAll(gpa, path);
    defer gpa.free(back);
    try t.expectEqualStrings("hello over the wire\n", back);
    try t.expectEqual(@as(u64, 20), try fs.size(gpa, path));

    // Ranged read.
    const range = try fs.readRange(gpa, path, 6, 4);
    defer gpa.free(range);
    try t.expectEqualStrings("over", range);

    // Hash token is stable until content changes.
    const h1 = try fs.hashToken(gpa, path);
    defer gpa.free(h1);
    const h2 = try fs.hashToken(gpa, path);
    defer gpa.free(h2);
    try t.expectEqualStrings(h1, h2);

    // Guarded overwrite with the right token succeeds…
    {
        const wtok = try fs.writeGuarded(gpa, path, "second version\n", h1);
        defer gpa.free(wtok);
        const fresh = try fs.hashToken(gpa, path);
        defer gpa.free(fresh);
        try t.expectEqualStrings(fresh, wtok); // returned token == on-disk content
    }
    const h3 = try fs.hashToken(gpa, path);
    defer gpa.free(h3);
    try t.expect(!std.mem.eql(u8, h1, h3));
    // …and with a stale token refuses without touching the file.
    try t.expectError(error.Stale, fs.writeGuarded(gpa, path, "lost update\n", h1));
    const still = try fs.readAll(gpa, path);
    defer gpa.free(still);
    try t.expectEqualStrings("second version\n", still);
    // Creation guard: the file exists now.
    try t.expectError(error.Stale, fs.writeGuarded(gpa, path, "x", null));
}

test "shellfs: binary-safe content and quoted paths" {
    const gpa = t.allocator;
    var tmp_dir = t.tmpDir(.{});
    defer tmp_dir.cleanup();
    var fs = try spawn(gpa, &.{"/bin/sh"}, testEnviron());
    defer fs.deinit();

    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/it's \"weird\" $name.bin", .{tmp_dir.sub_path});
    defer gpa.free(path);
    var payload: [513]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @truncate(i * 31 + 7);
    gpa.free(try fs.writeGuarded(gpa, path, &payload, null));
    const back = try fs.readAll(gpa, path);
    defer gpa.free(back);
    try t.expectEqualSlices(u8, &payload, back);
}

test "shellfs: list parses names, kinds, sizes" {
    const gpa = t.allocator;
    var tmp_dir = t.tmpDir(.{});
    defer tmp_dir.cleanup();
    var fs = try spawn(gpa, &.{"/bin/sh"}, testEnviron());
    defer fs.deinit();
    const dir = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp_dir.sub_path});
    defer gpa.free(dir);
    const f1 = try std.fmt.allocPrint(gpa, "{s}/plain name.txt", .{dir});
    defer gpa.free(f1);
    gpa.free(try fs.writeGuarded(gpa, f1, "12345", null));
    const mk = try std.fmt.allocPrint(gpa, "mkdir '{s}/subdir'", .{dir});
    defer gpa.free(mk);
    const mk_r = try fs.run(gpa, mk);
    gpa.free(mk_r.out);
    try t.expectEqual(@as(u8, 0), mk_r.status);

    var listing = try fs.list(gpa, dir);
    defer listing.deinit(gpa);
    var saw_file = false;
    var saw_dir = false;
    for (listing.entries) |e| {
        if (std.mem.eql(u8, e.name, "plain name.txt")) {
            saw_file = true;
            try t.expectEqual(Kind.file, e.kind);
            try t.expectEqual(@as(u64, 5), e.size);
        }
        if (std.mem.eql(u8, e.name, "subdir")) {
            saw_dir = true;
            try t.expectEqual(Kind.dir, e.kind);
        }
    }
    try t.expect(saw_file);
    try t.expect(saw_dir);
}
