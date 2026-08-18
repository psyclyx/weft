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
const pick_mod = @import("pick.zig");
const task = @import("task.zig");

pub const CompletionUi = struct {
    session: ?u64 = null,
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
        const prefix = try ctx.editor().wordPrefix(ctx.gpa);
        defer ctx.gpa.free(prefix);
        const id = try ctx.caps.fire(.completion, &ctx.editor().doc, ctx.editor().backingPath(), .{
            .offset = ctx.editor().cursorOffset(),
            .text = prefix,
        }) orelse return .nil;
        errdefer ctx.caps.finish(id);
        const plen = prefix.len;
        // Open with the source BEFORE recording the session, so a failed
        // open (which closes the source) sees session == null and the
        // errdefer above is the sole owner that finishes it.
        try ctx.pick.openWith(ctx, "complete", &.{}, .{
            .handler = accept,
            .data = self,
        }, .{ .source = self.source() });
        self.session = id;
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
            const labels = try ctx.gpa.alloc([]const u8, merged.len);
            defer ctx.gpa.free(labels);
            for (merged, 0..) |it, i| labels[i] = it.text;
            try pick_mod.refresh(ctx.pick, ctx.gpa, labels);
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

    fn accept(ctx: *command.Context, data: ?*anyopaque, choice: []const u8) anyerror!void {
        const self: *CompletionUi = @ptrCast(@alignCast(data.?));
        const cur = ctx.editor().cursorOffset();
        const start = cur -| self.prefix_len;
        // The one edit door: authored by the invoking principal and grade
        // -gated (a view peer's accept is refused, leaving no ghost). The
        // user path owns undo ingest, so we only mark the unit boundary.
        ctx.edit(.{ .start = start, .end = cur }, choice) catch |e| {
            if (e == error.Unauthorized) return;
            return e;
        };
        // Completion is its own undo unit — the next typing starts fresh.
        ctx.editor().history.barrier();
    }
};

test {
    std.testing.refAllDecls(@This());
}
