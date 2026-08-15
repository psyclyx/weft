//! LSP client — a language server as what it really is here: another
//! mutation-adjacent host the editor talks to, never waits on.
//!
//! Transport: the server is a child process; a reader thread decodes
//! Content-Length frames from its stdout into a lock-free inbox, a
//! writer thread drains a lock-free outbox into its stdin (futex
//! parking, same shape as the task pool). The hot path only ever
//! pushes frames and polls the inbox — `tick` runs once per frame on
//! the main thread and does all protocol work there.
//!
//! Document sync: a `Mirror` (the same old-coordinate feed tree-sitter
//! uses) turns commit-log patches into `didChange` ranges — UTF-16
//! positions computed against the pre-patch shadow, exactly what the
//! protocol demands. Servers that only do full sync get the whole text
//! instead. Diagnostics arrive as UTF-16 ranges and are converted to
//! byte offsets on arrival; completion results open a `pick`;
//! goto-definition moves the cursor (same-file targets).

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const stemma = @import("stemma");
const Document = @import("Document.zig");
const Mirror = @import("mirror.zig");
const command = @import("command.zig");
const task = @import("task.zig");

// ── Framing ─────────────────────────────────────────────────────────

/// Incremental Content-Length frame decoder (pure; fed by the reader
/// thread, unit-tested directly).
pub const Decoder = struct {
    buf: std.ArrayList(u8) = .empty,

    pub const empty: Decoder = .{};

    pub fn deinit(self: *Decoder, gpa: Allocator) void {
        self.buf.deinit(gpa);
    }

    pub fn feed(self: *Decoder, gpa: Allocator, bytes: []const u8) Allocator.Error!void {
        try self.buf.appendSlice(gpa, bytes);
    }

    /// The next complete message body (caller owns), or null.
    pub fn next(self: *Decoder, gpa: Allocator) Allocator.Error!?[]u8 {
        const data = self.buf.items;
        const header_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return null;
        var content_len: ?usize = null;
        var lines = std.mem.splitSequence(u8, data[0..header_end], "\r\n");
        while (lines.next()) |line| {
            const prefix = "Content-Length:";
            if (std.ascii.startsWithIgnoreCase(line, prefix)) {
                const v = std.mem.trim(u8, line[prefix.len..], " \t");
                content_len = std.fmt.parseInt(usize, v, 10) catch null;
            }
        }
        const len = content_len orelse {
            // Malformed header: drop it and resync.
            self.consume(header_end + 4);
            return null;
        };
        const body_start = header_end + 4;
        if (data.len < body_start + len) return null;
        const body = try gpa.dupe(u8, data[body_start..][0..len]);
        self.consume(body_start + len);
        return body;
    }

    fn consume(self: *Decoder, n: usize) void {
        const rest = self.buf.items.len - n;
        std.mem.copyForwards(u8, self.buf.items[0..rest], self.buf.items[n..]);
        self.buf.items.len = rest;
    }
};

// ── Client ──────────────────────────────────────────────────────────

const layers_mod = @import("layers.zig");

const Node = struct {
    next: ?*Node = null,
    bytes: []u8,
};

const SyncKind = enum { none, full, incremental };

