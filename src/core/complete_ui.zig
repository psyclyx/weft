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
        }, .{ .source = self.source() });
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
            const labels = try ctx.gpa.alloc([]const u8, merged.len);
            defer ctx.gpa.free(labels);
            const notes = try ctx.gpa.alloc([]const u8, merged.len);
            defer {
                for (notes) |n| ctx.gpa.free(n);
                ctx.gpa.free(notes);
            }
            const infos = try ctx.gpa.alloc([]const u8, merged.len);
            defer ctx.gpa.free(infos);
            for (merged, 0..) |it, i| {
                labels[i] = it.text;
                notes[i] = try annotate(ctx.gpa, it);
                infos[i] = it.documentation; // borrowed from the session; refresh dupes
            }
            try pick_mod.refresh(&ctx.head.pick, ctx.gpa, labels, notes, infos);
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

    /// A display-only annotation for a completion row: a short kind tag plus the
    /// provider's detail (a type/signature), e.g. `fn · fn (i32) i32`. Owned by
    /// the caller. The tag is the UI's reading of the LSP `CompletionItemKind`
    /// number — core stores the number, the UI names it.
    fn annotate(gpa: Allocator, it: *const capability.CompletionItem) ![]u8 {
        const tag = kindTag(it.kind);
        if (it.detail.len > 0 and tag.len > 0)
            return std.fmt.allocPrint(gpa, "{s} · {s}", .{ tag, it.detail });
        if (it.detail.len > 0) return gpa.dupe(u8, it.detail);
        return gpa.dupe(u8, tag);
    }

    fn kindTag(kind: u8) []const u8 {
        return switch (kind) {
            2, 3 => "fn", // Method, Function
            4 => "new", // Constructor
            5, 10 => "field", // Field, Property
            6 => "var", // Variable
            7, 22 => "type", // Class, Struct
            8 => "iface", // Interface
            9 => "mod", // Module
            13, 20 => "enum", // Enum, EnumMember
            14 => "kw", // Keyword
            15 => "snip", // Snippet
            21, 12 => "const", // Constant, Value
            25 => "typaram", // TypeParameter
            else => "", // Text/unknown → no tag
        };
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
