//! Completion UI — the race-and-refine consumer over `edit/completion`.
//! Written against the capability name only: it fires a session at
//! whatever providers matched, opens the pick immediately (instant-tier
//! results usually land inside the same frame), and refreshes the item
//! set as slower providers arrive. A dead provider degrades the list;
//! nothing here waits. Accepting replaces the word prefix the session
//! was fired with.
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
        const prefix = try ctx.editor().wordPrefix(ctx.gpa);
        defer ctx.gpa.free(prefix);
        const id = try ctx.caps.fire(.completion, &ctx.editor().doc, ctx.editor().backingPath(), .{
            .offset = ctx.editor().cursorOffset(),
            .text = prefix,
        }) orelse return .nil;
        self.session = id;
        self.prefix_len = prefix.len;
        try ctx.pick.open(ctx, "complete", &.{}, .{ .handler = accept, .data = self });
        // Instant-tier providers answered during fire; surface them now.
        _ = try self.tick(ctx);
        return .nil;
    }

    /// Per-frame: fold newly arrived results into the live pick.
    /// Returns true when the UI changed.
    pub fn tick(self: *CompletionUi, ctx: *command.Context) !bool {
        const id = self.session orelse return false;
        const s = ctx.caps.session(id) orelse {
            self.session = null;
            return false;
        };
        if (!ctx.pick.active) {
            // User dismissed the popup; the race is moot.
            ctx.caps.finish(id);
            self.session = null;
            return false;
        }
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
            // Items live in the pick now; the session can go.
            ctx.caps.finish(id);
            self.session = null;
        }
        return changed;
    }

    fn accept(ctx: *command.Context, data: ?*anyopaque, choice: []const u8) anyerror!void {
        const self: *CompletionUi = @ptrCast(@alignCast(data.?));
        const cur = ctx.editor().cursorOffset();
        const start = cur -| self.prefix_len;
        try ctx.editor().doc.replaceAll(ctx.gpa, &.{.{
            .range = .{ .start = start, .end = cur },
            .bytes = choice,
        }});
        try ctx.editor().history.ingest(ctx.gpa, &ctx.editor().doc);
        ctx.editor().history.barrier();
    }
};

test {
    std.testing.refAllDecls(@This());
}