pub const Lsp = struct {
    gpa: Allocator,
    threaded: std.Io.Threaded,
    child: std.process.Child,
    reader_thread: ?std.Thread = null,
    writer_thread: ?std.Thread = null,

    inbox: std.atomic.Value(?*Node) = .init(null),
    outbox: std.atomic.Value(?*Node) = .init(null),
    out_wake: std.atomic.Value(u32) = .init(0),
    shutdown: std.atomic.Value(bool) = .init(false),

    uri: []u8,
    mirror: Mirror = .empty,
    version: i64 = 0,
    next_id: i64 = 1,
    pending_completion: ?i64 = null,
    pending_definition: ?i64 = null,
    sync_kind: SyncKind = .full,
    ready: bool = false, // initialize handshake + didOpen done
    /// Diagnostics publish here (a `host`-scoped feed layer claimed by
    /// the host session). Feeds are droppable: no layer, no publish.
    diag_layer: ?*layers_mod.Layer = null,
    diags_changed: bool = false,
    ui_changed: bool = false,

    /// Spawn `argv` as the language server for `path` (`environ`
    /// supplies PATH for resolution). Never blocks on the server: the
    /// handshake completes asynchronously via `tick`.
    pub fn create(gpa: Allocator, argv: []const []const u8, path: []const u8, doc: *const Document, environ: std.process.Environ) !*Lsp {
        const self = try gpa.create(Lsp);
        errdefer gpa.destroy(self);

        var cwd_buf: [512]u8 = undefined;
        const cwd_rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
        const cwd: []const u8 = if (std.os.linux.errno(cwd_rc) == .SUCCESS)
            cwd_buf[0 .. cwd_rc - 1] // drop the NUL
        else
            "/";
        const uri = if (path.len > 0 and path[0] == '/')
            try std.fmt.allocPrint(gpa, "file://{s}", .{path})
        else
            try std.fmt.allocPrint(gpa, "file://{s}/{s}", .{ cwd, path });
        errdefer gpa.free(uri);

        self.* = .{
            .gpa = gpa,
            .threaded = .init(gpa, .{ .environ = environ }),
            .child = undefined,
            .uri = uri,
        };
        const io = self.threaded.io();
        self.child = try std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        errdefer {
            self.child.kill(io);
            _ = self.child.wait(io) catch {};
        }

        // Adopt the current text; didOpen sends the shadow later.
        self.mirror.rope = doc.text().snapshot();
        self.mirror.cursor = doc.commitCount();

        try self.request("initialize", self.next_id,
            \\{"processId":null,"rootUri":null,"capabilities":{"textDocument":{"synchronization":{},"completion":{"completionItem":{"snippetSupport":false}},"publishDiagnostics":{}}}}
        );
        self.next_id += 1;

        self.reader_thread = try std.Thread.spawn(.{}, readerMain, .{self});
        self.writer_thread = try std.Thread.spawn(.{}, writerMain, .{self});
        return self;
    }

    pub fn destroy(self: *Lsp) void {
        task.assertMayBlock();
        const gpa = self.gpa;
        const io = self.threaded.io();
        self.shutdown.store(true, .release);
        // Unblock the writer, then the reader (closing its pipe).
        _ = self.out_wake.fetchAdd(1, .release);
        futexWake(&self.out_wake, std.math.maxInt(i32));
        self.child.kill(io);
        if (self.reader_thread) |t_| t_.join();
        if (self.writer_thread) |t_| t_.join();
        _ = self.child.wait(io) catch {};
        freeList(gpa, self.inbox.swap(null, .acquire));
        freeList(gpa, self.outbox.swap(null, .acquire));
        self.mirror.deinit(gpa);
        gpa.free(self.uri);
        self.threaded.deinit();
        gpa.destroy(self);
    }

    pub fn attachDiagnostics(self: *Lsp, layer: *layers_mod.Layer) void {
        self.diag_layer = layer;
    }

    // ── Outgoing ────────────────────────────────────────────────

    fn send(self: *Lsp, body: []u8) void {
        const node = self.gpa.create(Node) catch {
            self.gpa.free(body);
            return;
        };
        node.* = .{ .bytes = body };
        var head = self.outbox.load(.monotonic);
        while (true) {
            node.next = head;
            head = self.outbox.cmpxchgWeak(head, node, .release, .monotonic) orelse break;
        }
        _ = self.out_wake.fetchAdd(1, .release);
        futexWake(&self.out_wake, 1);
    }

    fn request(self: *Lsp, method: []const u8, id: i64, params: []const u8) !void {
        const body = try std.fmt.allocPrint(
            self.gpa,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}",
            .{ id, method, params },
        );
        self.send(body);
    }

    fn notify(self: *Lsp, method: []const u8, params: []const u8) !void {
        const body = try std.fmt.allocPrint(
            self.gpa,
            "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}",
            .{ method, params },
        );
        self.send(body);
    }

    // ── Frame-loop driver ───────────────────────────────────────

    /// Poll the server: fold arrived messages into state (may open a
    /// pick, move the cursor), then push document changes. Returns
    /// true when anything user-visible changed (the view rebuilds).
    pub fn tick(self: *Lsp, ctx: *command.Context) !bool {
        self.diags_changed = false;
        self.ui_changed = false;
        var list = self.inbox.swap(null, .acquire);
        // Reverse to arrival order.
        var fifo: ?*Node = null;
        while (list) |n| {
            list = n.next;
            n.next = fifo;
            fifo = n;
        }
        while (fifo) |n| {
            fifo = n.next;
            defer self.gpa.destroy(n);
            defer self.gpa.free(n.bytes);
            self.handle(ctx, n.bytes) catch |err| {
                std.log.warn("lsp: message handling failed: {t}", .{err});
            };
        }
        if (self.ready) try self.pushChanges(ctx.document());
        return self.diags_changed or self.ui_changed;
    }

    fn handle(self: *Lsp, ctx: *command.Context, bytes: []const u8) !void {
        const gpa = self.gpa;
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{});
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) return;
        const obj = root.object;

        if (obj.get("method")) |m| {
            if (m == .string and std.mem.eql(u8, m.string, "textDocument/publishDiagnostics")) {
                try self.onDiagnostics(ctx.document(), obj.get("params"));
            }
            // Server-to-client requests are unanswered (none needed
            // for this feature set); other notifications ignored.
            return;
        }

        const id = obj.get("id") orelse return;
        if (id != .integer) return;
        if (id.integer == 1) {
            try self.onInitialized(obj.get("result"));
        } else if (self.pending_completion != null and id.integer == self.pending_completion.?) {
            self.pending_completion = null;
            try self.onCompletion(ctx, obj.get("result"));
        } else if (self.pending_definition != null and id.integer == self.pending_definition.?) {
            self.pending_definition = null;
            try self.onDefinition(ctx, obj.get("result"));
        }
    }

    fn onInitialized(self: *Lsp, result: ?std.json.Value) !void {
        self.sync_kind = .full;
        if (result) |r| if (r == .object) {
            if (r.object.get("capabilities")) |caps| if (caps == .object) {
                if (caps.object.get("textDocumentSync")) |s| {
                    const kind: i64 = switch (s) {
                        .integer => |i| i,
                        .object => |o| if (o.get("change")) |ch|
                            (if (ch == .integer) ch.integer else 1)
                        else
                            1,
                        else => 1,
                    };
                    self.sync_kind = switch (kind) {
                        0 => .none,
                        2 => .incremental,
                        else => .full,
                    };
                }
            };
        };
        try self.notify("initialized", "{}");

        // didOpen with the shadow's text (the mirror is exactly at the
        // state the server will now track).
        const text = try self.mirror.rope.toOwnedSlice(self.gpa);
        defer self.gpa.free(text);
        const params = try std.fmt.allocPrint(
            self.gpa,
            "{{\"textDocument\":{{\"uri\":\"{s}\",\"languageId\":\"zig\",\"version\":{d},\"text\":{f}}}}}",
            .{ self.uri, self.version, std.json.fmt(text, .{}) },
        );
        defer self.gpa.free(params);
        try self.notify("textDocument/didOpen", params);
        self.ready = true;
    }

    // ── didChange ───────────────────────────────────────────────

    const ChangeSink = struct {
        lsp: *Lsp,
        json: std.ArrayList(u8) = .empty,

        fn cb(sink: *ChangeSink, shadow: *const stemma.Rope, p: Document.Patch, inserted: []const u8) anyerror!void {
            const gpa = sink.lsp.gpa;
            if (sink.lsp.sync_kind != .incremental) return;
            const s = shadow.offsetToPointUtf16(p.offset);
            const e = shadow.offsetToPointUtf16(p.offset + p.removed);
            const w = try std.fmt.allocPrint(
                gpa,
                "{s}{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"text\":{f}}}",
                .{
                    if (sink.json.items.len == 0) "" else ",",
                    s.row,
                    s.col,
                    e.row,
                    e.col,
                    std.json.fmt(inserted, .{}),
                },
            );
            defer gpa.free(w);
            try sink.json.appendSlice(gpa, w);
        }
    };

    fn pushChanges(self: *Lsp, doc: *const Document) !void {
        if (self.mirror.cursor >= doc.commitCount()) return;
        var sink: ChangeSink = .{ .lsp = self };
        defer sink.json.deinit(self.gpa);
        _ = try self.mirror.drain(self.gpa, doc, &sink, ChangeSink.cb);
        self.version += 1;

        const changes = switch (self.sync_kind) {
            .none => return,
            .incremental => try self.gpa.dupe(u8, sink.json.items),
            .full => blk: {
                const text = try self.mirror.rope.toOwnedSlice(self.gpa);
                defer self.gpa.free(text);
                break :blk try std.fmt.allocPrint(self.gpa, "{{\"text\":{f}}}", .{std.json.fmt(text, .{})});
            },
        };
        defer self.gpa.free(changes);
        const params = try std.fmt.allocPrint(
            self.gpa,
            "{{\"textDocument\":{{\"uri\":\"{s}\",\"version\":{d}}},\"contentChanges\":[{s}]}}",
            .{ self.uri, self.version, changes },
        );
        defer self.gpa.free(params);
        try self.notify("textDocument/didChange", params);
    }

    // ── Incoming features ───────────────────────────────────────

    const SpanIn = layers_mod.SpanIn;

    fn onDiagnostics(self: *Lsp, doc: *const Document, params: ?std.json.Value) !void {
        const gpa = self.gpa;
        const layer = self.diag_layer orelse return; // feed dropped
        const p = params orelse return;
        if (p != .object) return;
        // Only our document.
        if (p.object.get("uri")) |u| {
            if (u != .string or !std.mem.eql(u8, u.string, self.uri)) return;
        }
        self.diags_changed = true;
        var spans: std.ArrayList(SpanIn) = .empty;
        defer spans.deinit(gpa);
        blk: {
            const list = p.object.get("diagnostics") orelse break :blk;
            if (list != .array) break :blk;
            const rope = doc.text();
            for (list.array.items) |item| {
                if (item != .object) continue;
                const range = item.object.get("range") orelse continue;
                const msg = item.object.get("message") orelse continue;
                const sev: u8 = if (item.object.get("severity")) |s|
                    (if (s == .integer) @intCast(std.math.clamp(s.integer, 1, 4)) else 1)
                else
                    1;
                if (range != .object or msg != .string) continue;
                const start = positionToOffset(rope, range.object.get("start")) orelse continue;
                const end = positionToOffset(rope, range.object.get("end")) orelse start;
                try spans.append(gpa, .{
                    .start = start,
                    .end = @max(start, end),
                    .kind = sev,
                    .message = msg.string,
                });
            }
        }
        try layer.publishSpans(gpa, spans.items);
    }

    fn onCompletion(self: *Lsp, ctx: *command.Context, result: ?std.json.Value) !void {
        const gpa = ctx.gpa;
        const r = result orelse return;
        const items = switch (r) {
            .array => |a| a.items,
            .object => |o| blk: {
                const it = o.get("items") orelse return;
                if (it != .array) return;
                break :blk it.array.items;
            },
            else => return,
        };
        var labels: std.ArrayList([]const u8) = .empty;
        defer labels.deinit(gpa);
        for (items) |item| {
            if (item != .object) continue;
            // Prefer insertText; fall back to label.
            const text = item.object.get("insertText") orelse item.object.get("label") orelse continue;
            if (text != .string or text.string.len == 0) continue;
            try labels.append(gpa, text.string);
            if (labels.items.len >= 200) break;
        }
        if (labels.items.len == 0) return;
        try ctx.pick.open(ctx, "complete", labels.items, .{ .handler = insertChoice });
        self.ui_changed = true;
    }

    fn insertChoice(ctx: *command.Context, data: ?*anyopaque, choice: []const u8) anyerror!void {
        _ = data;
        try ctx.editor.insertText(ctx.gpa, choice);
    }

    fn onDefinition(self: *Lsp, ctx: *command.Context, result: ?std.json.Value) !void {
        const r = result orelse return;
        const loc = switch (r) {
            .object => r,
            .array => |a| if (a.items.len > 0) a.items[0] else return,
            else => return,
        };
        if (loc != .object) return;
        const uri = loc.object.get("uri") orelse loc.object.get("targetUri") orelse return;
        if (uri != .string) return;
        if (!std.mem.eql(u8, uri.string, self.uri)) {
            std.log.info("lsp: definition in another file: {s}", .{uri.string});
            return;
        }
        const range = loc.object.get("range") orelse loc.object.get("targetSelectionRange") orelse return;
        if (range != .object) return;
        const off = positionToOffset(ctx.document().text(), range.object.get("start")) orelse return;
        ctx.editor.doc.anchors.set(ctx.editor.cursor, .{ .offset = off, .bias = .right });
        ctx.editor.history.barrier();
        self.ui_changed = true;
    }

    fn positionToOffset(rope: *const stemma.Rope, pos: ?std.json.Value) ?usize {
        const p = pos orelse return null;
        if (p != .object) return null;
        const line = p.object.get("line") orelse return null;
        const ch = p.object.get("character") orelse return null;
        if (line != .integer or ch != .integer) return null;
        const rows = rope.lineCount();
        const row: usize = @intCast(@max(0, line.integer));
        if (row >= rows) return rope.byteLen();
        // Clamp the UTF-16 column into the line.
        const line_range = rope.lineRange(row);
        const line_end_u16 = rope.offsetToPointUtf16(line_range.end);
        const col: usize = @min(@as(usize, @intCast(@max(0, ch.integer))), line_end_u16.col);
        return rope.pointUtf16ToOffset(.{ .row = row, .col = col });
    }

    // ── Requests the user triggers ──────────────────────────────

    pub fn requestCompletion(self: *Lsp, doc: *const Document, cursor_offset: usize) !void {
        if (!self.ready or self.pending_completion != null) return;
        const p = doc.text().offsetToPointUtf16(cursor_offset);
        const id = self.next_id;
        self.next_id += 1;
        self.pending_completion = id;
        const params = try std.fmt.allocPrint(
            self.gpa,
            "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
            .{ self.uri, p.row, p.col },
        );
        defer self.gpa.free(params);
        try self.request("textDocument/completion", id, params);
    }

    pub fn requestDefinition(self: *Lsp, doc: *const Document, cursor_offset: usize) !void {
        if (!self.ready or self.pending_definition != null) return;
        const p = doc.text().offsetToPointUtf16(cursor_offset);
        const id = self.next_id;
        self.next_id += 1;
        self.pending_definition = id;
        const params = try std.fmt.allocPrint(
            self.gpa,
            "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
            .{ self.uri, p.row, p.col },
        );
        defer self.gpa.free(params);
        try self.request("textDocument/definition", id, params);
    }

    // ── Transport threads ───────────────────────────────────────

    fn readerMain(self: *Lsp) void {
        const io = self.threaded.io();
        const stdout = self.child.stdout.?;
        var decoder: Decoder = .empty;
        defer decoder.deinit(self.gpa);
        var buf: [16384]u8 = undefined;
        while (!self.shutdown.load(.acquire)) {
            const n = stdout.readStreaming(io, &.{&buf}) catch break;
            if (n == 0) break;
            decoder.feed(self.gpa, buf[0..n]) catch break;
            while (decoder.next(self.gpa) catch break) |body| {
                const node = self.gpa.create(Node) catch {
                    self.gpa.free(body);
                    break;
                };
                node.* = .{ .bytes = body };
                var head = self.inbox.load(.monotonic);
                while (true) {
                    node.next = head;
                    head = self.inbox.cmpxchgWeak(head, node, .release, .monotonic) orelse break;
                }
            }
        }
    }

    fn writerMain(self: *Lsp) void {
        const io = self.threaded.io();
        const stdin = self.child.stdin.?;
        while (true) {
            const gen = self.out_wake.load(.acquire);
            if (self.outbox.swap(null, .acquire)) |head| {
                // Reverse to submission order, then write.
                var fifo: ?*Node = null;
                var cur: ?*Node = head;
                while (cur) |n| {
                    cur = n.next;
                    n.next = fifo;
                    fifo = n;
                }
                while (fifo) |n| {
                    fifo = n.next;
                    var hdr_buf: [64]u8 = undefined;
                    const hdr = std.fmt.bufPrint(&hdr_buf, "Content-Length: {d}\r\n\r\n", .{n.bytes.len}) catch unreachable;
                    stdin.writeStreamingAll(io, hdr) catch {};
                    stdin.writeStreamingAll(io, n.bytes) catch {};
                    self.gpa.free(n.bytes);
                    self.gpa.destroy(n);
                }
                continue;
            }
            if (self.shutdown.load(.acquire)) return;
            futexWait(&self.out_wake, gen);
        }
    }
};

