//! Completion UI — the race-and-refine consumer over `edit/completion`.
//! Written against the capability name only: it fires a session at
//! whatever providers matched, opens the pick immediately (instant-tier
//! results usually land inside the same frame), and refreshes the item
//! set as slower providers arrive. A dead provider degrades the list;
//! nothing here waits. Accepting replaces the word prefix the session
//! was fired with.
//!
//! The refresh is a `pick.Source`: the picker's own per-frame `tick`
//! folds new results in and closing the pick cancels the caps session —
//! one drive loop, no bespoke tick call in the frame loop.
//!
//! Stale policy (declared): completion items are plain text — if peer
//! commits land while the popup is open, accepted text still inserts at
//! the *current* cursor, which is the only honest interpretation; range
//! -carrying capabilities go through stamped-range rebase instead.

const std = @import("std");
const Allocator = std.mem.Allocator;

const command = @import("command.zig");
const capability = @import("capability.zig");
const Buffers = @import("Buffers.zig");
const pick_mod = @import("pick.zig");
const task = @import("task.zig");

pub const CompletionUi = struct {
    session: ?u64 = null,
    /// Buffer identity the capability request and prefix belong to. Completion
    /// follows concurrent edits within this buffer, but never ambient focus to
    /// another buffer (or a replacement which reused its slot).
    buffer: ?Buffers.Ref = null,
    prefix_len: usize = 0,
    /// Stashed at fire time so the source's `close` (which gets no ctx)
    /// can cancel the session when the pick is dismissed.
    caps: ?*capability.Caps = null,

    pub const empty: CompletionUi = .{};

    pub fn commandSpec(self: *CompletionUi) command.Command {
        return .{
            .name = "complete",
            .summary = "Completion at the cursor (all providers, race-and-refine).",
            .args = &.{},
            .handler = fireHandler,
            .data = self,
        };
    }

    fn fireHandler(ctx: *command.Context, data: ?*anyopaque, args: []const command.Value) anyerror!command.Value {
        _ = args;
        const self: *CompletionUi = @ptrCast(@alignCast(data.?));
        if (self.session) |old| {
            ctx.caps.finish(old);
            self.session = null;
        }
        self.caps = ctx.caps;
        const buffer = ctx.buffer();
        const editor = buffer.textEditor() orelse return .nil;
        const prefix = try editor.wordPrefix(ctx.gpa);
        defer ctx.gpa.free(prefix);
        const id = try ctx.fireRace(.completion, &editor.doc, editor.backingPath(), .{
            .offset = editor.cursorOffset(),
            .text = prefix,
        }) orelse return .nil;
        errdefer ctx.caps.finish(id);
        const plen = prefix.len;
        // Open with the source BEFORE recording the session, so a failed
        // open (which closes the source) sees session == null and the
        // errdefer above is the sole owner that finishes it.
        try ctx.head.pick.openWith(ctx, "complete", &.{}, .{
            .handler = accept,
            .data = self,
        }, .{ .source = self.source(), .category = "complete" });
        // Draw the completion list as a popup AT the caret, not the bottom dock.
        ctx.head.pick.caret_anchor = editor.cursorOffset();
        self.session = id;
        self.buffer = buffer.ref();
        self.prefix_len = plen;
        // Surface instant-tier results (they answered during fire) now.
        _ = try poll(self, ctx);
        return .nil;
    }

    pub fn source(self: *CompletionUi) pick_mod.Source {
        return .{ .data = self, .poll = poll, .close = close };
    }

    /// Per-frame: fold newly arrived results into the live pick; finish
    /// the session once every provider has answered (or timed out).
    fn poll(data: ?*anyopaque, ctx: *command.Context) anyerror!bool {
        const self: *CompletionUi = @ptrCast(@alignCast(data.?));
        const target = self.buffer orelse {
            try ctx.head.pick.dismiss(ctx);
            return true;
        };
        const buffer = ctx.buffers.resolve(target) orelse {
            try ctx.head.pick.dismiss(ctx);
            return true;
        };
        if (buffer != ctx.buffer()) {
            try ctx.head.pick.dismiss(ctx);
            return true;
        }
        const id = self.session orelse return false;
        const s = ctx.caps.session(id) orelse {
            self.session = null;
            return false;
        };
        const fresh = s.poll();
        var changed = false;
        if (fresh.len > 0) {
            const merged = try ctx.caps.mergedCompletion(ctx.gpa, id);
            defer ctx.gpa.free(merged);
            const entries = try ctx.gpa.alloc(pick_mod.Entry, merged.len);
            defer ctx.gpa.free(entries);
            const infos = try ctx.gpa.alloc([]const u8, merged.len);
            defer ctx.gpa.free(infos);
            for (merged, 0..) |it, i| {
                entries[i] = .{
                    .text = it.text,
                    // The PROVIDER's own affixation — a type or signature it
                    // chose to attach. Not a rendering of anything; core adds
                    // nothing to it (see this file's module doc).
                    .doc = it.detail,
                    // The row's public key is its `CompletionItemKind`
                    // number, so an annotator that understands that number
                    // space can name it. Core carries the digits and reads
                    // nothing into them.
                    .key = kindKey(it.kind),
                };
                infos[i] = it.documentation; // borrowed from the session; refresh dupes
            }
            try pick_mod.refresh(&ctx.head.pick, ctx.gpa, entries, infos);
            changed = true;
        }
        if (s.done(task.nowNs())) {
            ctx.caps.finish(id);
            self.session = null;
        }
        return changed;
    }

    /// The pick closed (accepted or dismissed): the race is moot, drop
    /// the session. No ctx here, so cancel through the stashed caps.
    fn close(data: ?*anyopaque, gpa: Allocator) void {
        _ = gpa;
        const self: *CompletionUi = @ptrCast(@alignCast(data.?));
        if (self.session) |id| {
            if (self.caps) |caps| caps.finish(id);
            self.session = null;
        }
    }

    /// The decimal spelling of a completion item's kind, as its row KEY.
    ///
    /// This is all that remains of what used to be `kindTag` — a switch in
    /// core that turned LSP's `CompletionItemKind` numbers into `"fn"`,
    /// `"var"`, `"kw"`. That was an annotator, it understood a protocol's
    /// number space, and it lived in core. It is now the `lsp` plugin's, which
    /// is where that number space is already understood; core carries the
    /// digits across and reads nothing into them.
    ///
    /// A static table rather than a format call: this runs per item per
    /// refresh, and a refresh happens every time a provider answers.
    /// Two digits is enough — `CompletionItemKind` is 1..25 and has been for
    /// the life of the protocol; anything outside it keys as `"0"`, which an
    /// annotator reads as "unknown" exactly like kind 0 itself.
    const kind_digits = "0123456789";
    var kind_key_bytes: [100 * 2]u8 = undefined;
    var kind_keys: [100][]const u8 = undefined;
    var kind_keys_ready = false;

    fn kindKey(kind: u8) []const u8 {
        if (!kind_keys_ready) {
            for (&kind_keys, 0..) |*s, i| {
                const tens = i / 10;
                const ones = i % 10;
                kind_key_bytes[i * 2] = kind_digits[tens];
                kind_key_bytes[i * 2 + 1] = kind_digits[ones];
                s.* = if (tens == 0)
                    kind_key_bytes[i * 2 + 1 .. i * 2 + 2]
                else
                    kind_key_bytes[i * 2 .. i * 2 + 2];
            }
            kind_keys_ready = true;
        }
        return kind_keys[if (kind < kind_keys.len) kind else 0];
    }

    fn accept(ctx: *command.Context, data: ?*anyopaque, outcome: pick_mod.Outcome) anyerror!void {
        const choice = switch (outcome) {
            .cancelled => return,
            .candidate => |candidate| candidate.text,
            .input => |input| input,
        };
        const self: *CompletionUi = @ptrCast(@alignCast(data.?));
        const target = self.buffer orelse return;
        const buffer = ctx.buffers.resolve(target) orelse return;
        if (buffer != ctx.buffer()) return;
        const editor = buffer.textEditor() orelse return;
        const cur = editor.cursorOffset();
        const start = cur -| self.prefix_len;
        // The one edit door: authored by the invoking principal and grade
        // -gated (a view peer's accept is refused, leaving no ghost). The
        // user path owns undo ingest, so we only mark the unit boundary.
        ctx.edit(.{ .start = start, .end = cur }, choice) catch |e| {
            if (e == error.Unauthorized) return;
            return e;
        };
        // Completion is its own undo unit — the next typing starts fresh.
        editor.history.barrier();
    }
};

test {
    std.testing.refAllDecls(@This());
}