fn freeList(gpa: Allocator, head: ?*Node) void {
    var cur = head;
    while (cur) |n| {
        cur = n.next;
        gpa.free(n.bytes);
        gpa.destroy(n);
    }
}

// Same raw-futex helpers as task.zig (see the signedness note there).
const linux = std.os.linux;

fn futexWait(word: *const std.atomic.Value(u32), expected: u32) void {
    _ = linux.futex_4arg(&word.raw, .{ .cmd = .WAIT, .private = true }, expected, null);
}

fn futexWake(word: *const std.atomic.Value(u32), max_waiters: i32) void {
    _ = linux.futex_3arg(&word.raw, .{ .cmd = .WAKE, .private = true }, @intCast(max_waiters));
}

// ── Commands ────────────────────────────────────────────────────────

pub fn completeCommand(self: *Lsp) command.Command {
    return .{
        .name = "complete",
        .summary = "Request completions at the cursor (LSP).",
        .args = &.{},
        .handler = completeHandler,
        .data = self,
    };
}

fn completeHandler(ctx: *command.Context, data: ?*anyopaque, args: []const command.Value) anyerror!command.Value {
    _ = args;
    const self: *Lsp = @ptrCast(@alignCast(data.?));
    try self.requestCompletion(&ctx.editor.doc, ctx.editor.cursorOffset());
    return .nil;
}

pub fn definitionCommand(self: *Lsp) command.Command {
    return .{
        .name = "goto-definition",
        .summary = "Jump to the definition under the cursor (LSP).",
        .args = &.{},
        .handler = definitionHandler,
        .data = self,
    };
}

fn definitionHandler(ctx: *command.Context, data: ?*anyopaque, args: []const command.Value) anyerror!command.Value {
    _ = args;
    const self: *Lsp = @ptrCast(@alignCast(data.?));
    try self.requestDefinition(&ctx.editor.doc, ctx.editor.cursorOffset());
    return .nil;
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "decoder: split frames, coalesced frames, malformed resync" {
    const gpa = t.allocator;
    var d: Decoder = .empty;
    defer d.deinit(gpa);

    try d.feed(gpa, "Content-Length: 5\r\n\r\nhel");
    try t.expectEqual(@as(?[]u8, null), try d.next(gpa));
    try d.feed(gpa, "loContent-Length: 2\r\nX-Other: y\r\n\r\nok");
    const a = (try d.next(gpa)).?;
    defer gpa.free(a);
    try t.expectEqualStrings("hello", a);
    const b = (try d.next(gpa)).?;
    defer gpa.free(b);
    try t.expectEqualStrings("ok", b);
    try t.expectEqual(@as(?[]u8, null), try d.next(gpa));

    // Malformed header: dropped, stream resyncs on the next frame.
    try d.feed(gpa, "Garbage: 1\r\n\r\nContent-Length: 3\r\n\r\nyes");
    try t.expectEqual(@as(?[]u8, null), try d.next(gpa));
    const c_ = (try d.next(gpa)).?;
    defer gpa.free(c_);
    try t.expectEqualStrings("yes", c_);
}

test {
    std.testing.refAllDecls(@This());
}
